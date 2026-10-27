using GLib;
using Gtk;

namespace Singularity.Apps {

    /**
     * Drives tree-sitter parsing for one GtkSource.Buffer and paints
     * GtkTextTag spans for the captures emitted by highlights.scm.
     *
     * Strategy (v1):
     *   - Each buffer edit applies a TSInputEdit to the current tree (so
     *     tree-sitter reuses subtrees) then triggers a full re-parse on idle.
     *   - On reparse complete, we clear our ts:* tags across the buffer and
     *     reapply the highlights query against the new root.
     *   - Colors are taken from the current GtkSource style scheme when it
     *     defines the corresponding def:* style; otherwise a sensible fallback
     *     palette is used so the editor never looks unstyled.
     *
     * Optimisations deferred: partial re-highlight using
     * ts_tree_get_changed_ranges, ts_query_cursor_set_byte_range scoping,
     * byte->iter index caching.
     */
    public class TsHighlighter : Object {
        public unowned GtkSource.Buffer buffer { get; private set; }
        public TsLanguageDef def { get; private set; }

        public signal void tree_updated ();

        private TS.Parser parser;
        private TS.Tree?  current_tree;
        public  unowned TS.Tree? tree { get { return current_tree; } }
        private HashTable<string, Gtk.TextTag> tag_cache;
        private GenericSet<string> unstyled;
        private uint reparse_id = 0;
        private ulong h_insert  = 0;
        private ulong h_delete  = 0;
        private ulong h_scheme  = 0;

        public TsHighlighter (GtkSource.Buffer buffer, TsLanguageDef def) {
            this.buffer = buffer;
            this.def    = def;
            this.tag_cache = new HashTable<string, Gtk.TextTag> (str_hash, str_equal);
            this.unstyled  = new GenericSet<string> (str_hash, str_equal);

            TsLangRegistry.get_default ().ensure_queries_loaded (def);

            parser = new TS.Parser ();
            parser.set_language (def.language);

            // insert_text fires AFTER insertion; delete_range fires BEFORE deletion.
            h_insert = buffer.insert_text.connect_after (on_insert);
            h_delete = buffer.delete_range.connect (on_delete_before);
            h_scheme = buffer.notify["style-scheme"].connect (() => {
                tag_cache.remove_all ();
                unstyled.remove_all ();
                schedule_reapply ();
            });

            full_reparse ();
            apply_highlights ();
            Idle.add (() => { tree_updated (); return Source.REMOVE; });
        }

        public void detach () {
            if (h_insert != 0) { buffer.disconnect (h_insert); h_insert = 0; }
            if (h_delete != 0) { buffer.disconnect (h_delete); h_delete = 0; }
            if (h_scheme != 0) { buffer.disconnect (h_scheme); h_scheme = 0; }
            if (reparse_id != 0) { Source.remove (reparse_id); reparse_id = 0; }

            // Strip ts:* tags so a future engine swap leaves a clean buffer.
            Gtk.TextIter s, e;
            buffer.get_bounds (out s, out e);
            var table = buffer.get_tag_table ();
            table.foreach ((tag) => {
                if (tag.name != null && tag.name.has_prefix ("ts:")) {
                    buffer.remove_tag (tag, s, e);
                }
            });

            current_tree = null;
        }

        //  byte/point helpers

        private uint32 iter_to_byte (Gtk.TextIter iter) {
            Gtk.TextIter start;
            buffer.get_start_iter (out start);
            return (uint32) buffer.get_text (start, iter, true).length;
        }

        private TS.Point iter_to_point (Gtk.TextIter iter) {
            uint32 row = (uint32) iter.get_line ();
            Gtk.TextIter line_start;
            buffer.get_iter_at_line (out line_start, iter.get_line ());
            uint32 col = (uint32) buffer.get_text (line_start, iter, true).length;
            return { row, col };
        }

        //  change tracking

        private void on_insert (Gtk.TextIter iter_after, string text, int len) {
            if (current_tree == null) { schedule_reparse (); return; }
            uint32 byte_len = (uint32) text.length;
            uint32 end_byte = iter_to_byte (iter_after);
            uint32 start_byte = end_byte - byte_len;
            TS.Point end_point = iter_to_point (iter_after);

            Gtk.TextIter iter_before;
            buffer.get_iter_at_offset (out iter_before,
                                       iter_after.get_offset () - text.char_count ());
            TS.Point start_point = iter_to_point (iter_before);

            TS.InputEdit edit = {
                start_byte, start_byte, end_byte,
                start_point, start_point, end_point
            };
            current_tree.edit (ref edit);
            schedule_reparse ();
        }

        private void on_delete_before (Gtk.TextIter start, Gtk.TextIter end) {
            if (current_tree == null) { schedule_reparse (); return; }
            uint32 start_byte    = iter_to_byte (start);
            uint32 old_end_byte  = iter_to_byte (end);
            TS.Point start_point  = iter_to_point (start);
            TS.Point old_end_point = iter_to_point (end);

            TS.InputEdit edit = {
                start_byte, old_end_byte, start_byte,
                start_point, old_end_point, start_point
            };
            current_tree.edit (ref edit);
            // Reparse must run after GTK has actually deleted the text.
            schedule_reparse ();
        }

        private void schedule_reparse () {
            if (reparse_id != 0) return;
            reparse_id = Idle.add (() => {
                reparse_id = 0;
                full_reparse ();
                apply_highlights ();
                tree_updated ();
                return Source.REMOVE;
            });
        }

        private void schedule_reapply () {
            if (reparse_id != 0) return;
            reparse_id = Idle.add (() => {
                reparse_id = 0;
                apply_highlights ();
                return Source.REMOVE;
            });
        }

        private void full_reparse () {
            Gtk.TextIter s, e;
            buffer.get_bounds (out s, out e);
            string text = buffer.get_text (s, e, true);
            current_tree = parser.parse_string (current_tree, (uint8[]) text.data, (uint32) text.length);
        }

        // capture-to-tag mapping

        private string? capture_to_style_id (string capture) {
            // Order matters: more specific first.
            if (capture.has_prefix ("comment"))             return "def:comment";
            if (capture.has_prefix ("string"))              return "def:string";
            if (capture.has_prefix ("character"))           return "def:string";
            if (capture.has_prefix ("number"))              return "def:number";
            if (capture.has_prefix ("float"))               return "def:floating-point";
            if (capture.has_prefix ("boolean"))             return "def:boolean";
            if (capture.has_prefix ("constant.builtin"))    return "def:special-constant";
            if (capture.has_prefix ("constant"))            return "def:constant";
            if (capture.has_prefix ("keyword"))             return "def:keyword";
            if (capture.has_prefix ("conditional"))         return "def:keyword";
            if (capture.has_prefix ("repeat"))              return "def:keyword";
            if (capture.has_prefix ("include"))             return "def:keyword";
            if (capture.has_prefix ("exception"))           return "def:keyword";
            if (capture.has_prefix ("operator"))            return "def:operator";
            if (capture.has_prefix ("function.builtin"))    return "def:builtin";
            if (capture.has_prefix ("function"))            return "def:function";
            if (capture.has_prefix ("method"))              return "def:function";
            if (capture.has_prefix ("constructor"))         return "def:function";
            if (capture.has_prefix ("type.builtin"))        return "def:builtin";
            if (capture.has_prefix ("type"))                return "def:type";
            if (capture.has_prefix ("attribute"))           return "def:preprocessor";
            if (capture.has_prefix ("preproc"))             return "def:preprocessor";
            if (capture.has_prefix ("macro"))               return "def:preprocessor";
            if (capture.has_prefix ("label"))               return "def:preprocessor";
            if (capture.has_prefix ("namespace"))           return "def:type";
            if (capture.has_prefix ("module"))              return "def:type";
            if (capture.has_prefix ("tag"))                 return "def:keyword";
            if (capture.has_prefix ("punctuation"))         return "def:operator";
            if (capture.has_prefix ("property"))            return "def:identifier";
            if (capture.has_prefix ("field"))               return "def:identifier";
            if (capture.has_prefix ("variable"))            return "def:identifier";
            if (capture.has_prefix ("parameter"))           return "def:identifier";
            return null;
        }

        private string fallback_color (string style_id) {
            switch (style_id) {
                case "def:keyword":         return "#c678dd";
                case "def:function":        return "#61afef";
                case "def:builtin":         return "#56b6c2";
                case "def:type":            return "#e5c07b";
                case "def:string":          return "#98c379";
                case "def:number":          return "#d19a66";
                case "def:floating-point":  return "#d19a66";
                case "def:boolean":         return "#d19a66";
                case "def:constant":        return "#d19a66";
                case "def:special-constant":return "#d19a66";
                case "def:comment":         return "#7f848e";
                case "def:operator":        return "#56b6c2";
                case "def:preprocessor":    return "#e06c75";
                case "def:identifier":      return "#abb2bf";
                default:                    return "#abb2bf";
            }
        }

        private Gtk.TextTag? tag_for_capture (string capture_name) {
            var existing = tag_cache.lookup (capture_name);
            if (existing != null) return existing;
            if (unstyled.contains (capture_name)) return null;

            var style_id = capture_to_style_id (capture_name);
            if (style_id == null) {
                // GHashTable can't store nulls; track unstyled captures
                // separately so we don't re-evaluate them on every match.
                unstyled.add (capture_name);
                return null;
            }

            var tag_name = "ts:" + capture_name;
            var table = buffer.get_tag_table ();
            var tag = table.lookup (tag_name);
            if (tag == null) tag = buffer.create_tag (tag_name);

            string? fg = null;
            bool bold = false, italic = false;

            var scheme = buffer.style_scheme;
            if (scheme != null) {
                var style = scheme.get_style (style_id);
                if (style != null) {
                    bool fg_set = false, bold_set = false, italic_set = false;
                    style.get ("foreground",     out fg,
                               "foreground-set", out fg_set,
                               "bold",           out bold,
                               "bold-set",       out bold_set,
                               "italic",         out italic,
                               "italic-set",     out italic_set);
                    if (!fg_set) fg = null;
                    if (!bold_set) bold = false;
                    if (!italic_set) italic = false;
                }
            }
            if (fg == null || fg == "") fg = fallback_color (style_id);

            tag.foreground = fg;
            if (bold)   tag.weight = Pango.Weight.BOLD;
            if (italic) tag.style  = Pango.Style.ITALIC;

            tag_cache.insert (capture_name, tag);
            return tag;
        }

        //  apply

        private static Singularity.Compute? compute;

        private void apply_highlights () {
            if (def.highlights_query == null || current_tree == null) return;

            Gtk.TextIter s, e;
            buffer.get_bounds (out s, out e);

            var table = buffer.get_tag_table ();
            table.foreach ((tag) => {
                if (tag.name != null && tag.name.has_prefix ("ts:")) {
                    buffer.remove_tag (tag, s, e);
                }
            });

            string text = buffer.get_text (s, e, true);
            if (compute == null) compute = new Singularity.Compute ();
            uint8[] spans = compute.call (1, Singularity.Compute.key ("edit-highlights:" + def.name, text.data),
                                          () => { return collect_spans (text); });

            uint32* v = (uint32*) spans;
            for (int i = 0; i + 2 < spans.length / 4; i += 3) {
                uint32 name_len = 0;
                unowned string capture_name = def.highlights_query.capture_name_for_id (v[i + 2], out name_len);
                if (capture_name == null) continue;
                var tag = tag_for_capture (capture_name);
                if (tag == null) continue;
                Gtk.TextIter ts_it, te_it;
                buffer.get_iter_at_offset (out ts_it, (int) v[i]);
                buffer.get_iter_at_offset (out te_it, (int) v[i + 1]);
                buffer.apply_tag (tag, ts_it, te_it);
            }
        }

        // Captures arrive sorted by start byte (next_capture iterates
        // left-to-right). We walk a monotonic byte->char cursor and use
        // g_utf8_strlen for each delta; this is O(N) total per pass.
        private uint8[] collect_spans (string text) {
            uint32[] spans = {};
            char* text_ptr  = (char*) text.data;
            int   text_blen = text.length;
            uint32 cursor_byte = 0;
            int    cursor_off  = 0;

            var qc = new TS.QueryCursor ();
            qc.exec (def.highlights_query, current_tree.root_node ());

            TS.QueryMatch match;
            uint32 cap_idx;
            while (qc.next_capture (out match, out cap_idx)) {
                if (def.highlights_predicates != null &&
                    !def.highlights_predicates.accepts (match, text_ptr, text_blen))
                    continue;
                unowned TS.QueryCapture cap = match.captures[cap_idx];

                uint32 sb = cap.node.start_byte ();
                uint32 eb = cap.node.end_byte ();
                if (sb >= eb) continue;
                if ((int) eb > text_blen) continue;

                // Captures can overlap (nested @keyword inside @function): if
                // sb is behind the cursor, rewind from start.
                if (sb < cursor_byte) {
                    cursor_byte = 0;
                    cursor_off  = 0;
                }
                if (cursor_byte < sb) {
                    cursor_off += (int) ((string)(text_ptr + cursor_byte)).char_count (
                    (ssize_t) (sb - cursor_byte));
                    cursor_byte = sb;
                }
                int char_start = cursor_off;
                int char_end = char_start + ((string)(text_ptr + sb)).char_count (
                    (ssize_t) (eb - sb));

                spans += (uint32) char_start;
                spans += (uint32) char_end;
                spans += cap.index;
            }
            uint8[] out_bytes = new uint8[spans.length * 4];
            if (spans.length > 0) Memory.copy (out_bytes, spans, out_bytes.length);
            return out_bytes;
        }
    }
}
