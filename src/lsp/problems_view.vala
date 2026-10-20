using Gtk;
using GLib;

namespace Singularity.Apps {

    public class ProblemsView : Box {
        public signal void activated (EditorTab tab, int line, int col);

        private ListBox list;
        private Label empty;
        private GenericArray<unowned EditorTab> tabs = new GenericArray<unowned EditorTab> ();

        public ProblemsView () {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class ("edit-problems");
            list = new ListBox ();
            list.add_css_class ("edit-problems-list");
            list.selection_mode = SelectionMode.SINGLE;
            list.row_activated.connect (on_row_activated);
            var sw = new ScrolledWindow ();
            sw.hscrollbar_policy = PolicyType.NEVER;
            sw.vexpand = true;
            sw.set_child (list);
            append (sw);
            empty = new Label (_("No problems in open files"));
            empty.add_css_class ("dim-label");
            empty.margin_top = 24;
            empty.visible = false;
            append (empty);
        }

        public void track (EditorTab tab) {
            if (tabs.find (tab, null)) return;
            tabs.add (tab);
            refresh ();
        }

        public void untrack (EditorTab tab) {
            tabs.remove (tab);
            refresh ();
        }

        public void counts (out int errors, out int warnings) {
            errors = 0;
            warnings = 0;
            foreach (var tab in tabs.data) {
                if (tab.lsp == null) continue;
                foreach (var d in tab.lsp.diagnostics.data) {
                    if (d.severity == 1) errors++;
                    else if (d.severity == 2) warnings++;
                }
            }
        }

        public void refresh () {
            Widget? child;
            while ((child = list.get_first_child ()) != null) list.remove (child);
            int rows = 0;
            foreach (var tab in tabs.data) {
                if (tab.lsp == null) continue;
                foreach (var d in tab.lsp.diagnostics.data) {
                    list.append (problem_row (tab, d));
                    rows++;
                }
            }
            empty.visible = rows == 0;
        }

        private Widget problem_row (EditorTab tab, LspDiagnostic d) {
            var row = new ListBoxRow ();
            row.set_data<unowned EditorTab> ("tab", tab);
            row.set_data<int> ("line", d.line);
            row.set_data<int> ("col", d.col);
            var box = new Box (Orientation.HORIZONTAL, 10);
            box.margin_start = 12;
            box.margin_end = 12;
            box.margin_top = 5;
            box.margin_bottom = 5;
            string icon = d.severity == 1 ? "edit-diagnostic-error" : (d.severity == 2 ? "edit-diagnostic-warning" : "edit-diagnostic-info");
            var img = new Image.from_icon_name (icon);
            img.pixel_size = 16;
            box.append (img);
            var msg = new Label (d.message.split ("\n")[0]);
            msg.xalign = 0;
            msg.hexpand = true;
            msg.ellipsize = Pango.EllipsizeMode.END;
            box.append (msg);
            var where = new Label ("%s:%d:%d · %s%s".printf (
                tab.file != null ? tab.file.get_basename () : tab.title,
                d.line + 1, d.col + 1, d.source, d.code != "" ? " " + d.code : ""));
            where.add_css_class ("dim-label");
            where.add_css_class ("numeric");
            box.append (where);
            row.set_child (box);
            return row;
        }

        private void on_row_activated (ListBoxRow row) {
            var tab = row.get_data<unowned EditorTab> ("tab");
            if (tab == null) return;
            activated (tab, row.get_data<int> ("line"), row.get_data<int> ("col"));
        }
    }
}
