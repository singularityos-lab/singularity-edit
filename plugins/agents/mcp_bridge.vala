int main (string[] args) {
    string? path = null;
    for (int i = 1; i < args.length; i++) if (args[i] == "--socket" && i + 1 < args.length) path = args[i + 1];
    if (path == null) {
        printerr ("usage: singularity-edit-mcp --socket PATH\n");
        return 2;
    }
    try {
        var client = new SocketClient ();
        var conn = client.connect (new UnixSocketAddress (path));
        var loop = new MainLoop ();
        var stdin_stream = new UnixInputStream (0, false);
        var stdout_stream = new UnixOutputStream (1, false);
        conn.output_stream.splice_async.begin (stdin_stream, OutputStreamSpliceFlags.NONE, Priority.DEFAULT, null, (o, r) => loop.quit ());
        stdout_stream.splice_async.begin (conn.input_stream, OutputStreamSpliceFlags.NONE, Priority.DEFAULT, null, (o, r) => loop.quit ());
        loop.run ();
    } catch (Error e) {
        printerr ("%s\n", e.message);
        return 1;
    }
    return 0;
}
