using Gtk;
using GLib;

namespace Singularity.Apps {

    [DBus (name = "dev.sinty.Collab.Code1")]
    public class CodeCollabBus : Object {
        private unowned EditApp app;

        public CodeCollabBus (EditApp app) {
            this.app = app;
        }

        public void receive (string title, string payload, string from) throws Error {
            app.hold ();
            try {
                EditCollab.get_default ().receive (app, title, payload, from);
            } finally {
                app.release ();
            }
        }

        public void join (string session, string title, string snapshot, string role, string from) throws Error {
            EditCollab.get_default ().join (app, session, title, snapshot, role, from);
        }
    }

    public class CollabPeer : Object {
        public string name;
        public string? path;
        public int line;
        public int column;
        public Widget? flag;
        public unowned GtkSource.View? view;
    }

    public class CollabDocument : Object {
        public EditorTab tab { get; private set; }
        public Singularity.Collab.Text text { get; private set; }
        public Singularity.Collab.Session session { get; private set; }
        public HashTable<string, CollabPeer> peers = new HashTable<string, CollabPeer> (str_hash, str_equal);
        public string? following { get; set; }

        public signal void people_changed ();

        private Singularity.Collab.TextBinding binding;
        private bool applying;
        private uint presence_id;
        private ulong changed_id;
        private ulong mark_id;

        public CollabDocument (EditorTab tab, Singularity.Collab.Text text, string title) {
            this.tab = tab;
            this.text = text;
            session = new Singularity.Collab.Session ("Code", title, text);
            binding = new Singularity.Collab.TextBinding (text, () => buffer_text (), (value, who) => apply_remote (value));
            changed_id = tab.buffer.changed.connect (() => {
                if (!applying) binding.local_changed ();
            });
            mark_id = tab.buffer.mark_set.connect ((it, mark) => {
                if (mark == tab.buffer.get_insert ()) schedule_presence ();
            });
            text.presence.connect (on_presence);
            session.person_joined.connect ((name) => people_changed ());
            session.person_left.connect ((name) => {
                var p = peers.lookup (name);
                if (p != null) drop_flag (p);
                peers.remove (name);
                people_changed ();
            });
            session.closed.connect (() => {
                foreach (var p in peers.get_values ()) drop_flag (p);
                peers.remove_all ();
                people_changed ();
            });
        }

        public void release () {
            tab.buffer.disconnect (changed_id);
            tab.buffer.disconnect (mark_id);
            if (presence_id != 0) Source.remove (presence_id);
            foreach (var p in peers.get_values ()) drop_flag (p);
        }

        private string buffer_text () {
            Gtk.TextIter s, e;
            tab.buffer.get_bounds (out s, out e);
            return tab.buffer.get_text (s, e, false);
        }

        private void apply_remote (string value) {
            string before = buffer_text ();
            if (before == value) return;
            int start, removed;
            string inserted;
            Singularity.Collab.TextBinding.diff (before, value, out start, out removed, out inserted);
            applying = true;
            Gtk.TextIter a, b;
            tab.buffer.get_iter_at_offset (out a, start);
            tab.buffer.get_iter_at_offset (out b, start + removed);
            tab.buffer.begin_irreversible_action ();
            if (removed > 0) tab.buffer.delete (ref a, ref b);
            if (inserted != "") tab.buffer.insert (ref a, inserted, -1);
            tab.buffer.end_irreversible_action ();
            applying = false;
        }

        private void schedule_presence () {
            if (presence_id != 0) return;
            presence_id = Timeout.add (120, () => {
                presence_id = 0;
                send_presence ();
                return Source.REMOVE;
            });
        }

        public void send_presence () {
            Gtk.TextIter it;
            tab.buffer.get_iter_at_mark (out it, tab.buffer.get_insert ());
            var state = new Json.Object ();
            state.set_string_member ("name", Environment.get_real_name () != "Unknown" ? Environment.get_real_name () : Environment.get_user_name ());
            state.set_int_member ("line", it.get_line ());
            state.set_int_member ("column", it.get_line_offset ());
            text.set_presence (state);
        }

        private void on_presence (string author, Json.Object state) {
            string name = state.has_member ("name") ? state.get_string_member ("name") : author;
            var p = peers.lookup (name);
            if (p == null) {
                p = new CollabPeer ();
                p.name = name;
                peers.insert (name, p);
                people_changed ();
            }
            p.line = (int) state.get_int_member ("line");
            p.column = (int) state.get_int_member ("column");
            place_flag (p);
            if (following == name) {
                Gtk.TextIter it;
                tab.buffer.get_iter_at_line (out it, int.min (p.line, tab.buffer.get_line_count () - 1));
                tab.view.scroll_to_iter (it, 0.25, false, 0, 0);
            }
        }

        private static string color_for (string name) {
            string[] palette = { "#d97757", "#2a78d6", "#2ea043", "#8957e5", "#d4a72c", "#e5534b", "#0f9d9a" };
            return palette[str_hash (name) % palette.length];
        }

        private void place_flag (CollabPeer p) {
            var view = tab.view;
            Gtk.TextIter it;
            tab.buffer.get_iter_at_line (out it, int.min (int.max (0, p.line), tab.buffer.get_line_count () - 1));
            Gtk.TextIter col = it;
            if (!col.ends_line ()) col.forward_chars (int.min (p.column, col.get_chars_in_line ()));
            Gdk.Rectangle r;
            view.get_iter_location (col, out r);
            if (p.flag == null) {
                var box = new Box (Orientation.VERTICAL, 0);
                box.can_target = false;
                var label = new Label (p.name);
                label.add_css_class ("edit-collab-flag");
                var caret = new Box (Orientation.HORIZONTAL, 0);
                caret.add_css_class ("edit-collab-caret");
                caret.width_request = 2;
                caret.height_request = r.height;
                caret.halign = Align.START;
                box.append (label);
                box.append (caret);
                var css = new CssProvider ();
                css.load_from_string (".edit-collab-flag { background-color: %s; } .edit-collab-caret { background-color: %s; }".printf (color_for (p.name), color_for (p.name)));
                label.get_style_context ().add_provider (css, STYLE_PROVIDER_PRIORITY_USER + 4);
                caret.get_style_context ().add_provider (css, STYLE_PROVIDER_PRIORITY_USER + 4);
                p.flag = box;
            }
            if (p.view == view && p.flag.get_parent () == view) {
                view.move_overlay (p.flag, r.x, r.y - 16);
            } else {
                drop_flag (p);
                view.add_overlay (p.flag, r.x, r.y - 16);
                p.view = view;
            }
        }

        private void drop_flag (CollabPeer p) {
            if (p.flag != null && p.view != null && p.flag.get_parent () == p.view) p.view.remove (p.flag);
            p.view = null;
        }

        public string[] people () {
            string[] out_ = {};
            foreach (var n in session.people) out_ += n;
            foreach (var n in peers.get_keys ()) if (!(n in out_)) out_ += n;
            return out_;
        }
    }

    public class EditCollab : Object {
        private static EditCollab? _instance;
        public static EditCollab get_default () {
            if (_instance == null) _instance = new EditCollab ();
            return _instance;
        }

        public signal void changed ();

        private GenericArray<CollabDocument> docs = new GenericArray<CollabDocument> ();

        public static bool available () {
            return Singularity.Collab.Client.installed ();
        }

        public CollabDocument? for_tab (EditorTab tab) {
            foreach (var d in docs.data) if (d.tab == tab) return d;
            return null;
        }

        private CollabDocument bind (EditorTab tab, Singularity.Collab.Text text, string title) {
            var d = new CollabDocument (tab, text, title);
            docs.add (d);
            d.people_changed.connect (() => changed ());
            d.session.closed.connect (() => {
                d.release ();
                docs.remove (d);
                changed ();
            });
            changed ();
            return d;
        }

        public CollabDocument? bind_tab (EditorTab tab) {
            var existing = for_tab (tab);
            if (existing != null) return existing;
            Gtk.TextIter s, e;
            tab.buffer.get_bounds (out s, out e);
            string title = tab.file != null ? tab.file.get_basename () : tab.title;
            return bind (tab, new Singularity.Collab.Text (tab.buffer.get_text (s, e, false)), title);
        }

        public void share (EditWindow win, EditorTab tab, Widget anchor) {
            var d = bind_tab (tab);
            d.session.pick_and_share (anchor, (person) => {
                win.notify_user (_("Invitation sent to %s").printf (person.name));
                d.send_presence ();
                changed ();
            });
        }

        public void stop (EditorTab tab) {
            var d = for_tab (tab);
            if (d != null) d.session.stop.begin ();
        }

        private static File shared_file (string id, string title) {
            string name = title.replace ("/", "_").strip ();
            if (name == "") name = "shared.txt";
            var dir = Path.build_filename (Environment.get_user_cache_dir (), "singularity-edit", "shared", id);
            DirUtils.create_with_parents (dir, 0700);
            return File.new_for_path (Path.build_filename (dir, name));
        }

        private EditWindow? window_of (EditApp app) {
            var w = app.get_active_window () as EditWindow;
            if (w != null) return w;
            foreach (var x in app.get_windows ()) if (x is EditWindow) return (EditWindow) x;
            app.activate ();
            return app.get_active_window () as EditWindow;
        }

        public void receive (EditApp app, string title, string payload, string from) throws Error {
            var o = Singularity.Collab.Shared.decode (payload);
            string body = o != null && o.has_member ("text") ? o.get_string_member ("text") : "";
            var file = shared_file ("received-%u".printf (Random.next_int ()), title);
            FileUtils.set_contents (file.get_path (), body);
            var win = window_of (app);
            if (win == null) return;
            win.open_file (file);
            win.present ();
            win.notify_user (_("%s sent you %s").printf (from, title));
        }

        public void join (EditApp app, string session_id, string title, string snapshot, string role, string from) throws Error {
            var text = new Singularity.Collab.Text ();
            text.load (snapshot);
            var file = shared_file (session_id, title);
            FileUtils.set_contents (file.get_path (), text.to_string ());
            var win = window_of (app);
            if (win == null) return;
            win.open_file (file);
            var tab = win.get_current_tab ();
            if (tab == null) return;
            if (role == "view") tab.view.editable = false;
            var d = bind (tab, text, title);
            d.session.join (session_id, from);
            d.following = from;
            d.send_presence ();
            win.present ();
            win.notify_user (_("You are editing %s with %s").printf (title, from));
        }
    }
}
