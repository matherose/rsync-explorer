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

your-nas:/backup/
├── 2026-05-01_00-44/
├── 2026-05-15_00-44/
├── 2026-05-30_00-44/
└── latest -> 2026-05-30_00-44/

## Building

cmake -B build && cmake --build build

## Configuration

Edit config.ini with your NAS host, user, SSH key and backup root path.

## License

WTFPL (yeah, I don't care what you do with it, as long as it doesn't become my problem).
