namespace Singularity.Edit {

    public class Dsh : Object {
        private static Dsh? instance;
        private static bool probed = false;

        public string host_root { get; private set; }
        public string guest_home { get; private set; }
        public string program { get; private set; }

        private HashTable<string, bool> programs = new HashTable<string, bool> (str_hash, str_equal);
        private Regex? guest_pattern;
        private Regex? escaped_pattern;

        private Dsh (string program, string host_root, string guest_home) {
            this.program = program;
            this.host_root = host_root;
            this.guest_home = guest_home;
            guest_pattern = home_pattern ("/");
            escaped_pattern = home_pattern ("\\/");
        }

        private Regex? home_pattern (string sep) {
            string home = Regex.escape_string (guest_home.replace ("/", sep));
            string slash = Regex.escape_string (sep);
            try {
                return new Regex ("(?<!\\\\)" + home + "(?=" + slash + "|[\"\\\\]|$)(?!" + slash + "artifacts(?:" + slash + "|[\"\\\\]|$))(?!" + slash + "\\.local" + slash + "share" + slash + "ush" + slash + ")");
            } catch (RegexError e) {
                return null;
            }
        }

        public static Dsh? get_default () {
            if (probed) return instance;
            probed = true;
            string? root = Environment.get_variable ("SINGULARITY_EDIT_DSH_ROOT");
            if (root == null) {
                if (!Singularity.Runtime.is_sinty_os ()) return null;
                root = Path.build_filename (Environment.get_home_dir (), ".local", "share", "ush", "layers", "persistent", "dev-home");
            }
            string? program = Environment.find_program_in_path (Environment.get_variable ("SINGULARITY_EDIT_DSH") ?? "dsh");
            if (program == null || !FileUtils.test (root, FileTest.IS_DIR)) return null;
            instance = new Dsh (program, root, Environment.get_home_dir ());
            return instance;
        }

        public static Dsh? for_path (string? path) {
            var dsh = get_default ();
            if (dsh == null || path == null || !dsh.owns (path)) return null;
            return dsh;
        }

        public static Dsh? for_file (File? file) {
            return file != null ? for_path (file.get_path ()) : null;
        }

        public bool owns (string path) {
            return path == host_root || path.has_prefix (host_root + "/");
        }

        public string to_guest (string path) {
            if (!owns (path)) return path;
            return guest_home + path.substring (host_root.length);
        }

        public string to_host (string path) {
            return to_host_text (path);
        }

        public string to_guest_text (string text) {
            return text.replace (host_root, guest_home);
        }

        public string to_host_text (string text) {
            if (guest_pattern == null || escaped_pattern == null) return text;
            try {
                string plain = guest_pattern.replace_literal (text, -1, 0, host_root);
                if (!("\\/" in plain)) return plain;
                return escaped_pattern.replace_literal (plain, -1, 0, host_root.replace ("/", "\\/"));
            } catch (RegexError e) {
                return text;
            }
        }

        public static string quote (string arg) {
            return "'" + arg.replace ("'", "'\\''") + "'";
        }

        public string[] wrap (string[] argv, string? host_cwd = null, string[]? env = null) {
            var line = new StringBuilder ();
            if (host_cwd != null) line.append ("cd %s && ".printf (quote (to_guest (host_cwd))));
            line.append ("exec");
            if (env != null && env.length > 0) {
                line.append (" env");
                foreach (var e in env) line.append (" " + quote (to_guest_text (e)));
            }
            foreach (var a in argv) line.append (" " + quote (to_guest_text (a)));
            return { program, "-c", line.str };
        }

        public bool has_program (string name) {
            if (programs.contains (name)) return programs.lookup (name);
            bool found = false;
            try {
                int status;
                Process.spawn_sync (null, { program, "-c", "command -v " + quote (name) }, null,
                                    SpawnFlags.STDOUT_TO_DEV_NULL | SpawnFlags.STDERR_TO_DEV_NULL, null, null, null, out status);
                found = Process.if_exited (status) && Process.exit_status (status) == 0;
            } catch (SpawnError e) {
                found = false;
            }
            programs.insert (name, found);
            return found;
        }
    }
}
