[CCode (cheader_filename = "tree_sitter/api.h")]
namespace TS {

    [CCode (cname = "TSLanguage", free_function = "")]
    [Compact]
    public class Language { }

    [SimpleType]
    [CCode (cname = "TSPoint", has_type_id = false)]
    public struct Point {
        public uint32 row;
        public uint32 column;
    }

    [SimpleType]
    [CCode (cname = "TSRange", has_type_id = false)]
    public struct Range {
        public Point start_point;
        public Point end_point;
        public uint32 start_byte;
        public uint32 end_byte;
    }

    [SimpleType]
    [CCode (cname = "TSInputEdit", has_type_id = false)]
    public struct InputEdit {
        public uint32 start_byte;
        public uint32 old_end_byte;
        public uint32 new_end_byte;
        public Point start_point;
        public Point old_end_point;
        public Point new_end_point;
    }

    [SimpleType]
    [CCode (cname = "TSNode", has_type_id = false)]
    public struct Node {
        public uint32 context[4];
        public void *id;
        public void *tree;

        [CCode (cname = "ts_node_type")]
        public unowned string type ();
        [CCode (cname = "ts_node_is_null")]
        public bool is_null ();
        [CCode (cname = "ts_node_is_named")]
        public bool is_named ();
        [CCode (cname = "ts_node_has_error")]
        public bool has_error ();
        [CCode (cname = "ts_node_start_byte")]
        public uint32 start_byte ();
        [CCode (cname = "ts_node_end_byte")]
        public uint32 end_byte ();
        [CCode (cname = "ts_node_start_point")]
        public Point start_point ();
        [CCode (cname = "ts_node_end_point")]
        public Point end_point ();
        [CCode (cname = "ts_node_child_count")]
        public uint32 child_count ();
        [CCode (cname = "ts_node_named_child_count")]
        public uint32 named_child_count ();
        [CCode (cname = "ts_node_child")]
        public Node child (uint32 index);
        [CCode (cname = "ts_node_named_child")]
        public Node named_child (uint32 index);
        [CCode (cname = "ts_node_parent")]
        public Node parent ();
        [CCode (cname = "ts_node_next_sibling")]
        public Node next_sibling ();
        [CCode (cname = "ts_node_eq")]
        public bool eq (Node other);
        [CCode (cname = "ts_node_edit")]
        public void edit (ref InputEdit edit);
    }

    [CCode (cname = "TSParser", free_function = "ts_parser_delete")]
    [Compact]
    public class Parser {
        [CCode (cname = "ts_parser_new")]
        public Parser ();
        [CCode (cname = "ts_parser_set_language")]
        public bool set_language (Language language);
        [CCode (cname = "ts_parser_parse_string", instance_pos = 0)]
        public Tree? parse_string (Tree? old_tree, [CCode (array_length = false)] uint8[] str, uint32 length);
        [CCode (cname = "ts_parser_reset")]
        public void reset ();
    }

    [CCode (cname = "TSTree", free_function = "ts_tree_delete")]
    [Compact]
    public class Tree {
        [CCode (cname = "ts_tree_copy")]
        public Tree copy ();
        [CCode (cname = "ts_tree_root_node")]
        public Node root_node ();
        [CCode (cname = "ts_tree_edit")]
        public void edit (ref InputEdit edit);
        [CCode (cname = "ts_tree_get_changed_ranges", array_length_pos = 1.1, array_length_type = "uint32_t")]
        public Range[] get_changed_ranges (Tree new_tree);
    }

    [CCode (cname = "TSQueryError", has_type_id = false, cprefix = "TSQueryError")]
    public enum QueryError {
        None,
        Syntax,
        NodeType,
        Field,
        Capture,
        Structure,
        Language,
    }

    [SimpleType]
    [CCode (cname = "TSQueryCapture", has_type_id = false)]
    public struct QueryCapture {
        public Node node;
        public uint32 index;
    }

    [CCode (cname = "TSQueryMatch", has_type_id = false)]
    public struct QueryMatch {
        public uint32 id;
        public uint16 pattern_index;
        public uint16 capture_count;
        [CCode (array_length = false)]
        public unowned QueryCapture[] captures;
    }

    [CCode (cname = "TSQueryPredicateStepType", has_type_id = false, cprefix = "TSQueryPredicateStepType")]
    public enum QueryPredicateStepType {
        Done,
        Capture,
        String,
    }

    [SimpleType]
    [CCode (cname = "TSQueryPredicateStep", has_type_id = false)]
    public struct QueryPredicateStep {
        public QueryPredicateStepType type;
        public uint32 value_id;
    }

    [CCode (cname = "TSQuery", free_function = "ts_query_delete")]
    [Compact]
    public class Query {
        [CCode (cname = "ts_query_predicates_for_pattern", array_length_pos = 1.1, array_length_type = "uint32_t")]
        public unowned QueryPredicateStep[] predicates_for_pattern (uint32 pattern_index);
        [CCode (cname = "ts_query_string_value_for_id")]
        public unowned string string_value_for_id (uint32 id, out uint32 length);
        [CCode (cname = "ts_query_new")]
        public Query (Language language,
                      [CCode (array_length = false)] uint8[] source,
                      uint32 source_len,
                      out uint32 error_offset,
                      out QueryError error_type);
        [CCode (cname = "ts_query_capture_name_for_id")]
        public unowned string capture_name_for_id (uint32 id, out uint32 length);
        [CCode (cname = "ts_query_pattern_count")]
        public uint32 pattern_count ();
        [CCode (cname = "ts_query_capture_count")]
        public uint32 capture_count ();
    }

    [CCode (cname = "TSQueryCursor", free_function = "ts_query_cursor_delete")]
    [Compact]
    public class QueryCursor {
        [CCode (cname = "ts_query_cursor_new")]
        public QueryCursor ();
        [CCode (cname = "ts_query_cursor_exec")]
        public void exec (Query query, Node node);
        [CCode (cname = "ts_query_cursor_set_byte_range")]
        public bool set_byte_range (uint32 start, uint32 end);
        [CCode (cname = "ts_query_cursor_next_match")]
        public bool next_match (out QueryMatch match);
        [CCode (cname = "ts_query_cursor_next_capture")]
        public bool next_capture (out QueryMatch match, out uint32 capture_index);
    }
}

[CCode (cheader_filename = "tree_sitter_grammars.h")]
namespace TSGrammars {
    [CCode (cname = "tree_sitter_go")]
    public unowned TS.Language go ();
    [CCode (cname = "tree_sitter_rust")]
    public unowned TS.Language rust ();
    [CCode (cname = "tree_sitter_python")]
    public unowned TS.Language python ();
    [CCode (cname = "tree_sitter_typescript")]
    public unowned TS.Language typescript ();
    [CCode (cname = "tree_sitter_tsx")]
    public unowned TS.Language tsx ();
}
