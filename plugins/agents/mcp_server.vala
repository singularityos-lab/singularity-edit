using GLib;
using Singularity.Edit;

namespace EditAgents {

    public class McpServer : Object {
        private unowned Workspace workspace;
        private SocketService service = new SocketService ();
        public string socket_path { get; private set; }

        public McpServer (Workspace ws) {
            workspace = ws;
            string dir = Environment.get_user_runtime_dir ();
            socket_path = Path.build_filename (dir, "singularity-edit-mcp-%d-%u.sock".printf ((int) Posix.getpid (), Random.next_int ()));
            try {
                SocketAddress effective;
                service.add_address (new UnixSocketAddress (socket_path), SocketType.STREAM, SocketProtocol.DEFAULT, null, out effective);
                service.incoming.connect ((conn) => {
                    serve.begin (conn);
                    return true;
                });
                service.start ();
            } catch (Error e) {
                socket_path = "";
            }
        }

        public void stop () {
            service.stop ();
            service.close ();
            if (socket_path != "") FileUtils.unlink (socket_path);
        }

        public static string? bridge_path () {
            try {
                string exe = FileUtils.read_link ("/proc/self/exe");
                string c = Path.build_filename (Path.get_dirname (Path.get_dirname (exe)), "libexec", "singularity-edit-mcp");
                if (FileUtils.test (c, FileTest.IS_EXECUTABLE)) return c;
            } catch (FileError e) {
            }
            return Environment.find_program_in_path ("singularity-edit-mcp");
        }

        public Json.Object? descriptor () {
            var bridge = bridge_path ();
            if (socket_path == "" || bridge == null) return null;
            var o = new Json.Object ();
            o.set_string_member ("name", "singularity-edit");
            o.set_string_member ("command", bridge);
            var args = new Json.Array ();
            args.add_string_element ("--socket");
            args.add_string_element (socket_path);
            o.set_array_member ("args", args);
            o.set_array_member ("env", new Json.Array ());
            return o;
        }

        private async void serve (SocketConnection conn) {
            var input = new DataInputStream (conn.input_stream);
            input.newline_type = DataStreamNewlineType.LF;
            try {
                while (true) {
                    size_t len;
                    var line = yield input.read_line_async (Priority.DEFAULT, null, out len);
                    if (line == null) break;
                    if (line.strip () == "") continue;
                    var parser = new Json.Parser ();
                    parser.load_from_data (line);
                    var msg = parser.get_root ().get_object ();
                    if (!msg.has_member ("id") || !msg.has_member ("method")) continue;
                    var reply = new Json.Object ();
                    reply.set_string_member ("jsonrpc", "2.0");
                    reply.set_member ("id", msg.get_member ("id").copy ());
                    var prm = msg.has_member ("params") ? msg.get_object_member ("params") : new Json.Object ();
                    var result = handle (msg.get_string_member ("method"), prm);
                    if (result != null) {
                        reply.set_object_member ("result", result);
                    } else {
                        var err = new Json.Object ();
                        err.set_int_member ("code", -32601);
                        err.set_string_member ("message", "method not found");
                        reply.set_object_member ("error", err);
                    }
                    var node = new Json.Node (Json.NodeType.OBJECT);
                    node.set_object (reply);
                    var text = Json.to_string (node, false) + "\n";
                    yield conn.output_stream.write_all_async (text.data, Priority.DEFAULT, null, null);
                }
            } catch (Error e) {
            }
        }

        private static Json.Object tool (string name, string description, Json.Object properties, string[] required) {
            var t = new Json.Object ();
            t.set_string_member ("name", name);
            t.set_string_member ("description", description);
            var schema = new Json.Object ();
            schema.set_string_member ("type", "object");
            schema.set_object_member ("properties", properties);
            var req = new Json.Array ();
            foreach (var r in required) req.add_string_element (r);
            schema.set_array_member ("required", req);
            t.set_object_member ("inputSchema", schema);
            return t;
        }

        private static Json.Object prop (string type, string description) {
            var p = new Json.Object ();
            p.set_string_member ("type", type);
            p.set_string_member ("description", description);
            return p;
        }

        private Json.Object? handle (string method, Json.Object prm) {
            switch (method) {
                case "initialize":
                    var r = new Json.Object ();
                    r.set_string_member ("protocolVersion", prm.has_member ("protocolVersion") ? prm.get_string_member ("protocolVersion") : "2025-06-18");
                    var caps = new Json.Object ();
                    caps.set_object_member ("tools", new Json.Object ());
                    r.set_object_member ("capabilities", caps);
                    var info = new Json.Object ();
                    info.set_string_member ("name", "singularity-edit");
                    info.set_string_member ("version", "1.0");
                    r.set_object_member ("serverInfo", info);
                    return r;
                case "ping":
                    return new Json.Object ();
                case "tools/list":
                    var tools = new Json.Array ();
                    tools.add_object_element (tool ("edit_open_documents", "List the files open in Singularity Edit, the active one first, with unsaved state", new Json.Object (), {}));
                    var dprops = new Json.Object ();
                    dprops.set_object_member ("path", prop ("string", "Absolute path of an open file; omit for all open files"));
                    tools.add_object_element (tool ("edit_diagnostics", "Errors and warnings reported by the language servers for open files", dprops, {}));
                    tools.add_object_element (tool ("edit_selection", "The active file, cursor position and selected text in Singularity Edit", new Json.Object (), {}));
                    var oprops = new Json.Object ();
                    oprops.set_object_member ("path", prop ("string", "Absolute path of the file to show"));
                    oprops.set_object_member ("line", prop ("integer", "1-based line to reveal"));
                    tools.add_object_element (tool ("edit_open_file", "Open a file in Singularity Edit so the user sees it, optionally at a line", oprops, { "path" }));
                    var r = new Json.Object ();
                    r.set_array_member ("tools", tools);
                    return r;
                case "tools/call":
                    return call_tool (prm.get_string_member ("name"), prm.has_member ("arguments") ? prm.get_object_member ("arguments") : new Json.Object ());
                default:
                    return null;
            }
        }

        private static Json.Object text_result (string text, bool error = false) {
            var r = new Json.Object ();
            var content = new Json.Array ();
            var c = new Json.Object ();
            c.set_string_member ("type", "text");
            c.set_string_member ("text", text);
            content.add_object_element (c);
            r.set_array_member ("content", content);
            r.set_boolean_member ("isError", error);
            return r;
        }

        private Json.Object call_tool (string name, Json.Object args) {
            var sb = new StringBuilder ();
            switch (name) {
                case "edit_open_documents":
                    var active = workspace.get_active_document ();
                    if (active != null && active.get_file () != null) sb.append ("%s (active)%s\n".printf (active.get_file ().get_path (), active.get_modified () ? " unsaved" : ""));
                    foreach (var d in workspace.documents ()) {
                        if (d == active || d.get_file () == null) continue;
                        sb.append ("%s%s\n".printf (d.get_file ().get_path (), d.get_modified () ? " unsaved" : ""));
                    }
                    return text_result (sb.len > 0 ? sb.str : "No files are open");
                case "edit_diagnostics":
                    string? only = args.has_member ("path") ? args.get_string_member ("path") : null;
                    foreach (var d in workspace.documents ()) {
                        if (d.get_file () == null) continue;
                        string p = d.get_file ().get_path ();
                        if (only != null && p != only) continue;
                        foreach (var line in d.get_diagnostics ()) sb.append ("%s:%s\n".printf (p, line));
                    }
                    return text_result (sb.len > 0 ? sb.str : "No problems reported");
                case "edit_selection":
                    var doc = workspace.get_active_document ();
                    if (doc == null || doc.get_file () == null) return text_result ("No file is active");
                    var buffer = doc.get_buffer ();
                    Gtk.TextIter s, e;
                    buffer.get_iter_at_mark (out s, buffer.get_insert ());
                    sb.append ("%s line %d column %d\n".printf (doc.get_file ().get_path (), s.get_line () + 1, s.get_line_offset () + 1));
                    if (buffer.get_selection_bounds (out s, out e)) sb.append (buffer.get_text (s, e, false));
                    return text_result (sb.str);
                case "edit_open_file":
                    string path = args.get_string_member ("path");
                    int line = args.has_member ("line") ? (int) args.get_int_member ("line") - 1 : -1;
                    if (!FileUtils.test (path, FileTest.EXISTS)) return text_result ("No such file: " + path, true);
                    workspace.open_file (File.new_for_path (path), line, 0);
                    return text_result ("Opened " + path);
                default:
                    return text_result ("Unknown tool " + name, true);
            }
        }
    }
}
