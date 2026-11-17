#!/usr/bin/env bash
# backerupper restore: bring a snapshot from the "homebackup" drive back onto
# this machine (typically a fresh Fedora install).
#
# Goes through these steps, asking before each one:
#   home      copy your home directory back (replaced files are kept aside)
#   wifi      Wi-Fi / VPN profiles (sudo)
#   packages  dnf repos + RPM Fusion + every package you had installed (sudo)
#   flatpak   Flatpak remotes + apps
#   dev       mise toolchains, cargo tools, VS Code extensions
#   podman    Podman volumes (Jellyfin config) + Quadlet containers
#   gnome     GNOME settings (dconf)
#
# Usage: ./restore.sh [options] [mountpoint]   (default /run/media/$USER/homebackup)
#   -s, --snapshot NAME   restore this snapshot instead of the newest
#   -l, --list            list snapshots and exit
#   -o, --only a,b,...    run only these steps (names above)
#   -n, --dry-run         show what each step would do; change nothing
#   -y, --yes             don't ask; run every (selected) step
#   -h, --help
#
# Easiest on a fresh install: unlock the drive in Files, then run
#   /run/media/$USER/homebackup/backerupper/restore.sh
set -uo pipefail     # no -e: one failed step shouldn't abort the whole restore

HERE=$(cd "$(dirname "$0")" && pwd)
ALL_STEPS=(home wifi packages flatpak dev podman gnome)
DRY=0 YES=0 ONLY='' PICK='' LIST=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -s|--snapshot) PICK=${2:?--snapshot needs a name}; shift ;;
    -l|--list)     LIST=1 ;;
    -o|--only)     ONLY=,${2:?--only needs step names},; shift ;;
    -n|--dry-run)  DRY=1 ;;
    -y|--yes)      YES=1 ;;
    -h|--help)     sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
    *)  break ;;
  esac
  shift
done
if [[ -n $ONLY ]]; then
  for s in ${ONLY//,/ }; do [[ " ${ALL_STEPS[*]} " == *" $s "* ]] || { echo "Unknown step: $s" >&2; exit 2; }; done
  STEPS=$(tr ',' '\n' <<<"$ONLY" | grep -c .)
else
  STEPS=${#ALL_STEPS[@]}
fi
# shellcheck source=lib.sh
source "$HERE/lib.sh"
trap kill_spinners EXIT
if [[ $DRY -eq 1 ]]; then   # make it obvious nothing actually happened
  ok() { printf '  %s✓%s %s %s(dry run)%s\n' "$GRN" "$R" "$*" "$DIM" "$R"; }
fi
trap 'echo; exit 130' INT TERM

DEST=${1:-/run/media/$USER/homebackup}
SNAPS=$DEST/snapshots
check_drive "$DEST"

# ---------------------------------------------------------------- pick snapshot
snap_name() { if [[ $1 == "$DEST" ]]; then echo "old-mirror"; else basename "$1"; fi; }
mapfile -t SNAP_LIST < <(list_snaps)
if [[ ${#SNAP_LIST[@]} -eq 0 && -d $DEST/home ]]; then
  SNAP_LIST=("$DEST")          # drive still uses the old single-mirror layout
fi
[[ ${#SNAP_LIST[@]} -gt 0 ]] || die "No snapshots found on $DEST."

if [[ $LIST -eq 1 ]]; then
  echo "Snapshots on $DEST (newest last):"
  for s in "${SNAP_LIST[@]}"; do printf '  %s\n' "$(snap_name "$s")"; done
  exit 0
fi
if [[ -n $PICK ]]; then
  SNAP=$SNAPS/$PICK
  [[ -d $SNAP/home ]] || die "No snapshot named $PICK (see --list)."
else
  SNAP=${SNAP_LIST[-1]}
fi
SYS=$SNAP/system
OLD_HOME=$(sed -n 's/^HOME=//p' "$SYS/os-release.txt" 2>/dev/null)
OLD_HOME=${OLD_HOME:-/home/matrix9180}   # snapshots made before HOME was recorded

printf '%sRestoring from snapshot %s%s\n' "$B" "$(snap_name "$SNAP")" "$R"
[[ -f $SYS/last-backup.txt ]] && echo "  taken $(date -d "$(cat "$SYS/last-backup.txt")" '+%A %-d %B %Y, %H:%M')"
[[ $DRY -eq 1 ]] && echo "  ${YEL}Dry run: nothing will be changed.${R}"

declare -A RESULT
mark() { if [[ $DRY -eq 1 && $2 != skipped && $2 != "none saved" ]]; then RESULT[$1]="dry run"; else RESULT[$1]=$2; fi; }

# begin <name> <title> <description>: prints the header; returns 1 to skip.
begin() {
  local name=$1 title=$2 desc=$3
  if [[ -n $ONLY && $ONLY != *",$name,"* ]]; then return 1; fi
  step "$title"
  printf '  %s%s%s\n' "$DIM" "$desc" "$R"
  if [[ $DRY -eq 0 ]] && ! ask "Run this step?" y; then
    skip "Skipped"; mark "$name" skipped; return 1
  fi
}

# run cmd...: run it, or just print it in dry-run mode.
run() {
  if [[ $DRY -eq 1 ]]; then printf '  %swould run:%s %s\n' "$DIM" "$R" "$*"; return 0; fi
  "$@"
}

SUDO_OK=0
need_sudo() {
  [[ $DRY -eq 1 || $SUDO_OK -eq 1 ]] && return 0
  sudo -v && SUDO_OK=1
}

# ================================================================ home
do_home() {
  begin home "Home directory" \
    "Copies $SNAP/home back into $HOME. Files that would be replaced are moved to ~/.restore-replaced/ first, nothing is deleted." || return 0
  local replaced=$HOME/.restore-replaced/$(date +%F_%H%M%S) plan
  local opts=(-aH --backup --backup-dir="$replaced")
  plan=$(mktemp)
  spin "Comparing the snapshot with $HOME" "$plan" \
    rsync "${opts[@]}" --dry-run --itemize-changes "$SNAP/home/" "$HOME/"
  local new changed
  new=$(grep -c '^>f+++++++++' "$plan"); changed=$(grep '^>f' "$plan" | grep -vc '^>f+++++++++')
  rm -f "$plan"
  ok "$new files to add, $changed existing files to replace"
  if [[ $DRY -eq 1 ]]; then mark home "dry run"; return 0; fi

  echo "  ${DIM}size copied · % done · speed · time left${R}"
  local rc=0
  rsync "${opts[@]}" --no-inc-recursive --info=progress2 --human-readable "$SNAP/home/" "$HOME/" || rc=$?
  echo
  if [[ $rc -ne 0 && $rc -ne 23 && $rc -ne 24 ]]; then
    warn "rsync failed (exit $rc)"; mark home failed; return 0
  fi
  ok "Home directory restored"
  [[ -d $replaced ]] && ok "Replaced files saved in ${replaced/#$HOME/\~}"

  if has restorecon; then
    spin "Fixing SELinux labels (restorecon)" /dev/null restorecon -R "$HOME" \
      && ok "SELinux labels fixed" || warn "restorecon reported problems"
  fi
  if [[ -d $HOME/.ssh ]]; then
    chmod 700 "$HOME/.ssh"
    find "$HOME/.ssh" -type f ! -name '*.pub' ! -name 'known_hosts*' -exec chmod 600 {} +
    ok "~/.ssh permissions tightened"
  fi
  if [[ $OLD_HOME != "$HOME" ]]; then
    warn "This snapshot came from $OLD_HOME but your home is now $HOME."
    warn "These files still mention the old path; fix them by hand:"
    { grep -rlI --exclude-dir=.restore-replaced -F "$OLD_HOME" \
        "$HOME"/.bashrc "$HOME"/.bashrc.d "$HOME"/.config/containers/systemd 2>/dev/null
      find "$HOME/.local/bin" -lname "$OLD_HOME/*" 2>/dev/null
    } | sed 's/^/      /'
  fi
  mark home done
}

# ================================================================ wifi
do_wifi() {
  local src=$SYS/etc/NetworkManager/system-connections
  begin wifi "Wi-Fi and VPN profiles" "Installs saved network profiles into /etc/NetworkManager (needs sudo)." || return 0
  if [[ ! -d $src ]] || [[ -z $(ls -A "$src") ]]; then skip "None in this snapshot"; mark wifi "none saved"; return 0; fi
  ls "$src" | sed 's/\.nmconnection$//; s/^/    /'
  need_sudo || { warn "No sudo"; mark wifi failed; return 0; }
  run sudo install -m 600 -o root -g root "$src"/* /etc/NetworkManager/system-connections/ &&
  run sudo restorecon -R /etc/NetworkManager/system-connections &&
  run sudo nmcli connection reload &&
  { ok "Profiles installed"; mark wifi done; } || { warn "Couldn't install profiles"; mark wifi failed; }
}

# ================================================================ packages
do_packages() {
  begin packages "System packages" "Adds your extra dnf repos and RPM Fusion, then installs every package you had (needs sudo)." || return 0
  need_sudo || { warn "No sudo"; mark packages failed; return 0; }
  local f added=0 status=done
  for f in "$SYS"/yum.repos.d/*.repo; do
    [[ -e $f ]] || continue
    if [[ -e /etc/yum.repos.d/$(basename "$f") ]]; then continue; fi
    run sudo install -m 644 "$f" /etc/yum.repos.d/ && added=$((added + 1))
  done
  ok "$added repo file(s) added"
  if grep -qi rpmfusion "$SYS/dnf-repos.txt" 2>/dev/null && ! rpm -q rpmfusion-free-release >/dev/null 2>&1; then
    local v; v=$(rpm -E %fedora)
    run sudo dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$v.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$v.noarch.rpm" \
      && ok "RPM Fusion enabled" || { warn "RPM Fusion install failed"; status=partial; }
  fi
  if [[ -s $SYS/dnf-packages.txt ]]; then
    local missing
    mapfile -t missing < <(comm -23 <(sort -u "$SYS/dnf-packages.txt") <(rpm -qa --qf '%{NAME}\n' | sort -u))
    if [[ ${#missing[@]} -eq 0 ]]; then
      ok "All $(wc -l <"$SYS/dnf-packages.txt") packages already installed"
    else
      echo "  ${#missing[@]} package(s) to install (dnf shows its own progress):"
      if run sudo dnf install -y --skip-unavailable "${missing[@]}"; then
        ok "Packages installed"
      else
        warn "dnf reported errors"; status=partial
      fi
    fi
  fi
  mark packages "$status"
}

# ================================================================ flatpak
do_flatpak() {
  begin flatpak "Flatpak apps" "Adds Flathub and reinstalls your Flatpak apps." || return 0
  has flatpak || { warn "flatpak isn't installed (run the packages step first)"; mark flatpak failed; return 0; }
  [[ -s $SYS/flatpaks.txt ]] || { skip "None in this snapshot"; mark flatpak "none saved"; return 0; }
  run flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  local missing
  mapfile -t missing < <(comm -23 <(sort -u "$SYS/flatpaks.txt") <(flatpak list --app --columns=application | sort -u))
  if [[ ${#missing[@]} -eq 0 ]]; then ok "All apps already installed"; mark flatpak done; return 0; fi
  printf '    %s\n' "${missing[@]}"
  if run flatpak install -y --noninteractive flathub "${missing[@]}"; then
    ok "Flatpak apps installed"; mark flatpak done
  else
    warn "flatpak reported errors"; mark flatpak partial
  fi
}

# ================================================================ dev
do_dev() {
  begin dev "Developer toolchains" "mise install (Ruby, Python, Rust, Node, ...), then cargo tools and VS Code extensions. Can take a while." || return 0
  local mise status=done
  mise=$(command -v mise || echo "$HOME/.local/bin/mise")
  if [[ -x $mise && -f $HOME/.config/mise/config.toml ]]; then
    run "$mise" trust "$HOME/.config/mise/config.toml" >/dev/null
    (cd "$HOME" && run "$mise" install) && ok "mise toolchains installed" || { warn "mise install had errors"; status=partial; }
  else
    skip "mise or its config not found (restore home first)"
  fi
  if [[ -s $SYS/cargo-installs.txt ]]; then
    local cargo=(cargo); has cargo || cargo=("$mise" exec -- cargo)
    local tools; mapfile -t tools <"$SYS/cargo-installs.txt"
    run "${cargo[@]}" install "${tools[@]}" && ok "cargo tools installed" || { warn "cargo install had errors"; status=partial; }
  fi
  if [[ -s $SYS/vscode-extensions.txt ]]; then
    if has code; then
      local e n=0
      while read -r e; do run code --install-extension "$e" >/dev/null && n=$((n + 1)); done <"$SYS/vscode-extensions.txt"
      ok "$n VS Code extension(s) installed"
    else
      skip "VS Code not installed; extensions skipped"
    fi
  fi
  mark dev "$status"
}

# ================================================================ podman
do_podman() {
  begin podman "Podman containers" "Recreates Podman volumes (Jellyfin config) and starts your Quadlet containers." || return 0
  has podman || { warn "podman isn't installed (run the packages step first)"; mark podman failed; return 0; }
  local tar v status=done
  # Volumes that were exported, plus empty ones (caches) that just need to exist.
  for tar in "$SYS"/podman-volumes/*.tar; do
    [[ -e $tar ]] || continue
    v=$(basename "$tar" .tar)
    if podman volume exists "$v"; then
      ask "Volume $v already exists. Overwrite its contents from the backup?" n || { skip "Kept existing volume $v"; continue; }
    else
      run podman volume create "$v" >/dev/null
    fi
    if [[ $DRY -eq 1 ]]; then run podman volume import "$v" "$tar"; continue; fi
    spin "Importing volume $v" /dev/null podman volume import "$v" "$tar" \
      && ok "Volume $v restored" || { warn "Couldn't import $v"; status=partial; }
  done
  if [[ -s $SYS/podman-volumes.txt ]]; then
    awk 'NR > 1 {print $2}' "$SYS/podman-volumes.txt" | while read -r v; do
      podman volume exists "$v" || { run podman volume create "$v" >/dev/null && ok "Volume $v created (empty)"; }
    done
  fi
  local q units=()
  for q in "$HOME"/.config/containers/systemd/*.container; do
    [[ -e $q ]] && units+=("$(basename "$q" .container).service")
  done
  if [[ ${#units[@]} -gt 0 ]]; then
    run systemctl --user daemon-reload
    for q in "${units[@]}"; do
      if [[ $DRY -eq 1 ]]; then run systemctl --user start "$q"; continue; fi
      # First start pulls the image, which can take a few minutes.
      spin "Starting $q (pulls the image on first run)" /dev/null systemctl --user start "$q" \
        && ok "$q running" || { warn "$q failed to start: journalctl --user -u $q"; status=partial; }
    done
  else
    skip "No Quadlet .container files in ~/.config/containers/systemd (restore home first)"
  fi
  mark podman "$status"
}

# ================================================================ gnome
do_gnome() {
  begin gnome "GNOME settings" "Loads your saved dconf settings (keyboard shortcuts, extensions, appearance, ...)." || return 0
  [[ -s $SYS/dconf-dump.ini ]] || { skip "None in this snapshot"; mark gnome "none saved"; return 0; }
  if run dconf load / <"$SYS/dconf-dump.ini"; then ok "Settings loaded"; mark gnome done
  else warn "dconf load failed"; mark gnome failed; fi
}

for s in "${ALL_STEPS[@]}"; do "do_$s"; done

# ================================================================ summary
printf '\n%sSummary%s\n' "$B" "$R"
for s in "${ALL_STEPS[@]}"; do
  r=${RESULT[$s]:-}
  [[ -z $r ]] && continue
  case $r in
    done)           c=$GRN ;;
    failed|partial) c=$RED ;;
    *)              c=$DIM ;;
  esac
  printf '  %-9s %s%s%s\n' "$s" "$c" "$r" "$R"
done
if [[ $DRY -eq 0 ]]; then
  echo
  echo "Log out and back in (or reboot) so the shell, GNOME settings and keyring all pick up the restored files."
  echo "See RESTORE.md for anything you need to reinstall by hand (Steam, Android Studio, Discord, ...)."
fi
