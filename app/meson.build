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
  # Meson derives the Swift module name from the target name, but
  # "rsync-explorer" is not a valid Swift identifier; override it.
  swift_args: ['-module-name', 'rsync_explorer'],
)
