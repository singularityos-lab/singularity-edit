using Singularity.Git;

void check (string name, bool ok) {
    if (!ok) {
        printerr ("FAIL %s\n", name);
        Process.exit (1);
    }
    print ("ok %s\n", name);
}

int main () {
    var a = "one\ntwo\nthree\nfour\nfive\n";
    var c = LineDiff.compare (a, a);
    check ("identical", c.length == 0);

    c = LineDiff.compare (a, "one\ntwo\nNEW\nthree\nfour\nfive\n");
    check ("insert", c.length == 1 && c[0].kind == LineChangeKind.ADDED && c[0].start == 2 && c[0].count == 1);

    c = LineDiff.compare (a, "one\ntwo\nfour\nfive\n");
    check ("delete", c.length == 1 && c[0].kind == LineChangeKind.DELETED && c[0].start == 2 && c[0].old_lines.length == 1 && c[0].old_lines[0] == "three");

    c = LineDiff.compare (a, "one\nTWO\nthree\nfour\nFIVE\n");
    check ("modify twice", c.length == 2 && c[0].kind == LineChangeKind.MODIFIED && c[0].start == 1 && c[1].start == 4 && c[1].old_lines[0] == "five");

    c = LineDiff.compare ("", "x\ny\n");
    check ("from empty", c.length == 1 && c[0].kind == LineChangeKind.ADDED && c[0].count == 2);

    c = LineDiff.compare ("a\nb\nc\nd\ne\nf\n", "a\nX\nc\nd\nY\nZ\nf\n");
    check ("mixed", c.length == 2 && c[0].kind == LineChangeKind.MODIFIED && c[0].start == 1 && c[1].kind == LineChangeKind.MODIFIED && c[1].start == 4 && c[1].count == 2);
    return 0;
}
