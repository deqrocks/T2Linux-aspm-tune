# ASPM Power Tuning for T2 Macs

Scripts to reduce idle power draw on Intel T2 MacBooks running Linux by enabling PCIe ASPM on relevant devices and applying `powertop --auto-tune`.

The goal is to reach the deeper package idle states that are missing out of the box on T2 Macs, especially the jump from package C3 to package C8. Reaching those deeper package states can have a dramatic effect on battery life and idle power draw, in some cases reducing idle consumption to half of the original level when using your Mac for light tasks like browsing, writing text etc... It won't have much impact when you run heavy tasks.

## Example MacBook Air 2020 9,1

This shows before running the script. Because of ASPM disabled on the Broadcom wireless card we only have Pkg state C3

<img title="mba2020 before" src="without.png">

This is after running the script. We have enabled ASPM successfully and are now running in Pkg state C8. Idle temperatures have lowered a bit. Idle Power draw is substantially reduced from 8 to 4.5W on idle.

<img title="mba2020 after" src="with.png">

For working suspend/resume with Broadcom Wi-Fi/Bluetooth, `pcie_ports=compat` needs to be active in the kernel command line. With that in place, this setup can reach package C8 while still keeping suspend/resume working in `s2idle`/`deep` (`mem_sleep_default=deep`) setups. It is also compatible with [T2Linux-suspend-fix](https://github.com/deqrocks/T2Linux-Suspend-Fix) which automatically configures`pcie_ports=compat` by default.

The main script can be run once in a non-persistent mode, so the result can be checked before the same setup is installed persistently with systemd.

## Files

- `pcie-aspm-tune.sh`: main interactive installer/runner
- `pcie-aspm-tune-uninstall.sh`: removes installed services and deployed helper files

## Usage

Run the main script as root:

```bash
sudo ./pcie-aspm-tune.sh
```

Recommended workflow:
1. Run it once without installing persistent services.
2. Test normal use and if all devices are working as expected.
3. Reboot and run again.
4. Only then install the optional services.

To remove installed components:

```bash
sudo ./pcie-aspm-tune-uninstall.sh
```

## Important Notes

- This is aimed at T2 MacBooks and similar setups where Broadcom Wi-Fi can block deeper package C-states.
- For Broadcom resume stability, use `pcie_ports=compat`. Without it, Wi-Fi/Bluetooth may fail to come back after suspend even if ASPM itself is configured correctly. The optional Broadcom suspend guard disables ASPM in the pre-suspend path and restores it only after the Broadcom PCIe endpoints and their drivers are back in a stable post-resume state.
- The boot service installs a managed copy under `/usr/local/sbin`. If you also enable the Broadcom suspend guard, the helper scripts, suspend hook, and resume restore service are installed as managed copies too, so the original project files can be deleted afterwards.
