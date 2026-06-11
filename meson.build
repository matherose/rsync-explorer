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
