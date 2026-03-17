#!/usr/bin/env bash

set -u

SERVICE_NAME="pcie-aspm-tune.service"
INSTALLED_SCRIPT_PATH="/usr/local/sbin/pcie-aspm-tune.sh"
SUSPEND_GUARD_SCRIPT_PATH="/usr/local/sbin/pcie-aspm-suspend-guard.sh"
RESUME_RESTORE_SCRIPT_PATH="/usr/local/sbin/pcie-aspm-resume-restore.sh"
SUSPEND_HOOK_PATH="/usr/lib/systemd/system-sleep/pcie-aspm-suspend-hook"
RESUME_RESTORE_SERVICE_NAME="pcie-aspm-resume-restore.service"
SERVICE_UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
RESUME_RESTORE_SERVICE_UNIT_PATH="/etc/systemd/system/${RESUME_RESTORE_SERVICE_NAME}"

RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
BLUE="$(printf '\033[34m')"
YELLOW="$(printf '\033[33m')"
RESET="$(printf '\033[0m')"

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

require_root() {
	if [[ "${EUID}" -ne 0 ]]; then
		fail "This script must be run as root."
		exit 1
	fi
}

remove_service() {
	local service_name="$1"
	local unit_path="$2"

	if systemctl list-unit-files "$service_name" >/dev/null 2>&1; then
		info "Disabling ${service_name}."
		systemctl disable --now "$service_name" >/dev/null 2>&1 || true
	fi

	if [[ -f "$unit_path" ]]; then
		info "Removing ${unit_path}."
		rm -f "$unit_path"
	fi
}

remove_file() {
	local file_path="$1"

	if [[ -e "$file_path" ]]; then
		info "Removing ${file_path}."
		rm -f "$file_path"
	fi
}

main() {
	require_root

	remove_service "$SERVICE_NAME" "$SERVICE_UNIT_PATH"
	remove_service "$RESUME_RESTORE_SERVICE_NAME" "$RESUME_RESTORE_SERVICE_UNIT_PATH"
	remove_file "$INSTALLED_SCRIPT_PATH"
	remove_file "$SUSPEND_GUARD_SCRIPT_PATH"
	remove_file "$RESUME_RESTORE_SCRIPT_PATH"
	remove_file "$SUSPEND_HOOK_PATH"

	info "Reloading systemd daemon."
	systemctl daemon-reload

	success "ASPM/powertop installed components removed."
}

main "$@"
