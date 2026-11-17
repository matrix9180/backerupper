#!/usr/bin/env bash
# backerupper: snapshot the important parts of $HOME onto the encrypted
# "homebackup" USB stick, along with lists of everything installed system-wide.
#
# Each run creates  snapshots/YYYY-MM-DD_HHMMSS/{home,system}  on the drive.
# Files unchanged since the previous snapshot are hard-linked to it, so each run
# only uses space for what changed, and every snapshot is still a complete,
# browsable copy. When the drive is too full, the oldest snapshots are pruned,
# but only after showing what would go and asking first.
#
# Usage: ./backup.sh [options] [mountpoint]   (default /run/media/$USER/homebackup)
#   -n, --dry-run   show what would be copied/pruned; change nothing
#   -y, --yes       don't ask before pruning old snapshots (for unattended runs)
#       --no-sudo   skip root-only files (NetworkManager Wi-Fi/VPN profiles)
#   -h, --help
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FILTERS=$HERE/filters.txt
DRY=0 YES=0 NO_SUDO=0
MARGIN=${BACKERUPPER_MARGIN:-$((2 * 1024**3))}         # keep at least 2 GiB free after the backup

while [[ $# -gt 0 ]]; do
  case $1 in
    -n|--dry-run) DRY=1 ;;
    -y|--yes)     YES=1 ;;
    --no-sudo)    NO_SUDO=1 ;;
    -h|--help)    sed -n '2,/^set -e/{/^set -e/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)  break ;;
  esac
  shift
done
DEST=${1:-/run/media/$USER/homebackup}
SNAPS=$DEST/snapshots

STEPS=5
# shellcheck source=lib.sh
source "$HERE/lib.sh"

PLAN='' WORK=''
on_exit() {
  local rc=$?
  [[ -n $PLAN ]] && rm -f "$PLAN"
  kill_spinners
  if [[ $rc -ne 0 && -n ${WORK:-} && -d ${WORK:-} ]]; then
    printf '\n%sBackup did not finish.%s Partial copy kept at %s;\nthe next run picks up from there.\n' "$YEL" "$R" "$WORK" >&2
  fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# ---------------------------------------------------------------- 1. checks
step "Checking the backup drive"
command -v rsync >/dev/null || die "rsync is not installed (sudo dnf install rsync)."
[[ -f $FILTERS ]] || die "missing $FILTERS"
check_drive "$DEST"
exec 9>"$DEST/.backerupper.lock"
flock -n 9 || die "another backup is already running on this drive."
ok "Drive mounted at $DEST ($(df -h --output=avail "$DEST" | tail -1 | tr -d ' ') free)"

# Older versions of this script kept a single mirror at $DEST/home + $DEST/system.
# Turn that into the first snapshot (a rename on the same filesystem, so it's instant).
if [[ -d $DEST/home && ! -d $SNAPS ]]; then
  stamp=$(date -d "$(cat "$DEST/system/last-backup.txt" 2>/dev/null || stat -c %y "$DEST/home")" +%F_%H%M%S)
  if [[ $DRY -eq 1 ]]; then
    ok "Would convert the old single-mirror backup into snapshot $stamp"
    PREV_HOME=$DEST/home
  else
    mkdir -p "$SNAPS/$stamp"
    mv "$DEST/home" "$SNAPS/$stamp/home"
    [[ -d $DEST/system ]] && mv "$DEST/system" "$SNAPS/$stamp/system"
    ln -sfn "$stamp" "$SNAPS/latest"
    ok "Converted the old single-mirror backup into snapshot $stamp"
  fi
fi
[[ $DRY -eq 1 ]] || mkdir -p "$SNAPS"

mapfile -t SNAP_LIST < <(list_snaps)
NSNAP=${#SNAP_LIST[@]}
PREV=''; [[ $NSNAP -gt 0 ]] && PREV=${SNAP_LIST[NSNAP-1]}
PREV_HOME=${PREV_HOME:-${PREV:+$PREV/home}}
if [[ -n $PREV_HOME ]]; then
  base=$(basename "$(dirname "$PREV_HOME")"); [[ $base == "$(basename "$DEST")" ]] && base="the old mirror"
  ok "$NSNAP existing snapshot(s); unchanged files will be hard-linked to $base"
else
  ok "No previous snapshot; this first run copies everything"
fi

NAME=$(date +%F_%H%M%S)
WORK=$SNAPS/$NAME.partial
if [[ $DRY -eq 0 ]]; then
  # Resume an interrupted run instead of starting over.
  for p in "$SNAPS"/*.partial; do
    [[ -d $p ]] || continue
    mv "$p" "$WORK"; ok "Resuming interrupted backup $(basename "$p")"; break
  done
  mkdir -p "$WORK/home" "$WORK/system"
fi

if [[ $DRY -eq 0 && $NO_SUDO -eq 0 ]]; then
  echo "  sudo is needed once to copy Wi-Fi/VPN profiles from /etc/NetworkManager (--no-sudo to skip)."
  sudo -v || { warn "No sudo; skipping Wi-Fi/VPN profiles."; NO_SUDO=1; }
fi

# ---------------------------------------------------------------- 2. estimate + prune
step "Working out what changed since the last snapshot"
RSYNC_OPTS=(-aH --delete --delete-excluded --filter="merge $FILTERS")
[[ -n $PREV_HOME ]] && RSYNC_OPTS+=(--link-dest="$PREV_HOME")
PLAN=$(mktemp)
SCAN_DEST=$WORK/home/; [[ $DRY -eq 1 ]] && SCAN_DEST=$(mktemp -d)/home/
spin "Scanning $HOME" "$PLAN" \
  rsync "${RSYNC_OPTS[@]}" --dry-run --stats --out-format='%n' "$HOME/" "$SCAN_DEST" || {
    rc=$?; [[ $rc -eq 23 || $rc -eq 24 ]] || die "rsync scan failed (exit $rc)"; }
NEED_FILES=$(sed -n 's/^Number of regular files transferred: //p' "$PLAN" | tr -d ,)
NEED_BYTES=$(sed -n 's/^Total transferred file size: \([0-9,]*\).*/\1/p' "$PLAN" | tr -d ,)
NEED_BYTES=$(( ${NEED_BYTES:-0} + 50 * 1024**2 ))   # + system lists, volume exports
ok "$NEED_FILES new or changed files, about $(hsize "$NEED_BYTES") to write"

if [[ $DRY -eq 1 ]]; then
  echo "  ${DIM}Files that would be copied:${R}"
  sed -n '/^Number of files:/q; /\/$/d; s/^/    /p' "$PLAN"
fi

AVAIL=$(df --output=avail -B1 "$DEST" | tail -1)
if (( AVAIL < NEED_BYTES + MARGIN )); then
  short=$(( NEED_BYTES + MARGIN - AVAIL ))
  warn "Not enough space: need $(hsize $((NEED_BYTES + MARGIN))) (incl. $(hsize $MARGIN) margin), have $(hsize "$AVAIL")."
  # Snapshots share hard-linked files, so deleting one frees only what no newer
  # snapshot also has. Listing newest-first, du credits each shared file to the
  # newest snapshot holding it, so the number shown for an old snapshot is exactly
  # what deleting it (oldest first) frees.
  [[ $NSNAP -gt 1 ]] || die "No older snapshots to prune. Free up space on the drive or exclude more in filters.txt."
  CANDS=("${SNAP_LIST[@]:0:NSNAP-1}")     # never the newest: it's the link base
  REV=(); for ((i=NSNAP-1; i>=0; i--)); do REV+=("${SNAP_LIST[i]}"); done
  DU=$(mktemp)
  spin "Measuring how much space each old snapshot holds" "$DU" du -sb "${REV[@]}"
  declare -A FREES; while read -r sz path; do FREES[$path]=$sz; done <"$DU"; rm -f "$DU"

  DOOMED=(); freed=0
  for s in "${CANDS[@]}"; do
    (( freed >= short )) && break
    DOOMED+=("$s"); freed=$(( freed + ${FREES[$s]:-0} ))
  done
  (( freed >= short )) || die "Even deleting every older snapshot only frees $(hsize "$freed"); still $(hsize $((short - freed))) short.
       Free up space on the drive or exclude more in filters.txt."

  printf '\n  %s%sWARNING: to make room, these old snapshots will be PERMANENTLY DELETED:%s\n' "$B" "$RED" "$R"
  for s in "${DOOMED[@]}"; do
    printf '    %s%s%s   frees %s\n' "$B" "$(basename "$s")" "$R" "$(hsize "${FREES[$s]:-0}")"
  done
  printf '  Kept: %s\n' "$(for s in "${SNAP_LIST[@]}"; do [[ " ${DOOMED[*]} " == *" $s "* ]] || printf '%s ' "$(basename "$s")"; done)"

  if [[ $DRY -eq 1 ]]; then
    ok "Dry run: nothing deleted."
  else
    ask "Delete them and continue?" n || die "Aborted; nothing was deleted."
    for s in "${DOOMED[@]}"; do
      spin "Deleting $(basename "$s")" /dev/null rm -rf --one-file-system "$s"
      ok "Deleted $(basename "$s")"
    done
    ok "Now $(df -h --output=avail "$DEST" | tail -1 | tr -d ' ') free"
  fi
else
  ok "Enough space ($(hsize "$AVAIL") free)"
fi

if [[ $DRY -eq 1 ]]; then
  printf '\n%sDry run complete; nothing was changed.%s\n' "$B" "$R"
  exit 0
fi

# ---------------------------------------------------------------- 3. system info
step "Recording installed packages and system settings"
SYS=$WORK/system
cap() {   # cap <file> <label> cmd...  : save output, report line count
  local file=$1 label=$2; shift 2
  if "$@" >"$SYS/$file" 2>/dev/null && [[ -s $SYS/$file ]]; then
    ok "$label ($(wc -l <"$SYS/$file") lines)"
  else
    rm -f "$SYS/$file"; skip "$label (not available)"
  fi
}
MISE=$(command -v mise || echo "$HOME/.local/bin/mise")

cap dnf-packages.txt   "dnf user-installed packages" sh -c "dnf repoquery --userinstalled --qf '%{name}\n' | sort -u"
cap dnf-repos.txt      "dnf repositories"            dnf repo list --all
mkdir -p "$SYS/yum.repos.d"; cp /etc/yum.repos.d/*.repo "$SYS/yum.repos.d/" 2>/dev/null && ok "Repo files ($(ls "$SYS/yum.repos.d" | wc -l))"
has flatpak && cap flatpaks.txt        "Flatpak apps"    flatpak list --app --columns=application
has flatpak && cap flatpak-remotes.txt "Flatpak remotes" flatpak remotes --columns=name,url
has code    && cap vscode-extensions.txt "VS Code extensions" code --list-extensions
[[ -x $MISE ]] && cap mise-ls.txt "mise toolchains" "$MISE" ls
has cargo   && cap cargo-installs.txt "cargo installs" sh -c "cargo install --list | grep -v '^ ' | cut -d' ' -f1"
cap dconf-dump.ini     "GNOME settings (dconf)" dconf dump /
cap systemd-user-enabled.txt "Enabled systemd user units" systemctl --user list-unit-files --state=enabled --no-legend
cap crontab.txt        "crontab" crontab -l
cap os-release.txt     "OS version" sh -c 'cat /etc/os-release; uname -a; hostname; echo "HOME=$HOME"'

if has podman; then
  cap podman-containers.json "Podman container definitions" sh -c 'ids=$(podman ps -aq); [ -n "$ids" ] && podman container inspect $ids'
  cap podman-volumes.txt     "Podman volume list" podman volume ls
  mkdir -p "$SYS/podman-volumes"
  for v in $(podman volume ls -q); do
    [[ $v == *cache* ]] && continue      # regenerated by the app
    if spin "Exporting podman volume $v" /dev/null podman volume export "$v" -o "$SYS/podman-volumes/$v.tar"; then
      ok "Podman volume $v ($(du -h "$SYS/podman-volumes/$v.tar" | cut -f1))"
    else
      warn "Couldn't export podman volume $v"
    fi
  done
fi

if [[ $NO_SUDO -eq 0 ]]; then
  mkdir -p "$SYS/etc/NetworkManager"
  if sudo tar -C /etc/NetworkManager -cf - system-connections 2>/dev/null \
       | tar -C "$SYS/etc/NetworkManager" -xf - --no-same-owner; then
    chmod -R go-rwx "$SYS/etc"
    ok "Wi-Fi/VPN profiles ($(ls "$SYS/etc/NetworkManager/system-connections" | wc -l))"
  else
    warn "Couldn't copy NetworkManager profiles"
  fi
fi
date -Is >"$SYS/last-backup.txt"

# ---------------------------------------------------------------- 4. copy home
step "Copying $HOME → $(basename "$WORK" .partial)"
echo "  ${DIM}size copied · % done · speed · time left (the speed is optimistic until the cache flushes in step 5)${R}"
rc=0
rsync "${RSYNC_OPTS[@]}" --no-inc-recursive --info=progress2 --human-readable \
  "$HOME/" "$WORK/home/" || rc=$?
echo
case $rc in
  0)  ok "Home directory copied" ;;
  24) ok "Home directory copied (some files vanished mid-copy, normal for open apps)" ;;
  23) warn "Some files couldn't be read (see errors above); the rest were copied" ;;
  *)  die "rsync failed (exit $rc)" ;;
esac

# ---------------------------------------------------------------- 5. finish
step "Finishing up"
mv "$WORK" "$SNAPS/$NAME"; WORK=''
ln -sfn "$NAME" "$SNAPS/latest"
cp "$HERE/RESTORE.md" "$DEST/RESTORE.md"
mkdir -p "$DEST/backerupper" && cp "$HERE"/{backup.sh,restore.sh,lib.sh,filters.txt,setup-drive.sh,RESTORE.md} "$DEST/backerupper/" 2>/dev/null || true
ok "Snapshot saved as snapshots/$NAME (also: snapshots/latest)"

# A USB stick takes a while to absorb the page cache. Show how much is left
# instead of a silent "sync".
sync -f "$DEST" & SPID=$!; PIDS+=("$SPID")
while kill -0 "$SPID" 2>/dev/null; do
  left=$(awk '/^(Dirty|Writeback):/ {s += $2} END {printf "%d", s / 1024}' /proc/meminfo)
  [[ $TTY -eq 1 ]] && printf '\r  Flushing to the stick: %s MB left to write…  ' "$left"
  sleep 1
done
wait "$SPID"; [[ $TTY -eq 1 ]] && printf '\r\e[K'
ok "All data written to the drive"

echo
echo "  ${B}Snapshots on the drive:${R}"
for s in $(list_snaps); do printf '    %s\n' "$(basename "$s")"; done
echo "  $(df -h --output=used,avail,pcent "$DEST" | tail -1 | awk '{print "Used "$1", "$2" free ("$3" full)"}')"
printf '\n%s%sBackup complete.%s Eject the drive in Files before unplugging.\n' "$B" "$GRN" "$R"
