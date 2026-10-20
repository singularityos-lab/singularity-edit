using Gtk;
using GLib;
using Singularity.Edit;
using Singularity.Widgets;

namespace EditTerminal {

    public const string LEAFS = "dev.sinty.leafs";

    public static bool leafs_installed () {
        return new DesktopAppInfo (LEAFS + ".desktop") != null;
    }

    public class Plugin : Object, Singularity.Edit.Plugin {
        private Host? host;
        private GenericArray<TerminalWorkspace> attached = new GenericArray<TerminalWorkspace> ();

        public void activate (Host host) {
            this.host = host;
            foreach (var ws in host.workspaces ()) attach (ws);
            host.workspace_added.connect (attach);
            host.workspace_removed.connect (detach);
        }

        public void deactivate () {
            if (host != null) {
                host.workspace_added.disconnect (attach);
                host.workspace_removed.disconnect (detach);
            }
            foreach (var t in attached.data) t.dispose_all ();
            attached = new GenericArray<TerminalWorkspace> ();
            host = null;
        }

        private void attach (Workspace ws) {
            attached.add (new TerminalWorkspace (ws));
        }

        private void detach (Workspace ws) {
            for (uint i = 0; i < attached.length; i++) {
                if (attached[i].workspace != ws) continue;
                attached[i].dispose_all ();
                attached.remove_index (i);
                return;
            }
        }
    }

    public class TerminalWorkspace : Object {
        public unowned Workspace workspace;
        private Box root;
        private Vte.Terminal? terminal;
        private CommandPaletteItem toggle_cmd;
        private CommandPaletteItem leafs_cmd;
        private CommandPaletteItem? devshell_cmd;
        private SimpleAction toggle_action;
        private GLib.Settings? leafs_settings;
        private bool focus_pending;

        public TerminalWorkspace (Workspace ws) {
            workspace = ws;
            var source = SettingsSchemaSource.get_default ();
            if (source != null && source.lookup (LEAFS, true) != null) leafs_settings = new GLib.Settings (LEAFS);
            root = new Box (Orientation.VERTICAL, 0);
            root.add_css_class ("edit-terminal-view");
            root.map.connect (() => Idle.add (() => {
                ensure_terminal ();
                return Source.REMOVE;
            }));
            ws.get_workbench ().register_view (new WorkbenchView ("terminal", _("Terminal"), WorkbenchRegion.PANEL, root, 5));
            toggle_cmd = new CommandPaletteItem ("utilities-terminal-symbolic", _("Terminal: Show or Hide"), null, "Ctrl+`", _("Terminal"), () => toggle ());
            leafs_cmd = new CommandPaletteItem ("dev.sinty.leafs", _("Terminal: Open Project in Leafs"), null, null, _("Terminal"), () => open_in_leafs ());
            ws.get_workbench ().register_command (toggle_cmd);
            ws.get_workbench ().register_command (leafs_cmd);
            if (on_sinty () && Environment.find_program_in_path ("dsh") != null) {
                devshell_cmd = new CommandPaletteItem ("utilities-terminal-symbolic", _("Terminal: Open Project in Dev Shell"), null, null, _("Terminal"), () => open_dev_shell ());
                ws.get_workbench ().register_command (devshell_cmd);
            }
            toggle_action = new SimpleAction ("terminal-toggle", null);
            toggle_action.activate.connect (() => toggle ());
            var map = ws.get_toplevel () as ActionMap;
            if (map != null) map.add_action (toggle_action);
            var app = ws.get_toplevel ().application;
            if (app != null) app.set_accels_for_action ("win.terminal-toggle", { "<Control>grave" });
        }

        public void dispose_all () {
            var wb = workspace.get_workbench ();
            wb.unregister_view ("terminal");
            wb.unregister_command (toggle_cmd);
            wb.unregister_command (leafs_cmd);
            if (devshell_cmd != null) wb.unregister_command (devshell_cmd);
            var map = workspace.get_toplevel () as ActionMap;
            if (map != null) map.remove_action ("terminal-toggle");
        }

        private void toggle () {
            var wb = workspace.get_workbench ();
            if (wb.is_view_visible ("terminal")) {
                wb.hide_region (WorkbenchRegion.PANEL);
                var doc = workspace.get_active_document ();
                if (doc != null) doc.get_view ().grab_focus ();
                return;
            }
            focus_pending = true;
            wb.show_view ("terminal");
            Idle.add (() => {
                if (terminal != null && focus_pending) {
                    focus_pending = false;
                    terminal.grab_focus ();
                }
                return Source.REMOVE;
            });
        }

        private string project_dir () {
            var root_file = workspace.get_project_root ();
            return root_file != null && root_file.get_path () != null ? root_file.get_path () : Environment.get_home_dir ();
        }

        private void ensure_terminal () {
            if (root.get_first_child () != null) return;
            if (!leafs_installed ()) {
                build_missing ();
                return;
            }
            var bar = new Box (Orientation.HORIZONTAL, 4);
            bar.halign = Align.END;
            bar.margin_end = 8;
            var restart = new Button.from_icon_name ("view-refresh-symbolic");
            restart.add_css_class ("flat");
            restart.tooltip_text = _("New Shell");
            restart.clicked.connect (() => spawn ());
            bar.append (restart);
            var leafs = new Button.from_icon_name ("dev.sinty.leafs");
            leafs.add_css_class ("flat");
            leafs.tooltip_text = _("Open in Leafs");
            leafs.clicked.connect (() => open_in_leafs ());
            bar.append (leafs);
            terminal = new Vte.Terminal ();
            terminal.hexpand = true;
            terminal.vexpand = true;
            terminal.set_size (80, 8);
            terminal.add_css_class ("edit-terminal");
            apply_theme ();
            if (leafs_settings != null) leafs_settings.changed.connect (() => apply_theme ());
            var keys = new EventControllerKey ();
            keys.key_pressed.connect ((val, code, state) => {
                bool cs = (state & Gdk.ModifierType.CONTROL_MASK) != 0 && (state & Gdk.ModifierType.SHIFT_MASK) != 0;
                if (cs && (val == Gdk.Key.C || val == Gdk.Key.c)) {
                    terminal.copy_clipboard_format (Vte.Format.TEXT);
                    return true;
                }
                if (cs && (val == Gdk.Key.V || val == Gdk.Key.v)) {
                    terminal.paste_clipboard ();
                    return true;
                }
                return false;
            });
            terminal.add_controller (keys);
            var overlay = new Overlay ();
            overlay.child = terminal;
            bar.valign = Align.START;
            overlay.add_overlay (bar);
            root.append (overlay);
            terminal.child_exited.connect (() => spawn ());
            spawn ();
            if (focus_pending) {
                focus_pending = false;
                terminal.grab_focus ();
            }
        }

        private void build_missing () {
            var box = new Box (Orientation.VERTICAL, 10);
            box.valign = Align.CENTER;
            box.halign = Align.CENTER;
            var icon = new Image.from_icon_name ("dev.sinty.leafs");
            icon.pixel_size = 48;
            box.append (icon);
            var label = new Label (_("The terminal in Edit comes from Leafs. Install Leafs to use it here."));
            label.wrap = true;
            label.justify = Justification.CENTER;
            label.max_width_chars = 50;
            box.append (label);
            var get = new Button.with_label (_("Get Leafs"));
            get.add_css_class ("suggested-action");
            get.add_css_class ("pill");
            get.halign = Align.CENTER;
            get.clicked.connect (() => {
                try {
                    if (Environment.find_program_in_path ("singularity-store") != null)
                        Process.spawn_command_line_async ("singularity-store --search Leafs");
                    else
                        workspace.notify_user (_("Install Leafs to use the terminal"));
                } catch (Error e) {
                    workspace.notify_user (e.message);
                }
            });
            box.append (get);
            root.append (box);
        }

        private static string login_shell () {
            unowned Posix.Passwd? pw = Posix.getpwuid (Posix.getuid ());
            if (pw != null && pw.pw_shell != null && FileUtils.test (pw.pw_shell, FileTest.IS_EXECUTABLE)) return pw.pw_shell;
            var env = Environment.get_variable ("SHELL");
            return env != null ? env : "/bin/sh";
        }

        private void spawn () {
            if (terminal == null) return;
            terminal.reset (true, true);
            terminal.spawn_async (Vte.PtyFlags.DEFAULT, project_dir (), { login_shell () }, null,
                (SpawnFlags) 0, null, -1, null, (t, pid, err) => {
                    if (err != null) workspace.notify_user (err.message);
                });
        }

        private void apply_theme () {
            if (terminal == null) return;
            string family = "Monospace";
            int size = 11;
            string scheme = "onedark";
            int scrollback = 10000;
            if (leafs_settings != null) {
                family = leafs_settings.get_string ("font-family");
                size = leafs_settings.get_int ("font-size");
                scheme = leafs_settings.get_string ("color-scheme");
                scrollback = leafs_settings.get_int ("scrollback-lines");
            }
            var font = new Pango.FontDescription ();
            font.set_family (family);
            font.set_size (size * Pango.SCALE);
            terminal.set_font (font);
            terminal.set_scrollback_lines (scrollback);
            var theme = Singularity.Core.TerminalThemes.get_by_id (scheme) ?? Singularity.Core.TerminalThemes.get_by_id ("onedark");
            if (theme == null) return;
            Gdk.RGBA bg = Gdk.RGBA (), fg = Gdk.RGBA ();
            bg.parse (theme.background);
            fg.parse (theme.foreground);
            var palette = new Gdk.RGBA[16];
            for (int i = 0; i < 16; i++) {
                palette[i] = Gdk.RGBA ();
                palette[i].parse (theme.palette[i]);
            }
            terminal.set_colors (fg, bg, palette);
        }

        private static bool on_sinty () {
            try {
                string text;
                FileUtils.get_contents ("/etc/os-release", out text);
                foreach (var line in text.split ("\n")) if (line.strip () == "ID=sinty") return true;
            } catch (Error e) {
            }
            return false;
        }

        private void open_dev_shell () {
            if (!leafs_installed ()) {
                workspace.notify_user (_("Install Leafs to open the Dev Shell"));
                return;
            }
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.NONE);
                launcher.set_cwd (project_dir ());
                var info = new DesktopAppInfo (LEAFS + ".desktop");
                launcher.spawnv ({ info.get_executable (), "--working-directory=" + project_dir (), "-e", "dsh" });
            } catch (Error e) {
                workspace.notify_user (e.message);
            }
        }

        private void open_in_leafs () {
            if (!leafs_installed ()) {
                workspace.notify_user (_("Install Leafs to open a terminal"));
                return;
            }
            try {
                var launcher = new SubprocessLauncher (SubprocessFlags.NONE);
                launcher.set_cwd (project_dir ());
                var info = new DesktopAppInfo (LEAFS + ".desktop");
                string exec = info.get_executable ();
                launcher.spawnv ({ exec, "--working-directory=" + project_dir () });
            } catch (Error e) {
                workspace.notify_user (e.message);
            }
        }
    }
}

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Edit.Plugin), typeof (EditTerminal.Plugin));
}
