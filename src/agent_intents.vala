namespace Singularity.Apps {

    internal class EditIntents : Object {
        private static string text (Json.Object args, string key) {
            return args.has_member (key) ? args.get_string_member (key) : "";
        }

        private static EditWindow window (Gtk.Application app) throws Error {
            app.activate ();
            var w = app.get_active_window () as EditWindow;
            if (w == null) throw new IOError.NOT_FOUND ("the editor window is not open");
            return w;
        }

        private static EditorTab tab (Gtk.Application app) throws Error {
            var t = window (app).get_current_tab ();
            if (t == null) throw new IOError.NOT_FOUND ("no document is open");
            return t;
        }

        private static Json.Node brief (EditorTab t) {
            var b = new Json.Builder ();
            b.begin_object ();
            b.set_member_name ("path").add_string_value (t.file != null ? t.file.get_path () ?? t.file.get_uri () : "");
            b.set_member_name ("language").add_string_value (t.get_language_id () ?? "");
            b.set_member_name ("modified").add_boolean_value (t.buffer.get_modified ());
            b.end_object ();
            return b.get_root ();
        }

        private static string selection (EditorTab t) {
            Gtk.TextIter a, b;
            return t.buffer.get_selection_bounds (out a, out b) ? t.buffer.get_text (a, b, true) : "";
        }

        internal static void install (Singularity.Application app) {
            var agent = app.agent;
            agent.add_intent ("edit_open", "Open a file, optionally at a line.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"},\"line\":{\"type\":\"integer\"}},\"required\":[\"path\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    int line = args.has_member ("line") ? (int) args.get_int_member ("line") : -1;
                    window (app).open_file (File.new_for_path (text (args, "path")), line);
                    return brief (tab (app));
                });
            agent.add_intent ("edit_open_folder", "Open a project folder in the sidebar.",
                "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}},\"required\":[\"path\"]}",
                Singularity.AppIntentRisk.READ, (args) => {
                    window (app).open_folder (File.new_for_path (text (args, "path")));
                    return null;
                });
            agent.add_intent ("edit_read", "Read the text and the selection of the open document.",
                "{\"type\":\"object\",\"properties\":{}}",
                Singularity.AppIntentRisk.READ, (args) => {
                    var t = tab (app);
                    Gtk.TextIter a, b;
                    t.buffer.get_bounds (out a, out b);
                    var node = brief (t);
                    node.get_object ().set_string_member ("text", t.buffer.get_text (a, b, true));
                    node.get_object ().set_string_member ("selection", selection (t));
                    return node;
                });
            agent.add_intent ("edit_insert", "Write text at the cursor, replacing the selection. The user sees it appear and can undo it.",
                "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                Singularity.AppIntentRisk.UNDOABLE, (args) => {
                    var t = tab (app);
                    t.buffer.begin_user_action ();
                    t.buffer.delete_selection (true, true);
                    t.buffer.insert_at_cursor (text (args, "text"), -1);
                    t.buffer.end_user_action ();
                    return brief (t);
                });
            agent.add_intent ("edit_save", "Save the open document.",
                "{\"type\":\"object\",\"properties\":{}}",
                Singularity.AppIntentRisk.IRREVERSIBLE, (args) => {
                    var t = tab (app);
                    if (t.file == null) throw new IOError.INVALID_ARGUMENT ("the document has no file yet");
                    t.save ();
                    return brief (t);
                });
            agent.set_context_provider (() => {
                var w = app.get_active_window () as EditWindow;
                var t = w != null ? w.get_current_tab () : null;
                if (t == null) return null;
                var node = brief (t);
                node.get_object ().set_string_member ("selection", selection (t));
                return node;
            });
        }
    }
}
