int main (string[] args) {
    var source = Environment.get_variable ("SINGULARITY_EDIT_TEST_QUERIES");
    string data_home;
    try {
        data_home = DirUtils.make_tmp ("edit-queries-XXXXXX");
    } catch (FileError e) {
        printerr ("%s\n", e.message);
        return 1;
    }
    var link_dir = Path.build_filename (data_home, "singularity-edit");
    DirUtils.create_with_parents (link_dir, 0755);
    FileUtils.symlink (source, Path.build_filename (link_dir, "queries"));
    Environment.set_variable ("XDG_DATA_HOME", data_home, true);

    string[] files = { "a.go", "a.rs", "a.py", "a.ts", "a.tsx" };
    int failures = 0;
    var registry = Singularity.Apps.TsLangRegistry.get_default ();
    foreach (var name in files) {
        var def = registry.lookup_for_file (File.new_for_path (name));
        registry.ensure_queries_loaded (def);
        if (def.highlights_query == null) {
            printerr ("%s: highlights rejected\n", def.name);
            failures++;
        }
        if (registry.read_query (def.name, "folds", 0) != null && def.folds_query == null) {
            printerr ("%s: folds rejected\n", def.name);
            failures++;
        }
        if (registry.read_query (def.name, "locals", 0) != null && def.locals_query == null) {
            printerr ("%s: locals rejected\n", def.name);
            failures++;
        }
        print ("%s: highlights=%s patterns=%u\n", def.name,
               def.highlights_query != null ? "ok" : "rejected",
               def.highlights_query != null ? def.highlights_query.pattern_count () : 0);
    }
    return failures == 0 ? 0 : 1;
}
