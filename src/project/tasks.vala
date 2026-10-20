using Gtk;
using GLib;

namespace Singularity.Apps {

    public class TaskDef : Object {
        public string label;
        public string[] argv;
        public string cwd;
        public bool build;

        public TaskDef (string label, string[] argv, string cwd, bool build = false) {
            this.label = label;
            this.argv = argv;
            this.cwd = cwd;
            this.build = build;
        }
    }

    public class TaskDetector : Object {

        private static bool has (string dir, string name) {
            return FileUtils.test (Path.build_filename (dir, name), FileTest.EXISTS);
        }

        private static bool tool (string name) {
            return Environment.find_program_in_path (name) != null;
        }

        public static TaskDef[] detect (string root) {
            TaskDef[] list = {};
            foreach (var t in from_vscode (root)) list += t;
            if (has (root, "Cargo.toml") && tool ("cargo")) {
                list += new TaskDef ("cargo build", { "cargo", "build" }, root, true);
                list += new TaskDef ("cargo test", { "cargo", "test" }, root);
                list += new TaskDef ("cargo run", { "cargo", "run" }, root);
                list += new TaskDef ("cargo clippy", { "cargo", "clippy" }, root);
            }
            if (has (root, "meson.build") && tool ("meson")) {
                if (has (root, "build")) {
                    list += new TaskDef ("meson compile", { "meson", "compile", "-C", "build" }, root, true);
                    list += new TaskDef ("meson test", { "meson", "test", "-C", "build" }, root);
                } else {
                    list += new TaskDef ("meson setup", { "meson", "setup", "build" }, root, true);
                }
            }
            if ((has (root, "Makefile") || has (root, "makefile")) && tool ("make")) {
                list += new TaskDef ("make", { "make" }, root, true);
                list += new TaskDef ("make test", { "make", "test" }, root);
                list += new TaskDef ("make clean", { "make", "clean" }, root);
            }
            if (has (root, "go.mod") && tool ("go")) {
                list += new TaskDef ("go build", { "go", "build", "./..." }, root, true);
                list += new TaskDef ("go test", { "go", "test", "./..." }, root);
                list += new TaskDef ("go run", { "go", "run", "." }, root);
            }
            if (has (root, "package.json")) {
                string runner = tool ("npm") ? "npm" : (tool ("pnpm") ? "pnpm" : "");
                if (runner != "") {
                    try {
                        var parser = new Json.Parser ();
                        parser.load_from_file (Path.build_filename (root, "package.json"));
                        var obj = parser.get_root ().get_object ();
                        if (obj.has_member ("scripts")) {
                            foreach (var name in obj.get_object_member ("scripts").get_members ())
                                list += new TaskDef ("%s run %s".printf (runner, name), { runner, "run", name }, root, name == "build");
                        }
                    } catch (Error e) {
                    }
                }
            }
            if ((has (root, "pyproject.toml") || has (root, "setup.py") || has (root, "tests") || has (root, "pytest.ini")) && tool ("python3"))
                list += new TaskDef ("pytest", { "python3", "-m", "pytest" }, root);
            return list;
        }

        private static TaskDef[] from_vscode (string root) {
            TaskDef[] list = {};
            var path = Path.build_filename (root, ".vscode", "tasks.json");
            if (!FileUtils.test (path, FileTest.EXISTS)) return list;
            try {
                string text;
                FileUtils.get_contents (path, out text);
                var clean = new StringBuilder ();
                foreach (var line in text.split ("\n")) {
                    if (line.strip ().has_prefix ("//")) continue;
                    clean.append (line);
                    clean.append_c ('\n');
                }
                var parser = new Json.Parser ();
                parser.load_from_data (clean.str);
                var tasks = parser.get_root ().get_object ().get_array_member ("tasks");
                for (uint i = 0; i < tasks.get_length (); i++) {
                    var t = tasks.get_object_element (i);
                    if (!t.has_member ("command")) continue;
                    string label = t.has_member ("label") ? t.get_string_member ("label") : t.get_string_member ("command");
                    var cmd = new StringBuilder (t.get_string_member ("command"));
                    if (t.has_member ("args")) {
                        var args = t.get_array_member ("args");
                        for (uint j = 0; j < args.get_length (); j++) {
                            cmd.append_c (' ');
                            cmd.append (GLib.Shell.quote (args.get_string_element (j)));
                        }
                    }
                    string command = cmd.str.replace ("${workspaceFolder}", root);
                    bool build = false;
                    if (t.has_member ("group")) {
                        var g = t.get_member ("group");
                        if (g.get_node_type () == Json.NodeType.VALUE) build = g.get_string () == "build";
                        else if (g.get_node_type () == Json.NodeType.OBJECT) build = g.get_object ().get_string_member ("kind") == "build";
                    }
                    list += new TaskDef (label, { "sh", "-c", command }, root, build);
                }
            } catch (Error e) {
            }
            return list;
        }
    }

    public class TasksView : Box {
        public signal void open_location (string path, int line, int column);

        private TextView text;
        private Label title;
        private Button stop_btn;
        private Subprocess? proc;
        private string cwd = "";
        private Regex location;

        public TasksView () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("edit-tasks-view");
            try {
                location = new Regex ("([A-Za-z0-9_./\\-]+\\.[A-Za-z0-9]+):(\\d+)(?::(\\d+))?");
            } catch (RegexError e) {
            }
            var bar = new Box (Orientation.HORIZONTAL, 6);
            bar.margin_start = 12;
            bar.margin_end = 8;
            bar.margin_top = 4;
            title = new Label (_("No task is running"));
            title.xalign = 0;
            title.hexpand = true;
            title.add_css_class ("dim-label");
            bar.append (title);
            stop_btn = new Button.from_icon_name ("media-playback-stop-symbolic");
            stop_btn.add_css_class ("flat");
            stop_btn.tooltip_text = _("Stop Task");
            stop_btn.sensitive = false;
            stop_btn.clicked.connect (() => {
                if (proc != null) proc.force_exit ();
            });
            bar.append (stop_btn);
            append (bar);
            text = new TextView ();
            text.editable = false;
            text.cursor_visible = false;
            text.monospace = true;
            text.wrap_mode = WrapMode.WORD_CHAR;
            text.left_margin = 12;
            text.right_margin = 12;
            text.add_css_class ("singularity-sourceview");
            var link = text.buffer.create_tag ("link");
            link.underline = Pango.Underline.SINGLE;
            var err = text.buffer.create_tag ("error");
            var red = Gdk.RGBA ();
            red.parse ("#e5534b");
            err.foreground_rgba = red;
            var ok = text.buffer.create_tag ("ok");
            var green = Gdk.RGBA ();
            green.parse ("#2ea043");
            ok.foreground_rgba = green;
            var click = new GestureClick ();
            click.released.connect ((n, x, y) => on_click (x, y));
            text.add_controller (click);
            var sw = new ScrolledWindow ();
            sw.vexpand = true;
            sw.child = text;
            append (sw);
        }

        public bool running { get { return proc != null; } }

        public void run (TaskDef task) {
            if (proc != null) proc.force_exit ();
            cwd = task.cwd;
            text.buffer.text = "";
            append_line ("$ " + string.joinv (" ", task.argv), null);
            title.label = task.label;
            title.remove_css_class ("dim-label");
            stop_btn.sensitive = true;
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_MERGE);
                launcher.set_cwd (task.cwd);
                launcher.setenv ("TERM", "dumb", true);
                launcher.setenv ("CARGO_TERM_COLOR", "never", true);
                var p = launcher.spawnv (task.argv);
                proc = p;
                read.begin (p, task);
            } catch (Error e) {
                append_line (e.message, "error");
                finish (false, task);
            }
        }

        private async void read (Subprocess p, TaskDef task) {
            var stream = new DataInputStream (p.get_stdout_pipe ());
            try {
                while (true) {
                    size_t len;
                    var line = yield stream.read_line_async (Priority.DEFAULT, null, out len);
                    if (line == null) break;
                    bool bad = line.has_prefix ("error") || " error" in line.down () || "FAILED" in line;
                    append_line (line, bad ? "error" : null);
                }
                yield p.wait_async (null);
            } catch (Error e) {
            }
            if (proc == p) {
                proc = null;
                finish (p.get_if_exited () && p.get_exit_status () == 0, task);
            }
        }

        private void finish (bool ok, TaskDef task) {
            stop_btn.sensitive = false;
            title.label = ok ? _("%s finished").printf (task.label) : _("%s failed").printf (task.label);
            append_line (ok ? _("Task finished") : _("Task failed"), ok ? "ok" : "error");
        }

        private void append_line (string line, string? tag) {
            Gtk.TextIter end;
            text.buffer.get_end_iter (out end);
            int start_offset = end.get_offset ();
            if (tag != null) text.buffer.insert_with_tags_by_name (ref end, line + "\n", -1, tag);
            else text.buffer.insert (ref end, line + "\n", -1);
            MatchInfo? info = null;
            if (location != null && location.match (line, 0, out info) && info != null) {
                do {
                    int s, e;
                    info.fetch_pos (0, out s, out e);
                    Gtk.TextIter a, b;
                    text.buffer.get_iter_at_offset (out a, start_offset + line.substring (0, s).char_count ());
                    text.buffer.get_iter_at_offset (out b, start_offset + line.substring (0, e).char_count ());
                    text.buffer.apply_tag_by_name ("link", a, b);
                } while (info.next ());
            }
            text.buffer.get_end_iter (out end);
            var mark = text.buffer.create_mark (null, end, false);
            text.scroll_to_mark (mark, 0, false, 0, 1);
            text.buffer.delete_mark (mark);
        }

        private void on_click (double x, double y) {
            int bx, by;
            text.window_to_buffer_coords (TextWindowType.WIDGET, (int) x, (int) y, out bx, out by);
            Gtk.TextIter it;
            if (!text.get_iter_at_location (out it, bx, by)) return;
            Gtk.TextIter ls = it, le = it;
            ls.set_line_offset (0);
            if (!le.ends_line ()) le.forward_to_line_end ();
            string line = text.buffer.get_text (ls, le, false);
            if (location == null) return;
            MatchInfo info;
            if (!location.match (line, 0, out info)) return;
            do {
                int s, e;
                info.fetch_pos (0, out s, out e);
                int cs = line.substring (0, s).char_count ();
                int ce = line.substring (0, e).char_count ();
                if (it.get_line_offset () < cs || it.get_line_offset () > ce) continue;
                string path = info.fetch (1);
                if (!Path.is_absolute (path)) path = Path.build_filename (cwd, path);
                if (!FileUtils.test (path, FileTest.EXISTS)) return;
                string col = info.fetch (3);
                open_location (path, int.parse (info.fetch (2)) - 1, col != null && col != "" ? int.parse (col) - 1 : 0);
                return;
            } while (info.next ());
        }
    }
}
