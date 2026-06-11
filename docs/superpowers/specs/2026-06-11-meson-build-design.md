# Meson + Ninja Build System Migration

**Date:** 2026-06-11
**Status:** Approved (design)

## 1. Problem

The build is split across two ad-hoc systems: `engine/Makefile` (C static
library + three test binaries that run as a side effect of building) and
`build.sh` (one `swiftc` invocation + manual `.app` bundle assembly with
`mkdir`/`cp`). Build outputs (`*.o`, `libengine.a`, the `rsync-explorer`
binary, `rsync-explorer.app/`) land in the source tree. The Makefile always
does `clean && make` via `build.sh`, so every app build recompiles the whole
engine.

## 2. Goal

One Meson project drives everything through Ninja: engine, tests, Swift app,
and `.app` bundle. Out-of-tree builds in `build/`. Incremental rebuilds.
Real test reporting via `meson test`.

## 3. Decisions (settled during brainstorming)

- **Scope:** full single project — root `meson.build` + `engine/meson.build`
  + `app/meson.build`, with the `.app` bundle assembled by a build-time
  `custom_target` (not `meson install`).
- **Old files:** `engine/Makefile` and `build.sh` are **deleted** once Meson
  reproduces everything. One source of truth.
- **Toolchain:** Meson 1.7.0 and Ninja 1.12.1, already installed via MacPorts
  (`/opt/local/bin`).

## 4. Non-Goals

- Xcode project generation, code signing, packaging/DMG.
- CI configuration.
- Changing any compiler flag semantics — the migration reproduces the current
  flags exactly.

## 5. Architecture

```
meson.build              project('rsync-explorer', 'c', 'swift'), options, subdirs
engine/meson.build       static_library('engine') + 3 test executables + test()
app/meson.build          executable('rsync-explorer', Swift sources) + bundle target
scripts/make_bundle.sh   assembles build/rsync-explorer.app (called by custom_target)
```

### 5.1 Root `meson.build`

- `project('rsync-explorer', 'c', 'swift', version: '1.0',
  default_options: ['c_std=c11', 'warning_level=2', 'werror=true',
  'buildtype=debugoptimized', 'optimization=2'])`.
  This reproduces the Makefile's `-std=c11 -Wall -Wextra -Werror -O2`.
- `subdir('engine')` then `subdir('app')`.

### 5.2 `engine/meson.build`

- `threads_dep = dependency('threads')` (replaces `-pthread`).
- `static_library('engine', <12 sources>, c_args: ['-fvisibility=hidden'],
  dependencies: threads_dep)`.
  Sources: config.c discover.c scan.c scan_macos.c scan_posix.c scan_remote.c
  classify.c search.c tree.c ssh.c util.c index.c.
- Three test executables (`test_search`, `test_ssh`, `test_index`), each
  `link_with: libengine` + `test('search', ...)` etc., so `meson test`
  builds and runs them with proper pass/fail reporting. (Today the Makefile
  runs them as a side effect of the build target.)
- `engine_inc = include_directories('.')` exported for the app.

### 5.3 `app/meson.build`

- `executable('rsync-explorer', <10 Swift sources>,
  include_directories: engine_inc, link_with: libengine,
  dependencies: dependency('appleframeworks', modules: ['Cocoa', 'Quartz']))`.
  Swift sources: AppDelegate, EngineBridge, ColumnConfig, LifecycleRow,
  QuickLookTableView, TimelineView, StatusBarController,
  SidebarViewController, FileListViewController, MainWindowController.
- The Swift→C import continues through `engine/module.modulemap`; the engine
  include dir reaches swiftc as `-I engine` exactly as `build.sh` does today.
- **Bundle:** `custom_target('app-bundle', build_by_default: true,
  input: [exe, Info.plist, config.ini], output: 'rsync-explorer.app',
  command: [make_bundle.sh, ...])` producing
  `build/rsync-explorer.app/Contents/{MacOS/rsync-explorer,
  Resources/config.ini}` + `Contents/Info.plist` — the same layout `build.sh`
  produces, but in the build directory.

### 5.4 `scripts/make_bundle.sh`

Small POSIX script: `rm -rf` the output bundle, `mkdir -p` the Contents
dirs, `cp` the executable, `Info.plist`, and `config.ini`. Arguments:
executable path, Info.plist path, config.ini path, output bundle path.

## 6. Workflow

```
meson setup build        # once (or after meson.build changes; ninja re-runs it)
ninja -C build           # engine + app + .app bundle, incremental
meson test -C build      # 3 engine tests
open build/rsync-explorer.app
```

## 7. Deletions / cleanup

- Delete `engine/Makefile` and `build.sh`.
- Remove stale in-tree build artifacts: `engine/*.o`, `engine/libengine.a`,
  `engine/test_search`, `engine/test_ssh`, `engine/test_index`,
  `engine/test_engine*`, root `rsync-explorer` binary, root
  `rsync-explorer.app/`, `app/*.o`.
- Add `.gitignore` entry for `build/` (and the artifact patterns above so
  stale copies never get committed).

## 8. Error Handling / Risks

- **Meson Swift support is less traveled than C.** If `include_directories`
  does not reach swiftc as `-I`, fall back to explicit
  `swift_args: ['-I', meson.project_source_root() / 'engine']`.
- **SDK detection:** if swiftc invoked by Meson misses the macOS SDK, add
  `swift_args: ['-sdk', <xcrun --show-sdk-path output>]` via
  `run_command('xcrun', '--show-sdk-path')` at setup time.
- **Mixed-language linking:** the Swift executable links a C static library —
  supported by Meson (`link_with:`); the languages are never mixed inside a
  single target.

## 9. Testing / Acceptance

- `meson setup build` succeeds with no warnings about missing tools.
- `ninja -C build` compiles engine + app with **zero compiler warnings**
  (werror catches regressions) and produces `build/rsync-explorer.app`.
- `meson test -C build` reports 3/3 tests passing
  (`search`, `ssh`, `index`).
- A second `ninja -C build` with no changes is a no-op (incrementality).
- `open build/rsync-explorer.app` launches (manual check).

## 10. Affected Files

- **New:** `meson.build`, `engine/meson.build`, `app/meson.build`,
  `scripts/make_bundle.sh`, `.gitignore` (or extend if created earlier).
- **Deleted:** `engine/Makefile`, `build.sh`, stale in-tree artifacts (§7).
