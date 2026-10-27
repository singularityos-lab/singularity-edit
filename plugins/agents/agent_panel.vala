using Gtk;
using GLib;
using Singularity.Edit;
using Singularity.Widgets;

namespace EditAgents {

    public const string PANEL_CSS = """
.edit-agent-panel { padding: 0; }
.edit-agent-header { padding: 6px 10px 6px 12px; }
.edit-agent-avatar {
    min-width: 26px; min-height: 26px; padding: 0;
    border-radius: 999px; color: white; font-weight: 700; font-size: 10px;
}
.edit-agent-avatar.small { min-width: 18px; min-height: 18px; font-size: 8px; }
.edit-agent-conv { padding: 6px 12px 12px 12px; }
.edit-agent-user {
    padding: 8px 12px; border-radius: 14px;
    background-color: alpha(@accent_color, 0.16);
}
.edit-agent-thought { color: alpha(@window_fg_color, 0.6); font-style: italic; }
.edit-agent-card {
    padding: 8px 10px; border-radius: 12px;
    background-color: alpha(@window_fg_color, 0.05);
    border: 1px solid alpha(@window_fg_color, 0.08);
}
.edit-agent-card.permission { border-color: alpha(@accent_color, 0.45); }
.edit-agent-card.review { border-color: alpha(#2ea043, 0.45); }
.edit-agent-ok { color: #2ea043; }
.edit-agent-fail { color: #e5534b; }
.edit-agent-add { color: #2ea043; font-weight: 600; }
.edit-agent-del { color: #e5534b; font-weight: 600; }
.edit-agent-composer {
    margin: 8px 10px 10px 10px; padding: 8px 8px 6px 8px;
    border-radius: 16px; border: 1px solid alpha(@window_fg_color, 0.14);
    background-color: @card_bg_color;
}
.edit-agent-composer textview, .edit-agent-composer textview > text {
    background: none; background-color: transparent;
}
.edit-agent-composer menubutton > button { padding: 2px 8px; border-radius: 999px; min-height: 26px; }
.edit-agent-send { min-width: 30px; min-height: 30px; padding: 0; border-radius: 999px; }
.edit-agent-flag {
    padding: 1px 7px; border-radius: 999px; color: white;
    font-family: "Noto Sans"; font-size: 10px; font-weight: 700;
}
.edit-agent-mode-row { padding: 6px 8px; border-radius: 8px; }
.edit-agent-mode-row.current { background-color: alpha(@accent_color, 0.14); }
""";

    public static string agent_color (string id) {
        switch (id) {
            case "claude-acp": return "#d97757";
            case "codex-acp": return "#10a37f";
            case "gemini": return "#4285f4";
            case "github-copilot-cli": return "#8957e5";
            default: return "#5e81ac";
        }
    }

    public static string initials (string name) {
        var parts = name.strip ().split (" ");
        if (parts.length >= 2 && parts[0].length > 0 && parts[1].length > 0)
            return (parts[0].substring (0, 1) + parts[1].substring (0, 1)).up ();
        return name.length >= 2 ? name.substring (0, 2).up () : name.up ();
    }

    public static Widget avatar (AgentEntry a, bool small = false) {
        var l = new Label (initials (a.name));
        l.add_css_class ("edit-agent-avatar");
        if (small) l.add_css_class ("small");
        l.valign = Align.CENTER;
        l.halign = Align.CENTER;
        var p = new CssProvider ();
        p.load_from_string ("label { background-color: %s; }".printf (agent_color (a.id)));
        l.get_style_context ().add_provider (p, STYLE_PROVIDER_PRIORITY_USER + 4);
        return l;
    }

    public class AgentPanel : Box {
        private unowned Workspace workspace;
        private AgentSession? session;
        private AgentEntry? agent;
        private Mode mode = Mode.ASK;
        private Box header_avatar;
        private Label header_name;
        private Label header_status;
        private ToggleButton follow_btn;
        private Button stop_btn;
        private Box conv;
        private ScrolledWindow scroller;
        private Box review;
        private TextView input;
        private MenuButton agent_btn;
        private MenuButton mode_btn;
        private Button send_btn;
        private Label limits;
        private string? last_role;
        private bool stick = true;
        private bool settling;
        private Label? last_label;
        private StringBuilder last_text = new StringBuilder ();
        private HashTable<string, ToolCard> cards = new HashTable<string, ToolCard> (str_hash, str_equal);
        private Box? plan_card;
        private Widget? flag;
        private unowned GtkSource.View? flag_view;

        public McpServer? mcp { get; set; }

        public AgentPanel (Workspace ws) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            workspace = ws;
            add_css_class ("edit-agent-panel");
            build ();
            var featured = AgentCatalog.get_default ().all ();
            foreach (var a in featured) {
                if (AgentCatalog.get_default ().runnable (a)) {
                    agent = a;
                    break;
                }
            }
            if (agent == null && featured.length > 0) agent = featured[0];
            AgentCatalog.get_default ().changed.connect (() => sync_header ());
            sync_header ();
            sync_mode ();
        }

        private void build () {
            var header = new Box (Orientation.HORIZONTAL, 8);
            header.add_css_class ("edit-agent-header");
            header_avatar = new Box (Orientation.HORIZONTAL, 0);
            header.append (header_avatar);
            var names = new Box (Orientation.VERTICAL, 0);
            names.hexpand = true;
            header_name = new Label ("");
            header_name.xalign = 0;
            header_name.add_css_class ("heading");
            names.append (header_name);
            header_status = new Label ("");
            header_status.xalign = 0;
            header_status.ellipsize = Pango.EllipsizeMode.END;
            header_status.add_css_class ("dim-label");
            header_status.add_css_class ("caption");
            names.append (header_status);
            header.append (names);
            follow_btn = new ToggleButton ();
            follow_btn.icon_name = "view-reveal-symbolic";
            follow_btn.add_css_class ("flat");
            follow_btn.tooltip_text = _("Follow the agent in the editor");
            header.append (follow_btn);
            stop_btn = new Button.from_icon_name ("media-playback-stop-symbolic");
            stop_btn.add_css_class ("flat");
            stop_btn.tooltip_text = _("Stop");
            stop_btn.visible = false;
            stop_btn.clicked.connect (() => stop ());
            header.append (stop_btn);
            var fresh = new Button.from_icon_name ("list-add-symbolic");
            fresh.add_css_class ("flat");
            fresh.tooltip_text = _("New Chat");
            fresh.clicked.connect (() => new_chat ());
            header.append (fresh);
            append (header);

            conv = new Box (Orientation.VERTICAL, 10);
            conv.add_css_class ("edit-agent-conv");
            conv.valign = Align.START;
            scroller = new ScrolledWindow ();
            scroller.vexpand = true;
            scroller.hscrollbar_policy = PolicyType.NEVER;
            scroller.child = conv;
            append (scroller);
            var adj = scroller.vadjustment;
            adj.value_changed.connect (() => {
                if (!settling) stick = adj.value >= adj.upper - adj.page_size - 24;
            });

            review = new Box (Orientation.VERTICAL, 6);
            review.add_css_class ("edit-agent-card");
            review.add_css_class ("review");
            review.margin_start = review.margin_end = 10;
            review.visible = false;
            append (review);

            var composer = new Box (Orientation.VERTICAL, 4);
            composer.add_css_class ("edit-agent-composer");
            input = new TextView ();
            input.wrap_mode = WrapMode.WORD_CHAR;
            input.add_css_class ("singularity-sourceview");
            input.top_margin = 4;
            input.left_margin = 4;
            input.right_margin = 4;
            input.height_request = 52;
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((val, code, state) => {
                if ((val == Gdk.Key.Return || val == Gdk.Key.KP_Enter) && (state & Gdk.ModifierType.SHIFT_MASK) == 0) {
                    send ();
                    return true;
                }
                return false;
            });
            input.add_controller (keys);
            composer.append (input);
            limits = new Label ("");
            limits.xalign = 0;
            limits.wrap = true;
            limits.add_css_class ("dim-label");
            limits.add_css_class ("caption");
            limits.margin_start = 4;
            limits.max_width_chars = 40;
            composer.append (limits);
            var row = new Box (Orientation.HORIZONTAL, 4);
            agent_btn = new MenuButton ();
            agent_btn.add_css_class ("flat");
            agent_btn.tooltip_text = _("Agent");
            var agent_pop = new Popover ();
            agent_pop.show.connect (() => fill_agents (agent_pop));
            agent_btn.popover = agent_pop;
            row.append (agent_btn);
            mode_btn = new MenuButton ();
            mode_btn.add_css_class ("flat");
            mode_btn.tooltip_text = _("Mode");
            var mode_pop = new Popover ();
            mode_pop.show.connect (() => fill_modes (mode_pop));
            mode_btn.popover = mode_pop;
            row.append (mode_btn);
            var spacer = new Box (Orientation.HORIZONTAL, 0);
            spacer.hexpand = true;
            row.append (spacer);
            send_btn = new Button.from_icon_name ("go-up-symbolic");
            send_btn.add_css_class ("suggested-action");
            send_btn.add_css_class ("edit-agent-send");
            send_btn.tooltip_text = _("Send");
            send_btn.clicked.connect (() => {
                if (session != null && session.busy) stop ();
                else send ();
            });
            row.append (send_btn);
            composer.append (row);
            append (composer);
        }

        public void focus_input () {
            input.grab_focus ();
        }

        private void sync_header () {
            Widget? c;
            while ((c = header_avatar.get_first_child ()) != null) header_avatar.remove (c);
            if (agent == null) {
                header_name.label = _("No agent available");
                return;
            }
            header_avatar.append (avatar (agent));
            header_name.label = agent.name;
            var box = new Box (Orientation.HORIZONTAL, 6);
            box.append (avatar (agent, true));
            var l = new Label (agent.name);
            box.append (l);
            box.append (new Image.from_icon_name ("pan-down-symbolic"));
            agent_btn.child = box;
            sync_status ();
        }

        private void sync_status () {
            bool busy = session != null && session.busy;
            bool running = session != null && session.running;
            string text;
            if (session != null) text = session.status;
            else if (agent != null && !AgentCatalog.get_default ().runnable (agent)) text = AgentCatalog.get_default ().requirement (agent);
            else text = mode.summary ();
            header_status.label = text;
            stop_btn.visible = busy || (running && mode == Mode.AUTOPILOT);
            send_btn.icon_name = busy ? "media-playback-stop-symbolic" : "go-up-symbolic";
            send_btn.tooltip_text = busy ? _("Stop") : _("Send");
        }

        private void sync_mode () {
            var box = new Box (Orientation.HORIZONTAL, 4);
            box.append (new Label (mode.label ()));
            box.append (new Image.from_icon_name ("pan-down-symbolic"));
            mode_btn.child = box;
            if (mode == Mode.AUTOPILOT) {
                limits.label = _("Autopilot works until done: project folder only, network only to the agent service, %d minute limit, restore point first, changes to review at the end.").printf (30);
                limits.visible = true;
            } else {
                limits.visible = false;
            }
            sync_status ();
        }

        private void fill_agents (Popover pop) {
            var box = new Box (Orientation.VERTICAL, 2);
            box.margin_start = box.margin_end = box.margin_top = box.margin_bottom = 4;
            var others = new Box (Orientation.VERTICAL, 2);
            foreach (var a in AgentCatalog.get_default ().all ()) {
                var btn = new Button ();
                btn.add_css_class ("flat");
                var r = new Box (Orientation.HORIZONTAL, 8);
                r.append (avatar (a, true));
                var texts = new Box (Orientation.VERTICAL, 0);
                var name = new Label (a.name);
                name.xalign = 0;
                texts.append (name);
                if (!AgentCatalog.get_default ().runnable (a)) {
                    var need = new Label (AgentCatalog.get_default ().requirement (a));
                    need.xalign = 0;
                    need.add_css_class ("dim-label");
                    need.add_css_class ("caption");
                    texts.append (need);
                    btn.sensitive = false;
                }
                r.append (texts);
                btn.child = r;
                var chosen = a;
                btn.clicked.connect (() => {
                    pop.popdown ();
                    if (agent != null && agent.id == chosen.id) return;
                    agent = chosen;
                    end_session ();
                    sync_header ();
                });
                if (a.featured || a.distribution.has_member ("local")) box.append (btn);
                else others.append (btn);
            }
            if (agent != null) {
                var keys = new Button.with_label (_("Sign In and API Key for %s").printf (agent.name));
                keys.add_css_class ("flat");
                keys.clicked.connect (() => {
                    pop.popdown ();
                    add_sign_in (session != null ? session.auth_methods : null, Singularity.Edit.Dsh.for_path (project_root ()) != null);
                });
                box.append (keys);
            }
            if (others.get_first_child () != null) {
                var more = new Expander (_("More agents from the ACP registry"));
                var sw = new ScrolledWindow ();
                sw.max_content_height = 280;
                sw.propagate_natural_height = true;
                sw.hscrollbar_policy = PolicyType.NEVER;
                sw.child = others;
                more.child = sw;
                box.append (more);
            }
            pop.child = box;
        }

        private void fill_modes (Popover pop) {
            var box = new Box (Orientation.VERTICAL, 2);
            box.margin_start = box.margin_end = box.margin_top = box.margin_bottom = 4;
            foreach (var m in new Mode[] { Mode.PLAN, Mode.ASK, Mode.AUTO_EDIT, Mode.AUTOPILOT }) {
                var btn = new Button ();
                btn.add_css_class ("flat");
                btn.add_css_class ("edit-agent-mode-row");
                if (m == mode) btn.add_css_class ("current");
                var texts = new Box (Orientation.VERTICAL, 0);
                var name = new Label (m.label ());
                name.xalign = 0;
                name.add_css_class ("heading");
                texts.append (name);
                var sum = new Label (m.summary ());
                sum.xalign = 0;
                sum.add_css_class ("dim-label");
                sum.add_css_class ("caption");
                texts.append (sum);
                btn.child = texts;
                var chosen = m;
                btn.clicked.connect (() => {
                    pop.popdown ();
                    bool restart = (chosen == Mode.AUTOPILOT) != (mode == Mode.AUTOPILOT);
                    mode = chosen;
                    if (restart) end_session ();
                    else if (session != null) session.change_mode (chosen);
                    sync_mode ();
                });
                box.append (btn);
            }
            pop.child = box;
        }

        private string project_root () {
            var r = workspace.get_project_root ();
            return r != null && r.get_path () != null ? r.get_path () : Environment.get_home_dir ();
        }

        public void send () {
            Gtk.TextIter s, e;
            input.buffer.get_bounds (out s, out e);
            string text = input.buffer.get_text (s, e, false).strip ();
            if (text == "" || agent == null) return;
            input.buffer.text = "";
            if (session == null || !session.running) {
                start_session.begin (text);
                return;
            }
            run_prompt (text);
        }

        private string? retry_prompt;
        private Widget? sign_in_card;

        private async void start_session (string first_prompt, string? auth_method = null) {
            retry_prompt = first_prompt;
            session = new AgentSession (agent, workspace, project_root (), mode);
            session.auth_method = auth_method;
            session.mcp = mcp;
            connect_session (session);
            sync_status ();
            add_note (mode == Mode.AUTOPILOT ? _("Creating a restore point and starting %s in Autopilot").printf (agent.name) : _("Starting %s").printf (agent.name));
            if (!yield session.start ()) return;
            drop_sign_in ();
            run_prompt (first_prompt);
        }

        private void run_prompt (string text) {
            var doc = workspace.get_active_document ();
            session.prompt.begin (text, doc);
            sync_status ();
        }

        private void connect_session (AgentSession s) {
            s.notify["status"].connect (() => {
                if (s == session) sync_status ();
            });
            s.notify["busy"].connect (() => {
                if (s == session) sync_status ();
            });
            s.text_chunk.connect ((role, text) => {
                if (s == session) add_text (role, text);
            });
            s.tool_added.connect ((call) => {
                if (s == session) add_tool (call);
            });
            s.plan_changed.connect ((entries) => {
                if (s == session) show_plan (entries);
            });
            s.permission_asked.connect ((req) => {
                if (s == session) add_permission (req);
            });
            s.changes_changed.connect (() => {
                if (s == session) sync_review ();
            });
            s.turn_finished.connect ((reason) => {
                if (s != session) return;
                last_role = null;
                sync_review ();
                sync_status ();
            });
            s.touched.connect ((path, line) => {
                if (s == session) on_touched (path, line);
            });
            s.ended.connect ((reason) => {
                if (s != session) return;
                add_note (reason);
                if (s.needs_auth) add_sign_in (s.auth_methods, s.runs_in_dsh);
                remove_flag ();
                flag = null;
                sync_review ();
                sync_status ();
            });
        }

        private void stop () {
            if (session == null) return;
            session.stop_turn ();
            if (mode == Mode.AUTOPILOT) session.end (_("Autopilot stopped"));
        }

        private void end_session () {
            if (session != null && session.running) session.end (_("Session closed"));
        }

        private void new_chat () {
            end_session ();
            session = null;
            Widget? c;
            while ((c = conv.get_first_child ()) != null) conv.remove (c);
            cards.remove_all ();
            plan_card = null;
            last_role = null;
            review.visible = false;
            remove_flag ();
            sync_status ();
        }

        private void scroll_down () {
            stick = true;
            foreach (uint delay in new uint[] { 30, 120, 300 }) {
                Timeout.add (delay, () => {
                    if (!stick) return Source.REMOVE;
                    var adj = scroller.vadjustment;
                    settling = true;
                    adj.value = adj.upper - adj.page_size;
                    settling = false;
                    return Source.REMOVE;
                });
            }
        }

        private void add_note (string text) {
            var l = new Label (text);
            l.xalign = 0;
            l.wrap = true;
            l.add_css_class ("dim-label");
            l.add_css_class ("caption");
            conv.append (l);
            last_role = null;
            scroll_down ();
        }

        private void add_text (string role, string text) {
            if (role == last_role && last_label != null && role != "user") {
                last_text.append (text);
                show_text (last_label, role, last_text.str);
                scroll_down ();
                return;
            }
            last_role = role;
            last_text.truncate ();
            last_text.append (role == "user" ? text : text.chug ());
            var l = new Label (null);
            show_text (l, role, last_text.str);
            l.xalign = 0;
            l.wrap = true;
            l.wrap_mode = Pango.WrapMode.WORD_CHAR;
            l.selectable = role != "user";
            l.can_focus = false;
            if (role == "user") {
                l.add_css_class ("edit-agent-user");
                l.halign = Align.END;
                l.max_width_chars = 34;
            } else if (role == "thought") {
                l.add_css_class ("edit-agent-thought");
            } else if (role == "error") {
                l.add_css_class ("edit-agent-fail");
            }
            last_label = l;
            conv.append (l);
            scroll_down ();
        }

        private void show_text (Label l, string role, string text) {
            if (role == "user" || role == "error") {
                l.use_markup = false;
                l.label = text;
                return;
            }
            string markup = AgentMarkdown.to_pango (text);
            try {
                Pango.AttrList attrs;
                string plain;
                unichar accel;
                var links = new Regex ("</?a( [^>]*)?>");
                Pango.parse_markup (links.replace (markup, -1, 0, ""), -1, 0, out attrs, out plain, out accel);
                l.set_markup (markup);
            } catch (Error e) {
                l.use_markup = false;
                l.label = text;
            }
        }

        private void add_tool (ToolCall call) {
            last_role = null;
            if (cards.contains (call.id)) return;
            var card = new ToolCard (call, session);
            cards.insert (call.id, card);
            conv.append (card);
            scroll_down ();
        }

        private void show_plan (Json.Array entries) {
            if (plan_card == null) {
                plan_card = new Box (Orientation.VERTICAL, 4);
                plan_card.add_css_class ("edit-agent-card");
                conv.append (plan_card);
            }
            Widget? c;
            while ((c = plan_card.get_first_child ()) != null) plan_card.remove (c);
            var title = new Label (_("Plan"));
            title.xalign = 0;
            title.add_css_class ("heading");
            plan_card.append (title);
            for (uint i = 0; i < entries.get_length (); i++) {
                var e = entries.get_object_element (i);
                string st = e.get_string_member ("status");
                var row = new Box (Orientation.HORIZONTAL, 6);
                var icon = new Image.from_icon_name (st == "completed" ? "object-select-symbolic" : (st == "in_progress" ? "media-playback-start-symbolic" : "radio-symbolic"));
                if (st == "completed") icon.add_css_class ("edit-agent-ok");
                row.append (icon);
                var l = new Label (e.get_string_member ("content"));
                l.xalign = 0;
                l.wrap = true;
                l.hexpand = true;
                if (st == "completed") l.add_css_class ("dim-label");
                row.append (l);
                plan_card.append (row);
            }
            last_role = null;
            scroll_down ();
        }

        private void add_permission (PermissionRequest req) {
            last_role = null;
            var card = new Box (Orientation.VERTICAL, 6);
            card.add_css_class ("edit-agent-card");
            card.add_css_class ("permission");
            var title = new Label (null);
            title.xalign = 0;
            title.wrap = true;
            title.set_markup (_("<b>%s</b> wants to: %s").printf (Markup.escape_text (agent.name), Markup.escape_text (req.call.title)));
            card.append (title);
            var row = new Box (Orientation.HORIZONTAL, 6);
            for (uint i = 0; i < req.options.get_length (); i++) {
                var o = req.options.get_object_element (i);
                var b = new Button.with_label (o.get_string_member ("name"));
                b.add_css_class ("pill");
                string kind = o.get_string_member ("kind");
                if (kind == "allow_once") b.add_css_class ("suggested-action");
                string id = o.get_string_member ("optionId");
                b.clicked.connect (() => req.choose (id));
                row.append (b);
            }
            card.append (row);
            req.settled.connect (() => {
                scroll_down ();
                card.remove (row);
                var done = new Label (_("Answered"));
                done.xalign = 0;
                done.add_css_class ("dim-label");
                done.add_css_class ("caption");
                card.append (done);
            });
            conv.append (card);
            scroll_down ();
            follow_call (req.call);
        }

        private void retry (string? auth_method = null) {
            if (agent == null) return;
            start_session.begin (retry_prompt ?? "", auth_method);
        }

        private void open_terminal_login (string[] argv, bool in_dsh) {
            var info = new DesktopAppInfo ("dev.sinty.leafs.desktop");
            if (info == null) {
                workspace.notify_user (_("Install Leafs to sign in from a terminal"));
                return;
            }
            string[] cmd = argv;
            var dsh = in_dsh ? Singularity.Edit.Dsh.for_path (project_root ()) : null;
            if (dsh != null) cmd = dsh.wrap (argv, project_root ());
            string[] full = { info.get_executable (), "--working-directory=" + Environment.get_home_dir (), "-e" };
            foreach (var a in cmd) full += a;
            try {
                new SubprocessLauncher (SubprocessFlags.NONE).spawnv (full);
            } catch (Error e) {
                workspace.notify_user (e.message);
            }
        }

        private static string[]? terminal_auth (Json.Object method) {
            if (!method.has_member ("_meta") || method.get_member ("_meta").get_node_type () != Json.NodeType.OBJECT) return null;
            var meta = method.get_object_member ("_meta");
            if (!meta.has_member ("terminal-auth") || meta.get_member ("terminal-auth").get_node_type () != Json.NodeType.OBJECT) return null;
            var t = meta.get_object_member ("terminal-auth");
            if (!t.has_member ("command")) return null;
            string[] argv = { t.get_string_member ("command") };
            if (t.has_member ("args")) {
                var a = t.get_array_member ("args");
                for (uint i = 0; i < a.get_length (); i++) argv += a.get_string_element (i);
            }
            return argv;
        }

        private void drop_sign_in () {
            if (sign_in_card != null && sign_in_card.get_parent () == conv) conv.remove (sign_in_card);
            sign_in_card = null;
        }

        private void add_sign_in (Json.Array? methods, bool in_dsh) {
            drop_sign_in ();
            last_role = null;
            var chosen = agent;
            var card = new Box (Orientation.VERTICAL, 8);
            card.add_css_class ("edit-agent-card");
            card.add_css_class ("permission");
            var title = new Label (null);
            title.xalign = 0;
            title.wrap = true;
            title.set_markup (_("<b>Sign in to %s</b>").printf (Markup.escape_text (chosen.name)));
            card.append (title);
            var info = new Label (in_dsh
                ? _("It runs in the developer shell, so it uses the account you signed in to there. Sign in, or give it an API key that Edit keeps in your keyring.")
                : _("Sign in with your account, or give it an API key that Edit keeps in your keyring."));
            info.xalign = 0;
            info.wrap = true;
            info.add_css_class ("caption");
            card.append (info);
            if (methods != null) {
                for (uint i = 0; i < methods.get_length (); i++) {
                    var m = methods.get_object_element (i);
                    if (!m.has_member ("id")) continue;
                    string id = m.get_string_member ("id");
                    string name = m.has_member ("name") ? m.get_string_member ("name") : id;
                    var b = new Button.with_label (name);
                    b.add_css_class ("pill");
                    b.halign = Align.START;
                    if (m.has_member ("description") && m.get_member ("description").get_node_type () == Json.NodeType.VALUE)
                        b.tooltip_text = m.get_string_member ("description");
                    var argv = terminal_auth (m);
                    b.clicked.connect (() => {
                        if (argv != null) {
                            open_terminal_login (argv, in_dsh);
                            add_note (_("Finish signing in in the terminal, then choose Try Again"));
                        } else {
                            retry (id);
                        }
                    });
                    card.append (b);
                }
            }
            var key_title = new Label (_("API key"));
            key_title.xalign = 0;
            key_title.add_css_class ("heading");
            card.append (key_title);
            var variable = new Entry ();
            variable.placeholder_text = _("Variable name, for example ANTHROPIC_API_KEY");
            variable.text = AgentKeys.default_variable (chosen);
            card.append (variable);
            var value = new PasswordEntry ();
            value.show_peek_icon = true;
            value.placeholder_text = _("Paste the key or token");
            card.append (value);
            var row = new Box (Orientation.HORIZONTAL, 6);
            var save = new Button.with_label (_("Save and Try Again"));
            save.add_css_class ("pill");
            save.add_css_class ("suggested-action");
            save.clicked.connect (() => {
                string v = variable.text.strip ();
                if (!AgentKeys.valid_variable (v) || value.text == "") {
                    add_note (_("Enter a variable name made of letters, digits and underscores, and the key"));
                    return;
                }
                AgentKeys.store.begin (chosen, v, value.text, (o, r) => {
                    try {
                        AgentKeys.store.end (r);
                        value.text = "";
                        add_note (_("The key is saved in your keyring"));
                        retry ();
                    } catch (Error e) {
                        add_note (_("Cannot save the key: %s").printf (e.message));
                    }
                });
            });
            row.append (save);
            var again = new Button.with_label (_("Try Again"));
            again.add_css_class ("pill");
            again.clicked.connect (() => retry ());
            row.append (again);
            card.append (row);
            var forget = new Button.with_label (_("Forget Saved Key"));
            forget.add_css_class ("flat");
            forget.halign = Align.START;
            forget.visible = false;
            AgentKeys.lookup.begin (chosen.id, (o, r) => forget.visible = AgentKeys.lookup.end (r) != null);
            forget.clicked.connect (() => {
                AgentKeys.forget.begin (chosen.id, (o, r) => {
                    try {
                        AgentKeys.forget.end (r);
                        forget.visible = false;
                        add_note (_("The saved key was removed"));
                    } catch (Error e) {
                        add_note (e.message);
                    }
                });
            });
            card.append (forget);
            conv.append (card);
            sign_in_card = card;
            scroll_down ();
        }

        private void follow_call (ToolCall call) {
            for (uint i = 0; i < call.locations.get_length (); i++) {
                var l = call.locations.get_object_element (i);
                if (l.has_member ("path")) {
                    on_touched (l.get_string_member ("path"), l.has_member ("line") ? (int) l.get_int_member ("line") - 1 : 0);
                    return;
                }
            }
        }

        private void sync_review () {
            Widget? c;
            while ((c = review.get_first_child ()) != null) review.remove (c);
            bool show = session != null && session.changes.size () > 0 && (mode != Mode.AUTOPILOT || !session.busy);
            bool restore = session != null && session.has_restore_point && !session.busy;
            review.visible = show || restore;
            scroll_down ();
            if (!review.visible) return;
            var title = new Label (null);
            title.xalign = 0;
            title.set_markup ("<b>%s</b>".printf (ngettext ("%u file changed", "%u files changed", session.changes.size ()).printf (session.changes.size ())));
            review.append (title);
            foreach (var path in session.changes.get_keys ()) {
                var ch = session.changes.lookup (path);
                var row = new Box (Orientation.HORIZONTAL, 6);
                var open = new Button ();
                open.add_css_class ("flat");
                open.hexpand = true;
                var name = new Label (File.new_for_path (path).get_basename ());
                name.xalign = 0;
                name.ellipsize = Pango.EllipsizeMode.START;
                open.child = name;
                string p = path;
                open.clicked.connect (() => workspace.open_file (File.new_for_path (p)));
                row.append (open);
                var add = new Label ("+%d".printf (ch.added));
                add.add_css_class ("edit-agent-add");
                row.append (add);
                var del = new Label ("−%d".printf (ch.removed));
                del.add_css_class ("edit-agent-del");
                row.append (del);
                var undo = new Button.from_icon_name ("edit-undo-symbolic");
                undo.add_css_class ("flat");
                undo.tooltip_text = _("Undo this file");
                undo.clicked.connect (() => session.revert (p));
                row.append (undo);
                var keep = new Button.from_icon_name ("object-select-symbolic");
                keep.add_css_class ("flat");
                keep.tooltip_text = _("Keep");
                keep.clicked.connect (() => session.accept (p));
                row.append (keep);
                review.append (row);
            }
            if (restore) {
                var r = new Button.with_label (_("Restore the project to before Autopilot"));
                r.add_css_class ("flat");
                r.halign = Align.START;
                r.clicked.connect (() => session.restore_project.begin ());
                review.append (r);
            }
            var actions = new Box (Orientation.HORIZONTAL, 6);
            actions.halign = Align.END;
            if (show) {
                var undo_all = new Button.with_label (_("Undo All"));
                undo_all.add_css_class ("pill");
                undo_all.clicked.connect (() => session.revert_all ());
                actions.append (undo_all);
                var keep_all = new Button.with_label (_("Keep All"));
                keep_all.add_css_class ("pill");
                keep_all.add_css_class ("suggested-action");
                keep_all.clicked.connect (() => session.accept_all ());
                actions.append (keep_all);
            }
            review.append (actions);
        }

        private void on_touched (string path, int line) {
            if (follow_btn.active) workspace.open_file (File.new_for_path (path), line, 0);
            place_flag (path, line);
        }

        private void remove_flag () {
            if (flag != null && flag_view != null && flag.get_parent () == flag_view) flag_view.remove (flag);
            flag_view = null;
        }

        private void place_flag (string path, int line) {
            var f = File.new_for_path (path);
            Document? doc = null;
            foreach (var d in workspace.documents ()) if (d.get_file () != null && d.get_file ().equal (f)) doc = d;
            if (doc == null || agent == null) {
                remove_flag ();
                return;
            }
            var view = doc.get_view ();
            var buffer = doc.get_buffer ();
            Gtk.TextIter it;
            buffer.get_iter_at_line (out it, int.min (int.max (0, line), buffer.get_line_count () - 1));
            if (!it.ends_line ()) it.forward_to_line_end ();
            Gdk.Rectangle r;
            view.get_iter_location (it, out r);
            if (flag == null) {
                var l = new Label (agent.name);
                l.add_css_class ("edit-agent-flag");
                l.can_target = false;
                flag = l;
            }
            var label = (Label) flag;
            label.label = agent.name;
            var p = new CssProvider ();
            p.load_from_string ("label { background-color: %s; }".printf (agent_color (agent.id)));
            label.get_style_context ().add_provider (p, STYLE_PROVIDER_PRIORITY_USER + 4);
            if (flag_view == view && flag.get_parent () == view) {
                view.move_overlay (flag, r.x + 16, r.y);
                return;
            }
            remove_flag ();
            view.add_overlay (flag, r.x + 16, r.y);
            flag_view = view;
        }
    }

    public class ToolCard : Box {
        private ToolCall call;
        private unowned AgentSession session;
        private Image status_icon;
        private Label title;
        private Expander details;
        private Box body;

        public ToolCard (ToolCall call, AgentSession session) {
            Object (orientation: Orientation.VERTICAL, spacing: 4);
            this.call = call;
            this.session = session;
            add_css_class ("edit-agent-card");
            var head = new Box (Orientation.HORIZONTAL, 8);
            var kind = new Image.from_icon_name (kind_icon (call.kind));
            head.append (kind);
            title = new Label ("");
            title.xalign = 0;
            title.hexpand = true;
            title.ellipsize = Pango.EllipsizeMode.END;
            head.append (title);
            status_icon = new Image ();
            head.append (status_icon);
            append (head);
            details = new Expander (_("Details"));
            details.add_css_class ("caption");
            body = new Box (Orientation.VERTICAL, 4);
            details.child = body;
            details.visible = false;
            append (details);
            call.changed.connect (() => refresh ());
            refresh ();
        }

        private static string kind_icon (string kind) {
            switch (kind) {
                case "read": return "document-open-symbolic";
                case "edit": return "document-edit-symbolic";
                case "delete": return "user-trash-symbolic";
                case "move": return "folder-symbolic";
                case "search": return "system-search-symbolic";
                case "execute": return "utilities-terminal-symbolic";
                case "fetch": return "network-transmit-receive-symbolic";
                case "think": return "dialog-information-symbolic";
                default: return "applications-system-symbolic";
            }
        }

        private void refresh () {
            title.label = call.title;
            status_icon.remove_css_class ("edit-agent-ok");
            status_icon.remove_css_class ("edit-agent-fail");
            switch (call.status) {
                case "completed":
                    status_icon.icon_name = "object-select-symbolic";
                    status_icon.add_css_class ("edit-agent-ok");
                    break;
                case "failed":
                    status_icon.icon_name = "dialog-error-symbolic";
                    status_icon.add_css_class ("edit-agent-fail");
                    break;
                case "in_progress":
                    status_icon.icon_name = "content-loading-symbolic";
                    break;
                default:
                    status_icon.icon_name = "radio-symbolic";
                    break;
            }
            Widget? c;
            while ((c = body.get_first_child ()) != null) body.remove (c);
            bool any = false;
            for (uint i = 0; i < call.content.get_length (); i++) {
                var item = call.content.get_object_element (i);
                string type = item.get_string_member ("type");
                if (type == "diff") {
                    var dv = new Singularity.Git.DiffView ();
                    string old_text = item.has_member ("oldText") && item.get_member ("oldText").get_node_type () == Json.NodeType.VALUE ? item.get_string_member ("oldText") : "";
                    string new_text = item.get_string_member ("newText");
                    dv.show_diff (unified (item.get_string_member ("path"), old_text, new_text));
                    dv.height_request = 160;
                    body.append (dv);
                    any = true;
                } else if (type == "terminal") {
                    var l = new Label (session.terminal_output (item.get_string_member ("terminalId")));
                    l.xalign = 0;
                    l.wrap = true;
                    l.selectable = true;
                    l.add_css_class ("monospace");
                    l.add_css_class ("caption");
                    body.append (l);
                    any = true;
                } else if (type == "content" && item.has_member ("content")) {
                    var cnt = item.get_object_member ("content");
                    if (cnt.has_member ("text")) {
                        var l = new Label (cnt.get_string_member ("text"));
                        l.xalign = 0;
                        l.wrap = true;
                        l.selectable = true;
                        l.add_css_class ("caption");
                        body.append (l);
                        any = true;
                    }
                }
            }
            details.visible = any;
        }

        private static string unified (string path, string a, string b) {
            var sb = new StringBuilder ();
            sb.append ("--- %s\n+++ %s\n".printf (Path.get_basename (path), Path.get_basename (path)));
            var lines = Singularity.Git.LineDiff.split_lines (b);
            foreach (var ch in Singularity.Git.LineDiff.compare (a, b)) {
                sb.append ("@@ -%d +%d @@\n".printf (ch.old_start + 1, ch.start + 1));
                foreach (var o in ch.old_lines) sb.append ("-" + o + "\n");
                for (int i = ch.start; i < ch.start + ch.count && i < lines.length; i++) sb.append ("+" + lines[i] + "\n");
            }
            return sb.str;
        }
    }
}
