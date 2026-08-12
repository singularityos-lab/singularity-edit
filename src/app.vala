using Gtk;
using GLib;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // =========================================================================
    // EditApp - Singularity.Application subclass
    // =========================================================================
    public class EditApp : Singularity.Application {
        private weak EditWindow? edit_win;
        private GLib.Settings? settings;
        private GLib.Settings? desktop_settings;

        public EditApp () {
            Object (application_id: "dev.sinty.edit",
                    flags: ApplicationFlags.HANDLES_OPEN);
        }

        protected override void startup () {
            base.startup ();
            setup_styles ();
            settings = load_settings ();
            setup_actions ();
            setup_accels ();
            set_menubar (build_app_menu ());

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

            var file_sec = new GLib.Menu ();
            file_sec.append ("Save As…",  "app.save-as");
            file_sec.append ("Revert",    "app.revert");
            file_sec.append ("Settings",  "app.settings");
            menu.append_section ("File", file_sec);

            var edit_sec = new GLib.Menu ();
            edit_sec.append ("Undo",        "app.undo");
            edit_sec.append ("Redo",        "app.redo");
            edit_sec.append ("Select All",  "app.select-all");
            menu.append_section ("Edit", edit_sec);

            var view_sec = new GLib.Menu ();
            view_sec.append ("Toggle Sidebar (F9)",    "app.toggle-sidebar");
            view_sec.append ("Toggle Minimap (Alt+M)", "app.toggle-minimap");
            view_sec.append ("Fullscreen (F11)",       "app.fullscreen");
            view_sec.append ("Zoom In",                "app.zoom-in");
            view_sec.append ("Zoom Out",               "app.zoom-out");
            view_sec.append ("Reset Zoom",             "app.zoom-reset");
            menu.append_section ("View", view_sec);

            var prefs_sec = new GLib.Menu ();
            menu.append_section ("", prefs_sec);

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
            add_act ("save",           on_save);
            add_act ("save-as",        on_save_as);
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
            add_act ("toggle-sidebar", on_toggle_sidebar);
            add_act ("toggle-minimap", on_toggle_minimap);
            add_act ("toggle-md-preview", on_toggle_md_preview);
            add_act ("fullscreen",     on_fullscreen);
            add_act ("revert",         on_revert);

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

        private void setup_accels () {
            set_accels_for_action ("app.new-file",       {"<Ctrl>n"});
            set_accels_for_action ("app.open",           {"<Ctrl>o"});
            set_accels_for_action ("app.save",           {"<Ctrl>s"});
            set_accels_for_action ("app.save-as",        {"<Ctrl><Shift>s"});
            set_accels_for_action ("app.close-tab",      {"<Ctrl>w"});
            // app.quit inherits {Ctrl+Q, Alt+F4} from Singularity.Application.
            set_accels_for_action ("app.undo",           {"<Ctrl>z"});
            set_accels_for_action ("app.redo",           {"<Ctrl><Shift>z"});
            set_accels_for_action ("app.find",           {"<Ctrl>f"});
            set_accels_for_action ("app.find-replace",   {"<Ctrl>h"});
            set_accels_for_action ("app.goto-line",      {"<Ctrl>g"});
            set_accels_for_action ("app.select-all",     {"<Ctrl>a"});
            set_accels_for_action ("app.duplicate-line", {"<Ctrl>d"});
            set_accels_for_action ("app.comment-toggle", {"<Ctrl>slash"});
            set_accels_for_action ("app.delete-line",    {"<Ctrl><Shift>k"});
            set_accels_for_action ("app.move-line-up",   {"<Alt>Up"});
            set_accels_for_action ("app.move-line-down", {"<Alt>Down"});
            set_accels_for_action ("app.zoom-in",        {"<Ctrl>plus", "<Ctrl>equal"});
            set_accels_for_action ("app.zoom-out",       {"<Ctrl>minus"});
            set_accels_for_action ("app.zoom-reset",     {"<Ctrl>0"});
            set_accels_for_action ("app.toggle-sidebar", {"F9"});
            set_accels_for_action ("app.toggle-minimap", {"<Alt>m"});
            set_accels_for_action ("app.toggle-md-preview", {"<Ctrl><Shift>m"});
            set_accels_for_action ("app.fullscreen",     {"F11"});
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
        }

        public override void open (GLib.File[] files, string hint) {
            activate ();
            var window = active_edit_window ();
            if (window == null) return;
            foreach (var f in files)
                window.add_tab (f);
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

        private void setup_styles () {
            var provider = new Gtk.CssProvider ();
            provider.load_from_data (EDIT_CSS.data);
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

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

/* Outline bottom dock */
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
