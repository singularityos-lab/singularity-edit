edit_agents_plugin = shared_module('edit-agents',
  files('agents_plugin.vala', 'acp_client.vala', 'agent_catalog.vala', 'agent_session.vala', 'autopilot.vala', 'agent_panel.vala', 'mcp_server.vala'),
  dependencies: [edit_lib_dep, gee_dep, json_dep, dependency('libpeas-2'), dependency('libsoup-3.0'), meson.get_compiler('vala').find_library('posix')],
  install: true,
  install_dir: edit_plugin_dir / 'agents',
)
install_data('agents.plugin', install_dir: edit_plugin_dir / 'agents')
install_data('singularity-agents-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'actions')
executable('singularity-edit-mcp', files('mcp_bridge.vala'),
  dependencies: [dependency('gio-2.0'), dependency('gio-unix-2.0')],
  install: true,
  install_dir: get_option('libexecdir'),
)
