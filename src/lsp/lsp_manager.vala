using GLib;

namespace Singularity.Apps {

    public class LspServerSpec {
        public string name;
        public string language_id;
        public string[] argv;
        public string[] markers;

        public LspServerSpec (string name, string language_id, string[] argv, string[] markers) {
            this.name = name;
            this.language_id = language_id;
            this.argv = argv;
            this.markers = markers;
        }
    }

    private class LspWaiter {
        public SourceFunc callback;
    }

    public class LspManager : Object {
        private static LspManager? _instance;
        public static LspManager get_default () {
            if (_instance == null) _instance = new LspManager ();
            return _instance;
        }

        public signal void diagnostics (string uri, Json.Array items);
        public signal void server_state (string name, string state);
        public signal void log_line (string name, string line);
        public signal void workspace_edit (Json.Object edit, bool utf8);

        private HashTable<string, GenericArray<LspServerSpec>> by_language = new HashTable<string, GenericArray<LspServerSpec>> (str_hash, str_equal);
        private int native_tsc = -1;
        private HashTable<string, LspClient> clients = new HashTable<string, LspClient> (str_hash, str_equal);
        private HashTable<string, GenericArray<LspWaiter>> starting = new HashTable<string, GenericArray<LspWaiter>> (str_hash, str_equal);

        private LspManager () {
            add (new LspServerSpec ("rust-analyzer", "rust", { "rust-analyzer" }, { "Cargo.toml" }), { "rust" });
            add (new LspServerSpec ("pylsp", "python", { "pylsp" }, { "pyproject.toml", "setup.py", "setup.cfg", "requirements.txt" }), { "python", "python3" });
            add (new LspServerSpec ("typescript-language-server", "typescript", { "typescript-language-server", "--stdio" }, { "tsconfig.json", "package.json" }), { "typescript", "js", "javascript", "typescript-jsx", "jsx" });
            add (new LspServerSpec ("tsc", "typescript", { "tsc", "--lsp", "--stdio" }, { "tsconfig.json", "package.json" }), { "typescript", "js", "javascript", "typescript-jsx", "jsx" });
            add (new LspServerSpec ("gopls", "go", { "gopls" }, { "go.mod", "go.work" }), { "go" });
            add (new LspServerSpec ("clangd", "c", { "clangd" }, { "compile_commands.json", "meson.build", "CMakeLists.txt", "Makefile" }), { "c", "cpp", "chdr", "cpphdr" });
            add (new LspServerSpec ("vala-language-server", "vala", { "vala-language-server" }, { "meson.build" }), { "vala" });
            if (Environment.get_variable ("SINGULARITY_EDIT_LSP_LOG") != null) {
                log_line.connect ((name, line) => printerr ("[%s] %s\n", name, line));
                server_state.connect ((name, state) => printerr ("[%s] state %s\n", name, state));
            }
        }

        private void add (LspServerSpec spec, string[] ids) {
            foreach (var id in ids) {
                var list = by_language.lookup (id);
                if (list == null) {
                    list = new GenericArray<LspServerSpec> ();
                    by_language.insert (id, list);
                }
                list.add (spec);
            }
        }

        public LspServerSpec? spec_for (string? language, File? file = null) {
            if (language == null) return null;
            var list = by_language.lookup (language);
            if (list == null) return null;
            var dsh = Singularity.Edit.Dsh.for_file (file);
            foreach (var spec in list.data) {
                if (dsh != null) {
                    if (spec.name == "tsc" || !dsh.has_program (spec.argv[0])) continue;
                    return spec;
                }
                if (Environment.find_program_in_path (spec.argv[0]) == null) continue;
                if (usable (spec, file)) return spec;
            }
            return null;
        }

        private bool usable (LspServerSpec spec, File? file) {
            if (spec.name == "typescript-language-server") {
                var root = file != null ? root_for (file, spec.markers) : Environment.get_home_dir ();
                return find_tsserver (root, spec.argv[0]) != null;
            }
            if (spec.name == "tsc") {
                if (native_tsc < 0) native_tsc = tsc_major () >= 7 ? 1 : 0;
                return native_tsc == 1;
            }
            return true;
        }

        private static int tsc_major () {
            try {
                string output;
                int status;
                Process.spawn_sync (null, { "tsc", "--version" }, null, SpawnFlags.SEARCH_PATH | SpawnFlags.STDERR_TO_DEV_NULL,
                                    null, out output, null, out status);
                var parts = output.strip ().split (" ");
                return parts.length >= 2 ? int.parse (parts[1].split (".")[0]) : 0;
            } catch (SpawnError e) {
                return 0;
            }
        }

        public static string language_id_for (string language) {
            switch (language) {
                case "cpp": case "cpphdr": return "cpp";
                case "chdr": return "c";
                case "js": case "javascript": return "javascript";
                case "jsx": return "javascriptreact";
                case "typescript-jsx": return "typescriptreact";
                case "python3": return "python";
                default: return language;
            }
        }

        public static string root_for (File file, string[] markers) {
            var dir = file.get_parent ();
            var start = dir;
            while (dir != null) {
                foreach (var marker in markers) {
                    if (dir.get_child (marker).query_exists ()) return dir.get_path ();
                }
                if (dir.get_child (".git").query_exists ()) return dir.get_path ();
                dir = dir.get_parent ();
            }
            return start != null ? start.get_path () : Environment.get_home_dir ();
        }

        public async LspClient? client_for (string language, File file) {
            var spec = spec_for (language, file);
            if (spec == null) return null;
            var root = root_for (file, spec.markers);
            var dsh = Singularity.Edit.Dsh.for_file (file);
            var key = (dsh != null ? "dsh|" : "") + spec.name + "|" + root;
            var existing = clients.lookup (key);
            if (existing != null && !starting.contains (key))
                return existing.alive ? existing : null;
            var waiters = starting.lookup (key);
            if (waiters != null) {
                var w = new LspWaiter ();
                w.callback = client_for.callback;
                waiters.add (w);
                yield;
                var c = clients.lookup (key);
                return c != null && c.alive ? c : null;
            }
            starting.insert (key, new GenericArray<LspWaiter> ());
            var client = new LspClient (spec.name, root);
            client.dsh = dsh;
            clients.insert (key, client);
            client.notification.connect ((method, prm) => on_notification (client, method, prm));
            client.log_line.connect ((line) => log_line (spec.name, line));
            client.apply_edit_requested.connect ((edit) => workspace_edit (edit, client.utf8_positions));
            client.exited.connect (() => {
                clients.remove (key);
                server_state (spec.name, "stopped");
            });
            server_state (spec.name, "starting");
            try {
                client.start (spec.argv);
                yield client.initialize (dsh != null ? null : init_options (spec, root));
                server_state (spec.name, "ready");
            } catch (Error e) {
                log_line (spec.name, "start failed: " + e.message);
                server_state (spec.name, "failed");
                clients.remove (key);
                client = null;
            }
            var list = starting.lookup (key);
            starting.remove (key);
            if (list != null) {
                foreach (var w in list.data) Idle.add ((owned) w.callback);
            }
            return client;
        }

        private Json.Node? init_options (LspServerSpec spec, string root) {
            if (spec.name != "typescript-language-server") return null;
            var tsserver = find_tsserver (root, spec.argv[0]);
            if (tsserver == null) return null;
            var path = new Json.Object ();
            path.set_string_member ("path", tsserver);
            var obj = new Json.Object ();
            obj.set_object_member ("tsserver", path);
            return new Json.Node (Json.NodeType.OBJECT).init_object (obj);
        }

        private static string? find_tsserver (string root, string program) {
            var dir = File.new_for_path (root);
            while (dir != null) {
                var lib = dir.get_child ("node_modules").get_child ("typescript").get_child ("lib");
                if (lib.get_child ("tsserver.js").query_exists ()) return lib.get_path ();
                dir = dir.get_parent ();
            }
            var bin = Environment.find_program_in_path (program);
            if (bin == null) return null;
            string real = bin;
            try {
                real = FileUtils.read_link (bin);
                if (!Path.is_absolute (real)) real = Path.build_filename (Path.get_dirname (bin), real);
            } catch (FileError e) {
            }
            var node_modules = File.new_for_path (real).get_parent ();
            while (node_modules != null && node_modules.get_basename () != "node_modules")
                node_modules = node_modules.get_parent ();
            if (node_modules == null) {
                var prefix = File.new_for_path (bin).get_parent ().get_parent ();
                node_modules = prefix.get_child ("lib").get_child ("node_modules");
            }
            var lib = node_modules.get_child ("typescript").get_child ("lib");
            return lib.get_child ("tsserver.js").query_exists () ? lib.get_path () : null;
        }

        private void on_notification (LspClient client, string method, Json.Node? prm) {
            if (method == "textDocument/publishDiagnostics" && prm != null) {
                var obj = prm.get_object ();
                diagnostics (obj.get_string_member ("uri"), obj.get_array_member ("diagnostics"));
            } else if (method == "window/logMessage" && prm != null) {
                log_line (client.language, prm.get_object ().get_string_member ("message"));
            }
        }

        public void shutdown () {
            foreach (var c in clients.get_values ()) c.stop ();
            clients.remove_all ();
        }
    }
}
