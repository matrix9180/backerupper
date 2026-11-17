#!/usr/bin/env bash
# Show a desktop notification if the last successful backup is too old.
# Run daily by the backerupper-reminder.timer systemd user unit
# (install it with ./install-reminder.sh).
#
# backup.sh records each successful run in ~/.local/state/backerupper/last-backup.
# Override the threshold with BACKERUPPER_REMIND_DAYS (default 7).
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
DAYS=${BACKERUPPER_REMIND_DAYS:-7}
STAMP=${XDG_STATE_HOME:-$HOME/.local/state}/backerupper/last-backup

if [[ -s $STAMP ]] && last=$(date -d "$(cat "$STAMP")" +%s 2>/dev/null); then
  age=$(( ($(date +%s) - last) / 86400 ))
  (( age < DAYS )) && exit 0
  msg="Your last backup was $age days ago ($(date -d "@$last" '+%a %-d %b'))."
else
  msg="No backup has been recorded on this computer yet."
fi

# Clicking "Back up now" (or the notification itself, which GNOME reports as
# the "default" action) opens a terminal running backup.sh. --wait keeps
# notify-send around until the notification is clicked or dismissed.
choice=$(notify-send --app-name=backerupper --icon=drive-removable-media \
  --urgency=normal --wait \
  --action=default="Back up now" --action=backup="Back up now" \
  "Time to back up" "$msg Plug in and unlock the homebackup drive first.")
echo "notification result: ${choice:-dismissed}"   # shows in journalctl --user -u backerupper-reminder

if [[ $choice == backup || $choice == default ]]; then
  ptyxis --new-window -T "Backup" -x \
    "bash -c '\"$HERE/backup.sh\"; echo; read -rp \"Press Enter to close…\"'"
fi
