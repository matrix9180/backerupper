#!/usr/bin/env bash
# Install (or remove) the systemd user timer that runs backup-reminder.sh once
# a day and shortly after login.
#
# Usage: ./install-reminder.sh            install / update and enable
#        ./install-reminder.sh --remove   disable and delete the units
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
UNITS=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
NAME=backerupper-reminder

if [[ ${1:-} == --remove ]]; then
  systemctl --user disable --now "$NAME.timer" 2>/dev/null || true
  rm -f "$UNITS/$NAME.service" "$UNITS/$NAME.timer"
  systemctl --user daemon-reload
  echo "Backup reminder removed."
  exit 0
fi

mkdir -p "$UNITS"
cat >"$UNITS/$NAME.service" <<EOF
[Unit]
Description=Remind me to back up to the homebackup drive
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=$HERE/backup-reminder.sh
# notify-send --wait sits until the notification is clicked or dismissed.
TimeoutStartSec=infinity
EOF

cat >"$UNITS/$NAME.timer" <<EOF
[Unit]
Description=Daily check for a stale backup

[Timer]
OnStartupSec=10min
OnCalendar=daily
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
EOF

# Seed the "last backup" time from the drive, if it's mounted and we have none.
STAMP=${XDG_STATE_HOME:-$HOME/.local/state}/backerupper/last-backup
DRIVE=/run/media/$USER/homebackup
if [[ ! -s $STAMP ]]; then
  for f in "$DRIVE"/snapshots/latest/system/last-backup.txt "$DRIVE"/system/last-backup.txt; do
    if [[ -s $f ]]; then mkdir -p "$(dirname "$STAMP")"; cp "$f" "$STAMP"; break; fi
  done
fi

systemctl --user daemon-reload
systemctl --user enable --now "$NAME.timer"
echo "Backup reminder installed. Next check:"
systemctl --user list-timers "$NAME.timer" --no-pager | sed -n 2p
[[ -s $STAMP ]] && echo "Last backup on record: $(cat "$STAMP")"
