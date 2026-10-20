using GLib;

namespace Singularity.Apps {

    public class DebugFrame {
        public int id;
        public string name;
        public string? path;
        public int line;
        public int column;
    }

    public class DebugTarget {
        public string adapter_id;
        public string label;
        public string[] argv;
        public bool tcp;
        public uint16 port;
        public string cwd;
        public string[]? build;
        public Json.Object launch;
    }

    public class DebugManager : Object {
        private static DebugManager? _instance;
        public static DebugManager get_default () {
            if (_instance == null) _instance = new DebugManager ();
            return _instance;
        }

        public const string BREAKPOINT = "edit-breakpoint";
        public const string CURRENT = "edit-debug-current";

        public signal void breakpoints_changed (string path);
        public signal void session_changed ();

        public DebugSession? session { get; private set; }
        private HashTable<string, GenericArray<int>> lines = new HashTable<string, GenericArray<int>> (str_hash, str_equal);

        public void install (EditorTab tab) {
            var a = new GtkSource.MarkAttributes ();
            a.icon_name = BREAKPOINT;
            tab.view.set_mark_attributes (BREAKPOINT, a, 60);
            var c = new GtkSource.MarkAttributes ();
            c.icon_name = CURRENT;
            tab.view.set_mark_attributes (CURRENT, c, 70);
            tab.view.show_line_marks = true;
            if (tab.file == null || tab.file.get_path () == null) return;
            var list = lines.lookup (tab.file.get_path ());
            if (list == null) return;
            foreach (var l in list.data) {
                if (l >= tab.buffer.get_line_count ()) continue;
                Gtk.TextIter it;
                tab.buffer.get_iter_at_line (out it, l);
                tab.buffer.create_source_mark (null, BREAKPOINT, it);
            }
        }

        public void toggle (EditorTab tab, int line) {
            if (tab.file == null || tab.file.get_path () == null) return;
            Gtk.TextIter it;
            tab.buffer.get_iter_at_line (out it, line);
            var marks = tab.buffer.get_source_marks_at_line (line, BREAKPOINT);
            if (marks != null && marks.length () > 0) {
                Gtk.TextIter s = it, e = it;
                if (!e.ends_line ()) e.forward_to_line_end ();
                tab.buffer.remove_source_marks (s, e, BREAKPOINT);
            } else {
                tab.buffer.create_source_mark (null, BREAKPOINT, it);
            }
            capture (tab);
            breakpoints_changed (tab.file.get_path ());
            if (session != null) session.send_breakpoints (tab.file.get_path ());
        }

        public void capture (EditorTab tab) {
            if (tab.file == null || tab.file.get_path () == null) return;
            var list = new GenericArray<int> ();
            Gtk.TextIter it;
            tab.buffer.get_start_iter (out it);
            while (tab.buffer.forward_iter_to_source_mark (ref it, BREAKPOINT)) {
                int l = it.get_line ();
                bool seen = false;
                foreach (var x in list.data) if (x == l) seen = true;
                if (!seen) list.add (l);
            }
            if (list.length == 0) lines.remove (tab.file.get_path ());
            else lines.insert (tab.file.get_path (), list);
        }

        public string[] files () {
            return lines.get_keys_as_array ();
        }

        public int[] lines_for (string path) {
            var list = lines.lookup (path);
            return list != null ? list.data : new int[0];
        }

        public void begin_session (DebugSession s) {
            session = s;
            s.finished.connect (() => {
                if (session == s) {
                    session = null;
                    session_changed ();
                }
            });
            session_changed ();
        }
    }

    public class DebugSession : Object {
        public enum State {
            STARTING,
            RUNNING,
            STOPPED,
            ENDED
        }

        public State state { get; private set; default = State.STARTING; }
        public string status { get; private set; default = ""; }
        public DebugTarget target { get; private set; }
        public int thread_id { get; private set; default = 0; }
        public DebugFrame[] frames { get; private set; }
        public int current_frame { get; private set; default = -1; }

        public signal void output (string text, string category);
        public signal void stopped_at (DebugFrame? frame);
        public signal void variables_invalidated ();
        public signal void finished ();

        private DapClient client = new DapClient ();
        private bool initialized_seen = false;
        private SourceFunc? initialized_cb = null;

        public DebugSession (DebugTarget target) {
            this.target = target;
            client.log_line.connect ((line) => output (line + "\n", "adapter"));
            client.event_received.connect (on_event);
            client.exited.connect (() => end (_("Debugger exited")));
        }

        public async bool start () {
            status = _("Starting %s").printf (target.label);
            if (target.build != null) {
                status = _("Building");
                output ("$ " + string.joinv (" ", target.build) + "\n", "console");
                if (!yield run_build ()) {
                    end (_("Build failed"));
                    return false;
                }
            }
            try {
                if (target.tcp) yield client.start_tcp (target.argv, target.cwd, target.port);
                else client.start_stdio (target.argv, target.cwd);
                yield client.initialize (target.adapter_id);
                client.request.begin ("launch", target.launch, (obj, res) => {
                    try {
                        client.request.end (res);
                    } catch (Error e) {
                        output (e.message + "\n", "stderr");
                        end (e.message);
                    }
                });
                if (!initialized_seen) {
                    initialized_cb = start.callback;
                    Timeout.add_seconds (15, () => {
                        if (initialized_cb != null) {
                            var cb = (owned) initialized_cb;
                            initialized_cb = null;
                            cb ();
                        }
                        return Source.REMOVE;
                    });
                    yield;
                }
                if (state == State.ENDED) return false;
                foreach (var path in DebugManager.get_default ().files ())
                    yield set_breakpoints (path);
                var exc = new Json.Object ();
                exc.set_array_member ("filters", new Json.Array ());
                try {
                    yield client.request ("setExceptionBreakpoints", exc);
                } catch (Error e) {
                }
                if (client.supports ("supportsConfigurationDoneRequest"))
                    yield client.request ("configurationDone", null);
                if (state == State.STARTING) {
                    state = State.RUNNING;
                    status = _("Running");
                }
                return true;
            } catch (Error e) {
                output (e.message + "\n", "stderr");
                end (e.message);
                return false;
            }
        }

        private async bool run_build () {
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
                launcher.set_cwd (target.cwd);
                var proc = launcher.spawnv (target.build);
                var stream = new DataInputStream (proc.get_stdout_pipe ());
                while (true) {
                    size_t len;
                    var line = yield stream.read_line_async (Priority.DEFAULT, null, out len);
                    if (line == null) break;
                    output (line + "\n", "console");
                }
                yield proc.wait_async (null);
                return proc.get_successful ();
            } catch (Error e) {
                output (e.message + "\n", "stderr");
                return false;
            }
        }

        public void send_breakpoints (string path) {
            set_breakpoints.begin (path);
        }

        private async void set_breakpoints (string path) {
            if (!client.alive) return;
            var source = new Json.Object ();
            source.set_string_member ("path", path);
            source.set_string_member ("name", Path.get_basename (path));
            var bps = new Json.Array ();
            foreach (var l in DebugManager.get_default ().lines_for (path)) {
                var bp = new Json.Object ();
                bp.set_int_member ("line", l + 1);
                bps.add_object_element (bp);
            }
            var args = new Json.Object ();
            args.set_object_member ("source", source);
            args.set_array_member ("breakpoints", bps);
            try {
                yield client.request ("setBreakpoints", args);
            } catch (Error e) {
                output (e.message + "\n", "stderr");
            }
        }

        private void on_event (string name, Json.Object body) {
            switch (name) {
                case "initialized":
                    initialized_seen = true;
                    if (initialized_cb != null) {
                        var cb = (owned) initialized_cb;
                        initialized_cb = null;
                        Idle.add ((owned) cb);
                    }
                    break;
                case "output":
                    if (body.has_member ("output")) {
                        var cat = body.has_member ("category") ? body.get_string_member ("category") : "console";
                        if (cat != "telemetry") output (body.get_string_member ("output"), cat);
                    }
                    break;
                case "stopped":
                    thread_id = body.has_member ("threadId") ? (int) body.get_int_member ("threadId") : thread_id;
                    string reason = body.has_member ("reason") ? body.get_string_member ("reason") : "pause";
                    string text;
                    if (reason == "breakpoint") text = _("Paused on breakpoint");
                    else if (reason == "step") text = _("Paused");
                    else text = _("Paused (%s)").printf (reason);
                    state = State.STOPPED;
                    status = text;
                    load_stack.begin ();
                    break;
                case "continued":
                    state = State.RUNNING;
                    status = _("Running");
                    stopped_at (null);
                    break;
                case "terminated":
                case "exited":
                    if (name == "exited" && body.has_member ("exitCode"))
                        output (_("Program exited with code %d\n").printf ((int) body.get_int_member ("exitCode")), "console");
                    if (name == "terminated") end (_("Finished"));
                    break;
            }
        }

        private async void load_stack () {
            if (thread_id == 0) {
                try {
                    var t = yield client.request ("threads", null);
                    var arr = t.get_array_member ("threads");
                    if (arr.get_length () > 0) thread_id = (int) arr.get_object_element (0).get_int_member ("id");
                } catch (Error e) {
                }
            }
            var args = new Json.Object ();
            args.set_int_member ("threadId", thread_id);
            args.set_int_member ("startFrame", 0);
            args.set_int_member ("levels", 30);
            DebugFrame[] list = {};
            try {
                var res = yield client.request ("stackTrace", args);
                var arr = res.get_array_member ("stackFrames");
                for (uint i = 0; i < arr.get_length (); i++) {
                    var o = arr.get_object_element (i);
                    var f = new DebugFrame ();
                    f.id = (int) o.get_int_member ("id");
                    f.name = o.get_string_member ("name");
                    f.line = o.has_member ("line") ? (int) o.get_int_member ("line") : 0;
                    f.column = o.has_member ("column") ? (int) o.get_int_member ("column") : 0;
                    if (o.has_member ("source")) {
                        var src = o.get_object_member ("source");
                        if (src != null && src.has_member ("path")) f.path = src.get_string_member ("path");
                    }
                    list += f;
                }
            } catch (Error e) {
                output (e.message + "\n", "stderr");
            }
            frames = list;
            int first = 0;
            for (int i = 0; i < list.length; i++) {
                if (list[i].path != null && FileUtils.test (list[i].path, FileTest.EXISTS)) {
                    first = i;
                    break;
                }
            }
            select_frame (list.length > 0 ? first : -1);
        }

        public void select_frame (int index) {
            current_frame = index;
            stopped_at (index >= 0 && index < frames.length ? frames[index] : null);
            variables_invalidated ();
        }

        public int frame_id () {
            return current_frame >= 0 && current_frame < frames.length ? frames[current_frame].id : -1;
        }

        public async Json.Array? scopes () {
            int id = frame_id ();
            if (id < 0) return null;
            var args = new Json.Object ();
            args.set_int_member ("frameId", id);
            try {
                var res = yield client.request ("scopes", args);
                return res.get_array_member ("scopes");
            } catch (Error e) {
                return null;
            }
        }

        public async Json.Array? variables (int64 reference) {
            var args = new Json.Object ();
            args.set_int_member ("variablesReference", reference);
            try {
                var res = yield client.request ("variables", args);
                return res.get_array_member ("variables");
            } catch (Error e) {
                return null;
            }
        }

        public async Json.Object? evaluate (string expression, string context) {
            var args = new Json.Object ();
            args.set_string_member ("expression", expression);
            args.set_string_member ("context", context);
            int id = frame_id ();
            if (id >= 0) args.set_int_member ("frameId", id);
            try {
                return yield client.request ("evaluate", args);
            } catch (Error e) {
                var err = new Json.Object ();
                err.set_string_member ("result", e.message);
                err.set_boolean_member ("failed", true);
                return err;
            }
        }

        private Json.Object thread_args () {
            var args = new Json.Object ();
            args.set_int_member ("threadId", thread_id);
            return args;
        }

        public void resume () {
            if (state != State.STOPPED) return;
            client.fire ("continue", thread_args ());
            state = State.RUNNING;
            status = _("Running");
            stopped_at (null);
        }

        public void pause () {
            if (state != State.RUNNING) return;
            client.fire ("pause", thread_args ());
        }

        public void step (string command) {
            if (state != State.STOPPED) return;
            client.fire (command, thread_args ());
            state = State.RUNNING;
            status = _("Running");
        }

        public void terminate () {
            if (state == State.ENDED) return;
            if (!client.alive) {
                end (_("Stopped"));
                return;
            }
            var args = new Json.Object ();
            args.set_boolean_member ("terminateDebuggee", true);
            client.request.begin ("disconnect", args, (obj, res) => {
                try {
                    client.request.end (res);
                } catch (Error e) {
                }
                client.stop ();
                end (_("Stopped"));
            });
            Timeout.add_seconds (3, () => {
                client.stop ();
                end (_("Stopped"));
                return Source.REMOVE;
            });
        }

        private void end (string reason) {
            if (state == State.ENDED) return;
            state = State.ENDED;
            status = reason;
            stopped_at (null);
            client.stop ();
            finished ();
        }
    }
}
