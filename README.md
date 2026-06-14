# rsync-explorer
Graphical file explorer for browsing rsync snapshot backups

Built for setups using `--link-dest` incremental snapshots over SSH.
No agents, no dependencies, no backup logic — just a clean UI on top
of tools you already have.

## Features

- Browse any snapshot in your backup history
- Files deleted from source shown with their deletion date
- File metadata: size, permissions, modified date
- Restore any file or folder from any snapshot via rsync

## Expected Backup Structure
```
your-nas:/backup/
├── 2026-05-01_00-44/
├── 2026-05-15_00-44/
├── 2026-05-30_00-44/
└── latest -> 2026-05-30_00-44/
```

## Building

macOS only — the UI is Swift/AppKit. Tested on macOS 14+.

### Prerequisites

- Xcode Command Line Tools (`xcode-select --install`)
- [Meson](https://mesonbuild.com/) and [Ninja](https://ninja-build.org/)

```sh
brew install meson ninja        # Homebrew
# or
sudo port install meson ninja   # MacPorts
```

### Compile

```sh
meson setup build
meson compile -C build
```

This builds the C engine (`engine/libengine.a`), the Swift app, and assembles
the macOS bundle in one shot. The `.app` bundle is the default target — no
extra step required.

Output: `build/rsync-explorer.app`

### Run

```sh
open build/rsync-explorer.app
```

To see engine stderr (useful when debugging), launch the executable directly
from a terminal instead:

```sh
build/rsync-explorer.app/Contents/MacOS/rsync-explorer
```

### Tests

```sh
meson test -C build
```

Runs the C engine test suite (`search`, `ssh`, `index`).


## Configuration

Edit the config.ini file by specifying your NAS hostname, username, SSH key, and the root path for the backup.
You can add as many entries as you like, provided you follow this format:

- Local:
  1. Start with [local.<name_of_your_choice>]
  2. Specify a destination as an absolute path (you can use a relative path if you wish, but this is not recommended)

- Remote:
  1. Start with [remote.<name_of_your_choice>]
  2. Add the desired user with ssh_user=<ssh_user>
  3. Add the desired private key with ssh_key=<ssh_key>
    3b. If you do not have an SSH key, add the desired password with ssh_pass=<ssh_password>
  4. Add a destination with an absolute path (as with the local configuration; you can use a relative path if you wish, but this is not recommended)

Good to know:
- If you configure key=value entries specific to remote access in the local configuration, rsync-explorer will simply ignore them
- It is recommended to use ssh_key rather than ssh_pass. If both are specified, ssh_pass will be ignored in favor of ssh_key. If ssh_key does not work, simply remove that entry.

### config.ini example
```
[local.myfolder]
dest=/media/external-drive

[remote.nas1]
host=192.168.1.100
ssh_user=user1
ssh_key=/home/myuser/.ssh/id_ed25519
dest=/mnt/nas/mybackupfolder
```

## License

WTFPL (yeah, I don't care what you do with it, as long as it doesn't become my problem).

-----

Don't expect regular updates—once it's up and running, I won't touch it again (unless I suddenly feel like adding new features, but I'm incredibly lazy, or more realistically, when there are problems).
