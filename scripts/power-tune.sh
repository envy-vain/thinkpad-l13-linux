#!/bin/bash
# Battery and power tuning for a ThinkPad on Arch-based Linux.
# Everything here is idempotent and reversible - see the README's "Undo" section.
#
# Usage: sudo ./power-tune.sh [options]
#   --charge-start N   start charging below N%   (default 85)
#   --charge-end N     stop charging at N%       (default 90)
#   --no-charge-limit  skip the battery charge thresholds
#   --no-audio-pm      skip the audio codec power saving
#   --no-pci-pm        skip PCI runtime power management
#   --help             show this text
set -euo pipefail

START=85 END=90 DO_CHARGE=1 DO_AUDIO=1 DO_PCI=1

die()  { echo "error: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

while [ $# -gt 0 ]; do
    case $1 in
        --charge-start)    START=$2; shift 2 ;;
        --charge-end)      END=$2; shift 2 ;;
        --no-charge-limit) DO_CHARGE=0; shift ;;
        --no-audio-pm)     DO_AUDIO=0; shift ;;
        --no-pci-pm)       DO_PCI=0; shift ;;
        --help|-h)         sed -n '2,11p' "$0"; exit 0 ;;
        *)                 die "unknown option: $1 (see --help)" ;;
    esac
done
[ "$(id -u)" = 0 ] || die "run with sudo"
[ "$START" -lt "$END" ] || die "--charge-start ($START) must be below --charge-end ($END)"

if [ "$DO_CHARGE" = 1 ]; then
    step "Battery charge thresholds ${START}-${END}%"
    # Kept in the embedded controller, so it survives reboots and other OSes.
    found=0
    for B in /sys/class/power_supply/BAT*; do
        [ -w "$B/charge_control_end_threshold" ] || continue
        # End first: some firmware rejects a start value above the current end.
        echo "$END"   > "$B/charge_control_end_threshold"
        [ -w "$B/charge_control_start_threshold" ] && echo "$START" > "$B/charge_control_start_threshold"
        echo "$(basename "$B"): $(cat "$B/charge_control_start_threshold" 2>/dev/null)-$(cat "$B/charge_control_end_threshold")%"
        found=1
    done
    [ "$found" = 1 ] || echo "no battery exposing charge thresholds - skipped"
fi

if [ "$DO_AUDIO" = 1 ]; then
    step "Audio codec power saving (sleep after 1s of silence)"
    echo "options snd_hda_intel power_save=1" > /etc/modprobe.d/audio-powersave.conf
    [ -w /sys/module/snd_hda_intel/parameters/power_save ] \
        && echo 1 > /sys/module/snd_hda_intel/parameters/power_save
    echo "wrote /etc/modprobe.d/audio-powersave.conf"
fi

if [ "$DO_PCI" = 1 ]; then
    step "PCI runtime power management for idle devices"
    install -Dm755 /dev/stdin /usr/local/bin/pci-runtime-pm <<'EOF'
#!/bin/bash
# Let idle PCI devices drop into low power. The skipped drivers are the ones
# TLP also leaves alone, because runtime PM makes them misbehave.
for d in /sys/bus/pci/devices/*; do
    drv=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null || true)
    case "$drv" in mei_me|xhci_hcd|nouveau|radeon) continue ;; esac
    echo auto > "$d/power/control" 2>/dev/null || true
done
EOF
    install -Dm644 /dev/stdin /etc/systemd/system/pci-runtime-pm.service <<'EOF'
[Unit]
Description=Enable PCI runtime power management
After=systemd-udev-settle.service multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pci-runtime-pm

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now pci-runtime-pm.service
    echo "pci-runtime-pm.service enabled"
fi

step "Done"
echo "Check power draw with:  powertop  (or the 'Energy' page in KDE's System Settings)"
