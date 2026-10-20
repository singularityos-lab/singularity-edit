using Gtk;
using GLib;

namespace Singularity.Apps {

    public class SearchHit {
        public string path;
        public int line;
        public string text;
    }

    public class ProjectSearchView : Box {
        public signal void open_location (string path, int line, int column);

        private unowned EditWindow win;
        private Entry query;
        private Entry replacement;
        private ToggleButton case_btn;
        private ToggleButton regex_btn;
        private Label summary;
        private Box results;
        private Button replace_btn;
        private GenericArray<SearchHit> hits = new GenericArray<SearchHit> ();
        private uint debounce;
        private uint generation;

        public ProjectSearchView (EditWindow win) {
            Object (orientation: Orientation.VERTICAL, spacing: 6);
            this.win = win;
            add_css_class ("edit-search-view");
            margin_start = 8;
            margin_end = 8;
            query = new Entry ();
            query.placeholder_text = _("Search in project");
            query.primary_icon_name = "system-search-symbolic";
            query.changed.connect (schedule);
            query.activate.connect (() => run_search.begin ());
            append (query);
            var row = new Box (Orientation.HORIZONTAL, 4);
            replacement = new Entry ();
            replacement.placeholder_text = _("Replace with");
            replacement.hexpand = true;
            row.append (replacement);
            replace_btn = new Button.from_icon_name ("edit-find-replace-symbolic");
            replace_btn.tooltip_text = _("Replace All");
            replace_btn.add_css_class ("flat");
            replace_btn.sensitive = false;
            replace_btn.clicked.connect (() => replace_all.begin ());
            row.append (replace_btn);
            append (row);
            var opts = new Box (Orientation.HORIZONTAL, 4);
            case_btn = new ToggleButton.with_label ("Aa");
            case_btn.tooltip_text = _("Match Case");
            case_btn.add_css_class ("flat");
            case_btn.toggled.connect (schedule);
            opts.append (case_btn);
            regex_btn = new ToggleButton.with_label (".*");
            regex_btn.tooltip_text = _("Regular Expression");
            regex_btn.add_css_class ("flat");
            regex_btn.toggled.connect (schedule);
            opts.append (regex_btn);
            summary = new Label (null);
            summary.xalign = 1;
            summary.hexpand = true;
            summary.add_css_class ("dim-label");
            summary.add_css_class ("caption");
            opts.append (summary);
            append (opts);
            results = new Box (Orientation.VERTICAL, 0);
            var sw = new ScrolledWindow ();
            sw.vexpand = true;
            sw.hscrollbar_policy = PolicyType.NEVER;
            sw.child = results;
            append (sw);
        }

        public void focus_query (string? seed) {
            if (seed != null && seed != "") query.text = seed;
            query.grab_focus ();
            query.select_region (0, -1);
        }

        private void schedule () {
            if (debounce != 0) Source.remove (debounce);
            debounce = Timeout.add (250, () => {
                debounce = 0;
                run_search.begin ();
                return Source.REMOVE;
            });
        }

        private string root () {
            var r = win.get_project_root ();
            return r != null && r.get_path () != null ? r.get_path () : Environment.get_home_dir ();
        }

        private async void run_search () {
            uint gen = ++generation;
            Widget? c;
            while ((c = results.get_first_child ()) != null) results.remove (c);
            hits = new GenericArray<SearchHit> ();
            string q = query.text;
            replace_btn.sensitive = false;
            if (q.strip () == "") {
                summary.label = "";
                return;
            }
            string dir = root ();
            bool repo = FileUtils.test (Path.build_filename (dir, ".git"), FileTest.EXISTS);
            string[] argv;
            if (repo) {
                argv = { "git", "grep", "-n", "-I", "--no-color", "--untracked", "--exclude-standard" };
            } else {
                argv = { "grep", "-rnI", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=target", "--exclude-dir=build", "--exclude-dir=__pycache__" };
            }
            if (!case_btn.active) argv += "-i";
            argv += regex_btn.active ? "-E" : "-F";
            argv += "-e";
            argv += q;
            if (!repo) argv += ".";
            string output = "";
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
                launcher.set_cwd (dir);
                var p = launcher.spawnv (argv);
                string? err;
                yield p.communicate_utf8_async (null, null, out output, out err);
            } catch (Error e) {
                summary.label = e.message;
                return;
            }
            if (gen != generation) return;
            string? current = null;
            int files = 0;
            Box? group = null;
            foreach (var l in output.split ("\n")) {
                if (l == "" || hits.length >= 2000) continue;
                int a = l.index_of_char (':');
                if (a <= 0) continue;
                int b = l.index_of_char (':', a + 1);
                if (b <= a) continue;
                var hit = new SearchHit ();
                hit.path = l.substring (0, a);
                if (hit.path.has_prefix ("./")) hit.path = hit.path.substring (2);
                hit.line = int.parse (l.substring (a + 1, b - a - 1)) - 1;
                hit.text = l.substring (b + 1);
                hits.add (hit);
                if (hit.path != current) {
                    current = hit.path;
                    files++;
                    var header = new Label (null);
                    header.xalign = 0;
                    header.ellipsize = Pango.EllipsizeMode.START;
                    header.margin_top = 8;
                    header.set_markup ("<b>%s</b>".printf (Markup.escape_text (hit.path)));
                    results.append (header);
                    group = new Box (Orientation.VERTICAL, 0);
                    results.append (group);
                }
                var btn = new Button ();
                btn.add_css_class ("flat");
                btn.add_css_class ("edit-search-hit");
                var lab = new Label (null);
                lab.xalign = 0;
                lab.ellipsize = Pango.EllipsizeMode.END;
                lab.add_css_class ("monospace");
                lab.set_markup ("<span alpha=\"55%%\">%d</span>  %s".printf (hit.line + 1, highlight (hit.text.strip (), q)));
                btn.child = lab;
                string full = Path.build_filename (dir, hit.path);
                int line = hit.line;
                btn.clicked.connect (() => open_location (full, line, 0));
                group.append (btn);
            }
            if (hits.length == 0) {
                summary.label = _("No results");
            } else {
                summary.label = "%s · %s".printf (
                    ngettext ("%d result", "%d results", hits.length).printf ((int) hits.length),
                    ngettext ("%d file", "%d files", files).printf (files));
            }
            replace_btn.sensitive = hits.length > 0;
        }

        private string highlight (string text, string q) {
            if (regex_btn.active) return Markup.escape_text (text);
            string hay = case_btn.active ? text : text.down ();
            string needle = case_btn.active ? q : q.down ();
            int at = hay.index_of (needle);
            if (at < 0 || needle == "") return Markup.escape_text (text);
            return Markup.escape_text (text.substring (0, at)) + "<span background=\"#d4a72c55\"><b>" +
                Markup.escape_text (text.substring (at, q.length)) + "</b></span>" + Markup.escape_text (text.substring (at + q.length));
        }

        private Regex? matcher () {
            try {
                string pattern = regex_btn.active ? query.text : Regex.escape_string (query.text);
                return new Regex (pattern, case_btn.active ? 0 : RegexCompileFlags.CASELESS);
            } catch (RegexError e) {
                win.notify_user (e.message);
                return null;
            }
        }

        private async void replace_all () {
            var re = matcher ();
            if (re == null) return;
            string with = replacement.text;
            string dir = root ();
            var paths = new GenericSet<string> (str_hash, str_equal);
            foreach (var h in hits.data) paths.add (Path.build_filename (dir, h.path));
            int changed = 0;
            foreach (var path in paths.get_values ()) {
                var file = File.new_for_path (path);
                EditorTab? tab = null;
                foreach (var d in win.documents ()) {
                    var t = d as EditorTab;
                    if (t != null && t.file != null && t.file.equal (file)) tab = t;
                }
                try {
                    if (tab != null) {
                        Gtk.TextIter s, e;
                        tab.buffer.get_bounds (out s, out e);
                        var before = tab.buffer.get_text (s, e, false);
                        var after = re.replace_literal (before, -1, 0, with);
                        if (after == before) continue;
                        tab.buffer.begin_user_action ();
                        tab.buffer.delete (ref s, ref e);
                        tab.buffer.insert (ref s, after, -1);
                        tab.buffer.end_user_action ();
                        tab.save ();
                    } else {
                        string before;
                        FileUtils.get_contents (path, out before);
                        var after = re.replace_literal (before, -1, 0, with);
                        if (after == before) continue;
                        FileUtils.set_contents (path, after);
                    }
                    changed++;
                } catch (Error e) {
                    win.notify_user (e.message);
                }
            }
            win.notify_user (ngettext ("Replaced in %d file", "Replaced in %d files", changed).printf (changed));
            yield run_search ();
        }
    }
}
