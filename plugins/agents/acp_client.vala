using GLib;

namespace EditAgents {

    public class AcpReply : Object {
        private unowned AcpClient client;
        private Json.Node id;
        public bool answered { get; private set; default = false; }

        public AcpReply (AcpClient client, Json.Node id) {
            this.client = client;
            this.id = id.copy ();
        }

        public void result (Json.Node? value) {
            if (answered) return;
            answered = true;
            client.send_response (id, value, null, 0);
        }

        public void result_object (Json.Object value) {
            result (new Json.Node (Json.NodeType.OBJECT).init_object (value));
        }

        public void error (int code, string message) {
            if (answered) return;
            answered = true;
            client.send_response (id, null, message, code);
        }
    }

    private class AcpPending {
        public SourceFunc callback;
        public Json.Node? result;
        public string? error;
    }

    public class AcpClient : Object {
        public bool alive { get; private set; default = false; }

        public signal void notification (string method, Json.Object prm);
        public signal void request (string method, Json.Object prm, AcpReply reply);
        public signal void stderr_line (string line);
        public signal void exited ();

        public Singularity.Edit.Dsh? dsh { get; set; }

        private Subprocess? proc;
        private DataInputStream input;
        private OutputStream output;
        private int next_id = 1;
        private HashTable<int, AcpPending> pending = new HashTable<int, AcpPending> (direct_hash, direct_equal);

        public void start (string[] argv, string cwd, string[]? env) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.set_cwd (cwd);
            if (env != null) launcher.set_environ (env);
            proc = launcher.spawnv (argv);
            input = new DataInputStream (proc.get_stdout_pipe ());
            input.newline_type = DataStreamNewlineType.LF;
            output = proc.get_stdin_pipe ();
            alive = true;
            read_loop.begin ();
            read_stderr.begin (new DataInputStream (proc.get_stderr_pipe ()));
            proc.wait_async.begin (null, () => shutdown ("agent exited"));
        }

        public void stop () {
            if (proc != null) proc.force_exit ();
            shutdown ("agent stopped");
        }

        private void shutdown (string reason) {
            if (!alive) return;
            alive = false;
            foreach (var id in pending.get_keys ()) {
                var p = pending.lookup (id);
                p.error = reason;
                Idle.add ((owned) p.callback);
            }
            pending.remove_all ();
            exited ();
        }

        private void write (Json.Object message) {
            if (!alive) return;
            message.set_string_member ("jsonrpc", "2.0");
            var node = new Json.Node (Json.NodeType.OBJECT);
            node.set_object (message);
            var line = Json.to_string (node, false) + "\n";
            if (dsh != null) line = dsh.to_guest_text (line);
            try {
                size_t written;
                output.write_all (line.data, out written);
                output.flush ();
            } catch (Error e) {
                stderr_line ("write failed: " + e.message);
            }
        }

        internal void send_response (Json.Node id, Json.Node? result, string? error, int code) {
            var msg = new Json.Object ();
            msg.set_member ("id", id.copy ());
            if (error != null) {
                var err = new Json.Object ();
                err.set_int_member ("code", code != 0 ? code : -32603);
                err.set_string_member ("message", error);
                msg.set_object_member ("error", err);
            } else {
                msg.set_member ("result", result ?? new Json.Node (Json.NodeType.NULL));
            }
            write (msg);
        }

        public void notify (string method, Json.Object prm) {
            var msg = new Json.Object ();
            msg.set_string_member ("method", method);
            msg.set_object_member ("params", prm);
            write (msg);
        }

        public async Json.Node? call (string method, Json.Object prm) throws Error {
            if (!alive) throw new IOError.CLOSED ("agent is not running");
            int id = next_id++;
            var p = new AcpPending ();
            p.callback = call.callback;
            pending.insert (id, p);
            var msg = new Json.Object ();
            msg.set_int_member ("id", id);
            msg.set_string_member ("method", method);
            msg.set_object_member ("params", prm);
            write (msg);
            yield;
            if (p.error != null) throw new IOError.FAILED (p.error);
            return p.result;
        }

        private void dispatch (Json.Object msg) {
            bool has_id = msg.has_member ("id") && msg.get_member ("id").get_node_type () != Json.NodeType.NULL;
            if (msg.has_member ("method")) {
                var prm = msg.has_member ("params") && msg.get_member ("params").get_node_type () == Json.NodeType.OBJECT
                    ? msg.get_object_member ("params") : new Json.Object ();
                if (has_id) {
                    var reply = new AcpReply (this, msg.get_member ("id"));
                    request (msg.get_string_member ("method"), prm, reply);
                    if (!reply.answered && !reply.get_data<bool> ("deferred")) reply.error (-32601, "method not supported");
                } else {
                    notification (msg.get_string_member ("method"), prm);
                }
                return;
            }
            if (!has_id) return;
            int id = (int) msg.get_int_member ("id");
            var p = pending.lookup (id);
            if (p == null) return;
            pending.remove (id);
            if (msg.has_member ("error")) {
                var err = msg.get_object_member ("error");
                p.error = err.has_member ("message") ? err.get_string_member ("message") : "agent error";
            } else if (msg.has_member ("result")) {
                p.result = msg.get_member ("result").copy ();
            }
            Idle.add ((owned) p.callback);
        }

        private async void read_loop () {
            try {
                while (alive) {
                    size_t len;
                    var line = yield input.read_line_async (Priority.DEFAULT, null, out len);
                    if (line == null) break;
                    line = line.strip ();
                    if (line == "" || !line.has_prefix ("{")) {
                        if (line != "") stderr_line (line);
                        continue;
                    }
                    if (dsh != null) line = dsh.to_host_text (line);
                    var parser = new Json.Parser ();
                    try {
                        parser.load_from_data (line);
                    } catch (Error e) {
                        stderr_line ("bad message: " + e.message);
                        continue;
                    }
                    var root = parser.get_root ();
                    if (root != null && root.get_node_type () == Json.NodeType.OBJECT) dispatch (root.get_object ());
                }
            } catch (Error e) {
                stderr_line ("read failed: " + e.message);
            }
            shutdown ("agent closed the connection");
        }

        private async void read_stderr (DataInputStream err) {
            try {
                while (true) {
                    size_t len;
                    var line = yield err.read_line_async (Priority.LOW, null, out len);
                    if (line == null) return;
                    stderr_line (line);
                }
            } catch (Error e) {
            }
        }
    }
}
