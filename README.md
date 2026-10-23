# ThinkPad L13 on Arch Linux: hibernation + power tuning

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Two small, re-runnable scripts for getting a ThinkPad working properly on an Arch-based
distro with a **btrfs root** and **GRUB**:

- **`scripts/hibernate-setup.sh`** — hibernation onto a btrfs swapfile, including the parts
  that are easy to get wrong: keeping the swapfile out of your snapshots, the `resume_offset`,
  and resuming with the right kernel.
- **`scripts/power-tune.sh`** — battery charge limits, audio codec power saving, PCI runtime PM.
- **`scripts/ultra-low-power.sh`** — an *Eco* mode you toggle on battery: CPU capped at 3 W average,
  fan off, and the desktop stripped of eye candy. It works on any Intel laptop; the fan part needs a ThinkPad.

Most of this applies to any Arch-based laptop. The two genuinely ThinkPad-specific bits are the
battery charge thresholds and the post-resume fix for the TrackPoint and keyboard backlight.

> Read a script before running it with `sudo`. Both back up every file they change
> (into `/root/hibernate-setup-backups`) and are safe to re-run.

## Contents

- [Hibernation](#hibernation)
- [Gotchas that cost me the most time](#gotchas-that-cost-me-the-most-time)
- [Power tuning](#power-tuning)
- [Ultra low power mode](#ultra-low-power-mode)
- [Undo](#undo)
- [Tested on](#tested-on)

---

## Hibernation

```sh
sudo ./scripts/hibernate-setup.sh            # swapfile sized to your RAM
sudo ./scripts/hibernate-setup.sh --size 16  # or pick the size, in GiB
```

It will:

1. Create a **`@swap` subvolume outside your root subvolume**, so snapper/timeshift snapshots
   never try to snapshot an active swapfile.
2. Create a btrfs swapfile at **priority 10**, leaving zram (priority 100) as the swap that
   normal memory pressure actually uses. The file is there for hibernation, not for swapping.
3. Work out the swapfile's physical `resume_offset` and add `resume=` / `resume_offset=` to
   the kernel command line, then rebuild the GRUB menu.
4. Install a systemd `system-sleep` hook (skip it with `--no-hook`) that handles the two
   ThinkPad quirks described below.

Then reboot and test with `systemctl hibernate`.

Options: `--size`, `--subvol`, `--mount`, `--no-hook`. Run with `--help` for details.

## Gotchas that cost me the most time

**Your BIOS may be hiding S3.** Check what the kernel has:

```sh
cat /sys/power/mem_sleep      # [s2idle] means modern standby only
```

If it shows only `s2idle`, look in the BIOS for a sleep-state option (on ThinkPads it's usually
*Config → Power → Sleep State*, set to **Linux** / *Linux S3*). After enabling it you get
`s2idle [deep]`, real S3 suspend, and a laptop that doesn't quietly cook in your bag. It's worth
checking even if the option looks absent at first glance.

**`resume_offset` is tied to the exact swapfile.** Delete or recreate the swapfile and the offset
changes, and resume silently fails back to a cold boot. Re-run the script, or recompute it:

```sh
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
```

**You must resume with the same kernel you hibernated with.** If you keep several kernels
installed, the GRUB default may not be the one that's running. The hook handles this by calling
`grub-reboot` before hibernating, pointing the next boot at the running kernel.

**Resume still shows the GRUB menu.** Since `grub-reboot` sets a one-shot entry, you can make
that specific boot skip the menu by adding this to `/etc/grub.d/40_custom`:

```sh
if [ "${boot_once}" = "true" ]; then set timeout=0; fi
```

**The TrackPoint buttons and keyboard backlight die after resume.** On some ThinkPads the Elan
touchpad/TrackPoint comes back with dead buttons, and the firmware clears the keyboard backlight.
The hook reloads `psmouse` and restores the saved backlight level on wake.

**Secure Boot is fine, kernel lockdown is not.** Hibernation works with Secure Boot enabled as
long as the kernel isn't in lockdown mode (`cat /sys/kernel/security/lockdown` should show
`[none]`). Arch's kernels don't enable lockdown by default; Fedora's and Ubuntu's do, and they
block hibernation under Secure Boot.

**Prefer `suspend-then-hibernate`.** Suspend for a couple of hours, then hibernate, so a closed
lid doesn't drain the battery overnight:

```ini
# /etc/systemd/sleep.conf.d/hibernate-delay.conf
[Sleep]
HibernateDelaySec=2h
```

## Power tuning

```sh
sudo ./scripts/power-tune.sh                             # 85-90% charge limit
sudo ./scripts/power-tune.sh --charge-start 60 --charge-end 65   # mostly-docked laptop
sudo ./scripts/power-tune.sh --no-pci-pm                 # skip a part
```

- **Battery charge thresholds** — stored in the embedded controller, so they persist across
  reboots and other operating systems. Keeping a laptop that mostly lives on a charger at
  ~60% rather than 100% measurably slows calendar ageing.
- **Audio codec power saving** — lets the HDA codec sleep after a second of silence.
- **PCI runtime power management** — idle PCI devices drop into low power. Uses the same driver
  denylist TLP does (`mei_me`, `xhci_hcd`, `nouveau`, `radeon`), since runtime PM makes those misbehave.

Each part can be skipped with `--no-charge-limit`, `--no-audio-pm`, `--no-pci-pm`.

## Ultra low power mode

```sh
./scripts/ultra-low-power.sh               # run as your user; asks for sudo
ultra-low-power                            # toggle (also an "Ultra Low Power" app in the menu)
ultra-low-power status                     # current cap and measured package power
```

When it's on:

- **CPU: 3 W sustained (PL1), 12 W for short bursts (PL2)**, with turbo still allowed. Clicks, app starts and
  page loads stay snappy, but steady load can't heat the laptop up. Idle and video draw don't change, so you
  lose nothing there. A stricter version (2.5 W, no turbo, EPP=power) was 2.2× slower single-threaded for no
  idle gain, so this one uses the RAPL cap alone.
- **iGPU capped at 700 MHz.** 300 MHz made scrolling and video choppy.
- **Fan off**, with a safety net: `ulp-fan-guard` hands the fan back to the EC at 65 °C, and the
  thinkpad_acpi watchdog does too if the guard ever stops. Needs `options thinkpad_acpi fan_control=1`.
- Keyboard backlight off, PCIe ASPM `powersupersave`, Bluetooth off (unless something is connected).
- **KDE Plasma:** animations and blur off, and sensor-polling widgets, kded modules and background
  services stopped. Everything comes back when you switch the mode off, even across a reboot.
- `throttled` and `nbfc` are paused while the mode is on, because both would undo the cap or the fan setting.

Switching the power profile to Balanced or Performance turns the mode off. A sleep hook re-applies the cap
after resume, since the firmware resets RAPL on wake.

## Undo

```sh
# hibernation
sudo swapoff /swap/swapfile
sudo rm -f /usr/lib/systemd/system-sleep/thinkpad-sleep-fix
# then remove the /swap lines from /etc/fstab and the resume= parameters from
# /etc/default/grub (originals are in /root/hibernate-setup-backups), and:
sudo grub-mkconfig -o /boot/grub/grub.cfg

# power tuning
sudo systemctl disable --now pci-runtime-pm.service
sudo rm -f /etc/systemd/system/pci-runtime-pm.service /usr/local/bin/pci-runtime-pm \
           /etc/modprobe.d/audio-powersave.conf
```

```sh
# ultra low power mode
./scripts/ultra-low-power.sh --uninstall
```

Battery thresholds live in the EC; reset them by writing `100` to
`/sys/class/power_supply/BAT0/charge_control_end_threshold`, or from KDE's
*Power Management → Charge Limit*.

## Tested on

- **ThinkPad L13 Gen 2** (i7-1165G7, Iris Xe), CachyOS (Arch-based), KDE Plasma 6 on Wayland,
  btrfs root with snapper snapshots, GRUB, Secure Boot enabled. Hibernate and resume verified
  working, including the TrackPoint and backlight fix.
- The scripts detect your root UUID, filesystem and RAM size rather than assuming mine, but
  they have only been exercised on the machine above. Reports from other models welcome.

## References

- [Arch Wiki: Power management](https://wiki.archlinux.org/title/Power_management)
- [Arch Wiki: btrfs swapfile](https://wiki.archlinux.org/title/Btrfs#Swap_file)
- [Arch Wiki: suspend and hibernate](https://wiki.archlinux.org/title/Power_management/Suspend_and_hibernate)

## Credits

Made by [envy-vain](https://github.com/envy-vain). **LLM disclaimer:** parts of these scripts were written with
help from an LLM (Claude, by Anthropic). Everything was tested on the laptop above. Read a script before you
run it with sudo.
