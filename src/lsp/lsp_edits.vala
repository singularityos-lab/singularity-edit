using GLib;

namespace Singularity.Apps {

    public class LspEdits : Object {

        public static Gtk.TextIter iter_at (Gtk.TextBuffer buffer, int line, int col, bool utf8) {
            Gtk.TextIter it;
            if (line >= buffer.get_line_count ()) {
                buffer.get_end_iter (out it);
                return it;
            }
            buffer.get_iter_at_line (out it, line);
            Gtk.TextIter end = it;
            if (!end.ends_line ()) end.forward_to_line_end ();
            var text = buffer.get_text (it, end, true);
            int chars = 0;
            int units = 0;
            int i = 0;
            unichar c = 0;
            while (units < col && text.get_next_char (ref i, out c)) {
                units = utf8 ? i : units + (c > 0xFFFF ? 2 : 1);
                chars++;
            }
            it.set_line_offset (int.min (chars, it.get_chars_in_line ()));
            return it;
        }

        public static void apply (Gtk.TextBuffer buffer, Json.Array edits, bool utf8) {
            var marks = new GenericArray<Gtk.TextMark> ();
            var texts = new GenericArray<string> ();
            for (uint i = 0; i < edits.get_length (); i++) {
                var e = edits.get_object_element (i);
                var range = e.get_object_member ("range");
                var a = range.get_object_member ("start");
                var b = range.get_object_member ("end");
                var s = iter_at (buffer, (int) a.get_int_member ("line"), (int) a.get_int_member ("character"), utf8);
                var t = iter_at (buffer, (int) b.get_int_member ("line"), (int) b.get_int_member ("character"), utf8);
                marks.add (buffer.create_mark (null, s, true));
                marks.add (buffer.create_mark (null, t, false));
                texts.add (e.get_string_member ("newText"));
            }
            buffer.begin_user_action ();
            for (uint i = 0; i < texts.length; i++) {
                Gtk.TextIter s, t;
                buffer.get_iter_at_mark (out s, marks[i * 2]);
                buffer.get_iter_at_mark (out t, marks[i * 2 + 1]);
                buffer.delete (ref s, ref t);
                buffer.insert (ref s, texts[i], -1);
            }
            buffer.end_user_action ();
            foreach (var m in marks.data) buffer.delete_mark (m);
        }

        public static HashTable<string, Json.Array> by_uri (Json.Object edit) {
            var map = new HashTable<string, Json.Array> (str_hash, str_equal);
            if (edit.has_member ("documentChanges")) {
                var changes = edit.get_array_member ("documentChanges");
                for (uint i = 0; i < changes.get_length (); i++) {
                    var c = changes.get_object_element (i);
                    if (!c.has_member ("textDocument") || !c.has_member ("edits")) continue;
                    var uri = c.get_object_member ("textDocument").get_string_member ("uri");
                    merge (map, uri, c.get_array_member ("edits"));
                }
            } else if (edit.has_member ("changes")) {
                var changes = edit.get_object_member ("changes");
                foreach (var uri in changes.get_members ())
                    merge (map, uri, changes.get_array_member (uri));
            }
            return map;
        }

        private static void merge (HashTable<string, Json.Array> map, string uri, Json.Array edits) {
            var list = map.lookup (uri);
            if (list == null) {
                list = new Json.Array ();
                map.insert (uri, list);
            }
            for (uint i = 0; i < edits.get_length (); i++)
                list.add_element (edits.get_element (i).copy ());
        }
    }
}
