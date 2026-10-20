using GLib;
using Gtk;

namespace Singularity.Apps {

    public class LspDiagnostic {
        public int line;
        public int col;
        public int end_line;
        public int end_col;
        public int severity;
        public string message;
        public string source;
        public string code;
        public Json.Node raw;
    }

    public class LspProposal : Object, GtkSource.CompletionProposal {
        public string label;
        public string? detail;
        public string? documentation;
        public string insert_text;
        public int kind;
        public string filter_text;

        public string? get_typed_text () {
            return label;
        }
    }

    public class LspDocument : Object {
        public unowned EditorTab tab { get; construct; }
        public string language { get; construct; }
        public LspClient? client { get; private set; }
        public string uri { get; private set; }
        public GenericArray<LspDiagnostic> diagnostics { get; private set; default = new GenericArray<LspDiagnostic> (); }

        public signal void diagnostics_changed ();

        private int version = 1;
        private uint change_id = 0;
        private ulong changed_handler = 0;
        private ulong diag_handler = 0;
        private LspCompletion? completion;
        private LspHover? hover;

        public LspDocument (EditorTab tab, string language) {
            Object (tab: tab, language: language);
        }

        public async void attach () {
            if (tab.file == null) return;
            uri = tab.file.get_uri ();
            diag_handler = LspManager.get_default ().diagnostics.connect (on_diagnostics);
            client = yield LspManager.get_default ().client_for (language, tab.file);
            if (client == null) return;
            var td = new Json.Object ();
            td.set_string_member ("uri", uri);
            td.set_string_member ("languageId", LspManager.language_id_for (language));
            td.set_int_member ("version", version);
            td.set_string_member ("text", buffer_text ());
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", td);
            client.notify_server ("textDocument/didOpen", obj_node (prm));
            pull_diagnostics.begin ();
            changed_handler = tab.buffer.changed.connect (schedule_change);
            install_marks ();
            if (client.supports ("completionProvider")) {
                completion = new LspCompletion (this);
                tab.view.get_completion ().add_provider (completion);
            }
            if (client.supports ("hoverProvider")) {
                hover = new LspHover (this);
                tab.view.get_hover ().add_provider (hover);
            }
        }

        public void detach () {
            if (changed_handler != 0) tab.buffer.disconnect (changed_handler);
            if (diag_handler != 0) LspManager.get_default ().disconnect (diag_handler);
            changed_handler = diag_handler = 0;
            if (change_id != 0) Source.remove (change_id);
            if (completion != null) tab.view.get_completion ().remove_provider (completion);
            if (hover != null) tab.view.get_hover ().remove_provider (hover);
            if (client == null) return;
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", doc_id ());
            client.notify_server ("textDocument/didClose", obj_node (prm));
        }

        public void saved () {
            if (client == null) return;
            flush_change ();
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", doc_id ());
            client.notify_server ("textDocument/didSave", obj_node (prm));
        }

        public static Json.Node obj_node (Json.Object o) {
            var n = new Json.Node (Json.NodeType.OBJECT);
            n.set_object (o);
            return n;
        }

        public Json.Object doc_id () {
            var o = new Json.Object ();
            o.set_string_member ("uri", uri);
            return o;
        }

        private string buffer_text () {
            Gtk.TextIter s, e;
            tab.buffer.get_bounds (out s, out e);
            return tab.buffer.get_text (s, e, true);
        }

        private void schedule_change () {
            if (change_id != 0) Source.remove (change_id);
            change_id = Timeout.add (180, () => {
                change_id = 0;
                send_change ();
                return Source.REMOVE;
            });
        }

        public void flush_change () {
            if (change_id == 0) return;
            Source.remove (change_id);
            change_id = 0;
            send_change ();
        }

        private void send_change () {
            if (client == null) return;
            version++;
            var td = doc_id ();
            td.set_int_member ("version", version);
            var change = new Json.Object ();
            change.set_string_member ("text", buffer_text ());
            var changes = new Json.Array ();
            changes.add_object_element (change);
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", td);
            prm.set_array_member ("contentChanges", changes);
            client.notify_server ("textDocument/didChange", obj_node (prm));
            pull_diagnostics.begin ();
        }

        private async void pull_diagnostics () {
            if (client == null || !client.supports ("diagnosticProvider")) return;
            int asked = version;
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", doc_id ());
            try {
                var result = yield client.request ("textDocument/diagnostic", obj_node (prm));
                if (asked != version || result == null || result.get_node_type () != Json.NodeType.OBJECT) return;
                var report = result.get_object ();
                if (report.has_member ("items")) on_diagnostics (uri, report.get_array_member ("items"));
            } catch (Error e) {
            }
        }

        public int column_to_lsp (Gtk.TextIter it) {
            Gtk.TextIter start = it;
            start.set_line_offset (0);
            var text = tab.buffer.get_text (start, it, true);
            if (client != null && client.utf8_positions) return text.length;
            int units = 0;
            unichar c;
            int i = 0;
            while (text.get_next_char (ref i, out c)) units += c > 0xFFFF ? 2 : 1;
            return units;
        }

        public Gtk.TextIter iter_from_lsp (int line, int col) {
            return LspEdits.iter_at (tab.buffer, line, col, client != null && client.utf8_positions);
        }

        public Json.Object position_params (Gtk.TextIter it) {
            var pos = new Json.Object ();
            pos.set_int_member ("line", it.get_line ());
            pos.set_int_member ("character", column_to_lsp (it));
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", doc_id ());
            prm.set_object_member ("position", pos);
            return prm;
        }

        private void install_marks () {
            set_mark ("lsp-error", "edit-diagnostic-error", 30);
            set_mark ("lsp-warning", "edit-diagnostic-warning", 20);
            set_mark ("lsp-info", "edit-diagnostic-info", 10);
            tab.view.show_line_marks = true;
        }

        private void set_mark (string category, string icon, int priority) {
            var a = new GtkSource.MarkAttributes ();
            a.icon_name = icon;
            a.query_tooltip_text.connect ((mark) => tooltip_for_line (mark));
            tab.view.set_mark_attributes (category, a, priority);
        }

        private string? tooltip_for_line (GtkSource.Mark mark) {
            Gtk.TextIter it;
            tab.buffer.get_iter_at_mark (out it, mark);
            var sb = new StringBuilder ();
            foreach (var d in diagnostics.data) {
                if (d.line != it.get_line ()) continue;
                if (sb.len > 0) sb.append_c ('\n');
                sb.append (d.message);
            }
            return sb.len > 0 ? sb.str : null;
        }

        private Gtk.TextTag tag_for (int severity) {
            string name = severity == 1 ? "lsp-error" : (severity == 2 ? "lsp-warning" : "lsp-info");
            var t = tab.buffer.tag_table.lookup (name);
            if (t != null) return t;
            t = tab.buffer.create_tag (name);
            t.underline = Pango.Underline.ERROR;
            var c = Gdk.RGBA ();
            c.parse (severity == 1 ? "#e5534b" : (severity == 2 ? "#d4a72c" : "#2a78d6"));
            t.underline_rgba = c;
            if (severity <= 2) {
                var bg = c;
                bg.alpha = 0.13f;
                t.background_rgba = bg;
            }
            return t;
        }

        private void clear_decorations () {
            Gtk.TextIter s, e;
            tab.buffer.get_bounds (out s, out e);
            foreach (var name in new string[] { "lsp-error", "lsp-warning", "lsp-info" }) {
                var t = tab.buffer.tag_table.lookup (name);
                if (t != null) tab.buffer.remove_tag (t, s, e);
                tab.buffer.remove_source_marks (s, e, name);
            }
        }

        private void on_diagnostics (string target, Json.Array items) {
            if (target != uri) return;
            clear_decorations ();
            diagnostics = new GenericArray<LspDiagnostic> ();
            for (uint i = 0; i < items.get_length (); i++) {
                var o = items.get_object_element (i);
                var range = o.get_object_member ("range");
                var a = range.get_object_member ("start");
                var b = range.get_object_member ("end");
                var d = new LspDiagnostic ();
                d.raw = items.get_element (i).copy ();
                d.line = (int) a.get_int_member ("line");
                d.col = (int) a.get_int_member ("character");
                d.end_line = (int) b.get_int_member ("line");
                d.end_col = (int) b.get_int_member ("character");
                d.severity = o.has_member ("severity") ? (int) o.get_int_member ("severity") : 1;
                d.message = o.get_string_member ("message");
                d.source = o.has_member ("source") ? o.get_string_member ("source") : client.language;
                d.code = "";
                if (o.has_member ("code")) {
                    var code = o.get_member ("code");
                    d.code = code.get_value_type () == typeof (string) ? code.get_string () : code.get_int ().to_string ();
                }
                diagnostics.add (d);
                var start = iter_from_lsp (d.line, d.col);
                var end = iter_from_lsp (d.end_line, d.end_col);
                if (start.equal (end)) {
                    if (!end.ends_line ()) end.forward_char ();
                    else if (!start.starts_line ()) start.backward_char ();
                }
                tab.buffer.apply_tag (tag_for (d.severity), start, end);
                string category = d.severity == 1 ? "lsp-error" : (d.severity == 2 ? "lsp-warning" : "lsp-info");
                Gtk.TextIter line_start = start;
                line_start.set_line_offset (0);
                tab.buffer.create_source_mark (null, category, line_start);
            }
            diagnostics_changed ();
        }

        public async bool goto_definition () {
            if (client == null || !client.supports ("definitionProvider")) return false;
            Gtk.TextIter it;
            tab.buffer.get_iter_at_mark (out it, tab.buffer.get_insert ());
            flush_change ();
            Json.Node? result;
            try {
                result = yield client.request ("textDocument/definition", obj_node (position_params (it)));
            } catch (Error e) {
                return false;
            }
            if (result == null || result.get_node_type () == Json.NodeType.NULL) return false;
            Json.Object loc;
            if (result.get_node_type () == Json.NodeType.ARRAY) {
                var arr = result.get_array ();
                if (arr.get_length () == 0) return false;
                loc = arr.get_object_element (0);
            } else {
                loc = result.get_object ();
            }
            string target = loc.has_member ("targetUri") ? loc.get_string_member ("targetUri") : loc.get_string_member ("uri");
            var range = loc.has_member ("targetSelectionRange") ? loc.get_object_member ("targetSelectionRange") : loc.get_object_member ("range");
            var start = range.get_object_member ("start");
            definition_found (target, (int) start.get_int_member ("line"), (int) start.get_int_member ("character"));
            return true;
        }

        public signal void definition_found (string uri, int line, int character);

        public bool can_format () {
            return client != null && client.supports ("documentFormattingProvider");
        }

        public async void format () {
            if (client == null || !client.supports ("documentFormattingProvider")) return;
            flush_change ();
            var opts = new Json.Object ();
            opts.set_int_member ("tabSize", (int) tab.view.tab_width);
            opts.set_boolean_member ("insertSpaces", tab.view.insert_spaces_instead_of_tabs);
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", doc_id ());
            prm.set_object_member ("options", opts);
            Json.Node? result;
            try {
                result = yield client.request ("textDocument/formatting", obj_node (prm));
            } catch (Error e) {
                return;
            }
            if (result == null || result.get_node_type () != Json.NodeType.ARRAY) return;
            apply_edits (result.get_array ());
        }

        public void apply_edits (Json.Array edits) {
            LspEdits.apply (tab.buffer, edits, client != null && client.utf8_positions);
        }

        public string word_at_cursor () {
            Gtk.TextIter s, e;
            tab.buffer.get_iter_at_mark (out s, tab.buffer.get_insert ());
            e = s;
            while (!s.starts_line ()) {
                var p = s;
                p.backward_char ();
                var c = p.get_char ();
                if (!c.isalnum () && c != '_') break;
                s = p;
            }
            while (!e.ends_line ()) {
                var c = e.get_char ();
                if (!c.isalnum () && c != '_') break;
                e.forward_char ();
            }
            return tab.buffer.get_text (s, e, false);
        }

        public async Json.Object? rename (string new_name) {
            if (client == null || !client.supports ("renameProvider")) return null;
            Gtk.TextIter it;
            tab.buffer.get_iter_at_mark (out it, tab.buffer.get_insert ());
            flush_change ();
            var prm = position_params (it);
            prm.set_string_member ("newName", new_name);
            try {
                var result = yield client.request ("textDocument/rename", obj_node (prm));
                if (result != null && result.get_node_type () == Json.NodeType.OBJECT) return result.get_object ();
            } catch (Error e) {
                tab_message (e.message);
            }
            return null;
        }

        public signal void message (string text);

        private void tab_message (string text) {
            message (text);
        }

        public async Json.Array? code_actions () {
            if (client == null || !client.supports ("codeActionProvider")) return null;
            Gtk.TextIter it;
            tab.buffer.get_iter_at_mark (out it, tab.buffer.get_insert ());
            flush_change ();
            int line = it.get_line ();
            var diags = new Json.Array ();
            int start_col = 0;
            int end_col = column_to_lsp (it);
            foreach (var d in diagnostics.data) {
                if (d.line > line || d.end_line < line) continue;
                diags.add_element (d.raw.copy ());
            }
            var start = new Json.Object ();
            start.set_int_member ("line", line);
            start.set_int_member ("character", start_col);
            var end = new Json.Object ();
            end.set_int_member ("line", line);
            end.set_int_member ("character", end_col);
            var range = new Json.Object ();
            range.set_object_member ("start", start);
            range.set_object_member ("end", end);
            var context = new Json.Object ();
            context.set_array_member ("diagnostics", diags);
            var prm = new Json.Object ();
            prm.set_object_member ("textDocument", doc_id ());
            prm.set_object_member ("range", range);
            prm.set_object_member ("context", context);
            try {
                var result = yield client.request ("textDocument/codeAction", obj_node (prm));
                if (result != null && result.get_node_type () == Json.NodeType.ARRAY) return result.get_array ();
            } catch (Error e) {
                tab_message (e.message);
            }
            return null;
        }

        public async void run_code_action (Json.Object action) {
            if (client == null) return;
            var act = action;
            if (!act.has_member ("edit") && act.has_member ("data") && client.supports_member ("codeActionProvider", "resolveProvider")) {
                try {
                    var resolved = yield client.request ("codeAction/resolve", obj_node (act));
                    if (resolved != null && resolved.get_node_type () == Json.NodeType.OBJECT) act = resolved.get_object ();
                } catch (Error e) {
                }
            }
            if (act.has_member ("edit")) client.apply_edit_requested (act.get_object_member ("edit"));
            Json.Object? command = null;
            if (act.has_member ("command")) {
                var c = act.get_member ("command");
                if (c.get_node_type () == Json.NodeType.OBJECT) command = c.get_object ();
                else command = act;
            }
            if (command == null) return;
            var prm = new Json.Object ();
            prm.set_string_member ("command", command.get_string_member ("command"));
            if (command.has_member ("arguments")) prm.set_member ("arguments", command.get_member ("arguments").copy ());
            try {
                yield client.request ("workspace/executeCommand", obj_node (prm));
            } catch (Error e) {
                tab_message (e.message);
            }
        }
    }

    public class LspCompletion : Object, GtkSource.CompletionProvider {
        private unowned LspDocument doc;

        public LspCompletion (LspDocument doc) {
            this.doc = doc;
        }

        public string? get_title () {
            return doc.client != null ? doc.client.language : null;
        }

        public bool is_trigger (Gtk.TextIter iter, unichar ch) {
            return ch == '.' || ch == ':' || ch == '>' || ch == '(';
        }

        public async ListModel populate_async (GtkSource.CompletionContext context, Cancellable? cancellable) throws Error {
            var store = new GLib.ListStore (typeof (LspProposal));
            if (doc.client == null) return store;
            Gtk.TextIter begin, end;
            context.get_bounds (out begin, out end);
            doc.flush_change ();
            var result = yield doc.client.request ("textDocument/completion", LspDocument.obj_node (doc.position_params (end)));
            if (result == null || result.get_node_type () == Json.NodeType.NULL) return store;
            Json.Array items;
            if (result.get_node_type () == Json.NodeType.ARRAY) items = result.get_array ();
            else items = result.get_object ().get_array_member ("items");
            string word = context.get_word ().down ();
            for (uint i = 0; i < items.get_length () && store.get_n_items () < 200; i++) {
                var o = items.get_object_element (i);
                var p = new LspProposal ();
                p.label = o.get_string_member ("label").strip ();
                p.detail = o.has_member ("detail") ? o.get_string_member ("detail") : null;
                p.kind = o.has_member ("kind") ? (int) o.get_int_member ("kind") : 0;
                p.filter_text = o.has_member ("filterText") ? o.get_string_member ("filterText") : p.label;
                p.insert_text = p.label;
                if (o.has_member ("textEdit")) p.insert_text = o.get_object_member ("textEdit").get_string_member ("newText");
                else if (o.has_member ("insertText")) p.insert_text = o.get_string_member ("insertText");
                if (o.has_member ("documentation")) {
                    var doc_node = o.get_member ("documentation");
                    p.documentation = doc_node.get_node_type () == Json.NodeType.OBJECT
                        ? doc_node.get_object ().get_string_member ("value") : doc_node.get_string ();
                }
                if (word == "" || p.filter_text.down ().has_prefix (word) || p.filter_text.down ().contains (word))
                    store.append (p);
            }
            return store;
        }

        public void refilter (GtkSource.CompletionContext context, ListModel model) {
            var word = context.get_word ().down ();
            var store = model as GLib.ListStore;
            if (store == null) return;
            for (int i = (int) store.get_n_items () - 1; i >= 0; i--) {
                var p = (LspProposal) store.get_item (i);
                if (word != "" && !p.filter_text.down ().contains (word)) store.remove (i);
            }
        }

        public void display (GtkSource.CompletionContext context, GtkSource.CompletionProposal proposal, GtkSource.CompletionCell cell) {
            var p = (LspProposal) proposal;
            switch (cell.get_column ()) {
                case GtkSource.CompletionColumn.ICON:
                    cell.set_icon_name (kind_icon (p.kind));
                    break;
                case GtkSource.CompletionColumn.TYPED_TEXT:
                    cell.set_text (p.label);
                    break;
                case GtkSource.CompletionColumn.AFTER:
                    cell.set_text (p.detail);
                    break;
                case GtkSource.CompletionColumn.DETAILS:
                    cell.set_text (p.documentation);
                    break;
                default:
                    cell.set_text (null);
                    break;
            }
        }

        public void activate (GtkSource.CompletionContext context, GtkSource.CompletionProposal proposal) {
            var p = (LspProposal) proposal;
            Gtk.TextIter begin, end;
            context.get_bounds (out begin, out end);
            var buffer = context.get_buffer ();
            buffer.begin_user_action ();
            buffer.delete (ref begin, ref end);
            buffer.insert (ref begin, p.insert_text, -1);
            buffer.end_user_action ();
        }

        private static string kind_icon (int kind) {
            switch (kind) {
                case 2: case 3: case 4: return "lang-function-symbolic";
                case 5: case 10: return "lang-variable-symbolic";
                case 6: return "lang-variable-symbolic";
                case 7: case 8: case 22: return "lang-class-symbolic";
                case 9: return "lang-namespace-symbolic";
                case 13: case 20: return "lang-enum-symbolic";
                case 14: return "lang-define-symbolic";
                case 21: return "lang-define-symbolic";
                default: return "text-x-generic-symbolic";
            }
        }
    }

    public class LspHover : Object, GtkSource.HoverProvider {
        private unowned LspDocument doc;

        public LspHover (LspDocument doc) {
            this.doc = doc;
        }

        public bool populate (GtkSource.HoverContext context, GtkSource.HoverDisplay display) throws Error {
            return false;
        }

        public async bool populate_async (GtkSource.HoverContext context, GtkSource.HoverDisplay display, Cancellable? cancellable) throws Error {
            Gtk.TextIter it;
            if (!context.get_iter (out it)) return false;
            var box = new Box (Orientation.VERTICAL, 6);
            box.margin_start = 8;
            box.margin_end = 8;
            box.margin_top = 6;
            box.margin_bottom = 6;
            bool any = false;
            foreach (var d in doc.diagnostics.data) {
                if (d.line != it.get_line ()) continue;
                var row = new Box (Orientation.HORIZONTAL, 8);
                var icon = new Image.from_icon_name (d.severity == 1 ? "edit-diagnostic-error" : (d.severity == 2 ? "edit-diagnostic-warning" : "edit-diagnostic-info"));
                icon.valign = Align.START;
                icon.margin_top = 2;
                row.append (icon);
                var text = new Box (Orientation.VERTICAL, 2);
                var l = new Label (d.message);
                l.wrap = true;
                l.xalign = 0;
                l.max_width_chars = 72;
                text.append (l);
                var src = new Label (d.source + (d.code != "" ? " " + d.code : ""));
                src.add_css_class ("dim-label");
                src.add_css_class ("caption");
                src.xalign = 0;
                text.append (src);
                row.append (text);
                box.append (row);
                any = true;
            }
            if (doc.client != null && doc.client.supports ("hoverProvider")) {
                try {
                    var result = yield doc.client.request ("textDocument/hover", LspDocument.obj_node (doc.position_params (it)));
                    var text = hover_text (result);
                    if (text != null && text.strip () != "") {
                        if (any) box.append (new Separator (Orientation.HORIZONTAL));
                        var l = new Label (text.strip ());
                        l.wrap = true;
                        l.xalign = 0;
                        l.max_width_chars = 80;
                        l.add_css_class ("monospace");
                        box.append (l);
                        any = true;
                    }
                } catch (Error e) {
                }
            }
            if (any) display.append (box);
            return any;
        }

        private static string? hover_text (Json.Node? result) {
            if (result == null || result.get_node_type () != Json.NodeType.OBJECT) return null;
            var contents = result.get_object ().get_member ("contents");
            if (contents == null) return null;
            if (contents.get_node_type () == Json.NodeType.VALUE) return strip_fences (contents.get_string ());
            if (contents.get_node_type () == Json.NodeType.OBJECT) return strip_fences (contents.get_object ().get_string_member ("value"));
            var sb = new StringBuilder ();
            var arr = contents.get_array ();
            for (uint i = 0; i < arr.get_length (); i++) {
                var n = arr.get_element (i);
                if (sb.len > 0) sb.append ("\n\n");
                sb.append (n.get_node_type () == Json.NodeType.OBJECT ? n.get_object ().get_string_member ("value") : n.get_string ());
            }
            return strip_fences (sb.str);
        }

        private static string strip_fences (string s) {
            var out_ = new StringBuilder ();
            foreach (var line in s.split ("\n")) {
                if (line.has_prefix ("```")) continue;
                if (line.strip () == "---") continue;
                out_.append (line);
                out_.append_c ('\n');
            }
            return out_.str;
        }
    }
}
