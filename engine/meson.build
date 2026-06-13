threads_dep = dependency('threads')
zlib_dep = dependency('zlib')

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
  'cache.c',
  'index.c',
)

libengine = static_library('engine', engine_sources,
  c_args: ['-fvisibility=hidden'],
  dependencies: [threads_dep, zlib_dep],
)

engine_inc = include_directories('.')

foreach t : ['search', 'ssh', 'index']
  test_exe = executable('test_' + t, 'test_' + t + '.c',
    include_directories: engine_inc,
    link_with: libengine,
    dependencies: [threads_dep, zlib_dep],
  )
  test(t, test_exe)
endforeach
