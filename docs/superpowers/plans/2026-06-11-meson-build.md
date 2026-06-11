# Meson + Ninja Build Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `engine/Makefile` + `build.sh` with a single Meson project (Ninja backend) that builds the C engine, runs its tests via `meson test`, compiles the Swift app, and assembles `build/rsync-explorer.app`.

**Architecture:** Root `meson.build` declares a mixed C/Swift project and reproduces the current flags (`-std=c11 -Wall -Wextra -Werror -O2`). `engine/meson.build` builds `libengine.a` and registers the three test binaries. `app/meson.build` builds the Swift executable against the engine (module import via the existing `engine/module.modulemap`). A `custom_target` calls `scripts/make_bundle.sh` to assemble the `.app` bundle in the build dir. Old build files and stale in-tree artifacts are then deleted.

**Tech Stack:** Meson 1.7.0 + Ninja 1.12.1 (installed at `/opt/local/bin`), clang, swiftc, AppKit/Quartz frameworks.

**Spec:** `docs/superpowers/specs/2026-06-11-meson-build-design.md`

**Note on TDD:** Build-system files have no unit tests; each task's "test" is an exact build/test command with its expected output. The engine's three existing C tests act as the regression suite throughout.

**Repo facts you need:**
- `engine/Makefile` and `config.ini` are **tracked**; `build.sh`, `Info.plist`, and everything under `app/` are currently **untracked** (the branch-wide source cleanup commit happens later, outside this plan).
- The Swift code does `import engine`, resolved by `engine/module.modulemap` when swiftc gets `-I <repo>/engine`.
- `Info.plist` has `CFBundleExecutable = rsync-explorer`, so the binary copied into `Contents/MacOS/` must keep that exact name.

---

### Task 1: Root project + engine library + tests

**Files:**
- Create: `meson.build` (repo root)
- Create: `engine/meson.build`

- [ ] **Step 1: Write the root `meson.build`**

```meson
project('rsync-explorer', 'c', 'swift',
  version: '1.0',
  default_options: [
    'c_std=c11',
    'warning_level=2',
    'werror=true',
    'buildtype=debugoptimized',
  ],
)

subdir('engine')
```

`warning_level=2` = `-Wall -Wextra`, `werror=true` = `-Werror`, `buildtype=debugoptimized` = `-O2 -g` (the Makefile used plain `-O2`; the added `-g` is harmless and useful).

- [ ] **Step 2: Write `engine/meson.build`**

```meson
threads_dep = dependency('threads')

engine_sources = files(
  'config.c',
  'discover.c',
  'scan.c',
  'scan_macos.c',
  'scan_posix.c',
  'scan_remote.c',
  'classify.c',
  'search.c',
  'tree.c',
  'ssh.c',
  'util.c',
  'index.c',
)

libengine = static_library('engine', engine_sources,
  c_args: ['-fvisibility=hidden'],
  dependencies: threads_dep,
)

engine_inc = include_directories('.')

foreach t : ['search', 'ssh', 'index']
  test_exe = executable('test_' + t, 'test_' + t + '.c',
    include_directories: engine_inc,
    link_with: libengine,
    dependencies: threads_dep,
  )
  test(t, test_exe)
endforeach
```

(`engine_inc` and `libengine` are read by `app/meson.build` in Task 2 — Meson subdir variables are global.)

- [ ] **Step 3: Configure and build**

Run: `cd /Users/joeltordjman/Documents/GIT/rsync-explorer && meson setup build`
Expected: ends with a target summary, no errors. Both `c` and `swift` compilers detected.

Run: `ninja -C build`
Expected: compiles 12 C objects + 3 test executables, zero warnings (werror would fail the build otherwise).

- [ ] **Step 4: Run the tests via meson**

Run: `meson test -C build --print-errorlogs`
Expected: `Ok: 3` (tests `search`, `ssh`, `index`), `Fail: 0`. The PASS lines from each binary appear in the logs.

- [ ] **Step 5: Commit**

```bash
git add meson.build engine/meson.build
git commit -m "build: Meson project for the C engine with meson-test wiring

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Swift app executable

**Files:**
- Create: `app/meson.build`
- Modify: `meson.build` (root — add `subdir('app')`)

- [ ] **Step 1: Write `app/meson.build`**

```meson
cocoa_dep = dependency('appleframeworks', modules: ['Cocoa', 'Quartz'])

app_sources = files(
  'AppDelegate.swift',
  'EngineBridge.swift',
  'ColumnConfig.swift',
  'LifecycleRow.swift',
  'QuickLookTableView.swift',
  'TimelineView.swift',
  'StatusBarController.swift',
  'SidebarViewController.swift',
  'FileListViewController.swift',
  'MainWindowController.swift',
)

rsync_explorer_exe = executable('rsync-explorer', app_sources,
  include_directories: engine_inc,
  link_with: libengine,
  dependencies: cocoa_dep,
)
```

- [ ] **Step 2: Add the subdir to the root `meson.build`**

In `meson.build`, after `subdir('engine')` add:

```meson
subdir('app')
```

- [ ] **Step 3: Build**

Run: `ninja -C build`
(Ninja re-runs meson setup automatically after meson.build changes.)
Expected: swiftc compiles the 10 sources and links `build/app/rsync-explorer`. Zero errors.

**Contingency A — `import engine` not found:** Meson didn't pass the include dir to swiftc. Add to the `executable()` call:
```meson
  swift_args: ['-I', meson.project_source_root() / 'engine'],
```

**Contingency B — SDK/AppKit not found:** swiftc is missing the macOS SDK. Add at the top of `app/meson.build`:
```meson
sdk_path = run_command('xcrun', '--show-sdk-path', check: true).stdout().strip()
```
and extend `swift_args` with `['-sdk', sdk_path]`.

**Contingency C — Swift warnings fatal under werror:** if swiftc fails on a warning-as-error that `build.sh` never enforced, add `override_options: ['werror=false']` to the `executable()` call and note it in the commit message.

- [ ] **Step 4: Smoke-check the binary**

Run: `file build/app/rsync-explorer`
Expected: `Mach-O 64-bit executable` (arm64 or x86_64).

- [ ] **Step 5: Commit**

```bash
git add meson.build app/meson.build
git commit -m "build: Meson target for the Swift app linking the engine

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: .app bundle assembly

**Files:**
- Create: `scripts/make_bundle.sh`
- Modify: `meson.build` (root — add the bundle `custom_target`)
- Add to git: `Info.plist` (currently untracked; the bundle target needs it tracked alongside the build files)

- [ ] **Step 1: Write `scripts/make_bundle.sh`**

```sh
#!/bin/sh
# Assemble the macOS .app bundle.
# Usage: make_bundle.sh <executable> <Info.plist> <config.ini> <output.app>
set -e

exe="$1"
plist="$2"
config="$3"
bundle="$4"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$exe" "$bundle/Contents/MacOS/"
cp "$plist" "$bundle/Contents/"
cp "$config" "$bundle/Contents/Resources/"
```

Run: `chmod +x scripts/make_bundle.sh`

- [ ] **Step 2: Add the bundle target to the root `meson.build`**

After `subdir('app')` add:

```meson
custom_target('app-bundle',
  input: [rsync_explorer_exe, files('Info.plist'), files('config.ini')],
  output: 'rsync-explorer.app',
  command: [
    files('scripts/make_bundle.sh'),
    '@INPUT0@', '@INPUT1@', '@INPUT2@', '@OUTPUT@',
  ],
  build_by_default: true,
)
```

- [ ] **Step 3: Build and inspect the bundle**

Run: `ninja -C build`
Expected: the `app-bundle` target runs.

Run: `find build/rsync-explorer.app -type f`
Expected exactly:
```
build/rsync-explorer.app/Contents/Info.plist
build/rsync-explorer.app/Contents/MacOS/rsync-explorer
build/rsync-explorer.app/Contents/Resources/config.ini
```

- [ ] **Step 4: Verify the bundle relinks when the app changes**

Run: `touch app/AppDelegate.swift && ninja -C build`
Expected: swiftc recompiles, `app-bundle` re-runs (the bundle binary's mtime updates).

- [ ] **Step 5: Commit**

```bash
git add scripts/make_bundle.sh meson.build Info.plist
git commit -m "build: assemble rsync-explorer.app via Meson custom target

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Delete old build system + stale artifacts, add .gitignore

**Files:**
- Delete (tracked): `engine/Makefile`
- Delete (untracked): `build.sh`, stale in-tree build outputs (exact list in Step 2)
- Create: `.gitignore`

- [ ] **Step 1: Remove the old build files**

```bash
git rm engine/Makefile
rm build.sh
```

- [ ] **Step 2: Remove stale in-tree build artifacts (all untracked)**

```bash
rm -f engine/*.o engine/libengine.a \
      engine/test_search engine/test_ssh engine/test_index \
      engine/test_engine engine/test_engine_full
rm -rf engine/test_engine.dSYM engine/test_engine_full.dSYM
rm -f app/*.o rsync-explorer
rm -rf rsync-explorer.app
```

Do NOT delete `engine/test_engine.c` / `engine/test_engine_full.c` (sources, not artifacts) and do NOT touch the `build/` directory (that's the live Meson build).

- [ ] **Step 3: Create `.gitignore`**

```gitignore
# Meson/Ninja out-of-tree build
build/

# Stray compiler outputs (should never exist in-tree anymore)
*.o
*.a
*.dSYM/
engine/test_search
engine/test_ssh
engine/test_index
engine/test_engine
engine/test_engine_full
/rsync-explorer
/rsync-explorer.app/
```

- [ ] **Step 4: Full from-scratch acceptance check**

```bash
rm -rf build
meson setup build
ninja -C build
meson test -C build --print-errorlogs
ninja -C build
```

Expected, in order:
1. setup succeeds;
2. full build, zero warnings, produces `build/rsync-explorer.app`;
3. `Ok: 3  Fail: 0`;
4. the second `ninja` prints `ninja: no work to do.` (incrementality).

- [ ] **Step 5: Verify nothing references the deleted files**

Run: `grep -rn "build.sh\|make -C engine\|Makefile" --include="*.md" --include="*.sh" --include="*.swift" --include="*.c" --include="*.h" . 2>/dev/null | grep -v "^./build/" | grep -v docs/superpowers`
Expected: no hits outside historical docs. If `DESIGN.md` (untracked) mentions `build.sh`, update the mention to `ninja -C build`.

- [ ] **Step 6: Commit**

```bash
git add .gitignore
# engine/Makefile deletion was already staged by `git rm` in Step 1
git commit -m "build: remove Makefile/build.sh and ignore build outputs

Meson + Ninja (meson setup build && ninja -C build) is now the only
build system; stale in-tree artifacts deleted.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Acceptance (matches spec §9)

- `meson setup build` clean; `ninja -C build` zero-warning build producing `build/rsync-explorer.app`.
- `meson test -C build` → 3/3 pass.
- No-change `ninja -C build` is a no-op.
- `open build/rsync-explorer.app` launches (manual, user).
