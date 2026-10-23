#!/bin/bash
# Install (or remove) the ultra-low-power mode. Run as your normal user; it asks for sudo.
#
# Usage: ./ultra-low-power.sh [--uninstall]
set -euo pipefail
src=$(cd "$(dirname "$0")/ultra-low-power" && pwd)
apps=${XDG_DATA_HOME:-$HOME/.local/share}/applications
units=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
autostart=${XDG_CONFIG_HOME:-$HOME/.config}/autostart

[ "$(id -u)" != 0 ] || { echo "error: run as your normal user (it uses sudo for the system part)" >&2; exit 1; }

if [ "${1:-}" = --uninstall ]; then
    [ -e /run/ultra-low-power ] && /usr/local/bin/ultra-low-power off
    systemctl --user disable --now ulp-profile-watch.service 2>/dev/null || true
    rm -f "$units/ulp-profile-watch.service" "$apps/ultra-low-power.desktop" "$autostart/ulp-profile-watch.desktop"
    sudo rm -f /usr/local/bin/ultra-low-power /usr/local/bin/ulp-root /usr/local/bin/ulp-fan-guard \
               /usr/lib/systemd/system-sleep/ulp-resume
    echo "Removed."
    exit 0
fi

for c in powerprofilesctl iw rfkill pkexec; do
    command -v "$c" >/dev/null || { echo "error: needs $c (power-profiles-daemon, iw, util-linux, polkit)" >&2; exit 1; }
done
[ -d /sys/class/powercap/intel-rapl:0 ] || { echo "error: no RAPL power capping on this CPU" >&2; exit 1; }

sudo install -Dm755 "$src/ultra-low-power" "$src/ulp-root" "$src/ulp-fan-guard" -t /usr/local/bin
sudo install -Dm755 "$src/ulp-resume" /usr/lib/systemd/system-sleep/ulp-resume
install -Dm644 "$src/ulp-profile-watch.service" "$units/ulp-profile-watch.service"
install -Dm644 "$src/ultra-low-power.desktop" "$apps/ultra-low-power.desktop"
install -Dm644 "$src/ulp-profile-watch.desktop" "$autostart/ulp-profile-watch.desktop"  # LXQt has no graphical-session.target
systemctl --user daemon-reload
systemctl --user enable ulp-profile-watch.service

if ! grep -q 'level <level>' /proc/acpi/ibm/fan 2>/dev/null; then
    echo "Note: fan control is off, so the fan stays on firmware control. To let the mode switch it off, run"
    echo "  echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf   and reboot."
fi
echo "Installed. Toggle with: ultra-low-power   (or the \"Ultra Low Power\" app; status: ultra-low-power status)"
