using Gtk;
using GLib;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    public class FileBrowserPane : Box {
        private Label    dir_lbl;
        private ListBox  list_box;
        public GLib.File current_dir;
        private EditWindow owner;
        private Box project_header;
        private Label project_lbl;
        private Label project_path_lbl;
        private Box dsh_hint;
        private GenericSet<string> expanded = new GenericSet<string> (str_hash, str_equal);
        private GenericArray<FileMonitor> monitors = new GenericArray<FileMonitor> ();
        private uint refresh_source;
        private GLib.File? selected_file;

        public GLib.File? project_root { get; private set; }

        public signal void project_close_requested ();

        public FileBrowserPane (EditWindow win) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            owner = win;

            // Current-directory chip sits at the top of the sidebar.
            // No "FILES" section label: the sidebar is already a file
            // browser; a header would just be noise.
            var header = new Box (Orientation.VERTICAL, 0);
            header.margin_start  = 12;
            header.margin_end    = 12;
            header.margin_bottom = 4;

            dir_lbl = new Label ("~");
            dir_lbl.ellipsize  = Pango.EllipsizeMode.START;
            dir_lbl.xalign     = 0;
            dir_lbl.add_css_class ("dim-label");
            dir_lbl.add_css_class ("caption");
            header.append (dir_lbl);

            project_header = new Box (Orientation.HORIZONTAL, 6);
            project_header.visible = false;
            var titles = new Box (Orientation.VERTICAL, 0);
            titles.hexpand = true;
            project_lbl = new Label ("");
            project_lbl.xalign = 0;
            project_lbl.ellipsize = Pango.EllipsizeMode.END;
            project_lbl.add_css_class ("heading");
            titles.append (project_lbl);
            project_path_lbl = new Label ("");
            project_path_lbl.xalign = 0;
            project_path_lbl.ellipsize = Pango.EllipsizeMode.START;
            project_path_lbl.add_css_class ("dim-label");
            project_path_lbl.add_css_class ("caption");
            titles.append (project_path_lbl);
            project_header.append (titles);
            var close_btn = new Button.from_icon_name ("window-close-symbolic");
            close_btn.add_css_class ("flat");
            close_btn.valign = Align.CENTER;
            close_btn.tooltip_text = _("Close Folder");
            close_btn.clicked.connect (() => project_close_requested ());
            project_header.append (close_btn);
            header.append (project_header);

            dsh_hint = new Box (Orientation.VERTICAL, 6);
            dsh_hint.add_css_class ("card");
            dsh_hint.margin_top = 6;
            dsh_hint.visible = false;
            var hint_lbl = new Label (_("This folder is outside the developer shell, so language servers, tasks and agents use the tools of the system. Open your project from Developer Files to use the tools installed in dsh."));
            hint_lbl.wrap = true;
            hint_lbl.xalign = 0;
            hint_lbl.margin_start = 10;
            hint_lbl.margin_end = 10;
            hint_lbl.margin_top = 8;
            hint_lbl.add_css_class ("caption");
            dsh_hint.append (hint_lbl);
            var hint_btn = new Button.with_label (_("Developer Files"));
            hint_btn.halign = Align.START;
            hint_btn.margin_start = 10;
            hint_btn.margin_bottom = 8;
            hint_btn.clicked.connect (() => {
                var dsh = Singularity.Edit.Dsh.get_default ();
                if (dsh != null) owner.open_folder_dialog (GLib.File.new_for_path (dsh.host_root));
            });
            dsh_hint.append (hint_btn);
            header.append (dsh_hint);

            append (header);

            var scroll = new ScrolledWindow ();
            scroll.vexpand           = true;
            scroll.hscrollbar_policy = PolicyType.NEVER;

            list_box = new ListBox ();
            list_box.selection_mode = SelectionMode.SINGLE;
            list_box.add_css_class ("navigation-sidebar");
            scroll.set_child (list_box);
            append (scroll);

            list_box.row_activated.connect (on_row_activated);

            navigate_to (GLib.File.new_for_path (Environment.get_home_dir ()));
        }

        private static string short_path (GLib.File dir) {
            string path = dir.get_path () ?? dir.get_uri ();
            string home = Environment.get_home_dir ();
            if (path.has_prefix (home))
                path = "~" + path.substring (home.length);
            return path;
        }

        public void open_project (GLib.File dir) {
            project_root = dir;
            current_dir = dir;
            expanded.remove_all ();
            selected_file = null;
            project_lbl.label = dir.get_basename () ?? short_path (dir);
            project_path_lbl.label = short_path (dir);
            dir_lbl.visible = false;
            project_header.visible = true;
            dsh_hint.visible = Singularity.Edit.Dsh.get_default () != null && Singularity.Edit.Dsh.for_file (dir) == null;
            populate_tree ();
        }

        public void close_project () {
            if (project_root == null) return;
            var dir = project_root;
            project_root = null;
            clear_monitors ();
            project_header.visible = false;
            dsh_hint.visible = false;
            dir_lbl.visible = true;
            navigate_to (dir);
        }

        public void reveal (GLib.File file) {
            if (project_root == null || !file.has_prefix (project_root)) return;
            var dir = file.get_parent ();
            while (dir != null && !dir.equal (project_root)) {
                expanded.add (dir.get_path ());
                dir = dir.get_parent ();
            }
            selected_file = file;
            populate_tree ();
        }

        private void clear_monitors () {
            foreach (var m in monitors.data) m.cancel ();
            monitors = new GenericArray<FileMonitor> ();
        }

        private void watch (GLib.File dir) {
            try {
                var m = dir.monitor_directory (FileMonitorFlags.WATCH_MOVES, null);
                m.changed.connect (() => queue_refresh ());
                monitors.add (m);
            } catch (Error e) {
            }
        }

        private void queue_refresh () {
            if (refresh_source != 0) return;
            refresh_source = Timeout.add (250, () => {
                refresh_source = 0;
                if (project_root != null) populate_tree ();
                return Source.REMOVE;
            });
        }

        private void populate_tree () {
            while (list_box.get_row_at_index (0) != null)
                list_box.remove (list_box.get_row_at_index (0));
            clear_monitors ();
            add_children (project_root, 0);
            if (selected_file == null) list_box.unselect_all ();
        }

        private void add_children (GLib.File dir, int depth) {
            watch (dir);
            GLib.List<GLib.FileInfo> dirs  = new GLib.List<GLib.FileInfo> ();
            GLib.List<GLib.FileInfo> files = new GLib.List<GLib.FileInfo> ();
            try {
                var en = dir.enumerate_children ("standard::name,standard::type", GLib.FileQueryInfoFlags.NONE);
                GLib.FileInfo? fi;
                while ((fi = en.next_file ()) != null) {
                    if (fi.get_name ().has_prefix (".")) continue;
                    if (fi.get_file_type () == GLib.FileType.DIRECTORY) dirs.append (fi);
                    else files.append (fi);
                }
            } catch (Error e) {
                warning ("File browser: %s", e.message);
                return;
            }
            dirs.sort  ((a, b) => strcmp (a.get_name (), b.get_name ()));
            files.sort ((a, b) => strcmp (a.get_name (), b.get_name ()));
            foreach (var d in dirs) {
                var child = dir.get_child (d.get_name ());
                bool open = expanded.contains (child.get_path ());
                append_tree_row (child, d.get_name (), true, depth, open);
                if (open) add_children (child, depth + 1);
            }
            foreach (var f in files)
                append_tree_row (dir.get_child (f.get_name ()), f.get_name (), false, depth, false);
        }

        private void append_tree_row (GLib.File file, string name, bool is_dir, int depth, bool open) {
            var row  = new ListBoxRow ();
            var hbox = new Box (Orientation.HORIZONTAL, 6);
            hbox.margin_start  = 6 + depth * 14;
            hbox.margin_end    = 6;
            hbox.margin_top    = 3;
            hbox.margin_bottom = 3;
            var arrow = new Image.from_icon_name (open ? "pan-down-symbolic" : "pan-end-symbolic");
            arrow.opacity = is_dir ? 1 : 0;
            hbox.append (arrow);
            var img = new Image.from_icon_name (is_dir ? "folder-symbolic" : "text-x-generic-symbolic");
            img.icon_size = IconSize.NORMAL;
            hbox.append (img);
            var lbl = new Label (name);
            lbl.xalign    = 0;
            lbl.ellipsize = Pango.EllipsizeMode.END;
            lbl.hexpand   = true;
            hbox.append (lbl);
            row.set_child (hbox);
            row.set_data<GLib.File> ("file", file);
            row.set_data<bool> ("is-dir", is_dir);
            list_box.append (row);
            if (selected_file != null && selected_file.equal (file)) list_box.select_row (row);
        }

        public void navigate_to (GLib.File dir) {
            if (project_root != null) return;
            current_dir = dir;
            string path = dir.get_path () ?? dir.get_uri ();
            string home = Environment.get_home_dir ();
            if (path.has_prefix (home))
                path = "~" + path.substring (home.length);
            dir_lbl.label = path;
            populate ();
        }

        public void navigate_to_file_dir (GLib.File file) {
            if (project_root != null) {
                reveal (file);
                return;
            }
            var parent = file.get_parent ();
            if (parent != null) navigate_to (parent);
        }

        private void populate () {
            while (list_box.get_row_at_index (0) != null)
                list_box.remove (list_box.get_row_at_index (0));

            if (current_dir.get_parent () != null)
                append_row (null, "..", true);

            try {
                var en = current_dir.enumerate_children (
                    "standard::name,standard::type",
                    GLib.FileQueryInfoFlags.NONE);

                GLib.List<GLib.FileInfo> dirs  = new GLib.List<GLib.FileInfo> ();
                GLib.List<GLib.FileInfo> files = new GLib.List<GLib.FileInfo> ();

                GLib.FileInfo? fi;
                while ((fi = en.next_file ()) != null) {
                    if (fi.get_name ().has_prefix (".")) continue;
                    if (fi.get_file_type () == GLib.FileType.DIRECTORY)
                        dirs.append (fi);
                    else
                        files.append (fi);
                }
                dirs.sort  ((a, b) => strcmp (a.get_name (), b.get_name ()));
                files.sort ((a, b) => strcmp (a.get_name (), b.get_name ()));

                foreach (var d in dirs)
                    append_row (current_dir.get_child (d.get_name ()), d.get_name (), true);
                foreach (var f in files)
                    append_row (current_dir.get_child (f.get_name ()), f.get_name (), false);
            } catch (Error e) {
                warning ("File browser: %s", e.message);
            }
        }

        private void append_row (GLib.File? file, string name, bool is_dir) {
            var row  = new ListBoxRow ();
            var hbox = new Box (Orientation.HORIZONTAL, 6);
            hbox.margin_start  = 6;
            hbox.margin_end    = 6;
            hbox.margin_top    = 3;
            hbox.margin_bottom = 3;

            var img = new Image.from_icon_name (
                is_dir ? "folder-symbolic" : "text-x-generic-symbolic");
            img.icon_size = IconSize.NORMAL;
            hbox.append (img);

            var lbl = new Label (null);
            lbl.xalign     = 0;
            lbl.ellipsize  = Pango.EllipsizeMode.END;
            lbl.hexpand    = true;
            if (is_dir) {
                lbl.label = "<b>%s</b>".printf (GLib.Markup.escape_text (name));
                lbl.use_markup = true;
            } else {
                lbl.label = name;
            }
            hbox.append (lbl);
            row.set_child (hbox);

            if (file != null)
                row.set_data<GLib.File> ("file", file);
            row.set_data<bool> ("is-dir", is_dir);
            list_box.append (row);
        }

        private void on_row_activated (ListBoxRow row) {
            bool is_dir      = row.get_data<bool> ("is-dir");
            GLib.File? file  = row.get_data<GLib.File> ("file");

            if (project_root != null && file != null) {
                if (is_dir) {
                    string key = file.get_path ();
                    if (expanded.contains (key)) expanded.remove (key);
                    else expanded.add (key);
                    populate_tree ();
                } else {
                    selected_file = file;
                    owner.open_file (file);
                }
                return;
            }

            if (file == null) {
                var parent = current_dir.get_parent ();
                if (parent != null) navigate_to (parent);
                return;
            }
            if (is_dir)
                navigate_to (file);
            else
                owner.open_file (file);
        }
    }

}
