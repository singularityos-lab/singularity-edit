using GLib;

namespace EditAgents {

    public class RestorePoint : Object {
        public string root;
        public string? tree;
        public string? snapshot_dir;
        public string[] files = {};

        private static async string? git (string root, string[] args, string? index = null) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            launcher.set_cwd (root);
            if (index != null) launcher.setenv ("GIT_INDEX_FILE", index, true);
            launcher.setenv ("GIT_AUTHOR_NAME", "Singularity Edit", true);
            launcher.setenv ("GIT_AUTHOR_EMAIL", "edit@localhost", true);
            launcher.setenv ("GIT_COMMITTER_NAME", "Singularity Edit", true);
            launcher.setenv ("GIT_COMMITTER_EMAIL", "edit@localhost", true);
            string[] argv = { "git" };
            foreach (var a in args) argv += a;
            var p = launcher.spawnv (argv);
            string? out_text;
            yield p.communicate_utf8_async (null, null, out out_text, null);
            return p.get_successful () ? (out_text ?? "").strip () : null;
        }

        private static string temp_index () {
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity-edit", "restore-index-%u".printf (Random.next_int ()));
        }

        public static async RestorePoint create (string root) throws Error {
            var r = new RestorePoint ();
            r.root = root;
            DirUtils.create_with_parents (Path.build_filename (Environment.get_user_cache_dir (), "singularity-edit"), 0755);
            if ((yield git (root, { "rev-parse", "--show-toplevel" })) != null) {
                var index = temp_index ();
                if ((yield git (root, { "add", "-A", "." }, index)) != null) {
                    r.tree = yield git (root, { "write-tree" }, index);
                    var listed = yield git (root, { "ls-files" }, index);
                    if (listed != null) r.files = listed.split ("\n");
                }
                FileUtils.unlink (index);
                if (r.tree != null) {
                    var commit = yield git (root, { "commit-tree", r.tree, "-m", "Singularity Edit restore point" });
                    if (commit != null) yield git (root, { "update-ref", "refs/singularity-edit/restore", commit });
                    return r;
                }
            }
            r.snapshot_dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-edit", "restore-%s".printf (Checksum.compute_for_string (ChecksumType.SHA1, root).substring (0, 12)));
            var list = new GenericArray<string> ();
            copy_tree (root, r.snapshot_dir, "", list);
            r.files = list.data;
            return r;
        }

        private static bool skipped (string name) {
            return name == ".git" || name == "node_modules" || name == "target" || name == "build" || name == "__pycache__" || name == ".venv";
        }

        private static void copy_tree (string from, string to, string rel, GenericArray<string> files) throws Error {
            var dir = Dir.open (Path.build_filename (from, rel));
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (skipped (name)) continue;
                string child = rel == "" ? name : Path.build_filename (rel, name);
                string src = Path.build_filename (from, child);
                if (FileUtils.test (src, FileTest.IS_SYMLINK)) continue;
                if (FileUtils.test (src, FileTest.IS_DIR)) {
                    copy_tree (from, to, child, files);
                    continue;
                }
                var info = File.new_for_path (src).query_info (FileAttribute.STANDARD_SIZE, FileQueryInfoFlags.NONE);
                if (info.get_size () > 5 * 1024 * 1024 || files.length > 20000) continue;
                string dst = Path.build_filename (to, child);
                DirUtils.create_with_parents (Path.get_dirname (dst), 0755);
                File.new_for_path (src).copy (File.new_for_path (dst), FileCopyFlags.OVERWRITE);
                files.add (child);
            }
        }

        public async void apply () throws Error {
            var keep = new GenericSet<string> (str_hash, str_equal);
            foreach (var f in files) if (f != "") keep.add (f);
            string[] now = {};
            if (tree != null) {
                var index = temp_index ();
                yield git (root, { "add", "-A", "." }, index);
                var listed = yield git (root, { "ls-files" }, index);
                FileUtils.unlink (index);
                if (listed != null) now = listed.split ("\n");
                var restore_index = temp_index ();
                yield git (root, { "read-tree", tree }, restore_index);
                yield git (root, { "checkout-index", "-a", "-f" }, restore_index);
                FileUtils.unlink (restore_index);
            } else if (snapshot_dir != null) {
                var current = new GenericArray<string> ();
                list_tree (root, "", current);
                now = current.data;
                foreach (var f in files) {
                    if (f == "") continue;
                    var dst = Path.build_filename (root, f);
                    DirUtils.create_with_parents (Path.get_dirname (dst), 0755);
                    File.new_for_path (Path.build_filename (snapshot_dir, f)).copy (File.new_for_path (dst), FileCopyFlags.OVERWRITE);
                }
            }
            foreach (var f in now) {
                if (f == "" || keep.contains (f)) continue;
                FileUtils.unlink (Path.build_filename (root, f));
            }
        }

        private static void list_tree (string root, string rel, GenericArray<string> out_files) throws Error {
            var dir = Dir.open (Path.build_filename (root, rel));
            string? name;
            while ((name = dir.read_name ()) != null) {
                if (skipped (name)) continue;
                string child = rel == "" ? name : Path.build_filename (rel, name);
                string path = Path.build_filename (root, child);
                if (FileUtils.test (path, FileTest.IS_SYMLINK)) continue;
                if (FileUtils.test (path, FileTest.IS_DIR)) list_tree (root, child, out_files);
                else out_files.add (child);
            }
        }
    }

    public class HostProxy : Object {
        private SocketService service = new SocketService ();
        private string[] hosts;
        public uint16 port { get; private set; }
        public bool limited { get { return hosts.length > 3; } }

        public HostProxy (string[] hosts) {
            this.hosts = hosts;
            try {
                var addr = new InetSocketAddress (new InetAddress.loopback (SocketFamily.IPV4), 0);
                SocketAddress effective;
                service.add_address (addr, SocketType.STREAM, SocketProtocol.TCP, null, out effective);
                port = ((InetSocketAddress) effective).get_port ();
                service.incoming.connect ((conn) => {
                    handle.begin (conn);
                    return true;
                });
                service.start ();
            } catch (Error e) {
                port = 0;
            }
        }

        public void stop () {
            service.stop ();
            service.close ();
        }

        public string[] apply (string[] input) {
            string[] env = input;
            if (port == 0) return env;
            string url = "http://127.0.0.1:%u".printf (port);
            foreach (var k in new string[] { "HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "ALL_PROXY", "all_proxy" })
                env = Environ.set_variable (env, k, url, true);
            env = Environ.unset_variable (env, "NO_PROXY");
            env = Environ.unset_variable (env, "no_proxy");
            env = Environ.set_variable (env, "NODE_USE_ENV_PROXY", "1", true);
            return env;
        }

        public bool allowed (string host) {
            if (!limited) return true;
            string h = host.down ();
            foreach (var a in hosts) {
                if (h == a || h.has_suffix ("." + a)) return true;
            }
            return false;
        }

        private async void handle (SocketConnection conn) {
            try {
                var input = new DataInputStream (conn.input_stream);
                input.newline_type = DataStreamNewlineType.CR_LF;
                size_t len;
                string? first = yield input.read_line_async (Priority.DEFAULT, null, out len);
                if (first == null) return;
                var head = new StringBuilder ();
                while (true) {
                    string? line = yield input.read_line_async (Priority.DEFAULT, null, out len);
                    if (line == null || line == "") break;
                    head.append (line);
                    head.append ("\r\n");
                }
                var parts = first.split (" ");
                if (parts.length < 3) return;
                string method = parts[0];
                string target = parts[1];
                string host;
                uint16 port = 443;
                string request_head = "";
                if (method == "CONNECT") {
                    int colon = target.last_index_of_char (':');
                    host = colon > 0 ? target.substring (0, colon) : target;
                    if (colon > 0) port = (uint16) int.parse (target.substring (colon + 1));
                } else {
                    var uri = Uri.parse (target, UriFlags.NONE);
                    host = uri.get_host ();
                    port = uri.get_port () > 0 ? (uint16) uri.get_port () : 80;
                    string path = uri.get_path () == "" ? "/" : uri.get_path ();
                    if (uri.get_query () != null) path += "?" + uri.get_query ();
                    request_head = "%s %s %s\r\n%s\r\n".printf (method, path, parts[2], head.str);
                }
                if (!allowed (host)) {
                    yield conn.output_stream.write_all_async ("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".data, Priority.DEFAULT, null, null);
                    yield conn.close_async ();
                    return;
                }
                var client = new SocketClient ();
                var upstream = yield client.connect_to_host_async (host, port, null);
                if (method == "CONNECT") {
                    yield conn.output_stream.write_all_async ("HTTP/1.1 200 Connection Established\r\n\r\n".data, Priority.DEFAULT, null, null);
                } else {
                    yield upstream.output_stream.write_all_async (request_head.data, Priority.DEFAULT, null, null);
                }
                var buffered = input.get_available ();
                if (buffered > 0) {
                    var rest = new uint8[buffered];
                    size_t got;
                    yield input.read_all_async (rest, Priority.DEFAULT, null, out got);
                    yield upstream.output_stream.write_all_async (rest[0:got], Priority.DEFAULT, null, null);
                }
                upstream.output_stream.splice_async.begin (input, OutputStreamSpliceFlags.NONE, Priority.DEFAULT, null);
                yield conn.output_stream.splice_async (upstream.input_stream, OutputStreamSpliceFlags.NONE, Priority.DEFAULT, null);
                yield conn.close_async ();
                yield upstream.close_async ();
            } catch (Error e) {
            }
        }
    }

    public class Sandbox : Object {
        private static int usable = -1;

        public static bool available () {
            if (usable >= 0) return usable == 1;
            usable = 0;
            if (Environment.find_program_in_path ("bwrap") == null) return false;
            try {
                int status;
                Process.spawn_sync (null, { "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "true" }, null,
                    SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL, null, null, null, out status);
                if (status == 0) usable = 1;
            } catch (SpawnError e) {
            }
            return usable == 1;
        }

        public static string[] wrap (string[] argv, string root) {
            if (!available ()) return argv;
            string home = Environment.get_home_dir ();
            string[] rw = { ".claude", ".claude.json", ".codex", ".gemini", ".copilot", ".config/github-copilot", ".npm", ".cache", ".local/share/singularity-edit" };
            string[] out_ = { "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp" };
            string? runtime = Environment.get_variable ("XDG_RUNTIME_DIR");
            foreach (var r in rw) {
                var p = Path.build_filename (home, r);
                if (FileUtils.test (p, FileTest.EXISTS)) out_ += "--bind"; else continue;
                out_ += p;
                out_ += p;
            }
            out_ += "--bind";
            out_ += root;
            out_ += root;
            if (runtime != null) {
                out_ += "--ro-bind";
                out_ += runtime;
                out_ += runtime;
            }
            out_ += "--die-with-parent";
            out_ += "--chdir";
            out_ += root;
            out_ += "--";
            foreach (var a in argv) out_ += a;
            return out_;
        }
    }
}
