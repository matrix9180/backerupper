# backerupper

Bash scripts that back up a Fedora home directory to an encrypted USB stick,
and bring it all back on a fresh install.

- **Snapshots, not a mirror.** Each run makes a dated folder like
  `snapshots/2026-11-17_133856/`. Unchanged files are hard-linked to the previous
  snapshot (`rsync --link-dest`), so each run only uses space for what changed,
  yet every snapshot is a complete copy you can browse.
- **Shows progress.** Numbered steps, overall copy progress with speed and time
  left, spinners on long scans, and a live "MB left to flush" count at the end so
  a slow USB stick never looks hung.
- **Prunes safely.** Before copying, it works out how much space the run needs.
  If the drive is too full, it lists which old snapshots would be deleted and how
  much each would free, and asks first. It never deletes the newest snapshot.
- **More than files.** It also saves lists of dnf packages and repos, Flatpaks,
  mise toolchains, cargo tools and VS Code extensions, plus a GNOME settings dump,
  NetworkManager Wi-Fi/VPN profiles and Podman volume exports.
- **Guided restore.** `restore.sh` walks through restoring home, Wi-Fi, packages,
  Flatpaks, toolchains, Podman containers and GNOME settings, asking before each
  step. Any file it would overwrite is moved aside first.
- **Reminders.** An optional systemd timer shows a notification, with a
  "Back up now" button, when the last backup is more than a week old.

## Files

| File | What it does |
|---|---|
| `setup-drive.sh` | One-time: wipes the USB stick and creates a LUKS2-encrypted ext4 volume labelled `homebackup` |
| `backup.sh` | Makes a snapshot of `$HOME` and the system info |
| `restore.sh` | Restores a snapshot, one step at a time |
| `filters.txt` | What to skip: caches, toolchains, games, build output |
| `lib.sh` | Shared output and progress helpers |
| `backup-reminder.sh`, `install-reminder.sh` | Daily "time to back up" notification |
| `RESTORE.md` | Restore instructions, including the manual steps (also copied to the drive) |

## Usage

```bash
sudo ./setup-drive.sh            # once: format the stick (asks you to type ERASE)

# Unlock the drive in Files (it mounts at /run/media/$USER/homebackup), then:
./backup.sh -n                   # preview: what would be copied or pruned
./backup.sh                      # back up

./install-reminder.sh            # optional: nag after 7 days without a backup
```

On a fresh install, unlock the drive and run the copy of the scripts the
backup keeps on it:

```bash
/run/media/$USER/homebackup/backerupper/restore.sh -n    # preview every step
/run/media/$USER/homebackup/backerupper/restore.sh       # restore
```

Options: `backup.sh [-n] [-y] [--no-sudo] [mountpoint]`.
`restore.sh [-n] [-y] [--list] [--snapshot NAME] [--only home,wifi,...] [mountpoint]`.
Run either one with `--help` for details.

## Adapting it

It's written for one machine, so check these first:

- `filters.txt` names some of my own folders; edit it to suit your home.
- `setup-drive.sh` refuses to run unless the target is a USB disk of roughly
  100–140 GB, as a safety check. Change the size range for your drive.
- `backup.sh` only writes to a drive with a `.homebackup-drive` marker file in
  its root (`setup-drive.sh` creates it).

Requires bash, rsync and coreutils. It uses dnf, flatpak, podman, mise, dconf
and NetworkManager when they're present.
