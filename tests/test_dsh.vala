using Singularity.Edit;

void check (bool ok, string what) {
    if (!ok) {
        stderr.printf ("FAIL %s\n", what);
        Process.exit (1);
    }
}

int main () {
    string home = Environment.get_home_dir ();
    string root = Path.build_filename (Environment.get_tmp_dir (), "edit-dsh-test", "dev-home");
    DirUtils.create_with_parents (Path.build_filename (root, "Projects", "app"), 0755);
    Environment.set_variable ("SINGULARITY_EDIT_DSH_ROOT", root, true);
    Environment.set_variable ("SINGULARITY_EDIT_DSH", "sh", true);
    var dsh = Dsh.get_default ();
    check (dsh != null, "available");
    string src = root + "/Projects/app/main.rs";
    check (Dsh.for_path (src) == dsh, "owns project file");
    check (Dsh.for_path ("/usr/include/stdio.h") == null, "ignores host paths");
    check (dsh.to_guest (src) == home + "/Projects/app/main.rs", "path to guest");
    string req = "{\"rootUri\":\"file://" + root + "/Projects/app\",\"x\":\"" + root + "/Projects/app/a b.rs\"}";
    string guest = dsh.to_guest_text (req);
    check (guest == "{\"rootUri\":\"file://" + home + "/Projects/app\",\"x\":\"" + home + "/Projects/app/a b.rs\"}", "text to guest");
    check (dsh.to_host_text (guest) == req, "text round trip");
    string art = "{\"uri\":\"file://" + home + "/artifacts/out/log.txt\",\"p\":\"" + home + "\"}";
    check (dsh.to_host_text (art) == "{\"uri\":\"file://" + home + "/artifacts/out/log.txt\",\"p\":\"" + root + "\"}", "artifacts stay, bare home maps");
    check (dsh.to_host_text (home + "2/x") == home + "2/x", "no partial prefix match");
    string esc_home = home.replace ("/", "\\/");
    string esc_root = root.replace ("/", "\\/");
    string py = "{\"uri\":\"file:\\/\\/" + esc_home + "\\/Work\\/a.py\",\"o\":\"" + esc_home + "\\/artifacts\\/x\"}";
    check (dsh.to_host_text (py) == "{\"uri\":\"file:\\/\\/" + esc_root + "\\/Work\\/a.py\",\"o\":\"" + esc_home + "\\/artifacts\\/x\"}", "escaped slashes " + dsh.to_host_text (py));
    check (dsh.to_host_text ("/usr/lib/rustlib/src/lib.rs") == "/usr/lib/rustlib/src/lib.rs", "system paths untouched");
    var argv = dsh.wrap ({ "rust-analyzer", "it's" }, root + "/Projects/app", { "RUST_LOG=info" });
    check (argv.length == 3 && argv[1] == "-c", "wrap shape");
    check (argv[2] == "cd '" + home + "/Projects/app' && exec env 'RUST_LOG=info' 'rust-analyzer' 'it'\\''s'", "wrap line " + argv[2]);
    check (dsh.has_program ("sh"), "finds sh");
    check (!dsh.has_program ("no-such-tool-xyz"), "misses absent tool");
    print ("dsh ok\n");
    return 0;
}
