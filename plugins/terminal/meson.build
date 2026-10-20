edit_terminal_plugin = shared_module('edit-terminal',
  files('terminal_plugin.vala'),
  dependencies: [edit_lib_dep, gee_dep, dependency('libpeas-2'), dependency('vte-2.91-gtk4'), meson.get_compiler('vala').find_library('posix')],
  install: true,
  install_dir: edit_plugin_dir / 'terminal',
)
install_data('terminal.plugin', install_dir: edit_plugin_dir / 'terminal')
