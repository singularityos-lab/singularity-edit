using Gtk;
using GLib;
using WebKit;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    // =========================================================================
    // EditorTab - single editor pane (view + minimap + find bar)
    // =========================================================================
    public class EditorTab : Box {
        public GtkSource.View   view   { get; private set; }
        public GtkSource.Buffer buffer { get; private set; }
        public GLib.File?       file   { get; set; }
        public string           title  { get; private set; default = "Untitled"; }
        public bool             modified { get; private set; default = false; }
        public FindBar find_bar { get; private set; }
        public bool is_markdown { get; private set; default = false; }

        private GtkSource.Map   minimap;
        private Gtk.CssProvider font_provider;
        private GLib.Settings?  settings;
        private uint            autosave_id = 0;

        private Stack           _view_stack;
        private WebView?        _md_preview;
        private uint            _md_update_id = 0;
        private Markdown.Parser _md_parser;
        private TsHighlighter?  _ts_highlighter;
        private TsFolding?      _ts_folding;
        private OutlineEntry[]  _outline_entries;
        private FoldRegion?[]   _ts_folds;

        // Dialogs stored as fields to avoid closure capture of GObject locals
        private FileChooserNative? save_dialog;
        private Gtk.InfoBar?       _close_confirm_bar = null;

        // Signals that pass `this` so EditWindow can use method handlers
        public signal void state_changed  (EditorTab tab);
        public signal void cursor_changed (EditorTab tab);
        public signal void close_save     (EditorTab tab);
        public signal void close_discard  (EditorTab tab);
        public signal void close_cancel   (EditorTab tab);
        public signal void outline_changed (EditorTab tab);

        public OutlineEntry[] get_outline_entries () { return _outline_entries; }
        public bool has_outline () { return _ts_highlighter != null; }

        public EditorTab (GLib.File? file, GLib.Settings? settings) {
            Object (orientation: Orientation.VERTICAL, spacing: 0);
            this.file     = file;
            this.settings = settings;

            //  view stack: editor ↔ markdown preview
            _view_stack = new Stack ();
            _view_stack.transition_type = StackTransitionType.CROSSFADE;
            _view_stack.transition_duration = 150;
            _view_stack.hexpand = true;
            _view_stack.vexpand = true;

            //  editor area: view + minimap side-by-side
            var editor_row = new Box (Orientation.HORIZONTAL, 0);
            editor_row.hexpand = true;
            editor_row.vexpand = true;

            var scroll = new ScrolledWindow ();
            scroll.hexpand = true;
            scroll.vexpand = true;

            buffer = new GtkSource.Buffer (null);
            buffer.highlight_matching_brackets = true;

            view = new Singularity.Widgets.SourceView.with_buffer (buffer);
            view.monospace                       = true;
            view.auto_indent                     = true;
            view.smart_backspace                 = true;
            view.show_line_numbers               = true;
            view.highlight_current_line          = true;
            view.tab_width                       = 4;
            view.indent_width                    = 4;
            view.insert_spaces_instead_of_tabs   = true;
            view.vexpand                         = true;
            view.top_margin                      = 60;
            view.bottom_margin                   = 8;
            view.left_margin                     = 12;
            view.right_margin                    = 12;

            scroll.set_child (view);
            editor_row.append (scroll);

            minimap = new GtkSource.Map ();
            minimap.set_view (view);
            minimap.width_request = 120;
            minimap.visible       = false;
            editor_row.append (minimap);

            _view_stack.add_named (editor_row, "editor");
            append (_view_stack);

            //  find bar
            find_bar = new FindBar ();
            find_bar.set_buffer (buffer);
            find_bar.close_requested.connect (() => find_bar.visible = false);
            append (find_bar);

            //  font CSS provider
            font_provider = new Gtk.CssProvider ();
            view.get_style_context ().add_provider (
                font_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            //  apply settings
            if (settings != null)
                bind_settings ();
            else
                apply_defaults ();

            //  load file or set empty title
            if (file != null)
                load_file ();
            else
                refresh_title ();

            //  buffer / cursor signals
            buffer.mark_set.connect (on_mark_set);
            buffer.changed.connect  (on_buffer_changed);
            view.notify["overwrite"].connect (on_overwrite_changed);
        }

        //  Close-confirmation inline banner

        public void show_close_confirmation () {
            if (_close_confirm_bar != null) return;
            _close_confirm_bar = new Gtk.InfoBar ();
            _close_confirm_bar.message_type = Gtk.MessageType.WARNING;
            _close_confirm_bar.show_close_button = false;
            var lbl = new Label (_("Save changes to \"%s\"?").printf (title.replace ("• ", "")));
            lbl.xalign = 0f;
            _close_confirm_bar.add_child (lbl);
            _close_confirm_bar.add_button ("Save",    Gtk.ResponseType.YES);
            _close_confirm_bar.add_button ("Discard", Gtk.ResponseType.NO);
            _close_confirm_bar.add_button ("Cancel",  Gtk.ResponseType.CANCEL);
            _close_confirm_bar.response.connect (on_close_confirm_response);
            prepend (_close_confirm_bar);
        }

        public void hide_close_confirmation () {
            if (_close_confirm_bar == null) return;
            remove (_close_confirm_bar);
            _close_confirm_bar = null;
        }

        private void on_close_confirm_response (int id) {
            hide_close_confirmation ();
            switch (id) {
                case Gtk.ResponseType.YES:    close_save    (this); break;
                case Gtk.ResponseType.NO:     close_discard (this); break;
                default:                      close_cancel  (this); break;
            }
        }

        //  Settings

        private void bind_settings () {
            settings.bind ("show-line-numbers",
                view, "show-line-numbers", SettingsBindFlags.DEFAULT);
            settings.bind ("highlight-current-line",
                view, "highlight-current-line", SettingsBindFlags.DEFAULT);
            settings.bind ("show-right-margin",
                view, "show-right-margin", SettingsBindFlags.DEFAULT);
            settings.bind ("right-margin-position",
                view, "right-margin-position", SettingsBindFlags.DEFAULT);
            settings.bind ("tab-width",
                view, "tab-width", SettingsBindFlags.DEFAULT);
            settings.bind ("use-spaces",
                view, "insert-spaces-instead-of-tabs", SettingsBindFlags.DEFAULT);

            update_wrap_mode ();
            update_color_scheme ();
            update_font ();
            update_whitespace ();

            settings.changed.connect (on_settings_changed);
        }

        private void apply_defaults () {
            view.show_line_numbers      = true;
            view.highlight_current_line = true;
            update_color_scheme ();
            update_font ();
        }

        private void on_settings_changed (string key) {
            switch (key) {
                case "wrap-text":            update_wrap_mode ();    break;
                case "color-scheme":         update_color_scheme (); break;
                case "font-name":            update_font ();         break;
                case "show-whitespace":      update_whitespace ();   break;
                case "auto-save":
                case "auto-save-interval":   setup_autosave ();      break;
            }
        }

        private void update_wrap_mode () {
            if (settings == null) { view.wrap_mode = WrapMode.NONE; return; }
            view.wrap_mode = settings.get_boolean ("wrap-text")
                ? WrapMode.WORD_CHAR : WrapMode.NONE;
        }

        private void update_color_scheme () {
            var sm  = GtkSource.StyleSchemeManager.get_default ();
            string id = (settings != null)
                ? settings.get_string ("color-scheme") : "auto";

            // Check if it's one of our Singularity themes
            var sinty_theme = Singularity.Core.TerminalThemes.get_by_id (id);
            if (sinty_theme != null) {
                string scheme_id = "sinty-" + id;
                _ensure_sinty_scheme (id, scheme_id, sm);
                var scheme = sm.get_scheme (scheme_id);
                if (scheme != null) { buffer.set_style_scheme (scheme); return; }
            }

            // Fall back to any system scheme with that name
            var scheme = sm.get_scheme (id)
                      ?? sm.get_scheme ("classic");
            if (scheme != null) buffer.set_style_scheme (scheme);
        }

        // Write (or overwrite for "auto") the Singularity scheme XML to the
        // user GtkSourceView styles directory and rescan the manager.
        private void _ensure_sinty_scheme (string id, string scheme_id,
                                           GtkSource.StyleSchemeManager sm) {
            string dir  = GLib.Path.build_filename (
                GLib.Environment.get_home_dir (),
                ".local", "share", "gtksourceview-5", "styles");
            string path = GLib.Path.build_filename (dir, scheme_id + ".xml");

            // "auto" must always be regenerated (accent/dark-mode can change).
            bool needs_write = (id == "auto")
                            || !GLib.FileUtils.test (path, GLib.FileTest.EXISTS);
            if (!needs_write) return;

            string xml = Singularity.Core.TerminalThemes.get_source_scheme_xml (id);
            if (xml == "") return;

            try {
                GLib.DirUtils.create_with_parents (dir, 0755);
                GLib.FileUtils.set_contents (path, xml);

                // Prepend to search path if not already present
                var paths = sm.get_search_path ();
                bool found = false;
                foreach (var p in paths)
                    if (p == dir) { found = true; break; }
                if (!found) {
                    string[] new_paths = new string[paths.length + 1];
                    new_paths[0] = dir;
                    for (int i = 0; i < paths.length; i++) new_paths[i + 1] = paths[i];
                    sm.set_search_path (new_paths);
                }
                sm.force_rescan ();
            } catch (Error e) {
                warning ("Failed to write Singularity scheme '%s': %s", scheme_id, e.message);
            }
        }

        /** Re-apply the current colour scheme (call when accent/dark-mode changes). */
        public void refresh_scheme () {
            update_color_scheme ();
        }

        private void update_font () {
            string fname = (settings != null)
                ? settings.get_string ("font-name") : "Monospace 12";
            apply_font_css_string (fname);
        }

        private void apply_font_css_string (string fname) {
            string css = "textview { font: %s; }".printf (fname);
            try { font_provider.load_from_string (css); }
            catch (Error e) { warning ("Font CSS: %s", e.message); }
        }

        private void update_whitespace () {
            if (settings == null) return;
            var sd   = view.get_space_drawer ();
            bool show = settings.get_boolean ("show-whitespace");
            if (show) {
                sd.set_types_for_locations (
                    GtkSource.SpaceLocationFlags.ALL,
                    GtkSource.SpaceTypeFlags.SPACE | GtkSource.SpaceTypeFlags.TAB);
                sd.enable_matrix = true;
            } else {
                sd.enable_matrix = false;
            }
        }

        //  Auto-save

        private void setup_autosave () {
            if (autosave_id != 0) {
                Source.remove (autosave_id);
                autosave_id = 0;
            }
            if (settings == null || !settings.get_boolean ("auto-save") || file == null)
                return;
            int interval = settings.get_int ("auto-save-interval");
            if (interval < 1) interval = 60;
            autosave_id = Timeout.add_seconds (interval, do_autosave);
        }

        private bool do_autosave () {
            if (file != null && modified) write_to_disk ();
            return Source.CONTINUE;
        }

        //  Signal handlers

        private void on_mark_set (Gtk.TextIter _loc, Gtk.TextMark mark) {
            if (mark == buffer.get_insert ())
                cursor_changed (this);
        }

        private void on_buffer_changed () {
            if (!modified) {
                modified = true;
                refresh_title ();
                state_changed (this);
            }
            cursor_changed (this);
        }

        private void on_overwrite_changed () {
            cursor_changed (this);
        }

        //  Title

        private void refresh_title () {
            string base_name = (file != null) ? file.get_basename () : "Untitled";
            title = modified ? ("• " + base_name) : base_name;
            state_changed (this);
        }

        //  File I/O

        private void load_file () {
            if (file == null) return;
            try {
                uint8[] data;
                string  etag;
                file.load_contents (null, out data, out etag);
                buffer.begin_irreversible_action ();
                buffer.text = (string) data;
                buffer.end_irreversible_action ();
                buffer.set_modified (false);
                modified = false;
                detect_language ();
                refresh_title ();
                add_to_recent ();
                setup_autosave ();
            } catch (Error e) {
                warning ("load_file: %s", e.message);
            }
        }

        private void detect_language () {
            if (file == null) return;
            var lm   = GtkSource.LanguageManager.get_default ();
            var lang = lm.guess_language (file.get_basename (), null);
            if (lang != null) buffer.set_language (lang);

            // Try tree-sitter for languages we ship grammars for. When it
            // claims the buffer we keep the GtkSource language assignment
            // (status bar / smart indent stay correct) but switch off the
            // built-in highlighter. TsHighlighter paints everything.
            if (_ts_highlighter != null) {
                _ts_highlighter.detach ();
                _ts_highlighter = null;
            }
            _ts_folding = null;
            _outline_entries = {};
            outline_changed (this);

            var ts_def = TsLangRegistry.get_default ().lookup_for_file (file);
            if (ts_def != null) {
                buffer.highlight_syntax = false;
                _ts_highlighter = new TsHighlighter (buffer, ts_def);
                _ts_folding     = new TsFolding (buffer, ts_def);
                _ts_highlighter.tree_updated.connect (on_ts_tree_updated);
                install_fold_shortcuts ();
                // The highlighter parses synchronously in its ctor; extract
                // the outline now so subsequent tab-switch reads see entries
                // before the deferred tree_updated emission fires.
                on_ts_tree_updated ();
            } else {
                buffer.highlight_syntax = true;
            }

            is_markdown = (lang != null && lang.id == "markdown")
                        || file.get_basename ().down ().has_suffix (".md")
                        || file.get_basename ().down ().has_suffix (".markdown");
            if (is_markdown) {
                _md_parser = new Markdown.Parser ();
                buffer.changed.connect (schedule_md_update);
            }
        }

        public void toggle_md_preview () {
            if (!is_markdown) return;
            if (_view_stack.visible_child_name == "editor") {
                show_md_preview ();
            } else {
                _view_stack.visible_child_name = "editor";
            }
        }

        public bool showing_md_preview () {
            return is_markdown && _view_stack.visible_child_name == "preview";
        }

        private void show_md_preview () {
            if (_md_preview == null) {
                _md_preview = new WebView();
                _md_preview.hexpand = true;
                _md_preview.vexpand = true;
                _md_preview.add_css_class("singularity");
                var scroll = new ScrolledWindow();
                scroll.set_child(_md_preview);
                _view_stack.add_named(scroll, "preview");
                _md_preview.realize.connect(() => {
                    update_md_preview();
                });
            }
            _view_stack.visible_child_name = "preview";
            if (_md_preview.get_realized()) {
                update_md_preview();
            }
        }

        private void schedule_md_update () {
            if (_md_update_id != 0) return;
            _md_update_id = Timeout.add (300, () => {
                _md_update_id = 0;
                update_md_preview ();
                return Source.REMOVE;
            });
        }

        private void update_md_preview () {
            if (_md_preview == null || !is_markdown) return;
            if (_md_parser == null) _md_parser = new Markdown.Parser ();
            Gtk.TextIter start, end;
            buffer.get_bounds (out start, out end);
            string text = buffer.get_text (start, end, false);
            string html;
            try {
                html = _md_parser.to_full_html (text);
            } catch (Error e) {
                warning ("md to_full_html threw: %s", e.message);
                html = "<html><body><pre>" + text + "</pre></body></html>";
            }
            try {
                _md_preview.load_html (html, null);
            } catch (Error e) {
                warning ("md load_html threw: %s", e.message);
            }
        }

        public void save () {
            if (file == null) { save_as (); return; }
            write_to_disk ();
        }

        private void write_to_disk () {
            if (file == null) return;
            Gtk.TextIter ts, te;
            buffer.get_bounds (out ts, out te);
            string text = buffer.get_text (ts, te, false);
            try {
                file.replace_contents (
                    text.data, null, false, GLib.FileCreateFlags.NONE, null);
                buffer.set_modified (false);
                modified = false;
                refresh_title ();
                add_to_recent ();
                var window = get_root () as Singularity.Widgets.Window;
                if (window != null) CloudActions.sync_back (window, file);
            } catch (Error e) {
                warning ("write_to_disk: %s", e.message);
            }
        }

        // save_as uses a field-stored dialog to avoid closure capture

        public void save_as () {
            var win = get_root () as Gtk.Window;
            save_dialog = new FileChooserNative (
                "Save As", win, FileChooserAction.SAVE, "Save", "Cancel");
            if (file != null) {
                try { save_dialog.set_file (file); } catch (Error e) {}
            }
            save_dialog.response.connect (on_save_as_response);
            save_dialog.show ();
        }

        private void on_save_as_response (int resp) {
            if (resp == ResponseType.ACCEPT && save_dialog != null) {
                file = save_dialog.get_file ();
                detect_language ();
                write_to_disk ();
            }
            save_dialog?.destroy ();
            save_dialog = null;
        }

        public void revert () {
            if (file == null) return;
            load_file ();
        }

        //  Editing operations

        public void undo () {
            if (buffer.can_undo) buffer.undo ();
        }

        public void redo () {
            if (buffer.can_redo) buffer.redo ();
        }

        public void select_all () {
            Gtk.TextIter ts, te;
            buffer.get_bounds (out ts, out te);
            buffer.select_range (ts, te);
        }

        public void duplicate_line () {
            Gtk.TextIter it;
            buffer.get_iter_at_mark (out it, buffer.get_insert ());

            Gtk.TextIter ls = it; ls.set_line_offset (0);
            Gtk.TextIter le = it; le.forward_to_line_end ();
            string line_text = buffer.get_text (ls, le, false);

            buffer.begin_user_action ();
            buffer.insert (ref le, "\n" + line_text, -1);
            buffer.end_user_action ();
        }

        public void delete_line () {
            Gtk.TextIter it;
            buffer.get_iter_at_mark (out it, buffer.get_insert ());

            Gtk.TextIter ls = it; ls.set_line_offset (0);
            Gtk.TextIter le = ls;
            if (le.forward_line ()) {
                // consumed the newline; delete start..le
                buffer.begin_user_action ();
                buffer.delete (ref ls, ref le);
                buffer.end_user_action ();
            } else {
                // last line - delete from previous newline if possible
                Gtk.TextIter end2 = it; end2.forward_to_line_end ();
                Gtk.TextIter start2 = ls;
                if (start2.backward_char ()) {
                    buffer.begin_user_action ();
                    buffer.delete (ref start2, ref end2);
                    buffer.end_user_action ();
                }
            }
        }

        public void move_line_up () {
            Gtk.TextIter it;
            buffer.get_iter_at_mark (out it, buffer.get_insert ());
            int line = it.get_line ();
            if (line == 0) return;
            swap_lines (line - 1, line);
            Gtk.TextIter np;
            buffer.get_iter_at_line_offset (out np, line - 1, it.get_line_offset ());
            buffer.place_cursor (np);
        }

        public void move_line_down () {
            Gtk.TextIter it;
            buffer.get_iter_at_mark (out it, buffer.get_insert ());
            int line = it.get_line ();
            if (line >= buffer.get_line_count () - 1) return;
            swap_lines (line, line + 1);
            Gtk.TextIter np;
            buffer.get_iter_at_line_offset (out np, line + 1, it.get_line_offset ());
            buffer.place_cursor (np);
        }

        private void swap_lines (int line_a, int line_b) {
            Gtk.TextIter a_s, a_e, b_s, b_e;
            buffer.get_iter_at_line (out a_s, line_a);
            a_e = a_s; a_e.forward_to_line_end ();
            buffer.get_iter_at_line (out b_s, line_b);
            b_e = b_s; b_e.forward_to_line_end ();
            string text_a = buffer.get_text (a_s, a_e, false);
            string text_b = buffer.get_text (b_s, b_e, false);

            buffer.begin_user_action ();
            // Replace b first (higher offset) to avoid iterator invalidation
            buffer.get_iter_at_line (out b_s, line_b);
            b_e = b_s; b_e.forward_to_line_end ();
            buffer.delete (ref b_s, ref b_e);
            buffer.get_iter_at_line (out b_s, line_b);
            buffer.insert (ref b_s, text_a, -1);

            buffer.get_iter_at_line (out a_s, line_a);
            a_e = a_s; a_e.forward_to_line_end ();
            buffer.delete (ref a_s, ref a_e);
            buffer.get_iter_at_line (out a_s, line_a);
            buffer.insert (ref a_s, text_b, -1);
            buffer.end_user_action ();
        }

        public void comment_toggle () {
            string? prefix = comment_prefix ();
            if (prefix == null) return;

            Gtk.TextIter ss, se;
            bool has_sel = buffer.get_selection_bounds (out ss, out se);
            if (!has_sel) {
                buffer.get_iter_at_mark (out ss, buffer.get_insert ());
                se = ss;
            }
            int first_line = ss.get_line ();
            int last_line  = se.get_line ();
            if (has_sel && se.get_line_offset () == 0 && last_line > first_line)
                last_line--;

            // determine if all lines are already commented
            bool all_commented = true;
            for (int l = first_line; l <= last_line; l++) {
                Gtk.TextIter li, le;
                buffer.get_iter_at_line (out li, l);
                le = li; le.forward_to_line_end ();
                if (!buffer.get_text (li, le, false).strip ().has_prefix (prefix.strip ())) {
                    all_commented = false;
                    break;
                }
            }

            buffer.begin_user_action ();
            for (int l = first_line; l <= last_line; l++) {
                Gtk.TextIter li;
                buffer.get_iter_at_line (out li, l);
                if (all_commented) {
                    Gtk.TextIter le = li; le.forward_to_line_end ();
                    string lt = buffer.get_text (li, le, false);
                    int idx = lt.index_of (prefix);
                    if (idx >= 0) {
                        Gtk.TextIter cs = li; cs.forward_chars (idx);
                        Gtk.TextIter ce = cs; ce.forward_chars (prefix.length);
                        buffer.delete (ref cs, ref ce);
                    }
                } else {
                    buffer.insert (ref li, prefix, -1);
                }
            }
            buffer.end_user_action ();
        }

        private string? comment_prefix () {
            var lang = buffer.get_language ();
            if (lang == null) return "# ";
            switch (lang.id) {
                case "c": case "cpp": case "chdr": case "java":
                case "javascript": case "typescript": case "rust":
                case "go": case "vala": case "swift": case "kotlin":
                case "csharp": case "php":
                    return "// ";
                case "python": case "ruby": case "sh": case "bash":
                case "perl": case "yaml": case "cmake": case "r":
                case "julia":
                    return "# ";
                case "lua": case "sql": case "haskell":
                    return "-- ";
                case "lisp": case "scheme":
                    return "; ";
                default:
                    return "# ";
            }
        }

        public void goto_line (int line_num) {
            int n = int.max (0, line_num - 1);
            n = int.min (n, buffer.get_line_count () - 1);
            Gtk.TextIter it;
            buffer.get_iter_at_line (out it, n);
            buffer.place_cursor (it);
            view.scroll_to_mark (buffer.get_insert (), 0.1, true, 0.0, 0.5);
            view.grab_focus ();
        }

        //  Zoom

        public void apply_font_size_delta (int delta) {
            string base_font = (settings != null)
                ? settings.get_string ("font-name") : "Monospace 12";
            string[] parts = base_font.split (" ");
            if (parts.length < 2) { apply_font_css_string (base_font); return; }
            int base_sz = int.parse (parts[parts.length - 1]);
            if (base_sz <= 0) base_sz = 12;
            int new_sz = int.max (6, base_sz + delta);
            string family = string.joinv (" ", parts[0:parts.length - 1]);
            apply_font_css_string ("%s %d".printf (family, new_sz));
        }

        public void reset_font_size () {
            update_font ();
        }

        //  Minimap

        public void set_minimap_visible (bool v) {
            minimap.visible = v;
        }

        //  Recent files

        private void add_to_recent () {
            if (file == null || settings == null) return;
            string uri    = file.get_uri ();
            string[] old  = settings.get_strv ("recent-files");
            string[] upd  = {};
            foreach (string r in old)
                if (r != uri) upd += r;
            string[] result = {uri};
            foreach (string r in upd) result += r;
            if (result.length > 10)
                result = result[0:10];
            settings.set_strv ("recent-files", result);
            Gtk.RecentManager.get_default ().add_item (uri);
        }

        ~EditorTab () {
            if (autosave_id != 0) Source.remove (autosave_id);
            if (_ts_highlighter != null) _ts_highlighter.detach ();
        }

        //  Tree-sitter outline + folding wiring

        private bool _fold_shortcuts_installed = false;

        private void install_fold_shortcuts () {
            if (_fold_shortcuts_installed) return;
            _fold_shortcuts_installed = true;

            var sc = new Gtk.ShortcutController ();
            sc.scope = Gtk.ShortcutScope.LOCAL;
            view.add_controller (sc);

            var fold_action = new Gtk.CallbackAction ((w, args) => {
                fold_at_cursor ();
                return true;
            });
            sc.add_shortcut (new Gtk.Shortcut (
                Gtk.ShortcutTrigger.parse_string ("<Control>minus"),
                fold_action));

            var unfold_all_action = new Gtk.CallbackAction ((w, args) => {
                if (_ts_folding != null) _ts_folding.unfold_all ();
                return true;
            });
            sc.add_shortcut (new Gtk.Shortcut (
                Gtk.ShortcutTrigger.parse_string ("<Control>equal"),
                unfold_all_action));
        }

        private void fold_at_cursor () {
            if (_ts_folding == null) return;
            Gtk.TextIter it;
            buffer.get_iter_at_mark (out it, buffer.get_insert ());
            _ts_folding.toggle_at_line (it.get_line (), _ts_folds);
        }

        public void fold_at_cursor_public () { fold_at_cursor (); }
        public void unfold_all_public () {
            if (_ts_folding != null) _ts_folding.unfold_all ();
        }

        private void on_ts_tree_updated () {
            if (_ts_highlighter == null) return;
            unowned TS.Tree? tree = _ts_highlighter.tree;
            if (tree == null) return;

            Gtk.TextIter s, e;
            buffer.get_bounds (out s, out e);
            var text = buffer.get_text (s, e, true);
            _outline_entries = TsOutline.extract (_ts_highlighter.def, tree, text);
            outline_changed (this);

            if (_ts_folding != null) {
                _ts_folds = _ts_folding.compute (tree);
                _ts_folding.reapply ();
            }
        }

        public void jump_to_outline_entry (OutlineEntry entry) {
            Gtk.TextIter target;
            buffer.get_iter_at_line (out target, entry.line);
            buffer.place_cursor (target);
            view.scroll_to_iter (target, 0.2, true, 0.0, 0.3);
            view.grab_focus ();
        }
    }

}
