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
# so we add them at the project level. We link the SDK's libz.tbd by absolute
# path (install_name /usr/lib/libz.1.dylib) instead of -lz, because the
# engine's pkg-config zlib cascades -L/opt/local/lib onto the swift link line
# and MacPorts' libz has an @rpath install_name that breaks at app launch.
swift_sdk = run_command('xcrun', '--sdk', 'macosx', '--show-sdk-path',
                        check: true).stdout().strip()
add_project_link_arguments(swift_sdk + '/usr/lib/libz.tbd', '-lpthread',
                           language: 'swift')

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
