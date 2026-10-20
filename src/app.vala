using Gtk;
using GLib;
using Singularity.Edit;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // =========================================================================
    // EditApp - Singularity.Application subclass
    // =========================================================================
    public class EditApp : Singularity.Application, Singularity.Edit.Host {
        private weak EditWindow? edit_win;
        private GLib.Settings? settings;
        private GLib.Settings? desktop_settings;

        private bool pending_new_file = false;
        private AppPluginHost? plugin_host;
        private uint collab_bus_id = 0;

        public override bool dbus_register (DBusConnection connection, string object_path) throws Error {
            if (!base.dbus_register (connection, object_path)) return false;
            collab_bus_id = connection.register_object ("/dev/sinty/edit/Collab", new CodeCollabBus (this));
            return true;
        }

        public override void dbus_unregister (DBusConnection connection, string object_path) {
            if (collab_bus_id != 0) connection.unregister_object (collab_bus_id);
            collab_bus_id = 0;
            base.dbus_unregister (connection, object_path);
        }

        public Gtk.Application get_host_application () { return this; }

        public Singularity.Edit.Workspace[] workspaces () {
            Singularity.Edit.Workspace[] out_ = {};
            foreach (var w in get_windows ()) {
                var ew = w as EditWindow;
                if (ew != null && ew.workspace_ready) out_ += ew;
            }
            return out_;
        }

        private EditorTab? find_tab (GLib.File file) {
            foreach (var w in get_windows ()) {
                var ew = w as EditWindow;
                if (ew == null) continue;
                foreach (var d in ew.documents ()) {
                    var t = d as EditorTab;
                    if (t != null && t.file != null && t.file.equal (file)) return t;
                }
            }
            return null;
        }

        private void apply_workspace_edit (Json.Object edit, bool utf8) {
            var map = LspEdits.by_uri (edit);
            foreach (var uri in map.get_keys ()) {
                var file = GLib.File.new_for_uri (uri);
                var tab = find_tab (file);
                if (tab == null) {
                    var win = active_edit_window ();
                    if (win == null) continue;
                    win.open_file (file);
                    tab = find_tab (file);
                }
                if (tab != null) LspEdits.apply (tab.buffer, map.lookup (uri), utf8);
            }
        }

        internal void announce_workspace (EditWindow w) {
            workspace_added (w);
        }

        private void setup_snippets () {
            var manager = GtkSource.SnippetManager.get_default ();
            string[] path = manager.search_path;
            foreach (var dir in Environment.get_system_data_dirs ()) {
                var candidate = Path.build_filename (dir, "singularity-edit", "snippets");
                if (FileUtils.test (candidate, FileTest.IS_DIR) && !(candidate in path)) path += candidate;
            }
            var user = Path.build_filename (Environment.get_user_data_dir (), "singularity-edit", "snippets");
            if (!(user in path)) path += user;
            manager.search_path = path;
        }

        private void setup_plugins () {
            window_removed.connect ((w) => {
                var ws = w as Singularity.Edit.Workspace;
                if (ws != null) workspace_removed (ws);
            });
            plugin_host = new AppPluginHost ("dev.sinty.edit", "edit", AppPluginHost.desktop_settings ());
            plugin_host.add_extension_type (typeof (Singularity.Edit.Plugin));
            plugin_host.extension_added.connect ((info, ext) => ((Singularity.Edit.Plugin) ext).activate (this));
            plugin_host.extension_removed.connect ((info, ext) => ((Singularity.Edit.Plugin) ext).deactivate ());
            plugin_host.load ();
        }

        public EditApp () {
            Object (application_id: "dev.sinty.edit",
                    flags: ApplicationFlags.HANDLES_OPEN);
            add_main_option ("new-document", 0, OptionFlags.NONE, OptionArg.NONE,
                             _("Open a new empty document"), null);
        }

        protected override int handle_local_options (VariantDict options) {
            if (!options.contains ("new-document")) return -1;
            try {
                register (null);
            } catch (Error e) {
                return -1;
            }
            if (get_is_remote ()) {
                activate ();
                activate_action ("new-file", null);
                return 0;
            }
            pending_new_file = true;
            return -1;
        }

        protected override void startup () {
            base.startup ();
            setup_styles ();
            setup_snippets ();
            settings = load_settings ();
            setup_actions ();
            setup_accels ();
            set_menubar (build_app_menu ());
            setup_plugins ();
            LspManager.get_default ().workspace_edit.connect (apply_workspace_edit);
            DebugManager.get_default ().session_changed.connect (() => {
                bool debugging = DebugManager.get_default ().session != null;
                set_accels_for_action ("app.fullscreen", debugging ? new string[0] : new string[] { "F11" });
                set_accels_for_action ("app.debug-step-into", debugging ? new string[] { "F11" } : new string[0]);
            });

            // Re-apply colour scheme when accent or dark-mode changes
            desktop_settings = Singularity.Core.safe_settings ("dev.sinty.desktop");
            if (desktop_settings != null) {
                desktop_settings.changed["accent-color"].connect ((_k) => {
                    if (settings != null && settings.get_string ("color-scheme") == "auto")
                        refresh_all_windows ();
                });
                desktop_settings.changed["custom-accent-color"].connect ((_k) => {
                    if (settings != null && settings.get_string ("color-scheme") == "auto")
                        refresh_all_windows ();
                });
                desktop_settings.changed["dark-mode"].connect ((_k) => {
                    if (settings != null && settings.get_string ("color-scheme") == "auto")
                        refresh_all_windows ();
                });
            }
        }

        private GLib.Menu build_app_menu () {
            var menu = new GLib.Menu ();

            var file = new GLib.Menu ();
            var f1 = new GLib.Menu ();
            f1.append (_("New File"), "app.new-file");
            f1.append (_("Open…"), "app.open");
            f1.append (_("Open Folder…"), "app.open-folder");
            f1.append (_("Open from Online Account…"), "app.open-online");
            file.append_section (null, f1);
            var f2 = new GLib.Menu ();
            f2.append (_("Save"), "app.save");
            f2.append (_("Save As…"), "app.save-as");
            f2.append (_("Save to Online Account…"), "app.save-online");
            f2.append (_("Share…"), "app.share");
            f2.append (_("Revert"), "app.revert");
            file.append_section (null, f2);
            var f3 = new GLib.Menu ();
            f3.append (_("Close Tab"), "app.close-tab");
            f3.append (_("Close Other Tabs"), "app.close-other-tabs");
            f3.append (_("Close All Tabs"), "app.close-all-tabs");
            file.append_section (null, f3);
            var f4 = new GLib.Menu ();
            f4.append (_("Close Window"), "win.close");
            f4.append (_("Quit"), "app.quit");
            file.append_section (null, f4);
            menu.append_submenu (_("File"), file);

            var edit = new GLib.Menu ();
            var e1 = new GLib.Menu ();
            e1.append (_("Undo"), "app.undo");
            e1.append (_("Redo"), "app.redo");
            edit.append_section (null, e1);
            var e2 = new GLib.Menu ();
            e2.append (_("Cut"), "app.cut");
            e2.append (_("Copy"), "app.copy");
            e2.append (_("Paste"), "app.paste");
            e2.append (_("Select All"), "app.select-all");
            edit.append_section (null, e2);
            var e3 = new GLib.Menu ();
            e3.append (_("Find"), "app.find");
            e3.append (_("Find and Replace"), "app.find-replace");
            e3.append (_("Go to Line…"), "app.goto-line");
            edit.append_section (null, e3);
            var e4 = new GLib.Menu ();
            e4.append (_("Duplicate Line"), "app.duplicate-line");
            e4.append (_("Delete Line"), "app.delete-line");
            e4.append (_("Move Line Up"), "app.move-line-up");
            e4.append (_("Move Line Down"), "app.move-line-down");
            e4.append (_("Toggle Comment"), "app.comment-toggle");
            edit.append_section (null, e4);
            var e5 = new GLib.Menu ();
            e5.append (_("Settings"), "app.settings");
            edit.append_section (null, e5);
            menu.append_submenu (_("Edit"), edit);

            var view = new GLib.Menu ();
            var v1 = new GLib.Menu ();
            v1.append (_("Command Palette"), "app.command-palette");
            view.append_section (null, v1);
            var v2 = new GLib.Menu ();
            v2.append (_("Sidebar"), "app.toggle-sidebar");
            v2.append (_("Outline"), "app.toggle-outline");
            v2.append (_("Minimap"), "app.toggle-minimap");
            v2.append (_("Markdown Preview"), "app.toggle-md-preview");
            view.append_section (null, v2);
            var v3 = new GLib.Menu ();
            v3.append (_("Zoom In"), "app.zoom-in");
            v3.append (_("Zoom Out"), "app.zoom-out");
            v3.append (_("Reset Zoom"), "app.zoom-reset");
            view.append_section (null, v3);
            var v4 = new GLib.Menu ();
            v4.append (_("Fullscreen"), "app.fullscreen");
            view.append_section (null, v4);
            menu.append_submenu (_("View"), view);

            var go = new GLib.Menu ();
            go.append (_("Next Tab"), "app.next-tab");
            go.append (_("Previous Tab"), "app.previous-tab");
            menu.append_submenu (_("Go"), go);

            return menu;
        }

        private GLib.Settings? load_settings () {
            var src = SettingsSchemaSource.get_default ();
            if (src != null && src.lookup ("dev.sinty.edit", true) != null)
                return new GLib.Settings ("dev.sinty.edit");
            // Fall back to compiled schema next to the binary
            try {
                string exe = GLib.FileUtils.read_link ("/proc/self/exe");
                var data_dir = GLib.File.new_for_path (exe)
                    .get_parent ().get_child ("data");
                if (data_dir.get_child ("gschemas.compiled").query_exists ()) {
                    var cs = new SettingsSchemaSource.from_directory (
                        data_dir.get_path (), src, true);
                    var schema = cs.lookup ("dev.sinty.edit", true);
                    if (schema != null)
                        return new GLib.Settings.full (schema, null, null);
                }
            } catch (Error e) {}
            return null;
        }

        //  Actions

        private void setup_actions () {
            add_act ("new-file",       on_new_file);
            add_act ("open",           on_open);
            add_act ("open-folder",    () => active_edit_window ()?.open_folder_dialog ());
            add_act ("save",           on_save);
            add_act ("save-as",        on_save_as);
            add_act ("open-online",    on_open_online);
            add_act ("save-online",    on_save_online);
            add_act ("share",          on_share);
            add_act ("close-tab",      on_close_tab);
            add_act ("quit",           on_quit);
            add_act ("undo",           on_undo);
            add_act ("redo",           on_redo);
            add_act ("find",           on_find);
            add_act ("find-replace",   on_find_replace);
            add_act ("goto-line",      on_goto_line);
            add_act ("select-all",     on_select_all);
            add_act ("duplicate-line", on_duplicate_line);
            add_act ("comment-toggle", on_comment_toggle);
            add_act ("delete-line",    on_delete_line);
            add_act ("move-line-up",   on_move_line_up);
            add_act ("move-line-down", on_move_line_down);
            add_act ("zoom-in",        on_zoom_in);
            add_act ("zoom-out",       on_zoom_out);
            add_act ("zoom-reset",     on_zoom_reset);
            add_toggle ("toggle-sidebar", on_toggle_sidebar);
            add_toggle ("toggle-minimap", on_toggle_minimap);
            add_toggle ("toggle-md-preview", on_toggle_md_preview);
            add_toggle ("toggle-outline", on_toggle_outline);
            add_toggle ("fullscreen",     on_fullscreen);
            add_act ("revert",         on_revert);
            add_act ("cut",            on_cut);
            add_act ("copy",           on_copy);
            add_act ("paste",          on_paste);
            add_act ("close-other-tabs", on_close_other_tabs);
            add_act ("close-all-tabs", on_close_all_tabs);
            add_act ("next-tab",       on_next_tab);
            add_act ("previous-tab",   on_previous_tab);
            add_act ("command-palette", on_command_palette);
            add_act ("goto-definition", on_goto_definition);
            add_act ("format-document", on_format_document);
            add_act ("rename-symbol", on_rename_symbol);
            add_act ("run-build-task", () => active_edit_window ()?.run_build_task ());
            add_act ("search-project", () => active_edit_window ()?.search_project ());
            add_act ("debug-start", () => active_edit_window ()?.debug.start_or_continue ());
            add_act ("debug-stop", () => active_edit_window ()?.debug.stop ());
            add_act ("debug-restart", () => active_edit_window ()?.debug.restart ());
            add_act ("debug-step-over", () => active_edit_window ()?.debug.step ("next"));
            add_act ("debug-step-into", () => active_edit_window ()?.debug.step ("stepIn"));
            add_act ("debug-step-out", () => active_edit_window ()?.debug.step ("stepOut"));
            add_act ("toggle-breakpoint", () => active_edit_window ()?.debug.toggle_breakpoint ());
            add_act ("quick-fix", on_quick_fix);
            notify["active-window"].connect (() => sync_document_actions ());

            var act_settings = new SimpleAction ("settings", null);
            act_settings.activate.connect (() => active_edit_window ()?.show_preferences ());
            add_action (act_settings);
        }

        private delegate void ActionHandler ();

        private void add_act (string name, ActionHandler handler) {
            var act = new SimpleAction (name, null);
            act.activate.connect ((_) => handler ());
            add_action (act);
        }

        private void add_toggle (string name, ActionHandler handler) {
            var act = new SimpleAction.stateful (name, null, new Variant.boolean (false));
            act.activate.connect ((_) => {
                handler ();
                sync_document_actions ();
            });
            add_action (act);
        }

        private GtkSource.Buffer? tracked_buffer = null;
        private ulong[] tracked_handlers = {};

        private void set_act (string name, bool enabled) {
            var act = lookup_action (name) as SimpleAction;
            if (act != null) act.set_enabled (enabled);
        }

        private void set_toggle (string name, bool enabled, bool active) {
            var act = lookup_action (name) as SimpleAction;
            if (act == null) return;
            act.set_enabled (enabled);
            act.set_state (new Variant.boolean (active));
        }

        internal void sync_document_actions () {
            var window = active_edit_window ();
            if (window != null && window.tab_container == null) window = null;
            var tab = window?.get_current_tab ();
            var buffer = tab?.buffer;
            if (buffer != tracked_buffer) {
                if (tracked_buffer != null)
                    foreach (var h in tracked_handlers) tracked_buffer.disconnect (h);
                tracked_handlers = {};
                tracked_buffer = buffer;
                if (buffer != null) {
                    tracked_handlers += buffer.notify["can-undo"].connect (() => sync_document_actions ());
                    tracked_handlers += buffer.notify["can-redo"].connect (() => sync_document_actions ());
                    tracked_handlers += buffer.notify["has-selection"].connect (() => sync_document_actions ());
                }
            }
            bool doc = tab != null;
            int pages = window != null ? (int) window.tab_container.get_n_pages () : 0;
            foreach (string name in new string[] { "save", "save-as", "save-online", "close-tab", "paste", "select-all",
                                                   "find", "find-replace", "goto-line", "duplicate-line",
                                                   "delete-line", "move-line-up", "move-line-down",
                                                   "comment-toggle", "close-all-tabs" })
                set_act (name, doc);
            set_act ("revert", doc && tab.file != null);
            set_act ("share", doc && tab.file != null && tab.file.query_exists (null));
            set_act ("undo", buffer != null && buffer.can_undo);
            set_act ("redo", buffer != null && buffer.can_redo);
            set_act ("cut", buffer != null && buffer.has_selection);
            set_act ("copy", buffer != null && buffer.has_selection);
            set_act ("close-other-tabs", pages > 1);
            set_act ("next-tab", pages > 1);
            set_act ("previous-tab", pages > 1);
            set_toggle ("toggle-sidebar", window != null, window != null && window.sidebar_shown);
            set_toggle ("toggle-minimap", doc, window != null && window.minimap_shown);
            set_toggle ("toggle-outline", doc && tab.has_outline (), window != null && window.outline_shown);
            set_toggle ("toggle-md-preview", doc && tab.is_markdown, doc && tab.showing_md_preview ());
            set_toggle ("fullscreen", window != null, window != null && window.fullscreened);
        }

        private void setup_accels () {
            set_accels_for_action ("app.new-file",       {"<Ctrl>n"});
            set_accels_for_action ("app.open",           {"<Ctrl>o"});
            set_accels_for_action ("app.open-folder",    {"<Ctrl><Shift>o"});
            set_accels_for_action ("app.save",           {"<Ctrl>s"});
            set_accels_for_action ("app.save-as",        {"<Ctrl><Shift>s"});
            set_accels_for_action ("app.close-tab",      {"<Ctrl>w"});
            // app.quit inherits {Ctrl+Q, Alt+F4} from Singularity.Application.
            set_accels_for_action ("app.undo",           {"<Ctrl>z"});
            set_accels_for_action ("app.redo",           {"<Ctrl><Shift>z"});
            set_accels_for_action ("app.find",           {"<Ctrl>f"});
            set_accels_for_action ("app.find-replace",   {"<Ctrl>h"});
            set_accels_for_action ("app.goto-line",      {"<Ctrl>g"});
            set_accels_for_action ("app.goto-definition", {"F12"});
            set_accels_for_action ("app.format-document", {"<Shift><Alt>f"});
            set_accels_for_action ("app.rename-symbol", {"F2"});
            set_accels_for_action ("app.run-build-task", {"<Ctrl><Shift>b"});
            set_accels_for_action ("app.search-project", {"<Ctrl><Shift>f"});
            set_accels_for_action ("app.debug-start", {"F5"});
            set_accels_for_action ("app.debug-stop", {"<Shift>F5"});
            set_accels_for_action ("app.debug-restart", {"<Ctrl><Shift>F5"});
            set_accels_for_action ("app.debug-step-over", {"F10"});
            set_accels_for_action ("app.debug-step-out", {"<Shift>F11"});
            set_accels_for_action ("app.toggle-breakpoint", {"F9"});
            set_accels_for_action ("app.quick-fix", {"<Ctrl>period"});
            set_accels_for_action ("app.select-all",     {"<Ctrl>a"});
            set_accels_for_action ("app.duplicate-line", {"<Ctrl>d"});
            set_accels_for_action ("app.comment-toggle", {"<Ctrl>slash"});
            set_accels_for_action ("app.delete-line",    {"<Ctrl><Shift>k"});
            set_accels_for_action ("app.move-line-up",   {"<Alt>Up"});
            set_accels_for_action ("app.move-line-down", {"<Alt>Down"});
            set_accels_for_action ("app.zoom-in",        {"<Ctrl>plus", "<Ctrl>equal"});
            set_accels_for_action ("app.zoom-out",       {"<Ctrl>minus"});
            set_accels_for_action ("app.zoom-reset",     {"<Ctrl>0"});
            set_accels_for_action ("app.toggle-sidebar", {"<Ctrl>b"});
            set_accels_for_action ("app.toggle-minimap", {"<Alt>m"});
            set_accels_for_action ("app.toggle-md-preview", {"<Ctrl><Shift>m"});
            set_accels_for_action ("app.fullscreen",     {"F11"});
            set_accels_for_action ("app.settings",       {"<Ctrl>comma"});
            set_accels_for_action ("app.command-palette", {"<Ctrl>p"});
            set_accels_for_action ("app.next-tab",       {"<Ctrl>Page_Down"});
            set_accels_for_action ("app.previous-tab",   {"<Ctrl>Page_Up"});
            set_accels_for_action ("win.close",          {"<Ctrl><Shift>w"});
        }

        //  Lifecycle

        protected override void activate () {
            if (edit_win != null) {
                edit_win.present ();
                return;
            }
            var window = new EditWindow (this, settings);
            edit_win = window;
            window.present ();
            if (pending_new_file) {
                pending_new_file = false;
                window.add_tab (null);
            }
        }

        public override void open (GLib.File[] files, string hint) {
            activate ();
            var window = active_edit_window ();
            if (window == null) return;
            foreach (var f in files) {
                if (f.query_file_type (FileQueryInfoFlags.NONE) == FileType.DIRECTORY) window.open_folder (f);
                else window.add_tab (f);
            }
        }

        private EditWindow? active_edit_window () {
            var active = get_active_window () as EditWindow;
            if (active != null) return active;
            foreach (var window in get_windows ()) {
                var edit_window = window as EditWindow;
                if (edit_window != null) return edit_window;
            }
            return null;
        }

        private void refresh_all_windows () {
            foreach (var window in get_windows ())
                (window as EditWindow)?.refresh_all_schemes ();
        }

        internal void detach_tab (EditWindow source, EditorTab tab) {
            EditorTab held_tab = tab;
            if (!source.release_tab (held_tab)) return;
            var window = new EditWindow (this, settings, false);
            window.adopt_tab (held_tab);
            window.present ();
        }

        //  Action handlers

        private void on_new_file ()       { active_edit_window ()?.add_tab (null); }
        private void on_open ()           { active_edit_window ()?.open_file_dialog (); }
        private void on_save ()           { active_edit_window ()?.save_current (); }
        private void on_save_as ()        { active_edit_window ()?.save_current_as (); }
        private void on_save_online ()    { CloudActions.save_tab (active_edit_window ()); }
        private void on_share () {
            var w = active_edit_window ();
            var f = w?.get_current_tab ()?.file;
            if (w != null && f != null) Singularity.Share.files (w, { f });
        }
        private void on_open_online () {
            var w = active_edit_window ();
            if (w != null) CloudActions.open.begin (w, (f) => { w.open_file (f); });
        }
        private void on_close_tab ()      { active_edit_window ()?.close_current_tab (); }
        private void on_quit ()           { quit (); }
        private void on_undo ()           { active_edit_window ()?.get_current_tab ()?.undo (); }
        private void on_redo ()           { active_edit_window ()?.get_current_tab ()?.redo (); }
        private void on_find ()           { active_edit_window ()?.show_find (false); }
        private void on_find_replace ()   { active_edit_window ()?.show_find (true); }
        private void on_goto_line ()      { active_edit_window ()?.show_goto_line (); }
        private void on_select_all ()     { active_edit_window ()?.get_current_tab ()?.select_all (); }
        private void on_duplicate_line () { active_edit_window ()?.get_current_tab ()?.duplicate_line (); }
        private void on_comment_toggle () { active_edit_window ()?.get_current_tab ()?.comment_toggle (); }
        private void on_delete_line ()    { active_edit_window ()?.get_current_tab ()?.delete_line (); }
        private void on_move_line_up ()   { active_edit_window ()?.get_current_tab ()?.move_line_up (); }
        private void on_move_line_down () { active_edit_window ()?.get_current_tab ()?.move_line_down (); }
        private void on_zoom_in ()        { active_edit_window ()?.zoom_change (1); }
        private void on_zoom_out ()       { active_edit_window ()?.zoom_change (-1); }
        private void on_zoom_reset ()     { active_edit_window ()?.zoom_reset (); }
        private void on_toggle_sidebar () { active_edit_window ()?.toggle_sidebar (); }
        private void on_toggle_minimap () { active_edit_window ()?.toggle_minimap (); }
        private void on_toggle_md_preview () { active_edit_window ()?.toggle_md_preview (); }
        private void on_fullscreen ()     { active_edit_window ()?.toggle_fullscreen (); }
        private void on_revert ()         { active_edit_window ()?.revert_current (); }
        private void on_toggle_outline () { active_edit_window ()?.toggle_outline_panel (); }
        private void on_cut ()            { active_edit_window ()?.clipboard_action (0); }
        private void on_copy ()           { active_edit_window ()?.clipboard_action (1); }
        private void on_paste ()          { active_edit_window ()?.clipboard_action (2); }
        private void on_close_other_tabs () { active_edit_window ()?.close_other_tabs (); }
        private void on_close_all_tabs () { active_edit_window ()?.close_all_tabs (); }
        private void on_next_tab ()       { active_edit_window ()?.cycle_tab (1); }
        private void on_previous_tab ()   { active_edit_window ()?.cycle_tab (-1); }
        private void on_command_palette () { active_edit_window ()?.open_command_palette (); }
        private void on_goto_definition () { active_edit_window ()?.goto_definition (); }
        private void on_format_document () { active_edit_window ()?.format_document (); }
        private void on_rename_symbol () { active_edit_window ()?.rename_symbol (); }
        private void on_quick_fix () { active_edit_window ()?.quick_fix (); }

        private void setup_styles () {
            var provider = new Gtk.CssProvider ();
            provider.load_from_data (EDIT_CSS.data);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
            var overlays = new Gtk.CssProvider ();
            overlays.load_from_data (OVERLAY_CSS.data);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), overlays,
                Gtk.STYLE_PROVIDER_PRIORITY_USER + 3);
        }

        private const string OVERLAY_CSS = """
GtkSourceAssistant > contents {
    background-color: @popover_bg_color;
    color: @popover_fg_color;
    border-radius: 12px;
    border: 1px solid alpha(@text_color, 0.10);
    box-shadow: 0 6px 24px alpha(black, 0.18);
    padding: 4px;
}
GtkSourceAssistant {
    background: none;
    box-shadow: none;
    border: none;
}
GtkSourceAssistant.completion list {
    background: transparent;
}
GtkSourceAssistant.completion list row {
    border-radius: 7px;
    min-height: 24px;
}
GtkSourceAssistant.completion list row:selected {
    background-color: alpha(@accent_color, 0.16);
    color: @popover_fg_color;
}
GtkSourceAssistant.completion list row cell {
    padding: 0 6px;
}
GtkSourceAssistant.completion list row cell.after,
GtkSourceAssistant.completion list row cell.before {
    color: alpha(@popover_fg_color, 0.55);
}
GtkSourceAssistant.completion box.details {
    border-top: 1px solid alpha(@text_color, 0.08);
    padding: 6px 8px;
}
.edit-collab-flag {
    padding: 1px 7px;
    border-radius: 999px;
    color: white;
    font-family: "Noto Sans";
    font-size: 10px;
    font-weight: 700;
}
.edit-collab-avatar {
    min-width: 22px;
    min-height: 22px;
    padding: 0;
    border-radius: 999px;
    color: white;
    font-size: 9px;
    font-weight: 700;
}
.edit-problems {
    background-color: @view_bg_color;
}
.edit-problems-list {
    background: transparent;
}
.edit-problems-list row {
    border-radius: 8px;
    margin: 0 6px;
}
.edit-problems-list row:selected {
    background-color: alpha(@accent_color, 0.16);
    color: @view_fg_color;
}
""";

        private const string EDIT_CSS = """
/* Edit App */
.edit-find-bar {
    background-color: alpha(@shadow_color, 0.3);
    padding: 8px 12px;
    border-top: 1px solid alpha(@text_color, 0.1);
}

.edit-find-bar entry {
    min-width: 200px;
}

.edit-statusbar {
    background-color: alpha(@shadow_color, 0.4);
    padding: 2px 12px;
    font-size: 11px;
}

.edit-statusbar label {
    opacity: 0.7;
}

.edit-statusbar separator {
    margin: 2px 8px;
}

.edit-sidebar-tab {
    padding: 6px 12px;
    font-size: 12px;
    border-radius: 0;
}

.edit-sidebar-tab:checked {
    background-color: alpha(@accent_color, 0.2);
    color: @accent_color;
}

.edit-file-row {
    padding: 3px 8px;
    border-radius: 4px;
}

.edit-file-row:hover {
    background-color: alpha(@text_color, 0.07);
}

.edit-file-row.directory {
    font-weight: 600;
}

.edit-region-header {
    padding: 0 8px;
}
.edit-region-sidebar .edit-region-header {
    padding: 0 12px;
}
.edit-region-inspector {
    min-width: 360px;
    border-left: 1px solid alpha(@text_color, 0.1);
}
.edit-region-panel {
    min-height: 210px;
    border-top: 1px solid alpha(@text_color, 0.1);
    background-color: alpha(@shadow_color, 0.25);
}
.edit-region-panel .edit-region-header {
    padding: 8px 8px 0 12px;
}
.edit-region-panel .sidebar-tabs {
    margin-bottom: 4px;
}
.edit-status-item image.error { color: #e5534b; }
.edit-status-item image.warning { color: #d4a72c; }
.edit-outline-panel {
    background-color: alpha(@shadow_color, 0.35);
    border-top: 1px solid alpha(@text_color, 0.1);
}
.edit-outline-header {
    border-bottom: 1px solid alpha(@text_color, 0.06);
}

""";
    }

}
