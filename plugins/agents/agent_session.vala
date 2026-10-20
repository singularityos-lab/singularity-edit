using GLib;
using Singularity.Edit;

namespace EditAgents {

    public enum Mode {
        PLAN,
        ASK,
        AUTO_EDIT,
        AUTOPILOT;

        public string label () {
            switch (this) {
                case PLAN: return _("Plan");
                case AUTO_EDIT: return _("Auto Edit");
                case AUTOPILOT: return _("Autopilot");
                default: return _("Ask First");
            }
        }

        public string summary () {
            switch (this) {
                case PLAN: return _("Reads and proposes, changes nothing");
                case AUTO_EDIT: return _("Edits project files, asks before commands");
                case AUTOPILOT: return _("Works until done inside the project, with a restore point");
                default: return _("Asks before every change");
            }
        }

        public string[] agent_mode_hints () {
            switch (this) {
                case PLAN: return { "plan" };
                case AUTO_EDIT: return { "acceptEdits", "accept-edits", "auto_edit", "auto-edit", "auto" };
                case AUTOPILOT: return { "bypassPermissions", "yolo", "full-access", "full_access" };
                default: return { "default", "ask", "read-only" };
            }
        }
    }

    public class ToolCall : Object {
        public string id;
        public string title = "";
        public string kind = "other";
        public string status = "pending";
        public Json.Array content = new Json.Array ();
        public Json.Array locations = new Json.Array ();
        public signal void changed ();

        public void update (Json.Object u) {
            if (u.has_member ("title") && u.get_member ("title").get_node_type () == Json.NodeType.VALUE) title = u.get_string_member ("title");
            if (u.has_member ("kind") && u.get_member ("kind").get_node_type () == Json.NodeType.VALUE) kind = u.get_string_member ("kind");
            if (u.has_member ("status") && u.get_member ("status").get_node_type () == Json.NodeType.VALUE) status = u.get_string_member ("status");
            if (u.has_member ("content") && u.get_member ("content").get_node_type () == Json.NodeType.ARRAY) content = u.get_array_member ("content");
            if (u.has_member ("locations") && u.get_member ("locations").get_node_type () == Json.NodeType.ARRAY) locations = u.get_array_member ("locations");
            changed ();
        }
    }

    public class PermissionRequest : Object {
        public ToolCall call;
        public Json.Array options;
        public AcpReply reply;
        public signal void settled ();

        public void choose (string? option_id) {
            var outcome = new Json.Object ();
            if (option_id == null) {
                outcome.set_string_member ("outcome", "cancelled");
            } else {
                outcome.set_string_member ("outcome", "selected");
                outcome.set_string_member ("optionId", option_id);
            }
            var res = new Json.Object ();
            res.set_object_member ("outcome", outcome);
            reply.result_object (res);
            settled ();
        }

        public string? option_of_kind (string[] kinds) {
            foreach (var k in kinds) {
                for (uint i = 0; i < options.get_length (); i++) {
                    var o = options.get_object_element (i);
                    if (o.get_string_member ("kind") == k) return o.get_string_member ("optionId");
                }
            }
            return null;
        }
    }

    public class ChangedFile : Object {
        public string path;
        public string? original;
        public int added;
        public int removed;
    }

    private class AgentTerminal {
        public Subprocess proc;
        public StringBuilder output = new StringBuilder ();
        public int64 limit = 1024 * 1024;
        public bool truncated;
        public bool done;
        public int exit_code = -1;
        public int signal_no = 0;
        public GenericArray<AcpReply> waiters = new GenericArray<AcpReply> ();
    }

    public class AgentSession : Object {
        public AgentEntry agent { get; private set; }
        public unowned Workspace workspace { get; private set; }
        public string root { get; private set; }
        public Mode mode { get; private set; }
        public bool busy { get; private set; }
        public bool running { get; private set; }
        public string status { get; set; default = ""; }
        public int autopilot_minutes { get; set; default = 30; }
        public Json.Array? agent_modes { get; private set; }
        public string? agent_mode { get; private set; }

        public signal void text_chunk (string role, string text);
        public signal void tool_added (ToolCall call);
        public signal void plan_changed (Json.Array entries);
        public signal void permission_asked (PermissionRequest request);
        public signal void changes_changed ();
        public signal void turn_finished (string stop_reason);
        public signal void ended (string reason);
        public signal void touched (string path, int line);

        private AcpClient client = new AcpClient ();
        private string? session_id;
        private HashTable<string, ToolCall> calls = new HashTable<string, ToolCall> (str_hash, str_equal);
        private HashTable<string, AgentTerminal> terminals = new HashTable<string, AgentTerminal> (str_hash, str_equal);
        private int next_terminal = 1;
        public HashTable<string, ChangedFile> changes = new HashTable<string, ChangedFile> (str_hash, str_equal);
        private RestorePoint? restore;
        private HostProxy? proxy;
        private Singularity.Edit.Dsh? dsh;
        private uint deadline;
        private Cancellable cancel = new Cancellable ();

        public Json.Object? mcp { get; set; }

        public AgentSession (AgentEntry agent, Workspace ws, string root, Mode mode) {
            this.agent = agent;
            this.workspace = ws;
            this.root = root;
            this.mode = mode;
            client.notification.connect (on_notification);
            client.request.connect (on_request);
            client.exited.connect (() => end (_("The agent stopped")));
        }

        public bool has_restore_point { get { return restore != null; } }

        public async bool start () {
            status = _("Starting %s").printf (agent.name);
            try {
                var launch = yield AgentCatalog.get_default ().launch_for (agent, cancel);
                string[] env = Environ.get ();
                foreach (var e in launch.env) env += e;
                string[] argv = launch.argv;
                var shell = Singularity.Edit.Dsh.for_path (root);
                if (mode != Mode.AUTOPILOT && shell != null && argv.length > 0
                    && (!Path.is_absolute (argv[0]) || shell.owns (argv[0])) && shell.has_program (shell.to_guest (argv[0]))) {
                    dsh = shell;
                    client.dsh = shell;
                    argv = shell.wrap (argv, root, launch.env);
                    env = Environ.get ();
                }
                if (dsh == null && argv.length > 0 && !Path.is_absolute (argv[0])
                    && Environment.find_program_in_path (argv[0]) == null) {
                    var any = Singularity.Edit.Dsh.get_default ();
                    if (any != null && any.has_program (argv[0]))
                        throw new IOError.NOT_FOUND (_("%s runs from the developer shell: open your project from Developer Files to use it").printf (agent.name));
                }
                if (mode == Mode.AUTOPILOT) {
                    restore = yield RestorePoint.create (root);
                    proxy = new HostProxy (agent.hosts);
                    env = proxy.apply (env);
                    argv = Sandbox.wrap (argv, root);
                }
                client.start (argv, dsh != null ? Environment.get_home_dir () : root, env);
                running = true;
                var caps = new Json.Object ();
                var fs = new Json.Object ();
                fs.set_boolean_member ("readTextFile", true);
                fs.set_boolean_member ("writeTextFile", true);
                caps.set_object_member ("fs", fs);
                caps.set_boolean_member ("terminal", true);
                var info = new Json.Object ();
                info.set_string_member ("name", "singularity-edit");
                info.set_string_member ("title", "Singularity Edit");
                info.set_string_member ("version", "1.0");
                var init = new Json.Object ();
                init.set_int_member ("protocolVersion", 1);
                init.set_object_member ("clientCapabilities", caps);
                init.set_object_member ("clientInfo", info);
                status = _("Connecting to %s").printf (agent.name);
                yield client.call ("initialize", init);
                var neu = new Json.Object ();
                neu.set_string_member ("cwd", root);
                var servers = new Json.Array ();
                if (mcp != null) servers.add_object_element (mcp);
                neu.set_array_member ("mcpServers", servers);
                Json.Node? created;
                try {
                    created = yield client.call ("session/new", neu);
                } catch (Error e) {
                    if ("auth" in e.message.down ()) throw new IOError.PERMISSION_DENIED (_("Sign in to %s first: run it once in a terminal").printf (agent.name));
                    throw e;
                }
                var obj = created.get_object ();
                session_id = obj.get_string_member ("sessionId");
                if (obj.has_member ("modes") && obj.get_member ("modes").get_node_type () == Json.NodeType.OBJECT) {
                    var modes = obj.get_object_member ("modes");
                    agent_modes = modes.get_array_member ("availableModes");
                    agent_mode = modes.get_string_member ("currentModeId");
                }
                yield apply_agent_mode ();
                if (mode == Mode.AUTOPILOT) {
                    deadline = Timeout.add_seconds ((uint) autopilot_minutes * 60, () => {
                        deadline = 0;
                        stop_turn ();
                        end (_("Autopilot reached its time limit"));
                        return Source.REMOVE;
                    });
                }
                status = _("Ready");
                return true;
            } catch (Error e) {
                end (e.message);
                return false;
            }
        }

        private async void apply_agent_mode () {
            if (agent_modes == null || session_id == null) return;
            foreach (var hint in mode.agent_mode_hints ()) {
                for (uint i = 0; i < agent_modes.get_length (); i++) {
                    var m = agent_modes.get_object_element (i);
                    if (m.get_string_member ("id").down () != hint.down ()) continue;
                    var prm = new Json.Object ();
                    prm.set_string_member ("sessionId", session_id);
                    prm.set_string_member ("modeId", m.get_string_member ("id"));
                    try {
                        yield client.call ("session/set_mode", prm);
                        agent_mode = m.get_string_member ("id");
                    } catch (Error e) {
                    }
                    return;
                }
            }
        }

        public void change_mode (Mode m) {
            if (m == Mode.AUTOPILOT && mode != Mode.AUTOPILOT) return;
            mode = m;
            apply_agent_mode.begin ();
        }

        public async void prompt (string text, Document? context) {
            if (session_id == null || busy) return;
            busy = true;
            status = _("Working");
            text_chunk ("user", text);
            var blocks = new Json.Array ();
            var t = new Json.Object ();
            t.set_string_member ("type", "text");
            string preface = mode == Mode.PLAN ? _("Plan only: do not modify files or run commands.\n\n") : "";
            t.set_string_member ("text", preface + text);
            blocks.add_object_element (t);
            if (context != null && context.get_file () != null) {
                var link = new Json.Object ();
                link.set_string_member ("type", "resource_link");
                link.set_string_member ("uri", context.get_file ().get_uri ());
                link.set_string_member ("name", context.get_file ().get_basename ());
                blocks.add_object_element (link);
            }
            var prm = new Json.Object ();
            prm.set_string_member ("sessionId", session_id);
            prm.set_array_member ("prompt", blocks);
            string reason = "end_turn";
            try {
                var res = yield client.call ("session/prompt", prm);
                if (res != null && res.get_node_type () == Json.NodeType.OBJECT && res.get_object ().has_member ("stopReason"))
                    reason = res.get_object ().get_string_member ("stopReason");
            } catch (Error e) {
                reason = "error";
                text_chunk ("error", e.message);
            }
            busy = false;
            status = reason == "cancelled" ? _("Stopped") : _("Ready");
            turn_finished (reason);
        }

        public void stop_turn () {
            if (session_id == null) return;
            var prm = new Json.Object ();
            prm.set_string_member ("sessionId", session_id);
            client.notify ("session/cancel", prm);
        }

        public void end (string reason) {
            if (!running && session_id == null && status == reason) return;
            if (deadline != 0) {
                Source.remove (deadline);
                deadline = 0;
            }
            cancel.cancel ();
            foreach (var t in terminals.get_values ()) if (!t.done) t.proc.force_exit ();
            if (client.alive) client.stop ();
            if (proxy != null) proxy.stop ();
            running = false;
            busy = false;
            session_id = null;
            status = reason;
            ended (reason);
        }

        private void on_notification (string method, Json.Object prm) {
            if (method != "session/update" || !prm.has_member ("update")) return;
            var u = prm.get_object_member ("update");
            string kind = u.get_string_member ("sessionUpdate");
            switch (kind) {
                case "agent_message_chunk":
                case "agent_thought_chunk":
                case "user_message_chunk":
                    var c = u.get_object_member ("content");
                    if (c != null && c.has_member ("text"))
                        text_chunk (kind == "agent_thought_chunk" ? "thought" : (kind == "user_message_chunk" ? "user" : "agent"), c.get_string_member ("text"));
                    break;
                case "tool_call":
                    var call = new ToolCall ();
                    call.id = u.get_string_member ("toolCallId");
                    call.update (u);
                    calls.insert (call.id, call);
                    tool_added (call);
                    follow_locations (call);
                    break;
                case "tool_call_update":
                    var existing = calls.lookup (u.get_string_member ("toolCallId"));
                    if (existing == null) {
                        existing = new ToolCall ();
                        existing.id = u.get_string_member ("toolCallId");
                        calls.insert (existing.id, existing);
                        existing.update (u);
                        tool_added (existing);
                    } else {
                        existing.update (u);
                    }
                    follow_locations (existing);
                    break;
                case "plan":
                    plan_changed (u.get_array_member ("entries"));
                    break;
                case "current_mode_update":
                    agent_mode = u.get_string_member ("currentModeId");
                    break;
            }
        }

        private void follow_locations (ToolCall call) {
            for (uint i = 0; i < call.locations.get_length (); i++) {
                var l = call.locations.get_object_element (i);
                if (!l.has_member ("path")) continue;
                int line = l.has_member ("line") && l.get_member ("line").get_node_type () == Json.NodeType.VALUE ? (int) l.get_int_member ("line") - 1 : 0;
                touched (l.get_string_member ("path"), line);
            }
        }

        public bool inside_root (string path) {
            var f = File.new_for_path (path);
            var r = File.new_for_path (root);
            return f.equal (r) || f.has_prefix (r);
        }

        private void on_request (string method, Json.Object prm, AcpReply reply) {
            switch (method) {
                case "session/request_permission":
                    handle_permission (prm, reply);
                    break;
                case "fs/read_text_file":
                    handle_read (prm, reply);
                    break;
                case "fs/write_text_file":
                    handle_write (prm, reply);
                    break;
                case "terminal/create":
                    handle_terminal_create (prm, reply);
                    break;
                case "terminal/output":
                    handle_terminal_output (prm, reply);
                    break;
                case "terminal/wait_for_exit":
                    handle_terminal_wait (prm, reply);
                    break;
                case "terminal/kill":
                case "terminal/release":
                    var t = terminals.lookup (prm.get_string_member ("terminalId"));
                    if (t != null && !t.done) t.proc.force_exit ();
                    if (method == "terminal/release") terminals.remove (prm.get_string_member ("terminalId"));
                    reply.result_object (new Json.Object ());
                    break;
            }
        }

        private void handle_permission (Json.Object prm, AcpReply reply) {
            var req = new PermissionRequest ();
            var tc = prm.get_object_member ("toolCall");
            string id = tc.get_string_member ("toolCallId");
            req.call = calls.lookup (id);
            if (req.call == null) {
                req.call = new ToolCall ();
                req.call.id = id;
                calls.insert (id, req.call);
            }
            req.call.update (tc);
            req.options = prm.get_array_member ("options");
            req.reply = reply;
            string kind = req.call.kind;
            bool writes = kind == "edit" || kind == "delete" || kind == "move";
            bool executes = kind == "execute";
            bool outside = false;
            for (uint i = 0; i < req.call.locations.get_length (); i++) {
                var l = req.call.locations.get_object_element (i);
                if (l.has_member ("path") && !inside_root (l.get_string_member ("path"))) outside = true;
            }
            string? auto = null;
            switch (mode) {
                case Mode.PLAN:
                    if (writes || executes) auto = req.option_of_kind ({ "reject_once", "reject_always" });
                    else auto = req.option_of_kind ({ "allow_once", "allow_always" });
                    break;
                case Mode.AUTO_EDIT:
                    if (!executes && !outside) auto = req.option_of_kind ({ "allow_once", "allow_always" });
                    break;
                case Mode.AUTOPILOT:
                    auto = outside ? req.option_of_kind ({ "reject_once", "reject_always" }) : req.option_of_kind ({ "allow_once", "allow_always" });
                    break;
                default:
                    break;
            }
            if (auto != null) {
                req.choose (auto);
                return;
            }
            reply.set_data<bool> ("deferred", true);
            permission_asked (req);
        }

        private Document? open_document (string path) {
            var f = File.new_for_path (path);
            foreach (var d in workspace.documents ()) {
                if (d.get_file () != null && d.get_file ().equal (f)) return d;
            }
            return null;
        }

        private static string text_of (Document d) {
            Gtk.TextIter s, e;
            d.get_buffer ().get_bounds (out s, out e);
            return d.get_buffer ().get_text (s, e, false);
        }

        private void handle_read (Json.Object prm, AcpReply reply) {
            string path = prm.get_string_member ("path");
            if (mode == Mode.AUTOPILOT && !inside_root (path)) {
                reply.error (-32602, _("Autopilot can only read inside the project"));
                return;
            }
            string content;
            var doc = open_document (path);
            if (doc != null) {
                content = text_of (doc);
            } else {
                try {
                    FileUtils.get_contents (path, out content);
                } catch (Error e) {
                    reply.error (-32602, e.message);
                    return;
                }
            }
            if (prm.has_member ("line") && prm.get_member ("line").get_node_type () == Json.NodeType.VALUE) {
                int start = int.max (1, (int) prm.get_int_member ("line")) - 1;
                int limit = prm.has_member ("limit") && prm.get_member ("limit").get_node_type () == Json.NodeType.VALUE ? (int) prm.get_int_member ("limit") : int.MAX;
                var lines = content.split ("\n");
                var sb = new StringBuilder ();
                for (int i = start; i < lines.length && i - start < limit; i++) {
                    sb.append (lines[i]);
                    if (i + 1 < lines.length) sb.append_c ('\n');
                }
                content = sb.str;
            }
            var res = new Json.Object ();
            res.set_string_member ("content", content);
            reply.result_object (res);
        }

        private void handle_write (Json.Object prm, AcpReply reply) {
            string path = prm.get_string_member ("path");
            string content = prm.get_string_member ("content");
            if (mode == Mode.PLAN) {
                reply.error (-32602, _("Plan mode does not change files"));
                return;
            }
            if (mode == Mode.AUTOPILOT && !inside_root (path)) {
                reply.error (-32602, _("Autopilot can only write inside the project"));
                return;
            }
            var doc = open_document (path);
            string? before = null;
            if (doc != null) before = text_of (doc);
            else if (FileUtils.test (path, FileTest.EXISTS)) {
                try {
                    FileUtils.get_contents (path, out before);
                } catch (Error e) {
                }
            }
            try {
                DirUtils.create_with_parents (Path.get_dirname (path), 0755);
                FileUtils.set_contents (path, content);
            } catch (Error e) {
                reply.error (-32603, e.message);
                return;
            }
            if (doc == null) doc = workspace.open_file (File.new_for_path (path));
            int first = first_difference (before ?? "", content);
            if (doc != null) {
                var buffer = doc.get_buffer ();
                if (text_of (doc) != content) {
                    Gtk.TextIter s, e;
                    buffer.get_bounds (out s, out e);
                    buffer.begin_user_action ();
                    buffer.delete (ref s, ref e);
                    buffer.insert (ref s, content, -1);
                    buffer.end_user_action ();
                }
                buffer.set_modified (false);
            }
            record_change (path, before, content);
            touched (path, first);
            reply.result_object (new Json.Object ());
        }

        private static int first_difference (string a, string b) {
            var la = a.split ("\n");
            var lb = b.split ("\n");
            int i = 0;
            while (i < la.length && i < lb.length && la[i] == lb[i]) i++;
            return i;
        }

        private void record_change (string path, string? before, string after) {
            var c = changes.lookup (path);
            if (c == null) {
                c = new ChangedFile ();
                c.path = path;
                c.original = before;
                changes.insert (path, c);
            }
            c.added = 0;
            c.removed = 0;
            foreach (var ch in Singularity.Git.LineDiff.compare (c.original ?? "", after)) {
                c.added += ch.count;
                c.removed += ch.old_lines.length;
            }
            if (c.original != null && c.original == after) changes.remove (path);
            changes_changed ();
        }

        public void accept (string path) {
            changes.remove (path);
            changes_changed ();
        }

        public void revert (string path) {
            var c = changes.lookup (path);
            if (c == null) return;
            var doc = open_document (path);
            try {
                if (c.original == null) {
                    FileUtils.unlink (path);
                } else {
                    FileUtils.set_contents (path, c.original);
                    if (doc != null) {
                        var buffer = doc.get_buffer ();
                        Gtk.TextIter s, e;
                        buffer.get_bounds (out s, out e);
                        buffer.begin_user_action ();
                        buffer.delete (ref s, ref e);
                        buffer.insert (ref s, c.original, -1);
                        buffer.end_user_action ();
                        buffer.set_modified (false);
                    }
                }
            } catch (Error e) {
                workspace.notify_user (e.message);
            }
            changes.remove (path);
            changes_changed ();
        }

        public void accept_all () {
            changes.remove_all ();
            changes_changed ();
        }

        public void revert_all () {
            foreach (var p in changes.get_keys ()) revert (p);
        }

        public async void restore_project () {
            if (restore == null) return;
            try {
                yield restore.apply ();
                foreach (var d in workspace.documents ()) {
                    var f = d.get_file ();
                    if (f == null || f.get_path () == null || !inside_root (f.get_path ())) continue;
                    string text;
                    if (FileUtils.get_contents (f.get_path (), out text) && text != text_of (d)) {
                        var buffer = d.get_buffer ();
                        Gtk.TextIter s, e;
                        buffer.get_bounds (out s, out e);
                        buffer.delete (ref s, ref e);
                        buffer.insert (ref s, text, -1);
                        buffer.set_modified (false);
                    }
                }
                changes.remove_all ();
                changes_changed ();
                workspace.notify_user (_("Project restored to the point before Autopilot"));
            } catch (Error e) {
                workspace.notify_user (e.message);
            }
        }

        private void handle_terminal_create (Json.Object prm, AcpReply reply) {
            if (mode == Mode.PLAN) {
                reply.error (-32602, _("Plan mode does not run commands"));
                return;
            }
            string[] argv = { prm.get_string_member ("command") };
            if (prm.has_member ("args")) {
                var args = prm.get_array_member ("args");
                for (uint i = 0; i < args.get_length (); i++) argv += args.get_string_element (i);
            }
            if (argv.length == 1 && " " in argv[0]) argv = { "sh", "-c", argv[0] };
            string cwd = prm.has_member ("cwd") && prm.get_member ("cwd").get_node_type () == Json.NodeType.VALUE ? prm.get_string_member ("cwd") : root;
            if (mode == Mode.AUTOPILOT && !inside_root (cwd)) cwd = root;
            string[] env = Environ.get ();
            if (prm.has_member ("env")) {
                var e = prm.get_array_member ("env");
                for (uint i = 0; i < e.get_length (); i++) {
                    var v = e.get_object_element (i);
                    env = Environ.set_variable (env, v.get_string_member ("name"), v.get_string_member ("value"), true);
                }
            }
            if (mode == Mode.AUTOPILOT) {
                if (proxy != null) env = proxy.apply (env);
                argv = Sandbox.wrap (argv, root);
            }
            if (dsh != null) {
                string[] extra = {};
                if (prm.has_member ("env")) {
                    var e = prm.get_array_member ("env");
                    for (uint i = 0; i < e.get_length (); i++) {
                        var v = e.get_object_element (i);
                        extra += v.get_string_member ("name") + "=" + v.get_string_member ("value");
                    }
                }
                argv = dsh.wrap (argv, cwd, extra);
                cwd = Environment.get_home_dir ();
                env = Environ.get ();
            }
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
                launcher.set_cwd (cwd);
                launcher.set_environ (env);
                var t = new AgentTerminal ();
                t.proc = launcher.spawnv (argv);
                if (prm.has_member ("outputByteLimit") && prm.get_member ("outputByteLimit").get_node_type () == Json.NodeType.VALUE)
                    t.limit = prm.get_int_member ("outputByteLimit");
                string id = "term-%d".printf (next_terminal++);
                terminals.insert (id, t);
                pump.begin (t);
                var res = new Json.Object ();
                res.set_string_member ("terminalId", id);
                reply.result_object (res);
            } catch (Error e) {
                reply.error (-32603, e.message);
            }
        }

        private async void pump (AgentTerminal t) {
            var stream = t.proc.get_stdout_pipe ();
            var buf = new uint8[8192];
            try {
                while (true) {
                    var n = yield stream.read_async (buf, Priority.DEFAULT, null);
                    if (n <= 0) break;
                    t.output.append_len ((string) buf, n);
                    if (t.output.len > t.limit) {
                        t.output.erase (0, (ssize_t) (t.output.len - t.limit));
                        t.truncated = true;
                    }
                }
                yield t.proc.wait_async (null);
            } catch (Error e) {
            }
            t.done = true;
            if (t.proc.get_if_exited ()) t.exit_code = t.proc.get_exit_status ();
            else if (t.proc.get_if_signaled ()) t.signal_no = t.proc.get_term_sig ();
            foreach (var w in t.waiters.data) w.result_object (exit_object (t));
            t.waiters = new GenericArray<AcpReply> ();
        }

        private static Json.Object exit_object (AgentTerminal t) {
            var o = new Json.Object ();
            if (t.exit_code >= 0) o.set_int_member ("exitCode", t.exit_code);
            else o.set_null_member ("exitCode");
            if (t.signal_no > 0) o.set_string_member ("signal", "SIG%d".printf (t.signal_no));
            else o.set_null_member ("signal");
            return o;
        }

        private void handle_terminal_output (Json.Object prm, AcpReply reply) {
            var t = terminals.lookup (prm.get_string_member ("terminalId"));
            if (t == null) {
                reply.error (-32602, "unknown terminal");
                return;
            }
            var res = new Json.Object ();
            res.set_string_member ("output", t.output.str.make_valid ());
            res.set_boolean_member ("truncated", t.truncated);
            if (t.done) res.set_object_member ("exitStatus", exit_object (t));
            reply.result_object (res);
        }

        private void handle_terminal_wait (Json.Object prm, AcpReply reply) {
            var t = terminals.lookup (prm.get_string_member ("terminalId"));
            if (t == null) {
                reply.error (-32602, "unknown terminal");
                return;
            }
            if (t.done) {
                reply.result_object (exit_object (t));
                return;
            }
            reply.set_data<bool> ("deferred", true);
            t.waiters.add (reply);
        }

        public string terminal_output (string id) {
            var t = terminals.lookup (id);
            return t != null ? t.output.str.make_valid () : "";
        }
    }
}
