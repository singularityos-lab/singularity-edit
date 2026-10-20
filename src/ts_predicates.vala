using GLib;

namespace Singularity.Apps {

    public class TsPredicate {
        public string op;
        public Array<uint32> captures = new Array<uint32> ();
        public GenericArray<string> values = new GenericArray<string> ();
        public Regex? regex;
        public bool negated;
    }

    public class TsPredicates {
        private GenericArray<TsPredicate>[] by_pattern;

        public TsPredicates (TS.Query query) {
            uint32 count = query.pattern_count ();
            by_pattern = new GenericArray<TsPredicate>[count];
            for (uint32 p = 0; p < count; p++) {
                by_pattern[p] = new GenericArray<TsPredicate> ();
                parse_pattern (query, p, by_pattern[p]);
            }
        }

        private void parse_pattern (TS.Query query, uint32 pattern,
                                    GenericArray<TsPredicate> into) {
            unowned TS.QueryPredicateStep[] steps = query.predicates_for_pattern (pattern);
            TsPredicate? current = null;
            foreach (var step in steps) {
                if (step.type == TS.QueryPredicateStepType.Done) {
                    if (current != null) {
                        compile (current);
                        into.add (current);
                    }
                    current = null;
                    continue;
                }
                uint32 len;
                if (current == null) {
                    current = new TsPredicate ();
                    current.op = query.string_value_for_id (step.value_id, out len);
                    continue;
                }
                if (step.type == TS.QueryPredicateStepType.Capture)
                    current.captures.append_val (step.value_id);
                else
                    current.values.add (query.string_value_for_id (step.value_id, out len));
            }
        }

        private void compile (TsPredicate pred) {
            string op = pred.op;
            if (op.has_prefix ("not-")) {
                pred.negated = true;
                op = op.substring (4);
            }
            pred.op = op;
            if (pred.values.length == 0) return;
            string? pattern = null;
            if (op == "match?" || op == "vim-match?")
                pattern = pred.values[0];
            else if (op == "lua-match?")
                pattern = lua_to_regex (pred.values[0]);
            if (pattern == null) return;
            try {
                pred.regex = new Regex (pattern, RegexCompileFlags.OPTIMIZE);
            } catch (RegexError e) {
                warning ("ts: predicate pattern %s rejected: %s", pred.values[0], e.message);
            }
        }

        private static string lua_to_regex (string lua) {
            var out_ = new StringBuilder ();
            bool in_class = false;
            int i = 0;
            while (i < lua.length) {
                char c = lua[i];
                if (c == '[' && !in_class) {
                    in_class = true;
                    out_.append_c (c);
                    i++;
                    continue;
                }
                if (c == ']' && in_class) {
                    in_class = false;
                    out_.append_c (c);
                    i++;
                    continue;
                }
                if (c == '%' && i + 1 < lua.length) {
                    out_.append (lua_class (lua[i + 1], in_class));
                    i += 2;
                    continue;
                }
                if (c == '-' && i > 0 && !in_class) {
                    out_.append ("*?");
                } else if (c == '\\' || c == '{' || c == '}' || c == '|') {
                    out_.append_c ('\\');
                    out_.append_c (c);
                } else {
                    out_.append_c (c);
                }
                i++;
            }
            return out_.str;
        }

        private static string lua_class (char n, bool in_class) {
            string inner;
            switch (n) {
                case 'a': inner = "A-Za-z"; break;
                case 'd': inner = "0-9"; break;
                case 'l': inner = "a-z"; break;
                case 'u': inner = "A-Z"; break;
                case 's': inner = "\\s"; break;
                case 'w': inner = "A-Za-z0-9"; break;
                case 'x': inner = "A-Fa-f0-9"; break;
                case 'p': inner = "[:punct:]"; break;
                case 'c': inner = "[:cntrl:]"; break;
                case 'S': return "\\S";
                case 'A': return in_class ? "" : "[^A-Za-z]";
                case 'D': return in_class ? "" : "[^0-9]";
                case 'W': return in_class ? "" : "[^A-Za-z0-9]";
                default: return Regex.escape_string (n.to_string ());
            }
            return in_class ? inner : "[" + inner + "]";
        }

        private static string node_text (TS.Node node, char* text, int text_len) {
            uint32 sb = node.start_byte ();
            uint32 eb = node.end_byte ();
            if ((int) eb > text_len || sb >= eb) return "";
            return ((string) (text + sb)).substring (0, (long) (eb - sb));
        }

        private static string? capture_text (TS.QueryMatch match, uint32 capture,
                                             char* text, int text_len) {
            for (int i = 0; i < match.capture_count; i++) {
                if (match.captures[i].index == capture)
                    return node_text (match.captures[i].node, text, text_len);
            }
            return null;
        }

        public bool accepts (TS.QueryMatch match, char* text, int text_len) {
            if (match.pattern_index >= by_pattern.length) return true;
            var preds = by_pattern[match.pattern_index];
            for (uint i = 0; i < preds.length; i++) {
                if (!evaluate (preds[i], match, text, text_len)) return false;
            }
            return true;
        }

        private bool evaluate (TsPredicate pred, TS.QueryMatch match,
                               char* text, int text_len) {
            if (pred.captures.length == 0) return true;
            string? subject = capture_text (match, pred.captures.index (0), text, text_len);
            if (subject == null) return true;
            bool result;
            switch (pred.op) {
                case "eq?":
                case "any-eq?":
                    string? other = pred.captures.length > 1
                        ? capture_text (match, pred.captures.index (1), text, text_len)
                        : (pred.values.length > 0 ? pred.values[0] : null);
                    if (other == null) return true;
                    result = subject == other;
                    break;
                case "match?":
                case "vim-match?":
                case "lua-match?":
                case "any-match?":
                    if (pred.regex == null) return true;
                    result = pred.regex.match (subject);
                    break;
                case "any-of?":
                    result = false;
                    for (uint i = 0; i < pred.values.length; i++) {
                        if (pred.values[i] == subject) { result = true; break; }
                    }
                    break;
                case "contains?":
                    result = false;
                    for (uint i = 0; i < pred.values.length; i++) {
                        if (subject.contains (pred.values[i])) { result = true; break; }
                    }
                    break;
                default:
                    return true;
            }
            return pred.negated ? !result : result;
        }
    }
}
