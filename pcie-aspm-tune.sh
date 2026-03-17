#!/usr/bin/env bash

set -u

SCRIPT_PATH="$(readlink -f "$0")"
SERVICE_NAME="pcie-aspm-tune.service"
INSTALLED_SCRIPT_PATH="/usr/local/sbin/pcie-aspm-tune.sh"
SUSPEND_GUARD_SCRIPT_NAME="pcie-aspm-suspend-guard.sh"
SUSPEND_HOOK_NAME="pcie-aspm-suspend-hook"
RESUME_RESTORE_SCRIPT_NAME="pcie-aspm-resume-restore.sh"
RESUME_RESTORE_SERVICE_NAME="pcie-aspm-resume-restore.service"
WORK_DIR=""
SKIP_SERVICE_PROMPT="${ASPM_TOOL_SKIP_SERVICE_PROMPT:-0}"

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
BLUE="$(printf '\033[34m')"
CYAN="$(printf '\033[36m')"
RESET="$(printf '\033[0m')"

SCAN_TOTAL=0
PCIE_TOTAL=0
SUPPORTED_TOTAL=0
CHANGED_TOTAL=0
ALREADY_TOTAL=0
FAILED_TOTAL=0
UNSUPPORTED_TOTAL=0
SKIPPED_TOTAL=0

declare -a BEFORE_ASPM_REPORT=()
declare -a AFTER_ASPM_REPORT=()
declare -a RECOVERY_DEVICES=()
declare -a RECOVERY_GUARD_DEVICES=()
declare -A PROTECTED_DEVICES=()

log() {
	printf '%b\n' "$*"
}

info() {
	log "${BLUE}==>${RESET} $*"
}

success() {
	log "${GREEN}==>${RESET} $*"
}

warn() {
	log "${YELLOW}==>${RESET} $*"
}

fail() {
	log "${RED}==>${RESET} $*" >&2
}

cleanup() {
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		rm -rf "$WORK_DIR"
	fi
}

trap cleanup EXIT

require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		fail "This script must be run as root."
		exit 1
	fi
}

set_stable_locale() {
	export LC_ALL=C
	export LANG=C
}

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

detect_package_manager() {
	local manager

	for manager in apt-get dnf yum zypper pacman; do
		if command_exists "$manager"; then
			printf '%s\n' "$manager"
			return 0
		fi
	done

	return 1
}

install_packages() {
	local manager="$1"
	shift

	case "$manager" in
	apt-get)
		apt-get update
		apt-get install -y "$@"
		;;
	dnf)
		dnf install -y "$@"
		;;
	yum)
		yum install -y "$@"
		;;
	zypper)
		zypper --non-interactive install "$@"
		;;
	pacman)
		pacman -Sy --noconfirm "$@"
		;;
	*)
		return 1
		;;
	esac
}

ensure_dependencies() {
	local manager package

	manager="$(detect_package_manager || true)"

	for package in lspci setpci; do
		if ! command_exists "$package"; then
			if [[ -z "$manager" ]]; then
				fail "Neither '$package' nor a supported package manager was found."
				exit 1
			fi

			info "Installing missing PCI utilities via $manager."

			install_packages "$manager" pciutils
			break
		fi
	done

	if ! command_exists powertop; then
		if [[ -z "$manager" ]]; then
			fail "'powertop' is missing and no supported package manager was found."
			exit 1
		fi

		info "Installing powertop via $manager."
		install_packages "$manager" powertop
	fi

	for package in lspci setpci powertop; do
		if ! command_exists "$package"; then
			fail "Dependency '$package' could not be provided."
			exit 1
		fi
	done
}

make_work_dir() {
	WORK_DIR="$(mktemp -d /tmp/aspm-powertop.XXXXXX)"
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s\n' "$value"
}

get_pcie_devices() {
	lspci -D | awk '{print $1}'
}

get_lspci_description() {
	lspci -D -s "$1"
}

get_sysfs_device_path() {
	local device="$1"
	readlink -f "/sys/bus/pci/devices/${device}"
}

get_device_vendor_id() {
	local device="$1"
	local vendor_file="/sys/bus/pci/devices/${device}/vendor"

	if [[ -r "$vendor_file" ]]; then
		cat "$vendor_file"
	fi
}

get_device_class_id() {
	local device="$1"
	local class_file="/sys/bus/pci/devices/${device}/class"

	if [[ -r "$class_file" ]]; then
		cat "$class_file"
	fi
}

get_device_driver_name() {
	local device="$1"
	local driver_link="/sys/bus/pci/devices/${device}/driver"

	if [[ -L "$driver_link" ]]; then
		basename "$(readlink -f "$driver_link")"
	fi
}

device_is_broadcom_wireless_or_bt() {
	local device="$1"
	local vendor_id class_id

	vendor_id="$(get_device_vendor_id "$device")"
	class_id="$(get_device_class_id "$device")"

	if [[ "$vendor_id" != "0x14e4" ]]; then
		return 1
	fi

	case "$class_id" in
	0x028000 | 0x028001 | 0x0d1100)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

protect_device_chain() {
	local device="$1"
	local sysfs_path current base

	sysfs_path="$(get_sysfs_device_path "$device" 2>/dev/null || true)"
	if [[ -z "$sysfs_path" ]]; then
		return 0
	fi

	current="$sysfs_path"
	while [[ "$current" != "/" && "$current" == *"/"* ]]; do
		base="$(basename "$current")"
		if [[ "$base" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
			PROTECTED_DEVICES["$base"]=1
		fi
		current="$(dirname "$current")"
	done
}

add_recovery_guard_chain() {
	local device="$1"
	local sysfs_path current base existing existing_device

	sysfs_path="$(get_sysfs_device_path "$device" 2>/dev/null || true)"
	if [[ -z "$sysfs_path" ]]; then
		return 0
	fi

	current="$sysfs_path"
	while [[ "$current" != "/" && "$current" == *"/"* ]]; do
		base="$(basename "$current")"
		if [[ "$base" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]]; then
			existing=0
			for existing_device in "${RECOVERY_GUARD_DEVICES[@]}"; do
				if [[ "$existing_device" == "$base" ]]; then
					existing=1
					break
				fi
			done
			if [[ "$existing" -eq 0 ]]; then
				RECOVERY_GUARD_DEVICES+=("$base")
			fi
		fi
		current="$(dirname "$current")"
	done
}

build_protected_device_map() {
	local device vendor_id protected_count=0

	info "Detecting Apple/T2 PCIe subtrees."
	PROTECTED_DEVICES=()

	while IFS= read -r device; do
		vendor_id="$(get_device_vendor_id "$device")"
		if [[ "$vendor_id" == "0x106b" ]]; then
			protect_device_chain "$device"
		fi
	done < <(get_pcie_devices)

	for device in "${!PROTECTED_DEVICES[@]}"; do
		protected_count=$((protected_count + 1))
	done

	if [[ "$protected_count" -gt 0 ]]; then
		warn "Apple/T2-connected PCIe branches will not be modified, to avoid destabilizing the T2 subsystem."
	fi
}

build_recovery_device_list() {
	local device

	info "Detecting Broadcom Wi-Fi/Bluetooth PCI devices."
	RECOVERY_DEVICES=()
	RECOVERY_GUARD_DEVICES=()

	while IFS= read -r device; do
		if device_is_broadcom_wireless_or_bt "$device"; then
			RECOVERY_DEVICES+=("$device")
			add_recovery_guard_chain "$device"
		fi
	done < <(get_pcie_devices)
}

is_protected_device() {
	local device="$1"
	[[ -n "${PROTECTED_DEVICES[$device]:-}" ]]
}

has_pcie_capability() {
	setpci -s "$1" CAP_EXP+0.w >/dev/null 2>&1
}

read_link_capabilities() {
	setpci -s "$1" CAP_EXP+0c.L 2>/dev/null
}

read_link_control() {
	setpci -s "$1" CAP_EXP+10.w 2>/dev/null
}

aspm_bits_to_text() {
	case "$1" in
	0)
		printf '%s\n' "disabled"
		;;
	1)
		printf '%s\n' "L0s"
		;;
	2)
		printf '%s\n' "L1"
		;;
	3)
		printf '%s\n' "L0s+L1"
		;;
	*)
		printf '%s\n' "unknown"
		;;
	esac
}

get_supported_aspm_bits() {
	local link_cap_hex="$1"
	printf '%d\n' $(( (16#${link_cap_hex} >> 10) & 0x3 ))
}

get_current_aspm_bits() {
	local link_ctl_hex="$1"
	printf '%d\n' $(( 16#${link_ctl_hex} & 0x3 ))
}

record_aspm_line() {
	local target="$1"
	local line="$2"

	if [[ "$target" == "before" ]]; then
		BEFORE_ASPM_REPORT+=("$line")
	else
		AFTER_ASPM_REPORT+=("$line")
	fi
}

scan_aspm_state() {
	local phase="$1"
	local device description link_cap_hex link_ctl_hex supported_bits current_bits line

	if [[ "$phase" == "before" ]]; then
		BEFORE_ASPM_REPORT=()
	else
		AFTER_ASPM_REPORT=()
	fi

	while IFS= read -r device; do
		description="$(get_lspci_description "$device")"

		if ! has_pcie_capability "$device"; then
			record_aspm_line "$phase" "$device|skip|$description|not_pcie|not_pcie"
			continue
		fi

		link_cap_hex="$(read_link_capabilities "$device")"
		link_ctl_hex="$(read_link_control "$device")"

		if [[ -z "$link_cap_hex" || -z "$link_ctl_hex" ]]; then
			record_aspm_line "$phase" "$device|skip|$description|unreadable|unreadable"
			continue
		fi

		if is_protected_device "$device"; then
			record_aspm_line "$phase" "$device|state|$description|protected|protected"
			continue
		fi

		supported_bits="$(get_supported_aspm_bits "$link_cap_hex")"
		current_bits="$(get_current_aspm_bits "$link_ctl_hex")"
		line="$device|state|$description|$(aspm_bits_to_text "$supported_bits")|$(aspm_bits_to_text "$current_bits")"
		record_aspm_line "$phase" "$line"
	done < <(get_pcie_devices)
}

print_aspm_snapshot() {
	local title="$1"
	local report_name="$2"
	local -n report_ref="$report_name"
	local entry device status description supported current

	info "$title"

	for entry in "${report_ref[@]}"; do
		IFS='|' read -r device status description supported current <<<"$entry"
		if [[ "$status" != "state" ]]; then
			continue
		fi

		log "  ${CYAN}${device}${RESET} ${description}"
		if [[ "$supported" == "protected" && "$current" == "protected" ]]; then
			log "    policy:    skipped on purpose to protect the Apple/T2 PCIe branch"
		else
			log "    supported: ${supported}"
			log "    current:   ${current}"
		fi
	done
}

enable_supported_aspm() {
	local device description link_cap_hex link_ctl_hex supported_bits current_bits desired_bits verify_hex result_text attempt

	info "Scanning PCIe devices and enabling supported ASPM."

	while IFS= read -r device; do
		SCAN_TOTAL=$((SCAN_TOTAL + 1))
		description="$(get_lspci_description "$device")"

		if ! has_pcie_capability "$device"; then
			SKIPPED_TOTAL=$((SKIPPED_TOTAL + 1))
			continue
		fi

		PCIE_TOTAL=$((PCIE_TOTAL + 1))

		if is_protected_device "$device"; then
			SKIPPED_TOTAL=$((SKIPPED_TOTAL + 1))
			log "  ${YELLOW}[SKIP]${RESET} ${device} ${description}"
			log "    Skipped on purpose: this device sits on the Apple/T2 PCIe branch"
			continue
		fi

		link_cap_hex="$(read_link_capabilities "$device")"
		link_ctl_hex="$(read_link_control "$device")"

		if [[ -z "$link_cap_hex" || -z "$link_ctl_hex" ]]; then
			FAILED_TOTAL=$((FAILED_TOTAL + 1))
			log "  ${RED}[FAIL]${RESET} ${device} ${description}"
			log "    Failed to read Link Capabilities or Link Control."
			continue
		fi

		supported_bits="$(get_supported_aspm_bits "$link_cap_hex")"
		current_bits="$(get_current_aspm_bits "$link_ctl_hex")"

		if [[ "$supported_bits" -eq 0 ]]; then
			UNSUPPORTED_TOTAL=$((UNSUPPORTED_TOTAL + 1))
			log "  ${YELLOW}[SKIP]${RESET} ${device} ${description}"
			log "    ASPM supported: disabled"
			continue
		fi

		SUPPORTED_TOTAL=$((SUPPORTED_TOTAL + 1))
		desired_bits="$supported_bits"

		if [[ "$current_bits" -eq "$desired_bits" ]]; then
			ALREADY_TOTAL=$((ALREADY_TOTAL + 1))
			log "  ${GREEN}[OK]${RESET} ${device} ${description}"
			log "    current already ${desired_bits} ($(aspm_bits_to_text "$desired_bits"))"
			continue
		fi

		if setpci -s "$device" CAP_EXP+10.w="$(printf '%x' "$desired_bits")":0003 2>/dev/null; then
			verify_hex=""
			for attempt in {1..10}; do
				verify_hex="$(read_link_control "$device")"
				if [[ -n "$verify_hex" && "$(get_current_aspm_bits "$verify_hex")" -eq "$desired_bits" ]]; then
					break
				fi
				sleep 0.1
			done
			if [[ -n "$verify_hex" && "$(get_current_aspm_bits "$verify_hex")" -eq "$desired_bits" ]]; then
				CHANGED_TOTAL=$((CHANGED_TOTAL + 1))
				result_text="$(aspm_bits_to_text "$desired_bits")"
				log "  ${GREEN}[SET]${RESET} ${device} ${description}"
				log "    $(aspm_bits_to_text "$current_bits") -> ${result_text}"
			else
				FAILED_TOTAL=$((FAILED_TOTAL + 1))
				log "  ${RED}[FAIL]${RESET} ${device} ${description}"
				log "    Write verification failed: wanted $(aspm_bits_to_text "$desired_bits"), got $(aspm_bits_to_text "$(get_current_aspm_bits "${verify_hex:-0}")")"
			fi
		else
			FAILED_TOTAL=$((FAILED_TOTAL + 1))
			log "  ${RED}[FAIL]${RESET} ${device} ${description}"
			log "    setpci could not apply the ASPM setting."
		fi
	done < <(get_pcie_devices)
}

run_powertop_report() {
	local target="$1"
	local report_file="$2"

	info "Generating powertop report: ${target}"
	if ! powertop --time=10 --html="$report_file" >/dev/null 2>&1; then
		fail "Failed to generate powertop report '${target}'."
		exit 1
	fi
}

parse_powertop_summary() {
	local report_file="$1"

	awk '
	function trim(s) {
		gsub(/^[[:space:]]+/, "", s)
		gsub(/[[:space:]]+$/, "", s)
		return s
	}
	function pct_num(s,    t) {
		t = s
		gsub(/,/, ".", t)
		gsub(/%/, "", t)
		return t + 0
	}
	function state_num(s,    chunk) {
		if (match(s, /C[0-9]+/)) {
			chunk = substr(s, RSTART, RLENGTH)
			gsub(/C/, "", chunk)
			return chunk + 0
		}
		return -1
	}
	/class="package"/ || /class="core"/ {
		type = ($0 ~ /class="package"/) ? "package" : "core"
		line = $0
		cell_count = 0
		while (match(line, /<(td|th)[^>]*class="[^"]*"[^>]*>[^<]*<\/(td|th)>/)) {
			cell = substr(line, RSTART, RLENGTH)
			line = substr(line, RSTART + RLENGTH)
			gsub(/<[^>]*>/, "", cell)
			gsub(/&nbsp;/, "", cell)
			cell = trim(cell)
			if (cell != "") {
				cells[++cell_count] = cell
			}
		}

		if (cell_count < 2) {
			next
		}

		label = cells[1]
		value = cells[2]
		if (label !~ /C[0-9]+/) {
			next
		}
		if (value !~ /%/) {
			next
		}

		key = type SUBSEP label
		if (pct_num(value) > pct_num(max_pct[key])) {
			max_pct[key] = value
		}
	}
	END {
		for (key in max_pct) {
			split(key, parts, SUBSEP)
			type = parts[1]
			label = parts[2]
			rank = state_num(label)
			if (rank > deepest_rank[type] && pct_num(max_pct[key]) > 0) {
				deepest_rank[type] = rank
				deepest_label[type] = label
				deepest_pct[type] = max_pct[key]
			}
		}

		for (type in deepest_label) {
			printf "%s|%s|%s\n", type, deepest_label[type], deepest_pct[type]
		}
	}' "$report_file"
}

show_powertop_summary() {
	local label="$1"
	local report_file="$2"
	local found=0 line kind state pct

	info "$label"
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		IFS='|' read -r kind state pct <<<"$line"
		log "  ${kind}: deepest observed ${state} at ${pct}"
		found=1
	done < <(parse_powertop_summary "$report_file")

	if [[ "$found" -eq 0 ]]; then
		warn "No readable C-state summary could be extracted from powertop."
	fi
}

print_powertop_comparison() {
	local before_report="$1"
	local after_report="$2"
	local line kind state pct
	local before_core="n/a"
	local before_package="n/a"
	local after_core="n/a"
	local after_package="n/a"

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		IFS='|' read -r kind state pct <<<"$line"
		case "$kind" in
		core)
			before_core="${state} at ${pct}"
			;;
		package)
			before_package="${state} at ${pct}"
			;;
		esac
	done < <(parse_powertop_summary "$before_report")

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		IFS='|' read -r kind state pct <<<"$line"
		case "$kind" in
		core)
			after_core="${state} at ${pct}"
			;;
		package)
			after_package="${state} at ${pct}"
			;;
		esac
	done < <(parse_powertop_summary "$after_report")

	log
	info "Powertop before/after comparison"
	log "  core:    ${before_core} -> ${after_core}"
	log "  package: ${before_package} -> ${after_package}"
}

run_powertop_auto_tune() {
	local log_file="$1"

	info "Running powertop --auto-tune."
	if powertop --auto-tune >"$log_file" 2>&1; then
		success "powertop --auto-tune completed."
	else
		fail "powertop --auto-tune failed."
		sed -n '1,40p' "$log_file"
		exit 1
	fi
}

print_change_summary() {
	log
	info "ASPM summary"
	log "  scanned PCI functions:    ${SCAN_TOTAL}"
	log "  PCIe devices:             ${PCIE_TOTAL}"
	log "  eligible for ASPM write:  ${SUPPORTED_TOTAL}"
	log "  changed:                  ${CHANGED_TOTAL}"
	log "  already enabled:          ${ALREADY_TOTAL}"
	log "  unsupported:              ${UNSUPPORTED_TOTAL}"
	log "  skipped:                  ${SKIPPED_TOTAL}"
	log "  failed:                   ${FAILED_TOTAL}"
}

print_next_steps() {
	log
	info "Recommendation"
	log "  1. Use the machine normally and check whether power use and device behavior improved."
	log "  2. Only install with persistence if everything stays stable."
	log "  3. If you notice non-working devices or instabilities later on, run the uninstaller and reboot."
}

install_systemd_service() {
	local unit_path="/etc/systemd/system/${SERVICE_NAME}"

	install -m 755 "$SCRIPT_PATH" "$INSTALLED_SCRIPT_PATH"

	cat >"$unit_path" <<EOF
[Unit]
Description=Enable ASPM and run powertop auto-tune
After=multi-user.target

[Service]
Type=oneshot
Environment=ASPM_TOOL_SKIP_SERVICE_PROMPT=1
ExecStart=/bin/bash ${INSTALLED_SCRIPT_PATH}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

	systemctl daemon-reload
	systemctl enable "$SERVICE_NAME"

	success "Installed dispatcher: ${INSTALLED_SCRIPT_PATH}"
	success "Systemd service installed and enabled: ${unit_path}"
}

install_sleep_recovery_helper() {
	local helper_path="/usr/local/sbin/${SUSPEND_GUARD_SCRIPT_NAME}"
	local device
	local devices_literal=""
	local endpoints_literal=""

	for device in "${RECOVERY_DEVICES[@]}"; do
		endpoints_literal+="\"${device}\" "
	done
	endpoints_literal="${endpoints_literal% }"

	for device in "${RECOVERY_GUARD_DEVICES[@]}"; do
		devices_literal+="\"${device}\" "
	done
	devices_literal="${devices_literal% }"

	cat >"$helper_path" <<EOF
#!/usr/bin/env bash

set -u

ACTION="\${1:-}"
DEVICES=(${devices_literal})
ENDPOINTS=(${endpoints_literal})
STATE_FILE="/run/pcie-aspm-suspend-guard.state"
TAG="pcie-aspm-suspend-guard"

if [[ -z "\${ACTION}" ]]; then
	exit 1
fi

log_msg() {
	local message="\$1"
	if command -v logger >/dev/null 2>&1; then
		logger -t "\${TAG}" "\${message}"
	else
		echo "\${message}"
	fi
}

if [[ "\${ACTION}" == "disable" ]]; then
	rm -f "\${STATE_FILE}"
	log_msg "Disabling ASPM on Broadcom PCIe branch before suspend. Endpoints: \${ENDPOINTS[*]}"
fi

if [[ "\${ACTION}" == "disable" ]]; then
	DEVICE_ITERATION=( "\${DEVICES[@]}" )
else
	DEVICE_ITERATION=()
	for (( idx=\${#DEVICES[@]} - 1; idx >= 0; idx-- )); do
		DEVICE_ITERATION+=( "\${DEVICES[idx]}" )
	done
fi

for DEVICE in "\${DEVICE_ITERATION[@]}"; do
	DEVICE_PATH="/sys/bus/pci/devices/\${DEVICE}"

	if [[ ! -e "\${DEVICE_PATH}" ]]; then
		log_msg "Skipping missing PCI device \${DEVICE}."
		continue
	fi

	case "\${ACTION}" in
	disable)
		LINK_CTL="\$(setpci -s "\${DEVICE}" CAP_EXP+10.w 2>/dev/null || true)"
		if [[ -z "\${LINK_CTL}" ]]; then
			log_msg "Could not read Link Control for \${DEVICE}; leaving it unchanged."
			continue
		fi

		CURRENT_BITS=\$(( 16#\${LINK_CTL} & 0x3 ))
		printf '%s %s\n' "\${DEVICE}" "\${CURRENT_BITS}" >>"\${STATE_FILE}"
		if setpci -s "\${DEVICE}" CAP_EXP+10.w=0:0003 2>/dev/null; then
			VERIFY_CTL="\$(setpci -s "\${DEVICE}" CAP_EXP+10.w 2>/dev/null || true)"
			VERIFY_BITS=""
			if [[ -n "\${VERIFY_CTL}" ]]; then
				VERIFY_BITS=\$(( 16#\${VERIFY_CTL} & 0x3 ))
			fi
			if [[ "\${VERIFY_BITS}" == "0" ]]; then
				log_msg "Disabled ASPM on \${DEVICE} (saved bits=\${CURRENT_BITS})."
			else
				log_msg "Tried to disable ASPM on \${DEVICE}, but verification shows bits=\${VERIFY_BITS}."
			fi
		else
			log_msg "Failed to disable ASPM on \${DEVICE}."
		fi
		;;
	restore)
		if [[ ! -r "\${STATE_FILE}" ]]; then
			log_msg "No saved ASPM state file found during resume."
			continue
		fi

		RESTORE_BITS="\$(awk -v dev="\${DEVICE}" '\$1 == dev { value=\$2 } END { if (value != "") print value }' "\${STATE_FILE}")"
		if [[ -z "\${RESTORE_BITS}" ]]; then
			continue
		fi

		if setpci -s "\${DEVICE}" CAP_EXP+10.w="\$(printf '%x' "\${RESTORE_BITS}")":0003 2>/dev/null; then
			VERIFY_CTL="\$(setpci -s "\${DEVICE}" CAP_EXP+10.w 2>/dev/null || true)"
			VERIFY_BITS=""
			if [[ -n "\${VERIFY_CTL}" ]]; then
				VERIFY_BITS=\$(( 16#\${VERIFY_CTL} & 0x3 ))
			fi
			if [[ "\${VERIFY_BITS}" == "\${RESTORE_BITS}" ]]; then
				log_msg "Restored ASPM on \${DEVICE} to bits=\${RESTORE_BITS}."
			else
				log_msg "Tried to restore ASPM on \${DEVICE} to bits=\${RESTORE_BITS}, but verification shows bits=\${VERIFY_BITS:-unreadable}."
			fi
		else
			log_msg "Failed to restore ASPM on \${DEVICE} to bits=\${RESTORE_BITS}."
		fi
		;;
	esac
done

if [[ "\${ACTION}" == "restore" ]]; then
	rm -f "\${STATE_FILE}"
	log_msg "Finished restoring ASPM on Broadcom PCIe branch after resume."
fi
EOF

	chmod 755 "$helper_path"
	success "Installed suspend/resume helper: ${helper_path}"
}

install_resume_restore_helper() {
	local helper_path="/usr/local/sbin/${RESUME_RESTORE_SCRIPT_NAME}"
	local guard_helper_path="/usr/local/sbin/${SUSPEND_GUARD_SCRIPT_NAME}"
	local device driver_name
	local endpoints_literal=""
	local drivers_literal=""

	for device in "${RECOVERY_DEVICES[@]}"; do
		endpoints_literal+="\"${device}\" "
		driver_name="$(get_device_driver_name "$device")"
		drivers_literal+="\"${driver_name}\" "
	done
	endpoints_literal="${endpoints_literal% }"
	drivers_literal="${drivers_literal% }"

	cat >"$helper_path" <<EOF
#!/usr/bin/env bash

set -u

ENDPOINTS=(${endpoints_literal})
EXPECTED_DRIVERS=(${drivers_literal})
STATE_FILE="/run/pcie-aspm-suspend-guard.state"
TAG="pcie-aspm-resume-restore"
GUARD_HELPER="${guard_helper_path}"

log_msg() {
	local message="\$1"
	if command -v logger >/dev/null 2>&1; then
		logger -t "\${TAG}" "\${message}"
	else
		echo "\${message}"
	fi
}

if [[ ! -x "\${GUARD_HELPER}" ]]; then
	log_msg "Suspend guard helper is missing: \${GUARD_HELPER}"
	exit 1
fi

if [[ ! -r "\${STATE_FILE}" ]]; then
	log_msg "No saved ASPM state file found; skipping resume restore."
	exit 0
fi

ready_streak=0

for (( attempt=1; attempt<=300; attempt++ )); do
	all_ready=1
	for idx in "\${!ENDPOINTS[@]}"; do
		device="\${ENDPOINTS[idx]}"
		expected_driver="\${EXPECTED_DRIVERS[idx]}"

		if [[ ! -e "/sys/bus/pci/devices/\${device}" ]]; then
			all_ready=0
			break
		fi
		if ! setpci -s "\${device}" CAP_EXP+10.w >/dev/null 2>&1; then
			all_ready=0
			break
		fi

		if [[ -n "\${expected_driver}" ]]; then
			driver_link="/sys/bus/pci/devices/\${device}/driver"
			if [[ ! -L "\${driver_link}" ]]; then
				all_ready=0
				break
			fi
			current_driver="\$(basename "\$(readlink -f "\${driver_link}")")"
			if [[ "\${current_driver}" != "\${expected_driver}" ]]; then
				all_ready=0
				break
			fi
		fi
	done

	if [[ "\${all_ready}" == "1" ]]; then
		ready_streak=\$((ready_streak + 1))
	else
		ready_streak=0
	fi

	if [[ "\${ready_streak}" -ge 5 ]]; then
		log_msg "Broadcom PCIe endpoints and drivers are stable; starting ASPM restore."
		exec "\${GUARD_HELPER}" restore
	fi

	sleep 0.1
done

log_msg "Timed out waiting for Broadcom PCIe endpoints/drivers to stabilize after resume."
exit 1
EOF

	chmod 755 "$helper_path"
	success "Installed resume restore helper: ${helper_path}"
}

install_sleep_recovery_hook() {
	local helper_path="/usr/local/sbin/${SUSPEND_GUARD_SCRIPT_NAME}"
	local resume_helper_path="/usr/local/sbin/${RESUME_RESTORE_SCRIPT_NAME}"
	local hook_path="/usr/lib/systemd/system-sleep/${SUSPEND_HOOK_NAME}"
	local resume_unit_path="/etc/systemd/system/${RESUME_RESTORE_SERVICE_NAME}"

	if [[ "${#RECOVERY_DEVICES[@]}" -eq 0 ]]; then
		warn "No Broadcom Wi-Fi/Bluetooth PCI devices were detected, so no suspend/resume guard hook can be installed."
		return 1
	fi

	install_sleep_recovery_helper
	install_resume_restore_helper
	mkdir -p "/usr/lib/systemd/system-sleep"

	cat >"$hook_path" <<EOF
#!/usr/bin/env bash

set -u

case "\${1:-}" in
pre)
	case "\${2:-}" in
	suspend)
		exec ${helper_path} disable
		;;
	esac
	;;
post)
	case "\${2:-}" in
	suspend)
		systemctl --no-block start ${RESUME_RESTORE_SERVICE_NAME}
		;;
	esac
	;;
esac

exit 0
EOF

	chmod 755 "$hook_path"

cat >"$resume_unit_path" <<EOF
[Unit]
Description=Restore Broadcom ASPM after resume

[Service]
Type=oneshot
ExecStart=${resume_helper_path}
EOF

	systemctl daemon-reload

	success "Installed pre-suspend hook: ${hook_path}"
	success "Installed post-resume restore service: ${resume_unit_path}"
	success "All done!"
	return 0
}

offer_systemd_service() {
	local answer

	if [[ "$SKIP_SERVICE_PROMPT" == "1" ]]; then
		return 0
	fi

	log
	read -r -p "Install a systemd service that applies this optimization automatically on every boot? [y/N] " answer
	case "$answer" in
	y | Y | yes | YES)
		install_systemd_service
		;;
	*)
		info "No boot-time optimization service installed."
		;;
	esac
}

offer_sleep_recovery_service() {
	local answer device

	if [[ "$SKIP_SERVICE_PROMPT" == "1" ]]; then
		return 0
	fi

	if [[ "${#RECOVERY_DEVICES[@]}" -eq 0 ]]; then
		return 0
	fi

	log
	warn "Detected Broadcom Wi-Fi/Bluetooth PCI devices."
	warn "On systems using these Broadcom devices, enabling ASPM can improve idle power use but may also cause Wi-Fi or Bluetooth to disappear after suspend."
	warn "Installing the suspend guard is recommended. It disables ASPM on the full Broadcom PCIe branch in the pre-suspend path and restores it only after the Broadcom/T2 resume path has completed."
	for device in "${RECOVERY_DEVICES[@]}"; do
		log "  ${CYAN}${device}${RESET} $(get_lspci_description "$device")"
	done
	read -r -p "Install the recommended Broadcom suspend guard for these devices? [y/N] " answer
	case "$answer" in
	y | Y | yes | YES)
		install_sleep_recovery_hook || true
		;;
	*)
		info "No Broadcom suspend/resume guard hook installed."
		;;
	esac
}

offer_persistent_setup() {
	local answer

	if [[ "$SKIP_SERVICE_PROMPT" == "1" ]]; then
		return 0
	fi

	log
	read -r -p "Do you want to make these changes persistent? [y/N] " answer
	case "$answer" in
	y | Y | yes | YES)
		return 0
		;;
	*)
		info "Leaving the changes non-persistent. Nothing will be installed for future boots."
		return 1
		;;
	esac
}

confirm_test_run() {
	local answer

	if [[ "$SKIP_SERVICE_PROMPT" == "1" ]]; then
		return 0
	fi

	log
	warn "This run is intended as a non-persistent test."
	log "  The script will try to enable relevant ASPM settings for the current boot,"
	log "  run powertop tuning, and show the before/after result."
	log "  If powertop or pciutils are missing, they will be installed first."
	log
	log "  These changes apply to this boot only unless you later choose to install"
	log "  persistent systemd services."
	log
	log "  Important: after this test, reboot first and only then run the script again"
	log "  if you want to make the setup persistent."
	log "  Otherwise the script may detect already-active settings from the test run,"
	log "  which can hide what actually changes on a fresh boot."
	log
	read -r -p "Continue? [y/N] " answer
	case "$answer" in
	y | Y | yes | YES)
		return 0
		;;
	*)
		info "Aborted before making any changes."
		return 1
		;;
	esac
}

main() {
	local before_report after_report after_tune_log

	info "Starting ASPM and powertop tuning run."
	require_root
	set_stable_locale
	if ! confirm_test_run; then
		exit 0
	fi
	info "Checking dependencies."
	ensure_dependencies
	info "Creating temporary workspace."
	make_work_dir
	build_recovery_device_list
	build_protected_device_map

	before_report="${WORK_DIR}/powertop-before.html"
	after_report="${WORK_DIR}/powertop-after.html"
	after_tune_log="${WORK_DIR}/powertop-auto-tune.log"

	run_powertop_report "before" "$before_report"
	scan_aspm_state "before"
	print_aspm_snapshot "ASPM before changes" BEFORE_ASPM_REPORT
	show_powertop_summary "Powertop before changes" "$before_report"

	log
	enable_supported_aspm
	log

	run_powertop_auto_tune "$after_tune_log"
	run_powertop_report "after" "$after_report"
	scan_aspm_state "after"

	print_aspm_snapshot "ASPM after changes" AFTER_ASPM_REPORT
	show_powertop_summary "Powertop after changes" "$after_report"
	print_powertop_comparison "$before_report" "$after_report"
	print_change_summary
	print_next_steps

	if offer_persistent_setup; then
		offer_systemd_service
		offer_sleep_recovery_service
	fi
}

main "$@"
