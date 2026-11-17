# Shared helpers for backup.sh and restore.sh. Source it; don't run it.
# shellcheck shell=bash

# ---------------------------------------------------------------- output
TTY=0; [[ -t 1 ]] && TTY=1
if [[ $TTY -eq 1 ]]; then
  B=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GRN=$'\e[32m' YEL=$'\e[33m' CYN=$'\e[36m' R=$'\e[0m'
else
  B='' DIM='' RED='' GRN='' YEL='' CYN='' R=''
fi
STEPS=${STEPS:-1} STEP=0
step()  { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$B$CYN" "$STEP" "$STEPS" "$1" "$R"; }
ok()    { printf '  %s✓%s %s\n' "$GRN" "$R" "$*"; }
skip()  { printf '  %s- %s%s\n' "$DIM" "$*" "$R"; }
warn()  { printf '  %s! %s%s\n' "$YEL" "$*" "$R" >&2; }
die()   { printf '%sError:%s %s\n' "$RED$B" "$R" "$*" >&2; exit 1; }
hsize() { numfmt --to=iec --suffix=B "$1"; }
has()   { command -v "$1" >/dev/null; }

# Ask a yes/no question. ask "Question?" [default y|n]. With YES=1, always yes.
ask() {
  local q=$1 def=${2:-n} ans hint='[y/N]'
  [[ $def == y ]] && hint='[Y/n]'
  [[ ${YES:-0} -eq 1 ]] && return 0
  [[ -t 0 ]] || die "Need an answer to \"$q\"; run in a terminal or pass --yes."
  read -rp "  $q $hint " ans || ans=''
  ans=${ans:-$def}
  [[ $ans == [yY]* ]]
}

# Run a quiet command with a spinner and elapsed time so it never looks hung.
#   spin "message" <stdout-file> cmd args...    (stderr is shown only on failure)
PIDS=()
spin() {
  local msg=$1 out=$2; shift 2
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 start=$SECONDS rc=0 err
  err=$(mktemp)
  "$@" >"$out" 2>"$err" & local pid=$!
  PIDS+=("$pid")
  if [[ $TTY -eq 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s %s %s(%ds)%s ' "${frames:i++%10:1}" "$msg" "$DIM" $((SECONDS - start)) "$R"
      sleep 0.2
    done
    printf '\r\e[K'
  fi
  wait "$pid" || rc=$?
  [[ $rc -eq 0 ]] || sed 's/^/    /' "$err" | tail -5 >&2
  rm -f "$err"
  return "$rc"
}
kill_spinners() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; }

# ---------------------------------------------------------------- snapshots
# Completed snapshots under $SNAPS, oldest first (skips "latest" and *.partial).
list_snaps() {
  local d
  for d in "$SNAPS"/20??-??-??_??????; do
    if [[ -d $d && ! -L $d ]]; then printf '%s\n' "$d"; fi
  done
}

# Refuse to work on anything but the real backup drive.
check_drive() {
  [[ -f $1/.homebackup-drive ]] || die "no backup drive at $1 (missing .homebackup-drive marker).
       Plug it in and unlock it in Files, or pass the mountpoint as an argument."
}
