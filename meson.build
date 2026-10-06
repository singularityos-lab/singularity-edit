project('singularity-edit', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-edit"', language: 'c')
subdir('po')

gnome = import('gnome')
cc    = meson.get_compiler('c')

gtk_dep       = dependency('gtk4')
gee_dep       = dependency('gee-0.8')
gtksource_dep = dependency('gtksourceview-5')
webkit_dep    = dependency('webkitgtk-6.0')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

# Tree-sitter runtime + bundled grammars (Go, Rust, Python, TypeScript, TSX).
# The C sources live in the desktop repo under vendor/ (two levels up when we
# are built as a subproject of singularity-desktop).
ts_root = 'vendor'
ts_runtime_inc = include_directories(
  ts_root / 'tree-sitter' / 'lib' / 'include',
  ts_root / 'tree-sitter' / 'lib' / 'src',
)
ts_public_inc  = include_directories(ts_root / 'tree-sitter' / 'lib' / 'include')

ts_runtime_lib = static_library('tree-sitter-runtime',
  ts_root / 'tree-sitter' / 'lib' / 'src' / 'lib.c',
  include_directories: ts_runtime_inc,
  c_args: ['-std=c11', '-D_GNU_SOURCE', '-fvisibility=hidden', '-Wno-unused-parameter'],
)

ts_grammar_args = ['-fvisibility=hidden', '-Wno-unused-parameter',
                   '-Wno-unused-but-set-variable', '-Wno-sign-compare']

ts_go_lib = static_library('tree-sitter-go-grammar',
  ts_root / 'tree-sitter-go' / 'src' / 'parser.c',
  include_directories: [include_directories(ts_root / 'tree-sitter-go' / 'src'), ts_runtime_inc],
  c_args: ts_grammar_args,
)
ts_rust_lib = static_library('tree-sitter-rust-grammar',
  ts_root / 'tree-sitter-rust' / 'src' / 'parser.c',
  ts_root / 'tree-sitter-rust' / 'src' / 'scanner.c',
  include_directories: [include_directories(ts_root / 'tree-sitter-rust' / 'src'), ts_runtime_inc],
  c_args: ts_grammar_args,
)
ts_python_lib = static_library('tree-sitter-python-grammar',
  ts_root / 'tree-sitter-python' / 'src' / 'parser.c',
  ts_root / 'tree-sitter-python' / 'src' / 'scanner.c',
  include_directories: [include_directories(ts_root / 'tree-sitter-python' / 'src'), ts_runtime_inc],
  c_args: ts_grammar_args,
)
ts_typescript_lib = static_library('tree-sitter-typescript-grammar',
  ts_root / 'tree-sitter-typescript' / 'typescript' / 'src' / 'parser.c',
  ts_root / 'tree-sitter-typescript' / 'typescript' / 'src' / 'scanner.c',
  include_directories: [include_directories(ts_root / 'tree-sitter-typescript' / 'typescript' / 'src'), ts_runtime_inc],
  c_args: ts_grammar_args,
)
ts_tsx_lib = static_library('tree-sitter-tsx-grammar',
  ts_root / 'tree-sitter-typescript' / 'tsx' / 'src' / 'parser.c',
  ts_root / 'tree-sitter-typescript' / 'tsx' / 'src' / 'scanner.c',
  include_directories: [include_directories(ts_root / 'tree-sitter-typescript' / 'tsx' / 'src'), ts_runtime_inc],
  c_args: ts_grammar_args,
)

ts_dep = declare_dependency(
  link_with: [ts_runtime_lib, ts_go_lib, ts_rust_lib, ts_python_lib, ts_typescript_lib, ts_tsx_lib],
  include_directories: [ts_public_inc, include_directories('src')],
)

subdir('ui')

resources = gnome.compile_resources(
  'singularity-edit-resources',
  'resources/dev.sinty.edit.gresource.xml',
  source_dir: [meson.current_source_dir(), meson.current_build_dir()],
  dependencies: main_ui
)

sources = files(
  'src/main.vala',
  'src/status_bar.vala',
  'src/find_bar.vala',
  'src/file_browser_pane.vala',
  'src/editor_tab.vala',
  'src/markdown.vala',
  'src/window.vala',
  'src/app.vala',
  'src/cloud_actions.vala',
  'src/ts_lang_registry.vala',
  'src/ts_highlighter.vala',
  'src/ts_outline.vala',
  'src/ts_folding.vala',
  'src/tree-sitter.vapi',
)

executable('singularity-edit',
  sources + [resources],
  dependencies: [gtk_dep, gee_dep, gtksource_dep, webkit_dep, libsingularity_dep, ts_dep],
  install: true
)

install_subdir('data/queries',
  install_dir: get_option('datadir') / 'singularity-edit',
  strip_directory: false,
)

install_data('data/dev.sinty.edit.desktop',
  install_dir: get_option('datadir') / 'applications'
)
install_data('data/dev.sinty.edit.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)
install_data('data/dev.sinty.edit.json',
  install_dir: get_option('datadir') / 'singularity' / 'app-settings'
)
install_data('data/icons/dev.sinty.edit.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
)
