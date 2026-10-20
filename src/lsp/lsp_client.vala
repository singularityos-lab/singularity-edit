using GLib;

namespace Singularity.Apps {

    public errordomain LspError {
        SPAWN,
        PROTOCOL,
        RESPONSE,
        CLOSED
    }

    private class LspPending {
        public SourceFunc callback;
        public Json.Node? result;
        public string? error;
    }

    public class LspClient : Object {
        public string language { get; construct; }
        public string root_path { get; construct; }
        public Json.Object? capabilities { get; private set; }
        public bool utf8_positions { get; private set; default = false; }
        public bool alive { get; private set; default = false; }

        public signal void notification (string method, Json.Node? prm);
        public signal void log_line (string line);
        public signal void exited ();
        public signal void apply_edit_requested (Json.Object edit);

        private Subprocess proc;
        private DataInputStream input;
        private OutputStream output;
        private int next_id = 1;
        private HashTable<int, LspPending> pending = new HashTable<int, LspPending> (direct_hash, direct_equal);

        public LspClient (string language, string root_path) {
            Object (language: language, root_path: root_path);
        }

        public void start (string[] argv) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.set_cwd (root_path);
            proc = launcher.spawnv (argv);
            input = new DataInputStream (proc.get_stdout_pipe ());
            input.newline_type = DataStreamNewlineType.ANY;
            output = proc.get_stdin_pipe ();
            alive = true;
            read_loop.begin ();
            read_stderr.begin (new DataInputStream (proc.get_stderr_pipe ()));
            proc.wait_async.begin (null, () => {
                alive = false;
                fail_pending ("language server exited");
                exited ();
            });
        }

        public void stop () {
            if (!alive) return;
            notify_server ("exit", null);
            proc.force_exit ();
        }

        private void fail_pending (string message) {
            var ids = pending.get_keys ();
            foreach (var id in ids) {
                var p = pending.lookup (id);
                pending.remove (id);
                p.error = message;
                Idle.add ((owned) p.callback);
            }
        }

        private void send (Json.Object message) {
            if (!alive) return;
            message.set_string_member ("jsonrpc", "2.0");
            var root = new Json.Node (Json.NodeType.OBJECT);
            root.set_object (message);
            var body = Json.to_string (root, false);
            var frame = "Content-Length: %d\r\n\r\n%s".printf (body.length, body);
            try {
                size_t written;
                output.write_all (frame.data, out written);
                output.flush ();
            } catch (Error e) {
                log_line ("write failed: " + e.message);
            }
        }

        public void notify_server (string method, Json.Node? prm) {
            var msg = new Json.Object ();
            msg.set_string_member ("method", method);
            if (prm != null) msg.set_member ("params", prm);
            send (msg);
        }

        public async Json.Node? request (string method, Json.Node? prm) throws Error {
            if (!alive) throw new LspError.CLOSED ("language server is not running");
            int id = next_id++;
            var p = new LspPending ();
            p.callback = request.callback;
            pending.insert (id, p);
            var msg = new Json.Object ();
            msg.set_int_member ("id", id);
            msg.set_string_member ("method", method);
            if (prm != null) msg.set_member ("params", prm);
            send (msg);
            yield;
            if (p.error != null) throw new LspError.RESPONSE (p.error);
            return p.result;
        }

        public void cancel_unused (int id) {
            var prm = new Json.Object ();
            prm.set_int_member ("id", id);
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (prm);
            notify_server ("$/cancelRequest", node);
        }

        private void reply (Json.Node id, Json.Node? result) {
            var msg = new Json.Object ();
            msg.set_member ("id", id.copy ());
            msg.set_member ("result", result ?? new Json.Node (Json.NodeType.NULL));
            send (msg);
        }

        private void handle_server_request (Json.Object msg) {
            var method = msg.get_string_member ("method");
            var id = msg.get_member ("id");
            if (method == "workspace/configuration") {
                var arr = new Json.Array ();
                var items = msg.get_object_member ("params").get_array_member ("items");
                for (uint i = 0; i < items.get_length (); i++)
                    arr.add_null_element ();
                var node = new Json.Node (Json.NodeType.ARRAY);
                node.set_array (arr);
                reply (id, node);
                return;
            }
            if (method == "workspace/applyEdit") {
                var prm = msg.get_object_member ("params");
                if (prm != null && prm.has_member ("edit")) apply_edit_requested (prm.get_object_member ("edit"));
                var res = new Json.Object ();
                res.set_boolean_member ("applied", true);
                reply (id, new Json.Node (Json.NodeType.OBJECT).init_object (res));
                return;
            }
            if (method == "workspace/workspaceFolders") {
                var arr = new Json.Array ();
                arr.add_object_element (folder_object ());
                var node = new Json.Node (Json.NodeType.ARRAY);
                node.set_array (arr);
                reply (id, node);
                return;
            }
            reply (id, null);
        }

        private void dispatch (Json.Object msg) {
            if (msg.has_member ("method") && msg.has_member ("id")) {
                handle_server_request (msg);
                return;
            }
            if (msg.has_member ("method")) {
                notification (msg.get_string_member ("method"),
                              msg.has_member ("params") ? msg.get_member ("params") : null);
                return;
            }
            if (!msg.has_member ("id")) return;
            int id = (int) msg.get_int_member ("id");
            var p = pending.lookup (id);
            if (p == null) return;
            pending.remove (id);
            if (msg.has_member ("error")) {
                var err = msg.get_object_member ("error");
                p.error = err.has_member ("message") ? err.get_string_member ("message") : "error";
            } else if (msg.has_member ("result")) {
                p.result = msg.get_member ("result").copy ();
            }
            Idle.add ((owned) p.callback);
        }

        private async void read_loop () {
            try {
                while (alive) {
                    int64 length = -1;
                    while (true) {
                        size_t len;
                        var line = yield input.read_line_async (Priority.DEFAULT, null, out len);
                        if (line == null) return;
                        line = line.strip ();
                        if (line == "") break;
                        if (line.down ().has_prefix ("content-length:"))
                            length = int64.parse (line.substring (15).strip ());
                    }
                    if (length <= 0) continue;
                    var buf = new uint8[length + 1];
                    size_t read;
                    yield input.read_all_async (buf[0:length], Priority.DEFAULT, null, out read);
                    if (read != length) return;
                    buf[length] = 0;
                    var parser = new Json.Parser ();
                    parser.load_from_data ((string) buf, (ssize_t) length);
                    var root = parser.get_root ();
                    if (root != null && root.get_node_type () == Json.NodeType.OBJECT)
                        dispatch (root.get_object ());
                }
            } catch (Error e) {
                log_line ("read failed: " + e.message);
            }
        }

        private async void read_stderr (DataInputStream err) {
            try {
                while (true) {
                    size_t len;
                    var line = yield err.read_line_async (Priority.LOW, null, out len);
                    if (line == null) return;
                    log_line (line);
                }
            } catch (Error e) {
            }
        }

        private Json.Object folder_object () {
            var folder = new Json.Object ();
            folder.set_string_member ("uri", File.new_for_path (root_path).get_uri ());
            folder.set_string_member ("name", Path.get_basename (root_path));
            return folder;
        }

        public async void initialize (Json.Node? options = null) throws Error {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("processId");
            b.add_null_value ();
            b.set_member_name ("rootUri");
            b.add_string_value (File.new_for_path (root_path).get_uri ());
            b.set_member_name ("clientInfo");
            b.begin_object ();
            b.set_member_name ("name");
            b.add_string_value ("Singularity Edit");
            b.end_object ();
            b.set_member_name ("workspaceFolders");
            b.begin_array ();
            b.add_value (new Json.Node (Json.NodeType.OBJECT).init_object (folder_object ()));
            b.end_array ();
            b.set_member_name ("capabilities");
            b.begin_object ();
            b.set_member_name ("general");
            b.begin_object ();
            b.set_member_name ("positionEncodings");
            b.begin_array ();
            b.add_string_value ("utf-8");
            b.add_string_value ("utf-16");
            b.end_array ();
            b.end_object ();
            b.set_member_name ("workspace");
            b.begin_object ();
            b.set_member_name ("configuration");
            b.add_boolean_value (true);
            b.set_member_name ("workspaceFolders");
            b.add_boolean_value (true);
            b.set_member_name ("applyEdit");
            b.add_boolean_value (true);
            b.set_member_name ("workspaceEdit");
            b.begin_object ();
            b.set_member_name ("documentChanges");
            b.add_boolean_value (true);
            b.end_object ();
            b.end_object ();
            b.set_member_name ("textDocument");
            b.begin_object ();
            b.set_member_name ("synchronization");
            b.begin_object ();
            b.set_member_name ("didSave");
            b.add_boolean_value (true);
            b.end_object ();
            b.set_member_name ("completion");
            b.begin_object ();
            b.set_member_name ("completionItem");
            b.begin_object ();
            b.set_member_name ("snippetSupport");
            b.add_boolean_value (false);
            b.set_member_name ("documentationFormat");
            b.begin_array ();
            b.add_string_value ("plaintext");
            b.add_string_value ("markdown");
            b.end_array ();
            b.end_object ();
            b.end_object ();
            b.set_member_name ("hover");
            b.begin_object ();
            b.set_member_name ("contentFormat");
            b.begin_array ();
            b.add_string_value ("plaintext");
            b.add_string_value ("markdown");
            b.end_array ();
            b.end_object ();
            b.set_member_name ("publishDiagnostics");
            b.begin_object ();
            b.set_member_name ("relatedInformation");
            b.add_boolean_value (false);
            b.end_object ();
            b.set_member_name ("codeAction");
            b.begin_object ();
            b.set_member_name ("dataSupport");
            b.add_boolean_value (true);
            b.set_member_name ("isPreferredSupport");
            b.add_boolean_value (true);
            b.set_member_name ("resolveSupport");
            b.begin_object ();
            b.set_member_name ("properties");
            b.begin_array ();
            b.add_string_value ("edit");
            b.end_array ();
            b.end_object ();
            b.set_member_name ("codeActionLiteralSupport");
            b.begin_object ();
            b.set_member_name ("codeActionKind");
            b.begin_object ();
            b.set_member_name ("valueSet");
            b.begin_array ();
            foreach (var kind in new string[] { "", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source", "source.organizeImports" })
                b.add_string_value (kind);
            b.end_array ();
            b.end_object ();
            b.end_object ();
            b.end_object ();
            foreach (var cap in new string[] { "definition", "formatting", "rename", "signatureHelp" }) {
                b.set_member_name (cap);
                b.begin_object ();
                b.end_object ();
            }
            b.end_object ();
            b.end_object ();
            if (options != null) {
                b.set_member_name ("initializationOptions");
                b.add_value (options);
            }
            b.end_object ();
            var result = yield request ("initialize", b.get_root ());
            if (result != null && result.get_node_type () == Json.NodeType.OBJECT) {
                var obj = result.get_object ();
                if (obj.has_member ("capabilities")) {
                    capabilities = obj.get_object_member ("capabilities");
                    utf8_positions = capabilities.has_member ("positionEncoding")
                        && capabilities.get_string_member ("positionEncoding") == "utf-8";
                }
            }
            notify_server ("initialized", new Json.Node (Json.NodeType.OBJECT).init_object (new Json.Object ()));
        }

        public bool supports_member (string capability, string member) {
            if (capabilities == null || !capabilities.has_member (capability)) return false;
            var node = capabilities.get_member (capability);
            if (node.get_node_type () != Json.NodeType.OBJECT) return false;
            var obj = node.get_object ();
            return obj.has_member (member) && obj.get_boolean_member (member);
        }

        public bool supports (string capability) {
            if (capabilities == null || !capabilities.has_member (capability)) return false;
            var node = capabilities.get_member (capability);
            if (node.get_node_type () == Json.NodeType.VALUE)
                return node.get_value_type () != typeof (bool) || node.get_boolean ();
            return node.get_node_type () == Json.NodeType.OBJECT;
        }
    }
}
