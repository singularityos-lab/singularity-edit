using GLib;

namespace EditAgents {

    public class AgentEntry : Object {
        public string id;
        public string name;
        public string description = "";
        public Json.Object distribution;
        public string[] hosts = {};
        public string key_variable = "";

        public bool featured {
            get { return id in AgentCatalog.FEATURED; }
        }
    }

    public class AgentLaunch {
        public string[] argv;
        public string[] env = {};
    }

    public class AgentCatalog : Object {
        public const string REGISTRY = "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
        public const string[] FEATURED = { "claude-acp", "codex-acp", "gemini", "github-copilot-cli" };

        private const string FALLBACK = """{"agents":[
{"id":"claude-acp","name":"Claude Agent","description":"Claude Code by Anthropic","distribution":{"npx":{"package":"@agentclientprotocol/claude-agent-acp"}}},
{"id":"codex-acp","name":"Codex","description":"Codex by OpenAI","distribution":{"npx":{"package":"@agentclientprotocol/codex-acp"}}},
{"id":"gemini","name":"Gemini CLI","description":"Gemini by Google","distribution":{"npx":{"package":"@google/gemini-cli","args":["--acp"]}}},
{"id":"github-copilot-cli","name":"Copilot","description":"GitHub Copilot","distribution":{"npx":{"package":"@github/copilot","args":["--acp"]}}}
]}""";

        private static AgentCatalog? _instance;
        public static AgentCatalog get_default () {
            if (_instance == null) _instance = new AgentCatalog ();
            return _instance;
        }

        public signal void changed ();

        private GenericArray<AgentEntry> entries = new GenericArray<AgentEntry> ();
        private bool fetching;

        private AgentCatalog () {
            string? cached = read_cache ();
            parse (cached ?? FALLBACK);
            if (cached == null || cache_age () > 3600) refresh.begin ();
            add_custom ();
        }

        private static string cache_path () {
            return Path.build_filename (Environment.get_user_cache_dir (), "singularity-edit", "acp-registry.json");
        }

        private static string? read_cache () {
            string text;
            try {
                if (!FileUtils.get_contents (cache_path (), out text)) return null;
            } catch (Error e) {
                return null;
            }
            return text;
        }

        private static int64 cache_age () {
            var f = File.new_for_path (cache_path ());
            try {
                var info = f.query_info (FileAttribute.TIME_MODIFIED, FileQueryInfoFlags.NONE);
                return (get_real_time () / 1000000) - (int64) info.get_attribute_uint64 (FileAttribute.TIME_MODIFIED);
            } catch (Error e) {
                return int64.MAX;
            }
        }

        public async void refresh () {
            if (fetching) return;
            fetching = true;
            try {
                var session = new Soup.Session ();
                session.user_agent = "Singularity-Edit";
                var msg = new Soup.Message ("GET", REGISTRY);
                var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, null);
                if (msg.status_code == 200) {
                    var text = (string) bytes.get_data ();
                    if (parse (text)) {
                        DirUtils.create_with_parents (Path.get_dirname (cache_path ()), 0755);
                        FileUtils.set_contents (cache_path (), text);
                        add_custom ();
                        changed ();
                    }
                }
            } catch (Error e) {
            }
            fetching = false;
        }

        private bool parse (string text) {
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (text);
                var arr = parser.get_root ().get_object ().get_array_member ("agents");
                var list = new GenericArray<AgentEntry> ();
                for (uint i = 0; i < arr.get_length (); i++) {
                    var o = arr.get_object_element (i);
                    if (!o.has_member ("id") || !o.has_member ("distribution")) continue;
                    var a = new AgentEntry ();
                    a.id = o.get_string_member ("id");
                    a.name = o.has_member ("name") ? o.get_string_member ("name") : a.id;
                    a.description = o.has_member ("description") ? o.get_string_member ("description") : "";
                    a.distribution = o.get_object_member ("distribution");
                    a.hosts = hosts_for (a.id);
                    list.add (a);
                }
                list.sort ((x, y) => {
                    int fx = index_of_featured (x.id);
                    int fy = index_of_featured (y.id);
                    if (fx != fy) return fx - fy;
                    return strcmp (x.name.down (), y.name.down ());
                });
                entries = list;
                return list.length > 0;
            } catch (Error e) {
                return false;
            }
        }

        private void add_custom () {
            var path = Path.build_filename (Environment.get_user_config_dir (), "singularity-edit", "agents.json");
            if (!FileUtils.test (path, FileTest.EXISTS)) return;
            try {
                var parser = new Json.Parser ();
                parser.load_from_file (path);
                var arr = parser.get_root ().get_object ().get_array_member ("agents");
                for (uint i = 0; i < arr.get_length (); i++) {
                    var o = arr.get_object_element (i);
                    var a = new AgentEntry ();
                    a.id = o.get_string_member ("id");
                    a.name = o.get_string_member ("name");
                    var cmd = new Json.Object ();
                    cmd.set_string_member ("command", o.get_string_member ("command"));
                    if (o.has_member ("args")) cmd.set_array_member ("args", o.get_array_member ("args"));
                    a.distribution = new Json.Object ();
                    a.distribution.set_object_member ("local", cmd);
                    if (o.has_member ("keyVariable")) a.key_variable = o.get_string_member ("keyVariable");
                    if (o.has_member ("hosts")) {
                        string[] h = {};
                        var ha = o.get_array_member ("hosts");
                        for (uint j = 0; j < ha.get_length (); j++) h += ha.get_string_element (j);
                        a.hosts = h;
                    }
                    entries.insert (0, a);
                }
            } catch (Error e) {
            }
        }

        private static int index_of_featured (string id) {
            for (int i = 0; i < FEATURED.length; i++) if (FEATURED[i] == id) return i;
            return FEATURED.length;
        }

        public static string[] hosts_for (string id) {
            string[] common = { "registry.npmjs.org", "pypi.org", "files.pythonhosted.org" };
            string[] own;
            switch (id) {
                case "claude-acp": own = { "anthropic.com", "claude.ai", "claude.com", "statsig.anthropic.com" }; break;
                case "codex-acp": own = { "openai.com", "chatgpt.com" }; break;
                case "gemini": own = { "googleapis.com", "google.com" }; break;
                case "github-copilot-cli": own = { "githubcopilot.com", "github.com", "githubusercontent.com" }; break;
                default: own = {}; break;
            }
            string[] all = {};
            foreach (var h in own) all += h;
            foreach (var h in common) all += h;
            return all;
        }

        public AgentEntry[] all () {
            return entries.data;
        }

        public AgentEntry? lookup (string id) {
            foreach (var a in entries.data) if (a.id == id) return a;
            return null;
        }

        private static string platform () {
            var uts = Posix.utsname ();
            string arch = uts.machine == "aarch64" || uts.machine == "arm64" ? "aarch64" : "x86_64";
            return "linux-" + arch;
        }

        public bool runnable (AgentEntry a) {
            var d = a.distribution;
            if (d.has_member ("local")) return true;
            if (d.has_member ("npx") && Environment.find_program_in_path ("npx") != null) return true;
            if (d.has_member ("uvx") && Environment.find_program_in_path ("uvx") != null) return true;
            if (d.has_member ("binary") && d.get_object_member ("binary").has_member (platform ())) return true;
            return false;
        }

        public string requirement (AgentEntry a) {
            var d = a.distribution;
            if (d.has_member ("npx")) return _("Needs Node.js (npx)");
            if (d.has_member ("uvx")) return _("Needs uv (uvx)");
            return _("Not available for this computer");
        }

        private static string[] with_args (string[] argv, Json.Object spec) {
            string[] out_ = argv;
            if (!spec.has_member ("args")) return out_;
            var args = spec.get_array_member ("args");
            for (uint i = 0; i < args.get_length (); i++) out_ += args.get_string_element (i);
            return out_;
        }

        private static string[] with_env (string[] env, Json.Object spec) {
            string[] out_ = env;
            if (!spec.has_member ("env")) return out_;
            var e = spec.get_object_member ("env");
            foreach (var k in e.get_members ()) out_ += "%s=%s".printf (k, e.get_string_member (k));
            return out_;
        }

        public async AgentLaunch launch_for (AgentEntry a, Cancellable? cancel) throws Error {
            var d = a.distribution;
            var l = new AgentLaunch ();
            string[] argv = {};
            string[] env = {};
            if (d.has_member ("local")) {
                var spec = d.get_object_member ("local");
                argv += spec.get_string_member ("command");
                argv = with_args (argv, spec);
            } else if (d.has_member ("npx") && Environment.find_program_in_path ("npx") != null) {
                var spec = d.get_object_member ("npx");
                argv = { "npx", "-y", spec.get_string_member ("package") };
                argv = with_args (argv, spec);
                env = with_env (env, spec);
            } else if (d.has_member ("uvx") && Environment.find_program_in_path ("uvx") != null) {
                var spec = d.get_object_member ("uvx");
                argv = { "uvx", spec.get_string_member ("package") };
                argv = with_args (argv, spec);
                env = with_env (env, spec);
            } else if (d.has_member ("binary")) {
                var bins = d.get_object_member ("binary");
                if (!bins.has_member (platform ())) throw new IOError.NOT_SUPPORTED (requirement (a));
                var spec = bins.get_object_member (platform ());
                var dir = yield install_binary (a.id, spec, cancel);
                argv += Path.build_filename (dir, spec.get_string_member ("cmd"));
                argv = with_args (argv, spec);
                env = with_env (env, spec);
            } else {
                throw new IOError.NOT_SUPPORTED (requirement (a));
            }
            l.argv = argv;
            l.env = env;
            return l;
        }

        private async string install_binary (string id, Json.Object spec, Cancellable? cancel) throws Error {
            string url = spec.get_string_member ("archive");
            string tag = Checksum.compute_for_string (ChecksumType.SHA1, url).substring (0, 12);
            string dir = Path.build_filename (Environment.get_user_data_dir (), "singularity-edit", "agents", id + "-" + tag);
            if (FileUtils.test (Path.build_filename (dir, ".ready"), FileTest.EXISTS)) return dir;
            DirUtils.create_with_parents (dir, 0755);
            var session = new Soup.Session ();
            var msg = new Soup.Message ("GET", url);
            var bytes = yield session.send_and_read_async (msg, Priority.DEFAULT, cancel);
            if (msg.status_code != 200) throw new IOError.FAILED (_("Download failed (%u)").printf (msg.status_code));
            if (spec.has_member ("sha256")) {
                var sum = Checksum.compute_for_bytes (ChecksumType.SHA256, bytes);
                if (sum != spec.get_string_member ("sha256")) throw new IOError.FAILED (_("The downloaded agent does not match its checksum"));
            }
            string name = Path.get_basename (url.split ("?")[0]);
            string archive = Path.build_filename (dir, name);
            FileUtils.set_data (archive, bytes.get_data ());
            string[] argv = name.has_suffix (".zip") ? new string[] { "unzip", "-q", "-o", archive, "-d", dir } : new string[] { "tar", "-xf", archive, "-C", dir };
            var proc = new Subprocess.newv (argv, SubprocessFlags.NONE);
            yield proc.wait_async (cancel);
            if (!proc.get_successful ()) throw new IOError.FAILED (_("Could not unpack the agent"));
            FileUtils.unlink (archive);
            FileUtils.set_contents (Path.build_filename (dir, ".ready"), url);
            return dir;
        }
    }
}
