using GLib;

namespace Singularity.Apps {

    public errordomain DebugError {
        UNSUPPORTED,
        MISSING
    }

    public class DebugTargets : Object {

        private static Singularity.Edit.Dsh? dsh;

        public static DebugTarget resolve (EditorTab tab) throws Error {
            if (tab.file == null || tab.file.get_path () == null)
                throw new DebugError.UNSUPPORTED (_("Save the file before debugging"));
            dsh = Singularity.Edit.Dsh.for_file (tab.file);
            var target = resolve_target (tab);
            target.dsh = dsh;
            return target;
        }

        private static bool has (string program) {
            return dsh != null ? dsh.has_program (program) : Environment.find_program_in_path (program) != null;
        }

        private static DebugTarget resolve_target (EditorTab tab) throws Error {
            string lang = tab.get_language_id () ?? "";
            string path = tab.file.get_path ();
            var from_vscode = from_launch_json (tab, lang);
            if (from_vscode != null) return from_vscode;
            switch (lang) {
                case "python":
                case "python3":
                    return python (path, project_root (tab.file, { "pyproject.toml", "setup.py", "requirements.txt" }));
                case "c":
                case "cpp":
                    return native_single (path, lang == "cpp" ? "c++" : "cc", project_root (tab.file, { "meson.build", "Makefile", "CMakeLists.txt" }));
                case "rust":
                    return rust (path, project_root (tab.file, { "Cargo.toml" }));
                case "go":
                    return go (path, project_root (tab.file, { "go.mod" }));
                default:
                    throw new DebugError.UNSUPPORTED (_("No debugger is available for this language"));
            }
        }

        private static string project_root (File file, string[] markers) {
            return LspManager.root_for (file, markers);
        }

        private static void need (string program) throws Error {
            if (!has (program))
                throw new DebugError.MISSING (_("%s is not installed").printf (program));
        }

        private static DebugTarget native_adapter (string program, string cwd) throws Error {
            var t = new DebugTarget ();
            t.cwd = cwd;
            t.launch = new Json.Object ();
            t.launch.set_string_member ("program", program);
            t.launch.set_string_member ("cwd", cwd);
            t.launch.set_array_member ("args", new Json.Array ());
            t.launch.set_boolean_member ("stopOnEntry", false);
            if (has ("lldb-dap")) {
                t.adapter_id = "lldb-dap";
                t.argv = { "lldb-dap" };
            } else if (has ("gdb")) {
                t.adapter_id = "gdb";
                t.argv = { "gdb", "-q", "-i", "dap" };
            } else {
                throw new DebugError.MISSING (_("Install lldb or gdb to debug this program"));
            }
            return t;
        }

        private static DebugTarget python (string path, string root) throws Error {
            need ("python3");
            var t = new DebugTarget ();
            t.adapter_id = "debugpy";
            t.label = Path.get_basename (path);
            t.argv = { "python3", "-m", "debugpy.adapter" };
            t.cwd = root;
            t.launch = new Json.Object ();
            t.launch.set_string_member ("type", "python");
            t.launch.set_string_member ("request", "launch");
            t.launch.set_string_member ("program", path);
            t.launch.set_string_member ("cwd", root);
            t.launch.set_string_member ("console", "internalConsole");
            t.launch.set_boolean_member ("justMyCode", true);
            return t;
        }

        private static string build_dir () {
            var cache = dsh != null ? Path.build_filename (dsh.host_root, ".cache") : Environment.get_user_cache_dir ();
            var dir = Path.build_filename (cache, "singularity-edit", "debug");
            DirUtils.create_with_parents (dir, 0755);
            return dir;
        }

        private static DebugTarget native_single (string path, string compiler, string root) throws Error {
            need (compiler);
            var stem = Path.get_basename (path);
            int dot = stem.last_index_of_char ('.');
            if (dot > 0) stem = stem.substring (0, dot);
            var output = Path.build_filename (build_dir (), "%s-%08x".printf (stem, str_hash (path)));
            var t = native_adapter (output, root);
            t.label = Path.get_basename (path);
            t.build = { compiler, "-g", "-O0", path, "-o", output };
            return t;
        }

        private static DebugTarget rust (string path, string root) throws Error {
            need ("cargo");
            string name = Path.get_basename (root);
            try {
                string text;
                FileUtils.get_contents (Path.build_filename (root, "Cargo.toml"), out text);
                bool package = false;
                foreach (var line in text.split ("\n")) {
                    var l = line.strip ();
                    if (l.has_prefix ("[")) package = l == "[package]";
                    if (package && l.has_prefix ("name")) {
                        var parts = l.split ("=", 2);
                        if (parts.length == 2) name = parts[1].strip ().replace ("\"", "");
                    }
                }
            } catch (Error e) {
            }
            var t = native_adapter (Path.build_filename (root, "target", "debug", name), root);
            t.label = name;
            t.build = { "cargo", "build" };
            return t;
        }

        private static uint16 free_port () {
            try {
                var socket = new Socket (SocketFamily.IPV4, SocketType.STREAM, SocketProtocol.TCP);
                socket.bind (new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0), true);
                var addr = (InetSocketAddress) socket.get_local_address ();
                uint16 port = addr.get_port ();
                socket.close ();
                return port;
            } catch (Error e) {
                return 38697;
            }
        }

        private static DebugTarget go (string path, string root) throws Error {
            need ("dlv");
            need ("go");
            var t = new DebugTarget ();
            t.adapter_id = "go";
            t.label = Path.get_basename (root);
            t.tcp = true;
            t.port = free_port ();
            t.argv = { "dlv", "dap", "--listen=127.0.0.1:%u".printf (t.port) };
            t.cwd = root;
            t.launch = new Json.Object ();
            t.launch.set_string_member ("mode", "debug");
            t.launch.set_string_member ("program", Path.get_dirname (path));
            t.launch.set_string_member ("output", Path.build_filename (build_dir (), "go-%08x".printf (str_hash (root))));
            t.launch.set_string_member ("cwd", root);
            return t;
        }

        private static DebugTarget? from_launch_json (EditorTab tab, string lang) throws Error {
            var dir = tab.file.get_parent ();
            File? found = null;
            while (dir != null && found == null) {
                var f = dir.get_child (".vscode").get_child ("launch.json");
                if (f.query_exists ()) found = f;
                dir = dir.get_parent ();
            }
            if (found == null) return null;
            string text;
            try {
                FileUtils.get_contents (found.get_path (), out text);
            } catch (Error e) {
                return null;
            }
            var clean = new StringBuilder ();
            foreach (var line in text.split ("\n")) {
                if (line.strip ().has_prefix ("//")) continue;
                clean.append (line);
                clean.append_c ('\n');
            }
            var parser = new Json.Parser ();
            try {
                parser.load_from_data (clean.str);
            } catch (Error e) {
                return null;
            }
            var root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) return null;
            var obj = root.get_object ();
            if (!obj.has_member ("configurations")) return null;
            var configs = obj.get_array_member ("configurations");
            string workspace = found.get_parent ().get_parent ().get_path ();
            for (uint i = 0; i < configs.get_length (); i++) {
                var c = configs.get_object_element (i);
                if (!c.has_member ("type") || (c.has_member ("request") && c.get_string_member ("request") != "launch")) continue;
                string type = c.get_string_member ("type");
                var launch = substitute (c, tab.file.get_path (), workspace);
                string cwd = launch.has_member ("cwd") ? launch.get_string_member ("cwd") : workspace;
                DebugTarget? t = null;
                if ((type == "python" || type == "debugpy") && (lang == "python" || lang == "python3")) {
                    t = python (tab.file.get_path (), workspace);
                } else if (type == "lldb" || type == "lldb-dap" || type == "cppdbg" || type == "gdb") {
                    if (!launch.has_member ("program")) continue;
                    t = native_adapter (launch.get_string_member ("program"), cwd);
                } else if (type == "go" && lang == "go") {
                    t = go (tab.file.get_path (), workspace);
                }
                if (t == null) continue;
                foreach (var m in launch.get_members ()) {
                    if (m == "type" || m == "request" || m == "preLaunchTask" || m == "name") continue;
                    t.launch.set_member (m, launch.get_member (m).copy ());
                }
                t.label = c.has_member ("name") ? c.get_string_member ("name") : t.label;
                t.cwd = cwd;
                return t;
            }
            return null;
        }

        private static Json.Object substitute (Json.Object config, string file, string workspace) {
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (config);
            var text = Json.to_string (node, false);
            var stem = Path.get_basename (file);
            int dot = stem.last_index_of_char ('.');
            if (dot > 0) stem = stem.substring (0, dot);
            text = text.replace ("${workspaceFolder}", workspace)
                       .replace ("${workspaceRoot}", workspace)
                       .replace ("${fileDirname}", Path.get_dirname (file))
                       .replace ("${fileBasenameNoExtension}", stem)
                       .replace ("${fileBasename}", Path.get_basename (file))
                       .replace ("${file}", file);
            try {
                return Json.from_string (text).get_object ();
            } catch (Error e) {
                return config;
            }
        }
    }
}
