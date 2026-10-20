using Gtk;
using GLib;

namespace Singularity.Apps {

    public class DebugVariablesView : Box {
        private DebugSession? session;
        private Box watches;
        private Box scopes_box;
        private GenericArray<string> expressions = new GenericArray<string> ();
        private uint generation = 0;

        public DebugVariablesView () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("edit-debug-view");
            var sw = new ScrolledWindow ();
            sw.vexpand = true;
            sw.hscrollbar_policy = PolicyType.NEVER;
            var content = new Box (Orientation.VERTICAL, 4);
            content.margin_start = content.margin_end = 12;
            content.margin_top = content.margin_bottom = 6;
            var add = new Entry ();
            add.placeholder_text = _("Watch an expression");
            add.add_css_class ("edit-debug-watch-entry");
            add.activate.connect (() => {
                var expr = add.text.strip ();
                if (expr == "") return;
                expressions.add (expr);
                add.text = "";
                refresh_watches.begin ();
            });
            content.append (add);
            watches = new Box (Orientation.VERTICAL, 2);
            content.append (watches);
            scopes_box = new Box (Orientation.VERTICAL, 2);
            content.append (scopes_box);
            sw.child = content;
            append (sw);
        }

        public void bind (DebugSession? s) {
            session = s;
            if (s != null) s.variables_invalidated.connect (() => reload ());
            reload ();
        }

        public void reload () {
            generation++;
            clear (scopes_box);
            refresh_watches.begin ();
            if (session != null && session.state == DebugSession.State.STOPPED) load_scopes.begin (generation);
        }

        private static void clear (Box box) {
            Widget? c;
            while ((c = box.get_first_child ()) != null) box.remove (c);
        }

        private async void refresh_watches () {
            clear (watches);
            for (uint i = 0; i < expressions.length; i++) {
                string expr = expressions[i];
                var row = new Box (Orientation.HORIZONTAL, 6);
                var value = new Label (null);
                value.xalign = 0;
                value.hexpand = true;
                value.ellipsize = Pango.EllipsizeMode.END;
                value.add_css_class ("monospace");
                value.set_markup ("<b>%s</b> = <span alpha=\"60%\">…</span>".printf (Markup.escape_text (expr)));
                row.append (value);
                var remove = new Button.from_icon_name ("window-close-symbolic");
                remove.add_css_class ("flat");
                remove.add_css_class ("circular");
                remove.clicked.connect (() => {
                    expressions.remove (expr);
                    refresh_watches.begin ();
                });
                row.append (remove);
                watches.append (row);
                if (session == null || session.state != DebugSession.State.STOPPED) continue;
                var res = yield session.evaluate (expr, "watch");
                string shown = res != null && res.has_member ("result") ? res.get_string_member ("result") : "";
                value.set_markup ("<b>%s</b> = %s".printf (Markup.escape_text (expr), Markup.escape_text (shown)));
            }
        }

        private async void load_scopes (uint gen) {
            var scopes = yield session.scopes ();
            if (gen != generation || scopes == null) return;
            for (uint i = 0; i < scopes.get_length (); i++) {
                var s = scopes.get_object_element (i);
                var exp = new Expander (null);
                var title = new Label (s.get_string_member ("name"));
                title.add_css_class ("heading");
                exp.label_widget = title;
                var body = new Box (Orientation.VERTICAL, 2);
                body.margin_start = 14;
                exp.child = body;
                int64 reference = s.get_int_member ("variablesReference");
                bool loaded = false;
                exp.notify["expanded"].connect (() => {
                    if (!exp.expanded || loaded) return;
                    loaded = true;
                    fill.begin (body, reference, gen);
                });
                scopes_box.append (exp);
                if (i == 0) exp.expanded = true;
            }
        }

        private async void fill (Box body, int64 reference, uint gen) {
            var vars = yield session.variables (reference);
            if (gen != generation || vars == null) return;
            for (uint i = 0; i < vars.get_length () && i < 300; i++) {
                var v = vars.get_object_element (i);
                string name = v.get_string_member ("name");
                string value = v.has_member ("value") ? v.get_string_member ("value") : "";
                string? type = v.has_member ("type") && v.get_member ("type").get_node_type () == Json.NodeType.VALUE ? v.get_string_member ("type") : null;
                int64 child_ref = v.has_member ("variablesReference") ? v.get_int_member ("variablesReference") : 0;
                var label = new Label (null);
                label.xalign = 0;
                label.ellipsize = Pango.EllipsizeMode.END;
                label.add_css_class ("monospace");
                label.set_markup ("<b>%s</b>: %s%s".printf (
                    Markup.escape_text (name), Markup.escape_text (value),
                    type != null && type != "" ? " <span alpha=\"55%\">%s</span>".printf (Markup.escape_text (type)) : ""));
                if (child_ref <= 0) {
                    label.margin_start = 18;
                    body.append (label);
                    continue;
                }
                var exp = new Expander (null);
                exp.label_widget = label;
                var inner = new Box (Orientation.VERTICAL, 2);
                inner.margin_start = 14;
                exp.child = inner;
                bool loaded = false;
                exp.notify["expanded"].connect (() => {
                    if (!exp.expanded || loaded) return;
                    loaded = true;
                    fill.begin (inner, child_ref, gen);
                });
                body.append (exp);
            }
        }
    }

    public class DebugStackView : Box {
        private ListBox list;
        private DebugSession? session;

        public DebugStackView () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("edit-debug-view");
            list = new ListBox ();
            list.add_css_class ("edit-problems-list");
            list.row_activated.connect ((row) => {
                if (session != null) session.select_frame (row.get_index ());
            });
            var sw = new ScrolledWindow ();
            sw.vexpand = true;
            sw.hscrollbar_policy = PolicyType.NEVER;
            sw.child = list;
            append (sw);
        }

        public void bind (DebugSession? s) {
            session = s;
            if (s != null) s.stopped_at.connect (() => reload ());
            reload ();
        }

        private void reload () {
            Widget? c;
            while ((c = list.get_first_child ()) != null) list.remove (c);
            if (session == null || session.state != DebugSession.State.STOPPED) return;
            for (int i = 0; i < session.frames.length; i++) {
                var f = session.frames[i];
                var box = new Box (Orientation.HORIZONTAL, 10);
                box.margin_start = box.margin_end = 12;
                box.margin_top = box.margin_bottom = 4;
                var name = new Label (f.name);
                name.xalign = 0;
                name.hexpand = true;
                name.ellipsize = Pango.EllipsizeMode.END;
                name.add_css_class ("monospace");
                box.append (name);
                if (f.path != null) {
                    var where = new Label ("%s:%d".printf (Path.get_basename (f.path), f.line));
                    where.add_css_class ("dim-label");
                    where.add_css_class ("numeric");
                    box.append (where);
                }
                var row = new ListBoxRow ();
                row.child = box;
                list.append (row);
                if (i == session.current_frame) list.select_row (row);
            }
        }
    }

    public class DebugConsoleView : Box {
        private TextView text;
        private Entry prompt;
        private DebugSession? session;

        public DebugConsoleView () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("edit-debug-view");
            text = new TextView ();
            text.editable = false;
            text.cursor_visible = false;
            text.monospace = true;
            text.wrap_mode = WrapMode.WORD_CHAR;
            text.left_margin = text.right_margin = 12;
            text.top_margin = 6;
            text.add_css_class ("singularity-sourceview");
            var err = text.buffer.create_tag ("stderr");
            var red = Gdk.RGBA ();
            red.parse ("#e5534b");
            err.foreground_rgba = red;
            var dim = text.buffer.create_tag ("dim");
            dim.foreground_rgba = { 0.5f, 0.5f, 0.5f, 1f };
            var sw = new ScrolledWindow ();
            sw.vexpand = true;
            sw.child = text;
            append (sw);
            prompt = new Entry ();
            prompt.placeholder_text = _("Evaluate in the paused program");
            prompt.add_css_class ("edit-debug-prompt");
            prompt.margin_start = prompt.margin_end = 8;
            prompt.margin_bottom = 6;
            prompt.activate.connect (() => {
                var expr = prompt.text.strip ();
                if (expr == "" || session == null) return;
                prompt.text = "";
                append_text ("› " + expr + "\n", "dim");
                session.evaluate.begin (expr, "repl", (obj, res) => {
                    var r = session.evaluate.end (res);
                    if (r == null) return;
                    bool failed = r.has_member ("failed");
                    append_text ((r.has_member ("result") ? r.get_string_member ("result") : "") + "\n", failed ? "stderr" : null);
                });
            });
            append (prompt);
        }

        public void bind (DebugSession? s) {
            session = s;
            text.buffer.text = "";
            if (s != null) s.output.connect ((t, cat) => append_text (t, cat == "stderr" ? "stderr" : (cat == "adapter" ? "dim" : null)));
        }

        public void append_text (string t, string? tag) {
            Gtk.TextIter end;
            text.buffer.get_end_iter (out end);
            if (tag != null) text.buffer.insert_with_tags_by_name (ref end, t, -1, tag);
            else text.buffer.insert (ref end, t, -1);
            text.buffer.get_end_iter (out end);
            var mark = text.buffer.create_mark (null, end, false);
            text.scroll_to_mark (mark, 0, false, 0, 1);
            text.buffer.delete_mark (mark);
        }
    }
}
