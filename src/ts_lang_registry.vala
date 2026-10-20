using GLib;

namespace Singularity.Apps {

    public class TsLanguageDef {
        public string name;
        public unowned TS.Language language;
        public TS.Query? highlights_query;
        public TS.Query? folds_query;
        public TS.Query? locals_query;
        public TsPredicates? highlights_predicates;
        public bool queries_loaded;

        public TsLanguageDef (string name, TS.Language language) {
            this.name = name;
            this.language = language;
        }
    }

    public class TsLangRegistry : Object {
        private static TsLangRegistry? _instance;
        public static TsLangRegistry get_default () {
            if (_instance == null) _instance = new TsLangRegistry ();
            return _instance;
        }

        private HashTable<string, TsLanguageDef> by_ext;

        private TsLangRegistry () {
            by_ext = new HashTable<string, TsLanguageDef> (str_hash, str_equal);

            register ("go",         TSGrammars.go (),         { "go" });
            register ("rust",       TSGrammars.rust (),       { "rs" });
            register ("python",     TSGrammars.python (),     { "py", "pyi", "pyw" });
            register ("typescript", TSGrammars.typescript (), { "ts", "mts", "cts" });
            register ("tsx",        TSGrammars.tsx (),        { "tsx", "jsx" });
        }

        private void register (string name, TS.Language lang, string[] exts) {
            var def = new TsLanguageDef (name, lang);
            foreach (var e in exts) by_ext.insert (e, def);
        }

        public TsLanguageDef? lookup_for_file (File file) {
            var basename = file.get_basename ();
            if (basename == null) return null;
            var dot = basename.last_index_of_char ('.');
            if (dot < 0) return null;
            var ext = basename.substring (dot + 1).down ();
            return by_ext.lookup (ext);
        }

        public void ensure_queries_loaded (TsLanguageDef def) {
            if (def.queries_loaded) return;
            def.queries_loaded = true;

            string? highlights = read_query (def.name, "highlights", 0);
            if (highlights == null) {
                warning ("tree-sitter: no queries found for %s", def.name);
                return;
            }
            def.highlights_query = load_query (def.language, def.name, "highlights", highlights);
            if (def.highlights_query != null)
                def.highlights_predicates = new TsPredicates (def.highlights_query);
            string? folds = read_query (def.name, "folds", 0);
            if (folds != null)
                def.folds_query = load_query (def.language, def.name, "folds", folds);
            string? locals = read_query (def.name, "locals", 0);
            if (locals != null)
                def.locals_query = load_query (def.language, def.name, "locals", locals);
        }

        private string[] query_roots () {
            string[] roots = {};
            roots += Path.build_filename (Environment.get_user_data_dir (),
                                          "singularity-edit", "queries");
            foreach (var d in Environment.get_system_data_dirs ()) {
                roots += Path.build_filename (d, "singularity-edit", "queries");
            }
            roots += "/usr/share/singularity-edit/queries";
            roots += "/usr/local/share/singularity-edit/queries";
            return roots;
        }

        public string? read_query (string name, string kind, int depth) {
            if (depth > 4) return null;
            foreach (var root in query_roots ()) {
                var path = Path.build_filename (root, name, kind + ".scm");
                if (!FileUtils.test (path, FileTest.EXISTS)) continue;
                string contents;
                try {
                    FileUtils.get_contents (path, out contents);
                } catch (Error e) {
                    warning ("ts: read %s failed: %s", path, e.message);
                    return null;
                }
                var source = new StringBuilder ();
                foreach (var parent in inherited (contents)) {
                    var parent_source = read_query (parent, kind, depth + 1);
                    if (parent_source != null) {
                        source.append (parent_source);
                        source.append_c ('\n');
                    }
                }
                source.append (contents);
                return source.str;
            }
            return null;
        }

        private string[] inherited (string contents) {
            string[] parents = {};
            var first = contents.split ("\n", 2)[0].strip ();
            if (!first.has_prefix (";")) return parents;
            var directive = first.substring (1).strip ();
            if (!directive.has_prefix ("inherits:")) return parents;
            foreach (var item in directive.substring (9).split (",")) {
                var parent = item.strip ().replace ("(", "").replace (")", "");
                if (parent != "") parents += parent;
            }
            return parents;
        }

        private TS.Query? load_query (TS.Language lang, string name, string kind,
                                      string contents) {
            uint32 err_off = 0;
            TS.QueryError err_type = TS.QueryError.None;
            var q = new TS.Query (lang, (uint8[]) contents.data,
                                  (uint32) contents.length, out err_off, out err_type);
            if (err_type != TS.QueryError.None) {
                warning ("ts: query %s/%s rejected at byte %u (error code %d)",
                         name, kind, err_off, (int) err_type);
                return null;
            }
            return q;
        }
    }
}
