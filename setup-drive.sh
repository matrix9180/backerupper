#!/usr/bin/env bash
# One-time: wipe the SanDisk USB stick and create an encrypted (LUKS2) ext4
# volume labelled "homebackup". Run with: sudo ./setup-drive.sh
set -euo pipefail

DEV=${1:-/dev/sda}
LABEL=homebackup
MAPPER=homebackup-setup
OWNER=${SUDO_USER:-matrix9180}

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }

# Safety: refuse to touch anything that isn't a USB disk around 128GB.
tran=$(lsblk -dno TRAN "$DEV")
model=$(lsblk -dno MODEL "$DEV")
size=$(lsblk -dbno SIZE "$DEV")
if [[ $tran != usb ]] || (( size < 100*1000**3 || size > 140*1000**3 )); then
  echo "Refusing: $DEV is '$model' via '$tran', $((size/1000**3))GB — not the expected USB stick." >&2
  exit 1
fi
if lsblk -no MOUNTPOINTS "$DEV" | grep -q .; then
  echo "Refusing: something on $DEV is mounted. Unmount it first." >&2
  exit 1
fi

echo "About to ERASE $DEV ($model, $((size/1000**3))GB):"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DEV"
read -rp "Type ERASE to continue: " ok
[[ $ok == ERASE ]] || { echo "Aborted."; exit 1; }

wipefs -a "$DEV"
parted -s "$DEV" mklabel gpt mkpart "$LABEL" 1MiB 100%
udevadm settle
PART=${DEV}1
# The new partition starts where the old one did, so its filesystem signature
# (exFAT from the factory) is still there; clear it.
wipefs -a "$PART"

echo ">> Choose the drive passphrase (you'll need it on the new install):"
# --batch-mode skips cryptsetup's own "type YES" prompt (ERASE above already
# confirmed); --verify-passphrase keeps the type-it-twice check.
cryptsetup luksFormat --type luks2 --label "$LABEL" --batch-mode --verify-passphrase "$PART"
cryptsetup open "$PART" "$MAPPER"
mkfs.ext4 -L "$LABEL" -m 0 "/dev/mapper/$MAPPER"

mnt=$(mktemp -d)
mount "/dev/mapper/$MAPPER" "$mnt"
chown "$OWNER:$OWNER" "$mnt"
# Marker that backup.sh requires before it will rsync --delete into a target.
sudo -u "$OWNER" touch "$mnt/.homebackup-drive"
umount "$mnt"; rmdir "$mnt"
cryptsetup close "$MAPPER"

echo "Done. Unplug/replug (or click it in Files), unlock it, then run ./backup.sh"
