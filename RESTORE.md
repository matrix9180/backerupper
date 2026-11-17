# Restoring onto a fresh Fedora install

Drive layout:

```
snapshots/
  2026-11-16_211705/      one folder per backup run, each a complete copy
    home/                 your home directory (Projects, dotfiles, .config, .ssh, media, ...)
    system/               package lists, repo files, dconf dump, Wi-Fi profiles, podman volumes
  latest -> 2026-...      symlink to the newest snapshot
RESTORE.md                this file
```

Unchanged files are hard-linked between snapshots, so each extra snapshot only
costs the space of what changed. To get back a file you deleted or broke, just
browse an older snapshot and copy it out.

## The quick way: restore.sh

Unlock the drive in Files, then:

```bash
/run/media/$USER/homebackup/backerupper/restore.sh -n   # preview every step
/run/media/$USER/homebackup/backerupper/restore.sh      # do it, asking before each step
```

It goes through home → Wi-Fi → packages → Flatpaks → toolchains → Podman → GNOME
settings and does everything in sections 1–7 below. Useful options:
`--list`, `--snapshot 2026-11-16_211705`, `--only home,wifi`, `--yes`.
Files it would overwrite in your home are moved to `~/.restore-replaced/<date>/`
first; nothing is deleted.

The manual steps below are the same thing by hand, if the script can't run.

## 1. Copy home back

Plug the drive in, unlock it in Files (it asks for the passphrase), then:

```bash
B=/run/media/$USER/homebackup/snapshots/latest
cp -a "$B/home/." ~/          # -a keeps permissions, symlinks, timestamps
restorecon -R ~               # fix SELinux labels (otherwise ssh rejects ~/.ssh)
chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_ed25519
```

If your username on the new install isn't `matrix9180`, fix the hardcoded
paths in `~/.bashrc` (mise line) and the `~/.local/bin` symlinks.

## 2. Wi-Fi and VPN profiles

```bash
sudo cp "$B"/system/etc/NetworkManager/system-connections/* /etc/NetworkManager/system-connections/
sudo chown root:root /etc/NetworkManager/system-connections/*
sudo chmod 600 /etc/NetworkManager/system-connections/*
sudo restorecon -R /etc/NetworkManager/system-connections
sudo nmcli connection reload
```

## 3. Repos + packages

```bash
sudo cp "$B"/system/yum.repos.d/{vscode,docker-ce,protonvpn-stable,chatgpt}.repo /etc/yum.repos.d/
# RPM Fusion (Steam, NVIDIA):
sudo dnf install \
  https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install --skip-unavailable $(cat "$B/system/dnf-packages.txt")
```

`system/dnf-repos.txt` lists every repo that was configured, in case one is missing above.

## 4. Flatpaks, VS Code extensions, cargo tools

```bash
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
xargs -a "$B/system/flatpaks.txt" flatpak install -y flathub
xargs -a "$B/system/vscode-extensions.txt" -n1 code --install-extension   # if present
xargs -a "$B/system/cargo-installs.txt" cargo install                     # after step 5
```

## 5. Language toolchains (mise)

`~/.local/bin/mise` and `~/.config/mise/config.toml` come back with home, so:

```bash
exec bash        # reload shell so mise activates
mise install     # reinstalls ruby, python, rust, node, cmake, perl, starship, d6...
```

`system/mise-ls.txt` has the exact versions that were installed.

## 6. Jellyfin (podman)

```bash
podman volume create jellyfin-config
podman volume import jellyfin-config "$B/system/podman-volumes/jellyfin-config.tar"
podman volume create jellyfin-cache
```

Then recreate the container. Its original ports, mounts and environment are in
`system/podman-containers.json` (look at `.HostConfig.PortBindings`, `.Mounts`,
`.Config.Env`). The media library is under `~/media`, which came back with home.

## 7. GNOME settings

They come back via `~/.config/dconf/user`. If they don't apply, run:
`dconf load / < "$B/system/dconf-dump.ini"`

## Not backed up (reinstall or log in again)

- **Claude Code / Codex CLI binaries**: install again. Config and sessions in `~/.claude` and `~/.codex` come back with home.
- **Android Studio + SDK**: `~/android-studio`, `~/Android`, AVDs. `~/.android` (adbkey, debug.keystore) *is* kept.
- **Steam, Lutris, games, Spotify** (`~/.var`): reinstall, then sign in.
- **Discord**: log in again.
- **Podman images** (re-pulled automatically), GNOME Boxes VMs.
- **ISOs/.deb/.rpm** in Documents/Downloads.
- `node_modules`, `target`, `.venv`, `.gradle` under Projects: run `npm install` / `cargo build` etc. again.

Full exclude list: `filters.txt` next to `backup.sh`.
