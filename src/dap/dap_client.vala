using GLib;

namespace Singularity.Apps {

    private class DapPending {
        public SourceFunc callback;
        public Json.Object? body;
        public string? error;
    }

    public class DapClient : Object {
        public bool alive { get; private set; default = false; }
        public Json.Object? capabilities { get; private set; }

        public signal void event_received (string name, Json.Object body);
        public signal void log_line (string line);
        public signal void exited ();

        private Subprocess? proc;
        private SocketConnection? connection;
        private DataInputStream input;
        private OutputStream output;
        private int seq = 1;
        private HashTable<int, DapPending> pending = new HashTable<int, DapPending> (direct_hash, direct_equal);

        public void start_stdio (string[] argv, string cwd) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDIN_PIPE | SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE);
            launcher.set_cwd (cwd);
            proc = launcher.spawnv (argv);
            attach_streams (proc.get_stdout_pipe (), proc.get_stdin_pipe ());
            read_stderr.begin (new DataInputStream (proc.get_stderr_pipe ()));
            watch_process ();
        }

        public async void start_tcp (string[] argv, string cwd, uint16 port) throws Error {
            var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
            launcher.set_cwd (cwd);
            proc = launcher.spawnv (argv);
            read_stderr.begin (new DataInputStream (proc.get_stdout_pipe ()));
            watch_process ();
            var client = new SocketClient ();
            Error? last = null;
            for (int i = 0; i < 50; i++) {
                try {
                    connection = yield client.connect_to_host_async ("127.0.0.1", port, null);
                    break;
                } catch (Error e) {
                    last = e;
                    Timeout.add (100, start_tcp.callback);
                    yield;
                }
            }
            if (connection == null) throw last ?? new IOError.FAILED ("cannot reach the debugger");
            attach_streams (connection.input_stream, connection.output_stream);
        }

        private void attach_streams (InputStream i, OutputStream o) {
            input = new DataInputStream (i);
            input.newline_type = DataStreamNewlineType.ANY;
            output = o;
            alive = true;
            read_loop.begin ();
        }

        private void watch_process () {
            proc.wait_async.begin (null, () => {
                if (!alive && connection == null) return;
                shutdown ();
            });
        }

        private void shutdown () {
            if (!alive) return;
            alive = false;
            foreach (var id in pending.get_keys ()) {
                var p = pending.lookup (id);
                p.error = "debugger exited";
                Idle.add ((owned) p.callback);
            }
            pending.remove_all ();
            exited ();
        }

        public void stop () {
            if (connection != null) {
                try {
                    connection.close ();
                } catch (Error e) {
                }
            }
            if (proc != null) proc.force_exit ();
            shutdown ();
        }

        private void send (Json.Object message) {
            if (!alive) return;
            message.set_int_member ("seq", seq++);
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

        public async Json.Object? request (string command, Json.Object? arguments = null) throws Error {
            if (!alive) throw new IOError.CLOSED ("debugger is not running");
            int id = seq;
            var p = new DapPending ();
            p.callback = request.callback;
            pending.insert (id, p);
            var msg = new Json.Object ();
            msg.set_string_member ("type", "request");
            msg.set_string_member ("command", command);
            if (arguments != null) msg.set_object_member ("arguments", arguments);
            send (msg);
            yield;
            if (p.error != null) throw new IOError.FAILED (p.error);
            return p.body;
        }

        public void fire (string command, Json.Object? arguments = null) {
            request.begin (command, arguments, (obj, res) => {
                try {
                    request.end (res);
                } catch (Error e) {
                    log_line (command + ": " + e.message);
                }
            });
        }

        private void dispatch (Json.Object msg) {
            var type = msg.get_string_member ("type");
            if (type == "event") {
                var body = msg.has_member ("body") && msg.get_member ("body").get_node_type () == Json.NodeType.OBJECT
                    ? msg.get_object_member ("body") : new Json.Object ();
                event_received (msg.get_string_member ("event"), body);
                return;
            }
            if (type == "request") {
                var reply = new Json.Object ();
                reply.set_string_member ("type", "response");
                reply.set_int_member ("request_seq", msg.get_int_member ("seq"));
                reply.set_string_member ("command", msg.get_string_member ("command"));
                reply.set_boolean_member ("success", false);
                reply.set_string_member ("message", "not supported");
                send (reply);
                return;
            }
            if (type != "response") return;
            int id = (int) msg.get_int_member ("request_seq");
            var p = pending.lookup (id);
            if (p == null) return;
            pending.remove (id);
            if (!msg.get_boolean_member ("success")) {
                string text = msg.has_member ("message") ? msg.get_string_member ("message") : "request failed";
                if (msg.has_member ("body")) {
                    var b = msg.get_object_member ("body");
                    if (b != null && b.has_member ("error")) {
                        var err = b.get_object_member ("error");
                        if (err.has_member ("format")) text = err.get_string_member ("format");
                    }
                }
                p.error = text;
            } else if (msg.has_member ("body") && msg.get_member ("body").get_node_type () == Json.NodeType.OBJECT) {
                p.body = msg.get_object_member ("body");
            } else {
                p.body = new Json.Object ();
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
                        if (line == null) {
                            shutdown ();
                            return;
                        }
                        line = line.strip ();
                        if (line == "") break;
                        if (line.down ().has_prefix ("content-length:"))
                            length = int64.parse (line.substring (15).strip ());
                    }
                    if (length <= 0) continue;
                    var buf = new uint8[length + 1];
                    size_t read;
                    yield input.read_all_async (buf[0:length], Priority.DEFAULT, null, out read);
                    if (read != length) {
                        shutdown ();
                        return;
                    }
                    buf[length] = 0;
                    var parser = new Json.Parser ();
                    parser.load_from_data ((string) buf, (ssize_t) length);
                    var root = parser.get_root ();
                    if (root != null && root.get_node_type () == Json.NodeType.OBJECT)
                        dispatch (root.get_object ());
                }
            } catch (Error e) {
                log_line ("read failed: " + e.message);
                shutdown ();
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

        public async void initialize (string adapter_id) throws Error {
            var args = new Json.Object ();
            args.set_string_member ("clientID", "singularity-edit");
            args.set_string_member ("clientName", "Singularity Edit");
            args.set_string_member ("adapterID", adapter_id);
            args.set_boolean_member ("linesStartAt1", true);
            args.set_boolean_member ("columnsStartAt1", true);
            args.set_string_member ("pathFormat", "path");
            args.set_boolean_member ("supportsVariableType", true);
            args.set_boolean_member ("supportsRunInTerminalRequest", false);
            capabilities = yield request ("initialize", args);
        }

        public bool supports (string capability) {
            return capabilities != null && capabilities.has_member (capability) && capabilities.get_boolean_member (capability);
        }
    }
}
