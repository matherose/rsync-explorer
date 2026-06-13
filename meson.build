project('rsync-explorer', 'c', 'swift',
  version: '1.0',
  default_options: [
    'c_std=c11',
    'warning_level=2',
    'werror=true',
    'buildtype=debugoptimized',
  ],
)

# libengine.a references zlib (cache.c) and pthread (index.c). Meson's swift
# backend does not forward dependency link flags from executable() to swiftc,
# so the swift app would fail to link without these project-wide flags.
add_project_link_arguments('-lz', '-lpthread', language: 'swift')

subdir('engine')
subdir('app')

custom_target('app-bundle',
  input: [rsync_explorer_exe, files('Info.plist'), files('config.ini')],
  output: 'rsync-explorer.app',
  command: [
    files('scripts/make_bundle.sh'),
    '@INPUT0@', '@INPUT1@', '@INPUT2@', '@OUTPUT@',
  ],
  build_by_default: true,
)
