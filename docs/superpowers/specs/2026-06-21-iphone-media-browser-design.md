# rsync explorer (iOS) — Design Spec

- **Date:** 2026-06-21
- **Status:** Approved (brainstorming) — ready for implementation planning
- **Author:** Joel Tordjman (with Claude)

## Summary

A new, standalone **SwiftUI iOS app** that browses an rsync snapshot backup on a
NAS over **SFTP** and views its media. It presents the **union of every
snapshot** (newest → oldest) as one Files-app-style tree, so you see every file
that ever existed; files missing from the newest snapshot are flagged with a
**red dot** (openable from the newest snapshot that still has them), and on tap:
shows images in a
swipeable, zoomable **carousel** (all images in the folder) and plays videos in
an **FFmpeg-backed player** that supports AVC → AV1 across all containers.
Read-only — no restoring/writing back to the NAS.

It is a **sibling** to the existing macOS app, not a branch of it. It shares the
repository and the `config.ini` connection model, but **not** the Meson build or
the C engine.

## Goal & non-goals

**Goal:** On an iPhone, connect to the home NAS, browse the full current backup
(via the `latest` symlink), and view photos (as a gallery carousel) and videos
(with broad codec support).

**Non-goals (v1):** restoring/uploading to the NAS, the full snapshot history
timeline (we keep only a red-dot marker for files deleted since the previous
snapshot), multi-server management UI, true network streaming of video,
background/offline sync.

## Background & constraints

The macOS app drives the `ssh` and `rsync` **binaries** to scan a remote NAS and
reconstruct `--link-dest` snapshot history. **iOS forbids `fork`/`exec` of
external binaries**, and ships no system `ssh`/`rsync`. Therefore:

- The C engine's process-spawning parts (`ssh.c`, `scan_remote.c`,
  rsync-based restore) cannot run on iOS and are **not** ported.
- Heavy engine logic (full snapshot indexing, deletion-date classification) is
  out of scope; we keep only a lightweight `latest`-vs-previous deletion diff.
- Networking is replaced by **in-process SFTP** (Citadel / SwiftNIO SSH).

rsync `--link-dest` snapshots are ordinary directories with hardlinks on the NAS;
over SFTP they appear as normal files/folders, so browsing them is transparent.

## Locked decisions

| Decision | Choice |
|---|---|
| Core use case | File browser + image carousel + video player (read-only) |
| Snapshot model | Union of all snapshots (newest→oldest), Files-style push navigation; red dot for files not in the newest snapshot, openable from the newest snapshot that has them |
| Distribution | Sideload from Mac via Xcode + free Apple ID (7-day expiry) |
| Architecture | Fresh native SwiftUI app; no C engine reuse |
| Transport | SFTP over SSH via **Citadel** (ed25519 key + password auth) |
| Video decode | **MobileVLCKit** (FFmpeg: AVC→AV1, all containers; VideoToolbox HW + software fallback; Metal render) |
| Thumbnails | On-disk cache; images via ImageIO, videos via VLCKit thumbnailer |
| Min OS | iOS 17+ (Citadel requires it) |
| Location | New `ios/` directory in this repo (own Xcode project + SwiftPM) |

## Architecture overview

Standalone SwiftUI app, iOS 17+. Dependencies:

- **Citadel** (SPM) — SSH/SFTP; pulls swift-nio-ssh + swift-crypto.
- **MobileVLCKit** — FFmpeg-based playback + video thumbnails (binary framework).
- **ImageIO / Core Image (Metal-backed `CIContext`)** — image thumbnails and
  GPU-accelerated zoom/pan in the carousel.

The UI talks to `SFTPService` through a **protocol**, so SwiftUI previews and
unit tests run against a fake that returns canned listings — no live NAS needed
to develop or test the UI.

## Components

| Component | Responsibility | Depends on |
|---|---|---|
| `ServerConfig` + `CredentialStore` | Connection settings (host, port, user, remote path); key/password in Keychain | Keychain |
| `ConfigImporter` | Optional: parse an imported `config.ini` into `ServerConfig` | — |
| `SFTPService` (actor, protocol-fronted) | `connect`, `listDirectory`, `download(progress:)`, `read(at:length:)`, `resolveLatestSnapshot` | Citadel |
| `HostKeyStore` | Trust-on-first-use host-key pinning | Keychain |
| `FileCache` | Cache downloaded files in `Caches/`, keyed by path+size+mtime; prefetch | SFTPService |
| `ThumbnailService` + `ThumbnailCache` | Generate + cache list thumbnails (images: ImageIO; videos: VLCKit) | SFTPService, VLCKit |
| `DirectoryView` | List one folder; show thumbnails; route taps by file kind | SFTPService, ThumbnailService |
| `MediaCarouselView` | Full-screen swipeable, zoomable gallery of all images in the folder | FileCache, Core Image/Metal |
| `VideoPlayerView` | VLCKit player; download-then-play with progress | FileCache, VLCKit |
| `QuickLookView` | Catch-all preview (PDF/text/docs/etc.) | FileCache |

### Routing by file kind

`DirectoryView` derives a `kind` from the file extension and routes one tap
handler: folder → push deeper · image → `MediaCarouselView` · video →
`VideoPlayerView` · everything else → `QuickLookView`.

## Data flow

1. Launch → load saved `ServerConfig` (Keychain). None → onboarding to enter
   settings or import a `config.ini`.
2. Tap **Connect** → `SFTPService.connect()` (SSH handshake + `openSFTP()`);
   host key pinned on first use (`HostKeyStore`), warn on change.
3. `resolveLatestSnapshot(under: remotePath)` → list remote path, keep
   directories, pick newest by mtime (tiebreak name desc). **Fallback:** if no
   dated subfolders, browse the remote path itself.
4. Push `DirectoryView` rooted at the latest snapshot. Each folder calls
   `listDirectory(path)`; rows show thumbnail, name, size, modified date.
   Pull-to-refresh re-lists.
5. Tap routes per "Routing by file kind" above.

## Media decoding (hardware-first, software fallback)

Single uniform video path via **MobileVLCKit** (libavcodec/libavformat). VLCKit
uses **VideoToolbox hardware decode** when the chip supports the codec and
**automatically falls back to software decode** otherwise, rendering frames on
the **GPU**. This guarantees AVC, HEVC, VP9, AV1 and all containers
(MKV/AVI/WebM/TS/MP4/MOV). v1 is **download-then-play** (file cached, then fed to
the player) with a progress bar.

**Images:** standard JPEG/HEIC/PNG decode via ImageIO (hardware-assisted) and
composite on the GPU. The carousel renders large images and pinch-zoom through a
**Metal-backed `CIContext`** to keep zoom/pan GPU-accelerated.

## Thumbnails

`ThumbnailService` with an on-disk cache (`Caches/thumbs`, keyed by
path+size+mtime, size-capped LRU; persists across launches):

- **Images** → `CGImageSourceCreateThumbnailAtIndex` (decodes only what's
  needed) → small cached JPEG.
- **Videos** → VLCKit thumbnailer grabs a representative frame → downscale →
  cache. Efficient path reads only needed bytes over SFTP (ranged reads via
  `SFTPService.read(at:length:)` / custom AVIO); simple fallback thumbnails only
  files already in `FileCache`.
- Generated lazily for visible rows, off the main thread, concurrency-limited,
  with neighbor prefetch.

## Caching

- `FileCache`: full downloaded files in `Caches/`, key = path+size+mtime, so a
  refreshed backup file changes the key and re-downloads automatically.
- Carousel prefetches ±1 image neighbors for instant swipes.
- Rely on iOS Caches eviction plus a simple size cap.

## Error handling

- Auth / host-unreachable → clear retry screen.
- Per-folder listing errors → inline retry row.
- Download failures → retry; clean up partial files.
- Low disk / very large file → warn.
- Host key changed since first use → warn before proceeding.

## Security

- Private key / password stored **only** in the Keychain — never UserDefaults or
  plaintext.
- Host-key trust-on-first-use pinning (the app keeps its own `known_hosts`
  equivalent in the Keychain).
- Raw SSH sockets are not HTTP, so no App Transport Security exceptions needed.

## Testing

- Unit-test pure logic against the `SFTPService` protocol fake: INI parser,
  latest-snapshot selection, extension→kind classification, cache-key
  derivation, host-key pin/compare.
- SwiftUI previews driven by the fake service (canned listings).
- Manual pass against the real NAS: connect, browse, carousel, video, thumbnails.

## Out of scope (v1)

Restore/upload to NAS · snapshot timeline + deleted-file view · true network
streaming (download-then-play instead) · multi-server management UI ·
background/offline sync · AVPlayer fast-path for native codecs (VLCKit handles
all video uniformly).

## Open questions / verify during planning

1. **OpenSSH key import:** parse the armored `id_ed25519` (OpenSSH private-key
   format) to the 32-byte seed Citadel expects.
2. **MobileVLCKit distribution:** confirm SPM/XCFramework integration and the
   hardware-decode option; confirm the build's video-thumbnail API.
3. **SFTP ranged reads:** confirm Citadel exposes read-at-offset for the
   efficient video-thumbnail path; otherwise use the download-first fallback.
4. **Latest-snapshot heuristic:** confirm mtime+name ordering matches the NAS's
   actual snapshot folder naming; expose an override if not.
5. **libVLC `sftp://` module** (optional v2): if present in the iOS build, could
   enable direct streaming instead of download-then-play.
