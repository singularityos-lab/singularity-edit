using Gtk;
using GLib;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // =========================================================================
    // StatusBar - shows position, encoding, EOL, language, mode, word count
    // =========================================================================
    public class StatusBar : Box {
        public signal void outline_toggled ();

        private Label pos_lbl;
        private Label enc_lbl;
        private Label eol_lbl;
        private Label lang_lbl;
        private Label mode_lbl;
        private Label words_lbl;
        public  Gtk.ToggleButton outline_btn { get; private set; }

        public StatusBar () {
            Object (orientation: Orientation.HORIZONTAL, spacing: 0);
            add_css_class ("edit-statusbar");

            pos_lbl   = sep_label ("Ln 1, Col 1");
            enc_lbl   = sep_label ("UTF-8");
            eol_lbl   = sep_label ("LF");
            lang_lbl  = sep_label ("Plain Text");
            mode_lbl  = sep_label ("INS");
            words_lbl = sep_label ("0 words");

            // Right-side spacer + outline toggle.
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            append (spacer);

            outline_btn = new Gtk.ToggleButton ();
            outline_btn.icon_name = "view-list-symbolic";
            outline_btn.tooltip_text = _("Toggle outline panel");
            outline_btn.add_css_class ("flat");
            outline_btn.sensitive = false;
            outline_btn.toggled.connect (() => outline_toggled ());
            append (outline_btn);
        }

        public void attach_items (Box start, Box end) {
            insert_child_after (start, words_lbl);
            insert_child_after (end, start.get_next_sibling ());
        }

        public void set_outline_available (bool available) {
            outline_btn.sensitive = available;
            if (!available) outline_btn.active = false;
        }

        private Label sep_label (string text) {
            var sep = new Separator (Orientation.VERTICAL);
            append (sep);
            var l = new Label (text);
            l.margin_start = 8;
            l.margin_end   = 8;
            append (l);
            return l;
        }

        public void update_for_tab (EditorTab? tab) {
            if (tab == null) {
                pos_lbl.label   = "-";
                lang_lbl.label  = "-";
                words_lbl.label = "-";
                mode_lbl.label  = "-";
                eol_lbl.label   = "-";
                return;
            }
            var buf = tab.buffer;
            Gtk.TextIter cursor;
            buf.get_iter_at_mark (out cursor, buf.get_insert ());
            pos_lbl.label = _("Ln %d, Col %d").printf (
                cursor.get_line () + 1, cursor.get_line_offset () + 1);

            var lang = buf.get_language ();
            lang_lbl.label = (lang != null) ? lang.name : _("Plain Text");

            Gtk.TextIter ts, te;
            buf.get_bounds (out ts, out te);
            string txt = buf.get_text (ts, te, false);
            eol_lbl.label   = ("\r\n" in txt) ? _("CRLF") : (("\r" in txt) ? _("CR") : _("LF"));
            words_lbl.label = _("%d words").printf (count_words (txt));
            mode_lbl.label  = tab.view.overwrite ? _("OVR") : _("INS");
        }

        private static int count_words (string txt) {
            int n = 0;
            bool in_w = false;
            for (int i = 0; i < txt.length; i++) {
                bool alnum = txt[i].isalnum () || txt[i] == '_';
                if (alnum && !in_w) { n++; in_w = true; }
                else if (!alnum)    { in_w = false; }
            }
            return n;
        }
    }

}
