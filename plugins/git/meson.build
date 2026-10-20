edit_git_plugin = shared_module('edit-git',
  files('git_plugin.vala'),
  dependencies: [edit_lib_dep, gee_dep, dependency('libpeas-2')],
  install: true,
  install_dir: edit_plugin_dir / 'git',
)
install_data('git.plugin', install_dir: edit_plugin_dir / 'git')
install_data(files('icons/singularity-git-branch-symbolic.svg'),
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'actions')
