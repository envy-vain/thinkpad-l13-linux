#!/bin/bash
# Set up hibernation on an Arch-based system with a btrfs root and GRUB.
#
# What it does (all of it is idempotent - safe to re-run):
#   1. creates a @swap subvolume OUTSIDE your root subvolume, so snapshots
#      (snapper / timeshift) never try to include the swapfile
#   2. creates a btrfs swapfile at low priority, so zram still handles normal
#      swapping and this file is really only there for hibernation
#   3. adds resume= / resume_offset= to the kernel command line and rebuilds
#      the GRUB menu
#   4. optionally installs a systemd system-sleep hook that fixes two ThinkPad
#      quirks after resume (see --help)
#
# Usage: sudo ./hibernate-setup.sh [options]
#   --size GiB      swapfile size (default: total RAM rounded up)
#   --subvol NAME   btrfs subvolume name for the swap (default: @swap)
#   --mount PATH    where to mount it (default: /swap)
#   --no-hook       don't install the ThinkPad resume hook
#   --help          show this text
set -euo pipefail

SIZE="" SUBVOL="@swap" MNT="/swap" HOOK=1

die()  { echo "error: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

while [ $# -gt 0 ]; do
    case $1 in
        --size)    SIZE=$2; shift 2 ;;
        --subvol)  SUBVOL=$2; shift 2 ;;
        --mount)   MNT=$2; shift 2 ;;
        --no-hook) HOOK=0; shift ;;
        --help|-h) sed -n '2,19p' "$0"; exit 0 ;;
        *)         die "unknown option: $1 (see --help)" ;;
    esac
done

step "0. Checks"
[ "$(id -u)" = 0 ] || die "run with sudo"
for t in btrfs findmnt grub-mkconfig python3; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done
ROOT_FS=$(findmnt -no FSTYPE /)
[ "$ROOT_FS" = btrfs ] || die "this script is btrfs-only; your root is $ROOT_FS"
ROOTUUID=$(findmnt -no UUID /)
[ -n "$ROOTUUID" ] || die "could not read the root filesystem UUID"
ROOTDEV=$(findmnt -no SOURCE / | sed 's/\[.*//')
if [ -z "$SIZE" ]; then
    # Hibernation needs room for RAM; the image is compressed, so RAM-sized is plenty.
    SIZE=$(awk '/MemTotal/{printf "%.0f", ($2/1048576)+0.5}' /proc/meminfo)
fi
echo "root:      $ROOTDEV (btrfs, UUID $ROOTUUID)"
echo "swapfile:  ${SIZE}G at $MNT/swapfile (subvolume $SUBVOL)"

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP=/root/hibernate-setup-backups
mkdir -p "$BACKUP"

step "1. Swap subvolume $SUBVOL (outside the root subvolume, so snapshots skip it)"
TOP=$(mktemp -d)
# subvolid=5 is the btrfs filesystem root, above @ / @home / etc.
mount -o subvolid=5 "$ROOTDEV" "$TOP"
if [ -d "$TOP/$SUBVOL" ]; then
    echo "already exists"
else
    btrfs subvolume create "$TOP/$SUBVOL"
fi
umount "$TOP"; rmdir "$TOP"

mkdir -p "$MNT"
cp -a /etc/fstab "$BACKUP/fstab.bak-$STAMP"
if grep -qE "[[:space:]]${MNT}[[:space:]]" /etc/fstab; then
    echo "fstab already mounts $MNT"
else
    echo "UUID=$ROOTUUID $MNT btrfs subvol=/$SUBVOL,noatime 0 0" >> /etc/fstab
    systemctl daemon-reload
fi
mountpoint -q "$MNT" || mount "$MNT"

step "2. ${SIZE}G swapfile (priority 10, so zram at 100 is still preferred)"
if [ -f "$MNT/swapfile" ]; then
    echo "already exists - leaving it alone (delete it and re-run to resize)"
else
    btrfs filesystem mkswapfile --size "${SIZE}g" --uuid clear "$MNT/swapfile"
fi
grep -q "^$MNT/swapfile" /etc/fstab || echo "$MNT/swapfile none swap defaults,pri=10 0 0" >> /etc/fstab
swapon --show=NAME | grep -qx "$MNT/swapfile" || swapon "$MNT/swapfile"

# The kernel needs the physical offset of the swapfile inside the filesystem.
# This changes if the swapfile is ever recreated - re-run this script if so.
OFFSET=$(btrfs inspect-internal map-swapfile -r "$MNT/swapfile")
[ -n "$OFFSET" ] || die "could not read the swapfile offset"
echo "resume_offset=$OFFSET"

step "3. Kernel resume parameters"
cp -a /etc/default/grub "$BACKUP/default-grub.bak-$STAMP"
# Handles GRUB_CMDLINE_LINUX_DEFAULT quoted with either ' or ".
python3 - "$ROOTUUID" "$OFFSET" <<'PY'
import re, sys
uuid, off = sys.argv[1], sys.argv[2]
path = '/etc/default/grub'
src = open(path).read()
def rewrite(m):
    prefix, quote, body = m.group(1), m.group(2), m.group(3)
    body = re.sub(r'\s*resume(_offset)?=\S*', '', body).strip()
    body = (body + ' resume=UUID=%s resume_offset=%s' % (uuid, off)).strip()
    return prefix + quote + body + quote
new, n = re.subn(r'''(?m)^(GRUB_CMDLINE_LINUX_DEFAULT=)(["'])(.*?)\2[ \t]*$''', rewrite, src)
if n == 0:
    raise SystemExit('error: no GRUB_CMDLINE_LINUX_DEFAULT line in /etc/default/grub')
open(path, 'w').write(new)
PY
grep ^GRUB_CMDLINE_LINUX_DEFAULT /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg 2>&1 | grep -vE "^Found snapshot" || true
grub-script-check /boot/grub/grub.cfg && echo "grub.cfg syntax OK"

if [ "$HOOK" = 1 ]; then
    step "4. Resume hook (same kernel on resume + ThinkPad TrackPoint/backlight fix)"
    install -Dm755 /dev/stdin /usr/lib/systemd/system-sleep/thinkpad-sleep-fix <<'EOF'
#!/bin/bash
# systemd system-sleep hook.  $1 = pre|post, $2 = suspend|hibernate|hybrid-sleep|suspend-then-hibernate
#
# pre  + hibernate : point GRUB's next boot at the kernel that is running right now.
#                    Resuming with a different kernel than the one that hibernated
#                    fails, and the menu default is not necessarily the running one.
# post             : re-initialise the Elan touchpad/TrackPoint (its buttons come back
#                    dead after resume on some ThinkPads) and restore the keyboard
#                    backlight level, which the firmware clears on wake.
KBD=/sys/class/leds/tpacpi::kbd_backlight/brightness
SAVE=/run/kbd-backlight.saved
ROOTUUID=@ROOTUUID@

case "$1" in
  pre)
    [ -w "$KBD" ] && cat "$KBD" > "$SAVE" 2>/dev/null
    if [[ "$2" == *hibernate* ]]; then
        img=$(sed -n 's|.*BOOT_IMAGE=[^ ]*/boot/vmlinuz-\([^ ]*\).*|\1|p' /proc/cmdline)
        [ -n "$img" ] && grub-reboot \
            "gnulinux-advanced-$ROOTUUID>gnulinux-$img-advanced-$ROOTUUID" 2>/dev/null
    fi
    ;;
  post)
    modprobe -r psmouse 2>/dev/null && modprobe psmouse
    sleep 1
    [ -s "$SAVE" ] && cat "$SAVE" > "$KBD" 2>/dev/null
    ;;
esac
exit 0
EOF
    sed -i "s/@ROOTUUID@/$ROOTUUID/" /usr/lib/systemd/system-sleep/thinkpad-sleep-fix
    echo "installed /usr/lib/systemd/system-sleep/thinkpad-sleep-fix"
fi

step "5. Result"
swapon --show
if grep -q resume= /proc/cmdline; then
    echo "resume parameters are already active"
else
    echo "resume parameters take effect after the next reboot"
fi
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager CanHibernate || true
echo
echo "Backups of fstab and /etc/default/grub are in $BACKUP"
echo "Reboot, then test with:  systemctl hibernate"
