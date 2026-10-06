using Gtk;
using GLib;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // =========================================================================
    // FindBar - inline find/replace bar
    // =========================================================================
    public class FindBar : Box {
        private Entry  search_entry;
        private Entry  replace_entry;
        private Box    replace_box;
        private Label  count_lbl;
        private CheckButton case_btn;
        private CheckButton word_btn;
        private CheckButton regex_btn;
        private CheckButton wrap_btn;

        public GtkSource.SearchSettings search_settings { get; private set; }
        private GtkSource.SearchContext? ctx;
        private GtkSource.Buffer?        buf;

        public signal void close_requested ();

        public FindBar () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            visible = false;
            search_settings             = new GtkSource.SearchSettings ();
            search_settings.wrap_around = true;

            add_css_class ("edit-find-bar");

            //  search row
            var sr = new Box (Orientation.HORIZONTAL, 6);
            sr.margin_start  = 4;
            sr.margin_end    = 4;
            sr.margin_top    = 4;
            sr.margin_bottom = 4;

            search_entry = new Entry ();
            search_entry.placeholder_text = _("Find…");
            search_entry.hexpand = true;
            search_entry.activate.connect (find_next);
            Singularity.Widgets.ContextMenu.attach_editable (search_entry);

            var prev_btn = new Button.from_icon_name ("go-up-symbolic");
            prev_btn.add_css_class ("flat");
            prev_btn.tooltip_text = _("Previous match");
            prev_btn.clicked.connect (find_prev);

            var next_btn = new Button.from_icon_name ("go-down-symbolic");
            next_btn.add_css_class ("flat");
            next_btn.tooltip_text = _("Next match");
            next_btn.clicked.connect (find_next);

            count_lbl = new Label ("");
            count_lbl.margin_start = 6;
            count_lbl.margin_end   = 6;

            case_btn = new CheckButton.with_label (_("Aa"));
            case_btn.tooltip_text = _("Case sensitive");
            word_btn = new CheckButton.with_label ("\\b");
            word_btn.tooltip_text = _("Whole word");
            regex_btn = new CheckButton.with_label (".*");
            regex_btn.tooltip_text = _("Regular expression");
            wrap_btn  = new CheckButton.with_label ("↩");
            wrap_btn.tooltip_text = _("Wrap around");
            wrap_btn.active = true;

            var close_btn = new Button.from_icon_name ("window-close-symbolic");
            close_btn.tooltip_text = _("Close");
            close_btn.add_css_class ("flat");
            close_btn.clicked.connect (() => close_requested ());

            sr.append (search_entry);
            sr.append (prev_btn);
            sr.append (next_btn);
            sr.append (count_lbl);
            sr.append (case_btn);
            sr.append (word_btn);
            sr.append (regex_btn);
            sr.append (wrap_btn);
            sr.append (close_btn);
            append (sr);

            //  replace row
            replace_box = new Box (Orientation.HORIZONTAL, 6);
            replace_box.margin_start  = 4;
            replace_box.margin_end    = 4;
            replace_box.margin_bottom = 4;
            replace_box.visible       = false;

            replace_entry = new Entry ();
            replace_entry.placeholder_text = _("Replace…");
            replace_entry.hexpand = true;
            replace_entry.activate.connect (replace_current);
            Singularity.Widgets.ContextMenu.attach_editable (replace_entry);

            var repl_btn = new Button.with_label (_("Replace"));
            repl_btn.add_css_class ("flat");
            repl_btn.clicked.connect (replace_current);

            var repl_all_btn = new Button.with_label (_("Replace All"));
            repl_all_btn.add_css_class ("flat");
            repl_all_btn.clicked.connect (replace_all);

            replace_box.append (replace_entry);
            replace_box.append (repl_btn);
            replace_box.append (repl_all_btn);
            append (replace_box);

            // wire up option buttons to settings
            case_btn.notify["active"].connect  (sync_settings);
            word_btn.notify["active"].connect  (sync_settings);
            regex_btn.notify["active"].connect (sync_settings);
            wrap_btn.notify["active"].connect  (sync_settings);
            search_entry.notify["text"].connect (on_search_changed);
        }

        private void sync_settings () {
            search_settings.case_sensitive      = case_btn.active;
            search_settings.at_word_boundaries  = word_btn.active;
            search_settings.regex_enabled       = regex_btn.active;
            search_settings.wrap_around         = wrap_btn.active;
        }

        private void on_search_changed () {
            search_settings.search_text = search_entry.text;
            update_count ();
        }

        public void set_buffer (GtkSource.Buffer b) {
            if (buf == b) return;
            buf = b;
            ctx = new GtkSource.SearchContext (b, search_settings);
            update_count ();
        }

        private void update_count () {
            if (ctx == null) return;
            int n = ctx.get_occurrences_count ();
            count_lbl.label = (n < 0) ? "" : _("%d matches").printf (n);
        }

        public void show_find (bool replace_mode) {
            replace_box.visible = replace_mode;
            visible = true;
            search_entry.grab_focus ();
            search_settings.search_text = search_entry.text;
        }

        public void find_next () {
            if (ctx == null || buf == null) return;
            Gtk.TextIter iter;
            buf.get_iter_at_mark (out iter, buf.get_insert ());
            // start search after current selection end
            Gtk.TextIter sel_end;
            buf.get_iter_at_mark (out sel_end, buf.get_selection_bound ());
            if (sel_end.compare (iter) > 0) iter = sel_end;

            Gtk.TextIter ms, me;
            bool wrapped;
            if (ctx.forward (iter, out ms, out me, out wrapped)) {
                buf.select_range (ms, me);
                scroll_to_selection ();
                update_count ();
            }
        }

        public void find_prev () {
            if (ctx == null || buf == null) return;
            Gtk.TextIter iter;
            buf.get_iter_at_mark (out iter, buf.get_insert ());

            Gtk.TextIter ms, me;
            bool wrapped;
            if (ctx.backward (iter, out ms, out me, out wrapped)) {
                buf.select_range (ms, me);
                scroll_to_selection ();
                update_count ();
            }
        }

        private void scroll_to_selection () {
            if (buf == null) return;
            var view = find_associated_view ();
            if (view != null)
                view.scroll_to_mark (buf.get_insert (), 0.1, false, 0.0, 0.0);
        }

        private void replace_current () {
            if (ctx == null || buf == null) return;
            Gtk.TextIter ms, me;
            if (!buf.get_selection_bounds (out ms, out me)) {
                find_next ();
                return;
            }
            try {
                ctx.replace (ms, me, replace_entry.text, -1);
            } catch (Error e) {
                warning ("Replace: %s", e.message);
            }
            find_next ();
        }

        private void replace_all () {
            if (ctx == null) return;
            try {
                uint n = ctx.replace_all (replace_entry.text, -1);
                count_lbl.label = _("%u replaced").printf (n);
            } catch (Error e) {
                warning ("Replace all: %s", e.message);
            }
        }

        private GtkSource.View? find_associated_view () {
            Widget? w = get_parent ();
            while (w != null) {
                var t = w as EditorTab;
                if (t != null) return t.view;
                w = w.get_parent ();
            }
            return null;
        }
    }

}
