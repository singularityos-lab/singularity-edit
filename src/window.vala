using Gtk;
using GLib;
using Singularity.Edit;
using Singularity;
using Singularity.Widgets;

namespace Singularity.Apps {

    [GtkTemplate(ui = "/dev/sinty/edit/ui/main.ui")]
    public class EditWindow : Singularity.Widgets.Window, Singularity.Edit.Workspace {

        public Singularity.Widgets.TabContainer tab_container { get; private set; }
        public Workbench workbench { get; private set; }
        public Gtk.Revealer debug_strip_revealer { get; private set; }
        private ProblemsView _problems;
        public DebugController debug { get; private set; }
        private TasksView _tasks;
        private MenuButton _people_btn;
        private Label _people_count;
        private ProjectSearchView _search;
        private Gtk.Button _problems_btn;
        private Gtk.Label _errors_lbl;
        private Gtk.Label _warnings_lbl;

        private EditApp         _app;
        private GLib.Settings?  _settings;
        private StatusBar       _statusbar;
        private FileBrowserPane _file_browser;
        [GtkChild (name = "root_stack")]   unowned Stack       _root_stack;
        private bool            _sidebar_visible = true;
        private bool            _minimap_visible = false;
        private int             _font_size_delta = 0;
        private Gtk.Button? _md_btn = null;
        private OutlinePanel    _outline_panel;
        private Gtk.Revealer    _outline_revealer;
        private ulong           _outline_tab_handler = 0;
        private EditorTab?      _outline_observed_tab = null;
        [GtkChild (name = "root_overlay")] unowned Gtk.Overlay _root_overlay;
        private CommandPalette  _palette;
        private Box             _editor_box;
        private Singularity.Widgets.HoverControls? _bubble_bar = null;
        private Singularity.Widgets.ChipBar? _tab_chips = null;
        private HashTable<unowned EditorTab, string>? _tab_to_chip = null;
        private HashTable<string, unowned EditorTab>? _chip_to_tab = null;
        private HashTable<unowned EditorTab, ulong>? _markdown_handlers = null;
        private uint _chip_counter = 0;
        private bool _suppress_chip_sync = false;
        private bool _session_owner = true;

        private void sync_md_btn_visibility () {
            _app.sync_document_actions ();
            if (_md_btn == null) return;
            var tab = get_current_tab ();
            _md_btn.visible = (tab != null && tab.is_markdown);
        }

        public EditWindow (EditApp app, GLib.Settings? settings, bool restore_session = true) {
            Object (application: app);
            _app      = app;
            _settings = settings;
            _session_owner = restore_session;
            if (!restore_session) _sidebar_visible = false;
            _build_ui ();
            var close_act = new SimpleAction ("close", null);
            close_act.activate.connect (() => close ());
            add_action (close_act);
            notify["fullscreened"].connect (() => _app.sync_document_actions ());
            close_request.connect(_on_close_request);
            if (restore_session) _restore_session ();
            workspace_ready = true;
            _app.announce_workspace (this);
        }

        public bool workspace_ready { get; private set; default = false; }

        private void _build_ui () {
            set_title (_("Edit"));
            set_default_size (1100, 700);

            //  Stack: welcome / editor (root_overlay + root_stack from ui/main.vetro)
            _root_stack.transition_duration = 180;

            // Welcome page
            var wp = new Singularity.Widgets.WelcomePage ();
            wp.app_icon_name = "dev.sinty.edit";
            wp.title    = _("Edit");
            wp.subtitle = _("Open a file to get started");
            wp.add_action (
                "text-x-generic",
                "New File",
                "Create a blank document.",
                () => add_tab (null)
            );
            wp.add_action (
                "folder-open",
                "Open File",
                "Choose a file from disk to edit.",
                () => open_file_dialog ()
            );
            _root_stack.add_named (wp, "welcome");

            // Editor area: tab container + statusbar
            _editor_box = new Box (Orientation.VERTICAL, 0);
            _editor_box.hexpand = true;
            _editor_box.vexpand = true;

            tab_container = new Singularity.Widgets.TabContainer ();
            tab_container.hexpand = true;
            tab_container.vexpand = true;
            _editor_box.append (tab_container);

            // Bottom dock: outline panel inside a Revealer for slide-up.
            _outline_panel = new OutlinePanel ();
            _outline_panel.entry_activated.connect (_on_outline_entry_activated);
            _outline_panel.close_requested.connect (() => _set_outline_revealed (false));

            _outline_revealer = new Gtk.Revealer ();
            _outline_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_UP;
            _outline_revealer.transition_duration = 180;
            _outline_revealer.reveal_child = false;
            _outline_revealer.vexpand = false;
            _outline_revealer.valign = Gtk.Align.END;
            _outline_revealer.set_child (_outline_panel);
            _editor_box.append (_outline_revealer);

            workbench = new Workbench ();
            _editor_box.append (workbench.panel_revealer);

            debug = new DebugController (this);
            _problems = new ProblemsView ();
            _problems.activated.connect (_on_problem_activated);
            workbench.register_view (new WorkbenchView ("problems", _("Problems"),
                WorkbenchRegion.PANEL, _problems, 0));
            _problems_btn = new Gtk.Button ();
            _problems_btn.add_css_class ("flat");
            _problems_btn.visible = false;
            var counts = new Box (Orientation.HORIZONTAL, 5);
            var err_img = new Image.from_icon_name ("edit-diagnostic-error");
            err_img.pixel_size = 12;
            counts.append (err_img);
            _errors_lbl = new Label ("0");
            counts.append (_errors_lbl);
            var warn_img = new Image.from_icon_name ("edit-diagnostic-warning");
            warn_img.pixel_size = 12;
            warn_img.margin_start = 6;
            counts.append (warn_img);
            _warnings_lbl = new Label ("0");
            counts.append (_warnings_lbl);
            _problems_btn.child = counts;
            _problems_btn.clicked.connect (() => {
                if (workbench.panel_revealer.reveal_child)
                    workbench.panel_revealer.reveal_child = false;
                else
                    workbench.show_view ("problems");
            });
            workbench.add_status_item (_problems_btn, StatusAlign.START, _("Problems"));
            _people_btn = new MenuButton ();
            _people_btn.add_css_class ("flat");
            var people_box = new Box (Orientation.HORIZONTAL, 5);
            var people_icon = new Image.from_icon_name ("system-users-symbolic");
            people_icon.pixel_size = 12;
            people_box.append (people_icon);
            _people_count = new Label ("");
            people_box.append (_people_count);
            _people_btn.child = people_box;
            _people_btn.visible = false;
            var people_pop = new Popover ();
            people_pop.show.connect (() => fill_people (people_pop));
            _people_btn.popover = people_pop;
            workbench.add_status_item (_people_btn, StatusAlign.END, _("People"));
            EditCollab.get_default ().changed.connect (() => sync_people ());

            _statusbar = new StatusBar ();
            _statusbar.attach_items (workbench.status_start, workbench.status_end);
            _statusbar.outline_toggled.connect (_on_outline_toggled);
            if (_settings != null)
                _settings.bind ("show-statusbar", _statusbar, "visible", SettingsBindFlags.DEFAULT);
            _editor_box.append (_statusbar);

            debug_strip_revealer = new Gtk.Revealer ();
            debug_strip_revealer.transition_type = Gtk.RevealerTransitionType.SLIDE_DOWN;
            debug_strip_revealer.reveal_child = false;
            _editor_box.prepend (debug_strip_revealer);

            var workspace = new Box (Orientation.HORIZONTAL, 0);
            workspace.append (_editor_box);
            workspace.append (workbench.inspector_revealer);
            _root_stack.add_named (workspace, "editor");
            _root_stack.visible_child_name = "welcome";

            // root_overlay (from the template) lets the command palette float
            // above the editor (à la VS Code Ctrl+Shift+P).
            _palette = new CommandPalette ();
            _palette.close_requested.connect (_hide_palette);
            _root_overlay.add_overlay (_palette);

            // Window owns the bubble bar; we just register actions in
            // _setup_toolbar(). set_content wraps with the bar lazily.
            set_content(_root_overlay);

            // Ctrl+P opens the palette.
            var pal_sc = new Gtk.ShortcutController ();
            pal_sc.scope = Gtk.ShortcutScope.MANAGED;
            pal_sc.add_shortcut (new Gtk.Shortcut (
                Gtk.ShortcutTrigger.parse_string ("<Control>p"),
                new Gtk.CallbackAction ((w, args) => { _open_palette (); return true; })));
            ((Gtk.Widget) this).add_controller (pal_sc);

            //  Sidebar
            _file_browser = new FileBrowserPane (this);
            set_sidebar_width (288);
            set_sidebar (workbench.sidebar);
            workbench.register_view (new WorkbenchView ("files", _("Files"),
                WorkbenchRegion.SIDEBAR, _file_browser, 0));
            _search = new ProjectSearchView (this);
            _search.open_location.connect ((p, l, c) => open_file (File.new_for_path (p), l, c));
            workbench.register_view (new WorkbenchView ("search", _("Search"),
                WorkbenchRegion.SIDEBAR, _search, 10));
            _tasks = new TasksView ();
            _tasks.open_location.connect ((p, l, c) => open_file (File.new_for_path (p), l, c));
            workbench.register_view (new WorkbenchView ("tasks", _("Tasks"),
                WorkbenchRegion.PANEL, _tasks, 20));
            set_sidebar_visible (_sidebar_visible);

            //  Toolbar
            _setup_toolbar ();

            //  Tab container signals
            tab_container.page_added.connect   (_on_page_added);
            tab_container.page_removed.connect (_on_page_removed);
            tab_container.switch_page.connect  (_on_page_switched);
        }

        private void _setup_toolbar () {
            var sidebar_btn = add_bubble_icon ("sidebar-show-symbolic", "Toggle Sidebar (Ctrl+B)", () => {});
            sidebar_btn.action_name = "app.toggle-sidebar";

            var new_btn  = add_bubble_icon ("document-new-symbolic",  "New (Ctrl+N)",   () => {});
            new_btn.action_name  = "app.new-file";

            var open_btn = add_bubble_icon ("document-open-symbolic", "Open (Ctrl+O)",  () => {});
            open_btn.action_name = "app.open";

            var save_btn = add_bubble_icon ("document-save-symbolic", "Save (Ctrl+S)",  () => {});
            save_btn.action_name = "app.save";

            var share_btn = add_bubble_icon ("singularity-share-symbolic", _("Share"), () => {});
            share_btn.action_name = "app.share";

            _md_btn = add_bubble_icon ("view-dual-symbolic", "Markdown Preview", () => {});
            _md_btn.action_name = "app.toggle-md-preview";
            _md_btn.visible = false;

            tab_container.notebook.notify["page"].connect (() => sync_md_btn_visibility ());
            tab_container.notebook.switch_page.connect ((page, _idx) => {
                GLib.Idle.add (() => {
                    sync_md_btn_visibility ();
                    sync_people ();
                    active_document_changed ();
                    return GLib.Source.REMOVE;
                });
            });

            // Tabs are rendered as a ChipBar pinned at the bottom of the
            // editor box. The notebook's own tab strip stays hidden; the
            // ChipBar mirrors it via signal forwarding.
            tab_container.tab_scroll.unparent ();
            tab_container.tab_scroll.visible = false;
            tab_container.notebook.show_tabs = false;

            _tab_chips = new Singularity.Widgets.ChipBar ();
            _tab_chips.add_css_class ("edit-bottom-tabs");
            _tab_chips.hexpand = true;
            // Tabs can be reordered by dragging the chips.
            _tab_chips.reorderable = true;
            _tab_chips.detachable = true;
            // File names are precious - show them in full; the bar
            // scrolls horizontally when tabs overflow.
            _tab_chips.ellipsize_labels = false;
            _tab_to_chip = new HashTable<unowned EditorTab, string> (direct_hash, direct_equal);
            _chip_to_tab = new HashTable<string, unowned EditorTab> (str_hash, str_equal);
            _markdown_handlers = new HashTable<unowned EditorTab, ulong> (direct_hash, direct_equal);

            _tab_chips.chip_activated.connect ((id) => {
                if (_suppress_chip_sync) return;
                var t = _chip_to_tab.lookup (id);
                if (t != null) {
                    int idx = tab_container.notebook.page_num (t);
                    if (idx >= 0) tab_container.notebook.set_current_page (idx);
                }
            });
            _tab_chips.chip_closed.connect ((id) => {
                var t = _chip_to_tab.lookup (id);
                if (t != null) _request_close_tab (t);
            });
            _tab_chips.chip_detached.connect ((id) => {
                var t = _chip_to_tab.lookup (id);
                if (t != null) _app.detach_tab (this, t);
            });
            // Mirror a chip drag-reorder onto the underlying notebook pages.
            _tab_chips.chips_reordered.connect ((ids) => {
                _suppress_chip_sync = true;
                for (int i = 0; i < ids.length; i++) {
                    var t = _chip_to_tab.lookup (ids[i]);
                    if (t != null) tab_container.notebook.reorder_child (t, i);
                }
                _suppress_chip_sync = false;
            });
            _editor_box.append (_tab_chips);
        }

        //  Tab management

        public void add_tab (GLib.File? file) {
            if (file != null) {
                int n = tab_container.get_n_pages ();
                for (int i = 0; i < n; i++) {
                    var p = tab_container.notebook.get_nth_page (i) as EditorTab;
                    if (p != null && p.file != null && p.file.equal (file)) {
                        tab_container.notebook.set_current_page (i);
                        return;
                    }
                }
            }
            _attach_tab (new EditorTab (file, _settings));
        }

        private void _attach_tab (EditorTab tab) {
            tab_container.add_tab (tab, tab.title);
            tab.state_changed.connect  (_on_tab_state_changed);
            tab.cursor_changed.connect (_on_tab_cursor_changed);
            tab.lsp_changed.connect (_on_tab_lsp_changed);
            _on_tab_lsp_changed (tab);
            DebugManager.get_default ().install (tab);
            tab.view.line_mark_activated.connect ((iter, button, state, n_presses) => {
                if (button == 1) DebugManager.get_default ().toggle (tab, iter.get_line ());
            });
            document_added (tab);
            ulong handler = tab.notify["is-markdown"].connect (() => sync_md_btn_visibility ());
            _markdown_handlers.insert (tab, handler);
            tab_container.notebook.set_current_page (
                tab_container.notebook.page_num (tab));
            Idle.add (() => {
                if (tab.get_root () == this) tab.view.grab_focus ();
                return Source.REMOVE;
            });
            if (_settings != null && _settings.get_boolean ("show-minimap"))
                tab.set_minimap_visible (true);
            sync_md_btn_visibility ();
        }

        private void _disconnect_tab (EditorTab tab) {
            tab.state_changed.disconnect  (_on_tab_state_changed);
            tab.cursor_changed.disconnect (_on_tab_cursor_changed);
            tab.lsp_changed.disconnect (_on_tab_lsp_changed);
            _problems.untrack (tab);
            DebugManager.get_default ().capture (tab);
            document_removed (tab);
            _update_problem_counts ();
            ulong handler = _markdown_handlers.lookup (tab);
            if (handler != 0) tab.disconnect (handler);
            _markdown_handlers.remove (tab);
        }

        internal bool release_tab (EditorTab tab) {
            if (tab_container.notebook.page_num (tab) < 0) return false;
            _disconnect_tab (tab);
            tab_container.remove_tab (tab);
            if (tab_container.get_n_pages () == 0) {
                _root_stack.visible_child_name = "welcome";
                set_title (_("Edit"));
            }
            return true;
        }

        internal void adopt_tab (EditorTab tab) {
            _attach_tab (tab);
            if (tab.file != null) _file_browser.navigate_to_file_dir (tab.file);
        }

        public Singularity.Edit.Workbench get_workbench () { return workbench; }
        public Gtk.Window get_toplevel () { return this; }
        public Singularity.Edit.Document? get_active_document () { return get_current_tab (); }

        public GLib.File? get_project_root () {
            var tab = get_current_tab ();
            var dir = tab != null && tab.file != null ? tab.file.get_parent () : _file_browser.current_dir;
            var start = dir;
            while (dir != null) {
                if (dir.get_child (".git").query_exists ()) return dir;
                dir = dir.get_parent ();
            }
            return start;
        }

        public Singularity.Edit.Document[] documents () {
            Singularity.Edit.Document[] out_ = {};
            foreach (var t in _collect_tabs ()) out_ += t;
            return out_;
        }

        public Singularity.Edit.Document? open_file (GLib.File file, int line = -1, int column = -1) {
            add_tab (file);
            _file_browser.navigate_to_file_dir (file);
            var tab = get_current_tab ();
            if (tab != null && line >= 0) {
                Idle.add (() => {
                    tab.goto_position (line, column);
                    return Source.REMOVE;
                });
            }
            return tab;
        }

        public void notify_user (string message) {
            add_toast (new Toast (message));
        }

        public void set_overlay_strip (Gtk.Widget? widget) {
            debug_strip_revealer.child = widget;
            debug_strip_revealer.reveal_child = widget != null;
        }

        public void open_file_dialog () {
            var dialog = new FileChooserNative (
                "Open File", this, FileChooserAction.OPEN, "Open", "Cancel");
            dialog.response.connect ((resp) => {
                if (resp == ResponseType.ACCEPT)
                    add_tab (dialog.get_file ());
                dialog.destroy ();
            });
            dialog.show ();
        }

        public EditorTab? get_current_tab () {
            return tab_container.get_current_page () as EditorTab;
        }

        public bool sidebar_shown { get { return _sidebar_visible; } }
        public bool minimap_shown { get { return _minimap_visible; } }
        public bool outline_shown { get { return _outline_revealer != null && _outline_revealer.reveal_child; } }

        public void open_command_palette () { _open_palette (); }

        public void cycle_tab (int delta) {
            int n = tab_container.notebook.get_n_pages ();
            if (n < 2) return;
            int cur = tab_container.notebook.get_current_page ();
            tab_container.notebook.set_current_page (((cur + delta) % n + n) % n);
        }

        public void clipboard_action (int kind) {
            var tab = get_current_tab ();
            if (tab == null) return;
            var clipboard = tab.view.get_clipboard ();
            if (kind == 0) tab.buffer.cut_clipboard (clipboard, tab.view.editable);
            else if (kind == 1) tab.buffer.copy_clipboard (clipboard);
            else tab.buffer.paste_clipboard (clipboard, null, tab.view.editable);
            tab.view.grab_focus ();
        }

        public void save_current ()    { get_current_tab ()?.save (); }
        public void save_current_as () { get_current_tab ()?.save_as (); }
        public void revert_current ()  { get_current_tab ()?.revert (); }

        public void close_current_tab () {
            var tab = get_current_tab ();
            if (tab != null) _request_close_tab (tab);
        }

        public void close_all_tabs () {
            EditorTab[] tabs = _collect_tabs ();
            foreach (var t in tabs) _request_close_tab (t);
        }

        public void close_other_tabs () {
            var current = get_current_tab ();
            if (current == null) return;
            foreach (var t in _collect_tabs ()) {
                if (t != current) _request_close_tab (t);
            }
        }

        public void close_tabs_to_right () {
            int cur = tab_container.notebook.get_current_page ();
            if (cur < 0) return;
            // Close from end backwards so indices don't shift under us.
            int n = tab_container.notebook.get_n_pages ();
            for (int i = n - 1; i > cur; i--) {
                var t = tab_container.notebook.get_nth_page (i) as EditorTab;
                if (t != null) _request_close_tab (t);
            }
        }

        public void close_tabs_to_left () {
            int cur = tab_container.notebook.get_current_page ();
            if (cur <= 0) return;
            // Close from 0 forwards; each close shifts cur down by 1, so just
            // hit index 0 repeatedly `cur` times.
            for (int i = 0; i < cur; i++) {
                var t = tab_container.notebook.get_nth_page (0) as EditorTab;
                if (t != null) _request_close_tab (t);
            }
        }

        private EditorTab[] _collect_tabs () {
            var arr = new GenericArray<EditorTab> ();
            int n = tab_container.notebook.get_n_pages ();
            for (int i = 0; i < n; i++) {
                var t = tab_container.notebook.get_nth_page (i) as EditorTab;
                if (t != null) arr.add (t);
            }
            return arr.steal ();
        }

        private void _request_close_tab (EditorTab tab) {
            if (!tab.modified) {
                _do_close_tab (tab);
                return;
            }
            ulong close_save_id    = 0;
            ulong close_discard_id = 0;
            ulong close_cancel_id  = 0;
            close_save_id    = tab.close_save.connect ((t) => {
                t.disconnect (close_save_id);
                t.disconnect (close_discard_id);
                t.disconnect (close_cancel_id);
                t.save ();
                _do_close_tab (t);
            });
            close_discard_id = tab.close_discard.connect ((t) => {
                t.disconnect (close_save_id);
                t.disconnect (close_discard_id);
                t.disconnect (close_cancel_id);
                _do_close_tab (t);
            });
            close_cancel_id  = tab.close_cancel.connect ((t) => {
                t.disconnect (close_save_id);
                t.disconnect (close_discard_id);
                t.disconnect (close_cancel_id);
            });
            tab.show_close_confirmation ();
        }

        private void _do_close_tab (EditorTab tab) {
            _disconnect_tab (tab);
            tab_container.remove_tab (tab);
            if (tab_container.get_n_pages () == 0) {
                _root_stack.visible_child_name = "welcome";
                set_title (_("Edit"));
            }
        }

        private void _on_tab_lsp_changed (EditorTab tab) {
            if (tab.lsp != null) _problems.track (tab);
            _problems.refresh ();
            _update_problem_counts ();
        }

        private void _update_problem_counts () {
            int errors, warnings;
            _problems.counts (out errors, out warnings);
            _errors_lbl.label = errors.to_string ();
            _warnings_lbl.label = warnings.to_string ();
            bool any_lsp = false;
            foreach (var t in _collect_tabs ()) if (t.lsp != null) any_lsp = true;
            _problems_btn.visible = any_lsp;
        }

        private void _on_problem_activated (EditorTab tab, int line, int col) {
            int idx = tab_container.notebook.page_num (tab);
            if (idx >= 0) tab_container.notebook.set_current_page (idx);
            if (tab.lsp == null) return;
            var it = tab.lsp.iter_from_lsp (line, col);
            tab.buffer.place_cursor (it);
            tab.view.scroll_to_iter (it, 0.2, false, 0.0, 0.0);
            tab.view.grab_focus ();
        }

        public void goto_definition () {
            var tab = get_current_tab ();
            if (tab == null || tab.lsp == null) return;
            ulong handler = 0;
            handler = tab.lsp.definition_found.connect ((uri, line, character) => {
                tab.lsp.disconnect (handler);
                open_file (File.new_for_uri (uri), line, character);
            });
            tab.lsp.goto_definition.begin ((obj, res) => {
                if (!tab.lsp.goto_definition.end (res) && handler != 0) tab.lsp.disconnect (handler);
            });
        }

        private Popover cursor_popover (EditorTab tab) {
            Gtk.TextIter it;
            tab.buffer.get_iter_at_mark (out it, tab.buffer.get_insert ());
            Gdk.Rectangle r;
            tab.view.get_iter_location (it, out r);
            int wx, wy;
            tab.view.buffer_to_window_coords (Gtk.TextWindowType.WIDGET, r.x, r.y, out wx, out wy);
            r.x = wx;
            r.y = wy;
            var pop = new Popover ();
            pop.add_css_class ("edit-cursor-popover");
            pop.set_parent (tab.view);
            pop.pointing_to = r;
            pop.position = PositionType.BOTTOM;
            pop.has_arrow = false;
            pop.closed.connect (() => {
                Idle.add (() => {
                    pop.unparent ();
                    return Source.REMOVE;
                });
            });
            return pop;
        }

        public void rename_symbol () {
            var tab = get_current_tab ();
            if (tab == null || tab.lsp == null || tab.lsp.client == null) return;
            if (!tab.lsp.client.supports ("renameProvider")) {
                notify_user (_("Renaming is not available for this file"));
                return;
            }
            var pop = cursor_popover (tab);
            var entry = new Entry ();
            entry.text = tab.lsp.word_at_cursor ();
            entry.width_chars = 28;
            entry.activates_default = false;
            var box = new Box (Orientation.VERTICAL, 6);
            box.margin_start = box.margin_end = box.margin_top = box.margin_bottom = 6;
            var title = new Label (_("Rename Symbol"));
            title.xalign = 0;
            title.add_css_class ("caption-heading");
            box.append (title);
            box.append (entry);
            pop.child = box;
            entry.activate.connect (() => {
                var name = entry.text.strip ();
                pop.popdown ();
                if (name == "") return;
                bool utf8 = tab.lsp.client.utf8_positions;
                tab.lsp.rename.begin (name, (obj, res) => {
                    var edit = tab.lsp.rename.end (res);
                    if (edit == null) {
                        notify_user (_("Nothing to rename here"));
                        return;
                    }
                    LspManager.get_default ().workspace_edit (edit, utf8);
                });
            });
            pop.popup ();
            entry.grab_focus ();
            entry.select_region (0, -1);
        }

        public void quick_fix () {
            var tab = get_current_tab ();
            if (tab == null || tab.lsp == null) return;
            tab.lsp.code_actions.begin ((obj, res) => {
                var actions = tab.lsp.code_actions.end (res);
                if (actions == null || actions.get_length () == 0) {
                    notify_user (_("No quick fixes here"));
                    return;
                }
                var pop = cursor_popover (tab);
                var list = new Box (Orientation.VERTICAL, 0);
                list.margin_top = list.margin_bottom = 4;
                for (uint i = 0; i < actions.get_length () && i < 12; i++) {
                    var action = actions.get_object_element (i);
                    var btn = new Button ();
                    btn.add_css_class ("flat");
                    btn.add_css_class ("edit-quick-fix");
                    var label = new Label (action.get_string_member ("title"));
                    label.xalign = 0;
                    label.ellipsize = Pango.EllipsizeMode.END;
                    label.max_width_chars = 60;
                    btn.child = label;
                    btn.clicked.connect (() => {
                        pop.popdown ();
                        tab.lsp.run_code_action.begin (action);
                    });
                    list.append (btn);
                }
                pop.child = list;
                pop.popup ();
            });
        }

        private void sync_people () {
            var tab = get_current_tab ();
            var d = tab != null ? EditCollab.get_default ().for_tab (tab) : null;
            _people_btn.visible = d != null;
            if (d != null) _people_count.label = "%d".printf (d.people ().length + 1);
        }

        private void fill_people (Popover pop) {
            var tab = get_current_tab ();
            var d = tab != null ? EditCollab.get_default ().for_tab (tab) : null;
            var box = new Box (Orientation.VERTICAL, 4);
            box.margin_start = box.margin_end = box.margin_top = box.margin_bottom = 6;
            box.width_request = 260;
            if (d == null) {
                pop.child = box;
                return;
            }
            foreach (var name in d.people ()) {
                var row = new Box (Orientation.HORIZONTAL, 8);
                var avatar = new Label (name.length >= 2 ? name.substring (0, 2).up () : name.up ());
                avatar.add_css_class ("edit-collab-avatar");
                var css = new CssProvider ();
                string[] palette = { "#d97757", "#2a78d6", "#2ea043", "#8957e5", "#d4a72c", "#e5534b", "#0f9d9a" };
                css.load_from_string ("label { background-color: %s; }".printf (palette[str_hash (name) % palette.length]));
                avatar.get_style_context ().add_provider (css, STYLE_PROVIDER_PRIORITY_USER + 4);
                row.append (avatar);
                var label = new Label (name);
                label.xalign = 0;
                label.hexpand = true;
                row.append (label);
                var follow = new ToggleButton.with_label (d.following == name ? _("Following") : _("Follow"));
                follow.active = d.following == name;
                follow.add_css_class ("flat");
                string who = name;
                follow.toggled.connect (() => {
                    d.following = follow.active ? who : null;
                    follow.label = follow.active ? _("Following") : _("Follow");
                });
                row.append (follow);
                box.append (row);
            }
            var actions = new Box (Orientation.HORIZONTAL, 6);
            actions.halign = Align.END;
            var invite = new Button.with_label (_("Invite"));
            invite.add_css_class ("pill");
            invite.clicked.connect (() => {
                pop.popdown ();
                d.session.pick_and_share (_people_btn, (person) => notify_user (_("Invitation sent to %s").printf (person.name)));
            });
            actions.append (invite);
            var stop = new Button.with_label (d.session.hosting ? _("Stop Sharing") : _("Leave"));
            stop.add_css_class ("pill");
            stop.add_css_class ("destructive-action");
            stop.clicked.connect (() => {
                pop.popdown ();
                EditCollab.get_default ().stop (tab);
            });
            actions.append (stop);
            box.append (actions);
            pop.child = box;
        }

        public void edit_together () {
            var tab = get_current_tab ();
            if (tab == null) return;
            if (!EditCollab.available ()) {
                notify_user (_("Turn on Nearby to edit together"));
                return;
            }
            EditCollab.get_default ().share (this, tab, _people_btn.visible ? (Widget) _people_btn : (Widget) _problems_btn.get_parent ());
        }

        public void run_task (TaskDef task) {
            foreach (var d in documents ()) if (d.get_modified ()) d.save ();
            workbench.show_view ("tasks");
            _tasks.run (task);
        }

        public void run_build_task () {
            var root = get_project_root ();
            if (root == null || root.get_path () == null) return;
            foreach (var t in TaskDetector.detect (root.get_path ())) {
                if (t.build) {
                    run_task (t);
                    return;
                }
            }
            notify_user (_("No build task found for this project"));
        }

        public void search_project () {
            string? seed = null;
            var tab = get_current_tab ();
            if (tab != null) {
                Gtk.TextIter s, e;
                if (tab.buffer.get_selection_bounds (out s, out e) && s.get_line () == e.get_line ())
                    seed = tab.buffer.get_text (s, e, false);
            }
            if (!_sidebar_visible) toggle_sidebar ();
            workbench.show_view ("search");
            _search.focus_query (seed);
        }

        public void format_document () {
            var tab = get_current_tab ();
            if (tab != null && tab.lsp != null) tab.lsp.format.begin ();
        }

        //  Find / Go-to-line

        public void show_find (bool replace) {
            get_current_tab ()?.find_bar.show_find (replace);
        }

        public void show_goto_line () {
            var tab = get_current_tab ();
            if (tab == null) return;

            var pop = new Popover ();
            var box = new Box (Orientation.HORIZONTAL, 8);
            box.margin_start  = 12;
            box.margin_end    = 12;
            box.margin_top    = 8;
            box.margin_bottom = 8;

            box.append (new Label (_("Go to line:")));
            var spin = new SpinButton.with_range (
                1, tab.buffer.get_line_count (), 1);
            spin.width_chars = 6;
            box.append (spin);

            var go_btn = new Button.with_label (_("Go"));
            go_btn.add_css_class ("suggested-action");
            box.append (go_btn);

            pop.set_child (box);
            pop.set_parent (toolbar);

            go_btn.clicked.connect (() => {
                tab.goto_line ((int) spin.value);
                pop.popdown ();
            });
            spin.activate.connect (() => {
                tab.goto_line ((int) spin.value);
                pop.popdown ();
            });
            pop.popup ();
        }

        //  Zoom

        public void zoom_change (int delta) {
            _font_size_delta += delta;
            int n = tab_container.get_n_pages ();
            for (int i = 0; i < n; i++) {
                var t = tab_container.notebook.get_nth_page (i) as EditorTab;
                t?.apply_font_size_delta (_font_size_delta);
            }
        }

        public void zoom_reset () {
            _font_size_delta = 0;
            int n = tab_container.get_n_pages ();
            for (int i = 0; i < n; i++) {
                var t = tab_container.notebook.get_nth_page (i) as EditorTab;
                t?.reset_font_size ();
            }
        }

        //  View toggles

        public void toggle_sidebar () {
            _sidebar_visible = !_sidebar_visible;
            set_sidebar_visible (_sidebar_visible);
            if (_session_owner && _settings != null)
                _settings.set_boolean ("sidebar-visible", _sidebar_visible);
        }

        public void toggle_minimap () {
            _minimap_visible = !_minimap_visible;
            int n = tab_container.get_n_pages ();
            for (int i = 0; i < n; i++) {
                var t = tab_container.notebook.get_nth_page (i) as EditorTab;
                t?.set_minimap_visible (_minimap_visible);
            }
        }

        public void toggle_md_preview () {
            var tab = get_current_tab ();
            if (tab != null) tab.toggle_md_preview ();
        }

        public void toggle_fullscreen () {
            if (is_fullscreen ()) unfullscreen ();
            else                  fullscreen ();
        }

        //  Preferences

        public void show_preferences () {
            try {
                Singularity.Shell.ShellService shell = Bus.get_proxy_sync (
                    BusType.SESSION, "dev.sinty.desktop", "/dev/sinty/Shell");
                shell.open_app_settings ("dev.sinty.edit");
            } catch (Error e) {
                warning ("Failed to open settings: %s", e.message);
            }
        }

        public void refresh_all_schemes () {
            int n = tab_container.get_n_pages ();
            for (int i = 0; i < n; i++) {
                var t = tab_container.notebook.get_nth_page (i) as EditorTab;
                t?.refresh_scheme ();
            }
        }

        //  Window close

        private bool _on_close_request() {
            int n = tab_container.get_n_pages();
            bool has_modified = false;
            bool has_unsaved_new = false;
            for (int i = 0; i < n; i++) {
                var t = tab_container.notebook.get_nth_page(i) as EditorTab;
                if (t != null && t.modified) {
                    has_modified = true;
                    if (t.file == null) has_unsaved_new = true;
                }
            }
            if (!has_modified) {
                save_session ();
                return false;
            }

            var dlg = new ConfirmDialog((Gtk.Application)_app,
                "Save Changes?", "dialog-warning-symbolic",
                has_unsaved_new
                    ? "Some documents have never been saved. Save them first, or discard all changes."
                    : "You have unsaved changes in one or more tabs.",
                "Discard All", ConfirmDialog.ActionStyle.DESTRUCTIVE);
            if (!has_unsaved_new)
                dlg.set_secondary("Save All", ConfirmDialog.ActionStyle.SUGGESTED);
            dlg.transient_for = this;

            int shown = 0;
            for (int i = 0; i < n && shown < 8; i++) {
                var t = tab_container.notebook.get_nth_page(i) as EditorTab;
                if (t != null && t.modified) {
                    var row = new Box(Orientation.HORIZONTAL, 8);
                    row.margin_start = 4;
                    row.margin_end = 4;
                    var dot = new Label("\u2022");
                    dot.add_css_class("dim-label");
                    row.append(dot);
                    var lbl = new Label(t.file != null ? t.file.get_basename() : _("Untitled"));
                    lbl.halign = Align.START;
                    lbl.hexpand = true;
                    row.append(lbl);
                    if (t.file == null) {
                        var badge = new Label("(unsaved)");
                        badge.add_css_class("dim-label");
                        badge.add_css_class("caption");
                        row.append(badge);
                    }
                    dlg.custom_area.append(row);
                    shown++;
                }
            }
            if (n > 8) {
                var more = new Label(_("(%d more...)").printf(n - 8));
                more.add_css_class("dim-label");
                dlg.custom_area.append(more);
            }

            dlg.response.connect((r) => {
                if (r == ConfirmDialog.Response.CANCEL) return;
                if (r == ConfirmDialog.Response.SECONDARY) {
                    for (int i = 0; i < n; i++) {
                        var t = tab_container.notebook.get_nth_page(i) as EditorTab;
                        if (t != null && t.modified) t.save();
                    }
                }
                save_session ();
                for (int i = n - 1; i >= 0; i--) {
                    var t = tab_container.notebook.get_nth_page(i) as EditorTab;
                    if (t != null) _do_close_tab(t);
                }
                close();
            });
            dlg.present();
            return true;
        }

        //  Tab signal handlers

        private void _on_tab_state_changed (EditorTab tab) {
            tab_container.set_tab_title (tab, tab.title);
            // Keep the chip label in sync with the tab title (file rename,
            // dirty marker, etc).
            if (_tab_chips != null && _tab_to_chip != null) {
                var id = _tab_to_chip.lookup (tab);
                if (id != null) _tab_chips.update_chip_label (id, tab.title);
            }
            if (tab_container.get_current_page () == tab)
                _update_title ();
            _app.sync_document_actions ();
        }

        private void _on_tab_cursor_changed (EditorTab tab) {
            if (tab_container.get_current_page () == tab)
                _statusbar.update_for_tab (tab);
        }

        private void _on_page_added (Widget page, uint _n) {
            _root_stack.visible_child_name = "editor";
            var tab = page as EditorTab;
            if (tab != null && _tab_chips != null && _tab_to_chip != null) {
                _chip_counter++;
                string id = "chip-" + _chip_counter.to_string ();
                _tab_to_chip.insert (tab, id);
                _chip_to_tab.insert (id, tab);
                _tab_chips.add_chip (id, tab.title);
            }
            GLib.Idle.add (() => { _app.sync_document_actions (); return GLib.Source.REMOVE; });
        }

        private void _on_page_removed (Widget page, uint _n) {
            var tab = page as EditorTab;
            if (tab != null && _tab_chips != null && _tab_to_chip != null) {
                var id = _tab_to_chip.lookup (tab);
                if (id != null) {
                    _tab_chips.remove_chip (id);
                    _chip_to_tab.remove (id);
                    _tab_to_chip.remove (tab);
                }
            }
            _update_title ();
            GLib.Idle.add (() => { _app.sync_document_actions (); return GLib.Source.REMOVE; });
        }

        private void _on_page_switched (Widget? page, uint _n) {
            _update_title ();
            GLib.Idle.add (() => { _app.sync_document_actions (); return GLib.Source.REMOVE; });
            var tab = page as EditorTab;
            _statusbar.update_for_tab (tab);
            if (tab != null && tab.file != null)
                _file_browser.navigate_to_file_dir (tab.file);
            _attach_outline_observer (tab);
            // Sync chip selection without re-triggering page switch.
            if (tab != null && _tab_chips != null && _tab_to_chip != null) {
                var id = _tab_to_chip.lookup (tab);
                if (id != null) {
                    _suppress_chip_sync = true;
                    _tab_chips.set_active (id);
                    _suppress_chip_sync = false;
                }
            }
        }

        //  Outline panel wiring

        private void _attach_outline_observer (EditorTab? tab) {
            if (_outline_observed_tab != null && _outline_tab_handler != 0) {
                _outline_observed_tab.disconnect (_outline_tab_handler);
                _outline_tab_handler = 0;
            }
            _outline_observed_tab = tab;
            if (tab != null) {
                _outline_tab_handler = tab.outline_changed.connect (_on_tab_outline_changed);
                _on_tab_outline_changed (tab);
            } else {
                _statusbar.set_outline_available (false);
                _outline_panel.set_entries ({});
                _outline_panel.set_title_suffix (null);
                if (_outline_revealer.reveal_child)
                    _set_outline_revealed (false);
            }
        }

        private void _on_tab_outline_changed (EditorTab tab) {
            // Trust the observed-tab identity instead of querying the notebook:
            // during `switch_page` the notebook hasn't fully committed the
            // new page yet and `get_current_tab()` can still return the old one.
            if (tab != _outline_observed_tab) return;
            var entries = tab.get_outline_entries ();
            _statusbar.set_outline_available (tab.has_outline ());
            _app.sync_document_actions ();
            _outline_panel.set_entries (entries);
            _outline_panel.set_title_suffix (
                tab.file != null ? tab.file.get_basename () : null);
        }

        private void _on_outline_toggled () {
            _set_outline_revealed (_statusbar.outline_btn.active);
        }

        private void _set_outline_revealed (bool revealed) {
            _outline_revealer.reveal_child = revealed;
            _app.sync_document_actions ();
            if (_statusbar.outline_btn.active != revealed)
                _statusbar.outline_btn.active = revealed;
        }

        private void _on_outline_entry_activated (OutlineEntry entry) {
            var tab = get_current_tab ();
            if (tab != null) tab.jump_to_outline_entry (entry);
        }

        public void toggle_outline_panel () {
            _set_outline_revealed (!_outline_revealer.reveal_child);
        }

        //  Command palette

        private void _open_palette () {
            _palette.set_items (_build_palette_items ());
            _palette.open ();
        }

        private void _hide_palette () {
            _palette.close ();
            get_current_tab ()?.view.grab_focus ();
        }

        private CommandPaletteItem[] _build_palette_items () {
            var items = new GenericArray<CommandPaletteItem> ();

            //  Commands
            items.add (new CommandPaletteItem (
                "document-new-symbolic", "New File", "Create a blank document",
                "Ctrl+N", "Command", () => add_tab (null)));
            items.add (new CommandPaletteItem (
                "document-open-symbolic", "Open File…", "Choose a file from disk",
                "Ctrl+O", "Command", () => open_file_dialog ()));
            items.add (new CommandPaletteItem (
                "document-save-symbolic", "Save", null,
                "Ctrl+S", "Command", () => save_current ()));
            items.add (new CommandPaletteItem (
                "document-save-as-symbolic", "Save As…", null,
                "Ctrl+Shift+S", "Command", () => save_current_as ()));
            items.add (new CommandPaletteItem (
                "edit-undo-symbolic", "Revert", "Reload from disk",
                null, "Command", () => revert_current ()));
            items.add (new CommandPaletteItem (
                "window-close-symbolic", "Close Tab", null,
                "Ctrl+W", "Command", () => close_current_tab ()));
            items.add (new CommandPaletteItem (
                "window-close-symbolic", "Close All Tabs", null,
                null, "Command", () => close_all_tabs ()));
            items.add (new CommandPaletteItem (
                "window-close-symbolic", "Close Other Tabs", null,
                null, "Command", () => close_other_tabs ()));
            items.add (new CommandPaletteItem (
                "go-next-symbolic", "Close Tabs to the Right", null,
                null, "Command", () => close_tabs_to_right ()));
            items.add (new CommandPaletteItem (
                "go-previous-symbolic", "Close Tabs to the Left", null,
                null, "Command", () => close_tabs_to_left ()));
            items.add (new CommandPaletteItem (
                "view-list-symbolic", "Toggle Outline Panel", null,
                null, "Command", () => toggle_outline_panel ()));
            items.add (new CommandPaletteItem (
                "view-sidebar-symbolic", "Toggle Sidebar", null,
                null, "Command", () => toggle_sidebar ()));
            items.add (new CommandPaletteItem (
                "view-grid-symbolic", "Toggle Minimap", null,
                null, "Command", () => toggle_minimap ()));
            items.add (new CommandPaletteItem (
                "view-fullscreen-symbolic", "Toggle Fullscreen", null,
                "F11", "Command", () => toggle_fullscreen ()));
            items.add (new CommandPaletteItem (
                "edit-find-symbolic", "Find", null,
                "Ctrl+F", "Command", () => show_find (false)));
            items.add (new CommandPaletteItem (
                "edit-find-replace-symbolic", "Find and Replace", null,
                "Ctrl+H", "Command", () => show_find (true)));
            items.add (new CommandPaletteItem (
                "go-jump-symbolic", "Go to Line…", null,
                "Ctrl+G", "Command", () => show_goto_line ()));
            items.add (new CommandPaletteItem (
                "preferences-system-symbolic", "Preferences", null,
                null, "Command", () => show_preferences ()));

            foreach (var item in workbench.get_commands ())
                items.add (item);
            var task_root = get_project_root ();
            if (task_root != null && task_root.get_path () != null) {
                foreach (var task in TaskDetector.detect (task_root.get_path ())) {
                    var t = task;
                    items.add (new CommandPaletteItem (
                        "system-run-symbolic", _("Run Task: %s").printf (t.label), null,
                        t.build ? "Ctrl+Shift+B" : null, _("Tasks"), () => run_task (t)));
                }
            }
            if (get_current_tab () != null && EditCollab.available ())
                items.add (new CommandPaletteItem (
                    "system-users-symbolic", _("Edit Together"), null,
                    null, _("Share"), () => edit_together ()));
            items.add (new CommandPaletteItem (
                "system-search-symbolic", _("Search in Project"), null,
                "Ctrl+Shift+F", _("Search"), () => search_project ()));
            if (get_current_tab () != null) {
                items.add (new CommandPaletteItem (
                    "edit-debug-symbolic", debug.active ? _("Continue") : _("Start Debugging"), null,
                    "F5", _("Debug"), () => debug.start_or_continue ()));
                items.add (new CommandPaletteItem (
                    "edit-breakpoint", _("Toggle Breakpoint"), null,
                    "F9", _("Debug"), () => debug.toggle_breakpoint ()));
                if (debug.active)
                    items.add (new CommandPaletteItem (
                        "media-playback-stop-symbolic", _("Stop Debugging"), null,
                        "Shift+F5", _("Debug"), () => debug.stop ()));
            }
            var lsp_tab = get_current_tab ();
            if (lsp_tab != null && lsp_tab.lsp != null && lsp_tab.lsp.client != null) {
                items.add (new CommandPaletteItem (
                    "go-jump-symbolic", _("Go to Definition"), null,
                    "F12", _("Language"), () => goto_definition ()));
                items.add (new CommandPaletteItem (
                    "format-justify-left-symbolic", _("Format Document"), lsp_tab.lsp.client.language,
                    "Shift+Alt+F", _("Language"), () => format_document ()));
                items.add (new CommandPaletteItem (
                    "edit-symbolic", _("Rename Symbol"), null,
                    "F2", _("Language"), () => rename_symbol ()));
                items.add (new CommandPaletteItem (
                    "dialog-information-symbolic", _("Quick Fix"), null,
                    "Ctrl+.", _("Language"), () => quick_fix ()));
                items.add (new CommandPaletteItem (
                    "dialog-error-symbolic", _("Show Problems"), null,
                    null, _("Language"), () => workbench.show_view ("problems")));
            }

            var cur = get_current_tab ();
            if (cur != null && cur.is_markdown) {
                items.add (new CommandPaletteItem (
                    "text-x-generic-symbolic", "Toggle Markdown Preview", null,
                    null, "Command", () => toggle_md_preview ()));
            }
            if (cur != null && cur.has_outline ()) {
                items.add (new CommandPaletteItem (
                    "view-list-symbolic", "Fold at Cursor", null,
                    "Ctrl+-", "Command", () => cur.fold_at_cursor_public ()));
                items.add (new CommandPaletteItem (
                    "view-list-symbolic", "Unfold All", null,
                    "Ctrl+=", "Command", () => cur.unfold_all_public ()));
            }

            //  Open tabs
            int n = tab_container.notebook.get_n_pages ();
            for (int i = 0; i < n; i++) {
                var p = tab_container.notebook.get_nth_page (i) as EditorTab;
                if (p == null) continue;
                string title = p.title.replace ("• ", "");
                string? subtitle = p.file != null ? p.file.get_path () : null;
                var idx = i;
                items.add (new CommandPaletteItem (
                    "text-x-generic-symbolic", title, subtitle,
                    null, "Tab", () => {
                        tab_container.notebook.set_current_page (idx);
                    }));
            }

            return items.steal ();
        }

        private void _update_title () {
            var tab = get_current_tab ();
            set_title (tab != null ? tab.title + _(" - Edit") : _("Edit"));
        }

        //  Session restore / save

        private void _restore_session () {
            if (_settings == null) return;
            string[] uris = _settings.get_strv ("session-files");
            int active = _settings.get_int ("session-active");
            string sidebar_path = _settings.get_string ("sidebar-path");
            bool sidebar_vis = _settings.get_boolean ("sidebar-visible");

            set_sidebar_visible (sidebar_vis);
            _sidebar_visible = sidebar_vis;

            if (sidebar_path != "" && sidebar_path != null) {
                var f = File.new_for_uri (sidebar_path);
                if (f.query_exists ())
                    _file_browser.navigate_to (f);
            }

            if (uris.length == 0) return;

            for (int i = 0; i < uris.length; i++) {
                var f = File.new_for_uri (uris[i]);
                if (f.query_exists ()) {
                    add_tab (f);
                }
            }
            if (active >= 0 && active < (int)tab_container.get_n_pages ()) {
                tab_container.notebook.set_current_page (active);
            }
        }

        public void save_session () {
            if (!_session_owner || _settings == null) return;

            string[] uris = {};
            int n = tab_container.get_n_pages ();
            int active = tab_container.notebook.get_current_page ();
            for (int i = 0; i < n; i++) {
                var t = tab_container.notebook.get_nth_page (i) as EditorTab;
                if (t != null && t.file != null) {
                    uris += t.file.get_uri ();
                } else if (active >= i) {
                    active--;
                }
            }
            _settings.set_strv ("session-files", uris);
            _settings.set_int ("session-active", active);

            var cur_dir = _file_browser.current_dir;
            if (cur_dir != null)
                _settings.set_string ("sidebar-path", cur_dir.get_uri ());
            _settings.set_boolean ("sidebar-visible", _sidebar_visible);
        }
    }

}
