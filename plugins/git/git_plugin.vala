using Gtk;
using GLib;
using Singularity.Edit;
using Singularity.Git;
using Singularity.Widgets;

namespace EditGit {

    public const string GIT_APP = "dev.sinty.git";

    public static bool git_app_installed () {
        return new DesktopAppInfo (GIT_APP + ".desktop") != null;
    }

    public class Plugin : Object, Singularity.Edit.Plugin {
        private Host? host;
        private GenericArray<GitWorkspace> attached = new GenericArray<GitWorkspace> ();

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
            foreach (var g in attached.data) g.dispose_all ();
            attached = new GenericArray<GitWorkspace> ();
            host = null;
        }

        private void attach (Workspace ws) {
            attached.add (new GitWorkspace (ws));
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

    public class GitWorkspace : Object {
        public unowned Workspace workspace;
        private MenuButton button;
        private Label branch_label;
        private Label counts_label;
        private Popover popover;
        private GitRepo? repo;
        private StatusReport? report;
        private HashTable<Document, GitDocument> docs = new HashTable<Document, GitDocument> (direct_hash, direct_equal);
        private CommandPaletteItem commit_cmd;
        private CommandPaletteItem open_cmd;
        private uint refresh_id;

        public GitWorkspace (Workspace ws) {
            workspace = ws;
            build_status ();
            foreach (var d in ws.documents ()) add_doc (d);
            ws.document_added.connect (add_doc);
            ws.document_removed.connect (remove_doc);
            ws.active_document_changed.connect (queue_refresh);
            commit_cmd = new CommandPaletteItem ("singularity-git-branch-symbolic", _("Git: Commit All Changes"), null, null, _("Git"), () => {
                Timeout.add (150, () => {
                    if (button.visible) popover.popup ();
                    return Source.REMOVE;
                });
            });
            open_cmd = new CommandPaletteItem ("dev.sinty.git", _("Git: Open Repository in Git"), null, null, _("Git"), () => open_in_git ());
            ws.get_workbench ().register_command (commit_cmd);
            ws.get_workbench ().register_command (open_cmd);
            queue_refresh ();
        }

        public void dispose_all () {
            workspace.document_added.disconnect (add_doc);
            workspace.document_removed.disconnect (remove_doc);
            workspace.active_document_changed.disconnect (queue_refresh);
            workspace.get_workbench ().remove_status_item (button);
            workspace.get_workbench ().unregister_command (commit_cmd);
            workspace.get_workbench ().unregister_command (open_cmd);
            foreach (var g in docs.get_values ()) g.detach ();
            docs.remove_all ();
            if (refresh_id != 0) Source.remove (refresh_id);
        }

        private void build_status () {
            button = new MenuButton ();
            button.add_css_class ("flat");
            var box = new Box (Orientation.HORIZONTAL, 5);
            var icon = new Image.from_icon_name ("singularity-git-branch-symbolic");
            icon.pixel_size = 12;
            box.append (icon);
            branch_label = new Label ("");
            box.append (branch_label);
            counts_label = new Label ("");
            box.append (counts_label);
            button.child = box;
            button.visible = false;
            popover = new Popover ();
            popover.add_css_class ("edit-git-popover");
            popover.show.connect (() => fill_popover ());
            button.popover = popover;
            workspace.get_workbench ().add_status_item (button, StatusAlign.START, _("Source Control"));
        }

        private void add_doc (Document d) {
            if (docs.contains (d)) return;
            var g = new GitDocument (d, this);
            docs.insert (d, g);
            d.saved.connect (queue_refresh);
        }

        private void remove_doc (Document d) {
            var g = docs.lookup (d);
            if (g != null) g.detach ();
            docs.remove (d);
            d.saved.disconnect (queue_refresh);
        }

        public void queue_refresh () {
            if (refresh_id != 0) Source.remove (refresh_id);
            refresh_id = Timeout.add (250, () => {
                refresh_id = 0;
                refresh.begin ();
                return Source.REMOVE;
            });
        }

        private async void refresh () {
            var root = workspace.get_project_root ();
            if (root == null || root.get_path () == null) {
                button.visible = false;
                return;
            }
            var top = yield GitRepo.discover (root.get_path ());
            if (top == null) {
                repo = null;
                button.visible = false;
                return;
            }
            if (repo == null || repo.path != top) repo = new GitRepo (top);
            report = yield repo.status ();
            int changed = report.staged.size + report.unstaged.size + report.untracked.size;
            branch_label.label = report.branch;
            counts_label.visible = changed > 0;
            counts_label.set_markup ("<span foreground=\"#d4a72c\">%d</span>".printf (changed));
            button.tooltip_text = changed > 0 ? ngettext ("%d changed file", "%d changed files", changed).printf (changed) : _("No changes");
            button.visible = true;
            foreach (var g in docs.get_values ()) g.reload.begin ();
        }

        public async GitRepo? repo_for (File file) {
            var parent = file.get_parent ();
            if (parent == null || parent.get_path () == null) return null;
            var top = yield GitRepo.discover (parent.get_path ());
            if (top == null) return null;
            if (repo != null && repo.path == top) return repo;
            return new GitRepo (top);
        }

        private static string letter_markup (FileState state) {
            switch (state) {
                case FileState.ADDED: return "<span foreground=\"#2ea043\" weight=\"bold\">A</span>";
                case FileState.UNTRACKED: return "<span foreground=\"#2ea043\" weight=\"bold\">U</span>";
                case FileState.DELETED: return "<span foreground=\"#e5534b\" weight=\"bold\">D</span>";
                case FileState.RENAMED: return "<span foreground=\"#2a78d6\" weight=\"bold\">R</span>";
                case FileState.CONFLICTED: return "<span foreground=\"#e5534b\" weight=\"bold\">!</span>";
                default: return "<span foreground=\"#d4a72c\" weight=\"bold\">M</span>";
            }
        }

        private void fill_popover () {
            var box = new Box (Orientation.VERTICAL, 8);
            box.margin_start = box.margin_end = 6;
            box.margin_top = box.margin_bottom = 6;
            box.width_request = 340;
            var head = new Box (Orientation.HORIZONTAL, 6);
            var title = new Label (null);
            title.xalign = 0;
            title.hexpand = true;
            title.set_markup ("<b>%s</b>".printf (Markup.escape_text (report != null ? report.branch : "")));
            head.append (title);
            var open = new Button.from_icon_name ("dev.sinty.git");
            open.add_css_class ("flat");
            open.tooltip_text = _("Open in Git");
            open.clicked.connect (() => {
                popover.popdown ();
                open_in_git ();
            });
            head.append (open);
            box.append (head);
            if (!git_app_installed ()) {
                var hint = new Label (_("Install the Git app to commit, browse history and resolve conflicts."));
                hint.wrap = true;
                hint.xalign = 0;
                hint.max_width_chars = 40;
                hint.add_css_class ("dim-label");
                box.append (hint);
                var get = new Button.with_label (_("Get Git"));
                get.add_css_class ("suggested-action");
                get.add_css_class ("pill");
                get.halign = Align.START;
                get.clicked.connect (() => {
                    popover.popdown ();
                    open_store ();
                });
                box.append (get);
                open.visible = false;
                popover.child = box;
                return;
            }
            var list = new Box (Orientation.VERTICAL, 2);
            var all = new Gee.ArrayList<FileChange> ();
            if (report != null) {
                all.add_all (report.conflicts);
                all.add_all (report.staged);
                foreach (var f in report.unstaged) {
                    bool dup = false;
                    foreach (var s in report.staged) if (s.path == f.path) dup = true;
                    if (!dup) all.add (f);
                }
                all.add_all (report.untracked);
            }
            int shown = 0;
            foreach (var change in all) {
                if (shown++ >= 14) break;
                var row = new Button ();
                row.add_css_class ("flat");
                var r = new Box (Orientation.HORIZONTAL, 8);
                var letter = new Label (null);
                letter.set_markup (letter_markup (change.state));
                letter.width_chars = 2;
                r.append (letter);
                var name = new Label (change.path);
                name.xalign = 0;
                name.hexpand = true;
                name.ellipsize = Pango.EllipsizeMode.START;
                r.append (name);
                row.child = r;
                string p = change.path;
                row.clicked.connect (() => {
                    popover.popdown ();
                    if (repo != null) workspace.open_file (File.new_for_path (Path.build_filename (repo.path, p)));
                });
                list.append (row);
            }
            if (all.size == 0) {
                var none = new Label (_("No changes"));
                none.add_css_class ("dim-label");
                none.xalign = 0;
                list.append (none);
            }
            box.append (list);
            if (all.size > 0) {
                var message = new Entry ();
                message.placeholder_text = _("Commit message");
                box.append (message);
                var commit = new Button.with_label (_("Commit All"));
                commit.add_css_class ("suggested-action");
                commit.add_css_class ("pill");
                commit.halign = Align.END;
                commit.sensitive = false;
                message.changed.connect (() => commit.sensitive = message.text.strip () != "");
                message.activate.connect (() => {
                    if (commit.sensitive) commit.clicked ();
                });
                commit.clicked.connect (() => {
                    var text = message.text.strip ();
                    popover.popdown ();
                    foreach (var d in workspace.documents ()) if (d.get_modified ()) d.save ();
                    repo.commit_all.begin (text, (obj, res) => {
                        var r = repo.commit_all.end (res);
                        workspace.notify_user (r.ok ? _("Committed to %s").printf (report.branch) : r.stderr_text.strip ());
                        queue_refresh ();
                    });
                });
                box.append (commit);
                Idle.add (() => {
                    message.grab_focus ();
                    return Source.REMOVE;
                });
            }
            popover.child = box;
        }

        public void open_in_git () {
            if (!git_app_installed ()) {
                open_store ();
                return;
            }
            var info = new DesktopAppInfo (GIT_APP + ".desktop");
            var list = new GLib.List<File> ();
            if (repo != null) list.append (File.new_for_path (repo.path));
            try {
                info.launch (list, workspace.get_toplevel ().get_display ().get_app_launch_context ());
            } catch (Error e) {
                workspace.notify_user (e.message);
            }
        }

        public void open_store () {
            try {
                if (Environment.find_program_in_path ("singularity-store") != null)
                    Process.spawn_command_line_async ("singularity-store --search Git");
                else
                    workspace.notify_user (_("Install Singularity Git to manage this repository"));
            } catch (Error e) {
                workspace.notify_user (e.message);
            }
        }
    }

    public class GitGutter : GtkSource.GutterRenderer {
        public HashTable<uint, int> kinds = new HashTable<uint, int> (direct_hash, direct_equal);
        public signal void hunk_activated (int line, Gtk.TextIter iter);

        construct {
            width_request = 6;
            add_css_class ("edit-git-gutter");
        }

        public override void snapshot_line (Gtk.Snapshot snapshot, GtkSource.GutterLines lines, uint line) {
            if (!kinds.contains (line)) return;
            int kind = kinds.lookup (line);
            int y, h;
            lines.get_line_yrange (line, GtkSource.GutterRendererAlignmentMode.CELL, out y, out h);
            var c = Gdk.RGBA ();
            if (kind == (int) LineChangeKind.ADDED) c.parse ("#2ea043");
            else if (kind == (int) LineChangeKind.MODIFIED) c.parse ("#2a78d6");
            else c.parse ("#e5534b");
            var rect = Graphene.Rect ();
            if (kind == (int) LineChangeKind.DELETED) rect.init (1, y - 2, 4, 4);
            else rect.init (1, y, 3, h);
            snapshot.append_color (c, rect);
        }

        public override bool query_activatable (Gtk.TextIter iter, Gdk.Rectangle area) {
            return kinds.contains ((uint) iter.get_line ());
        }

        public override void activate (Gtk.TextIter iter, Gdk.Rectangle area, uint button, Gdk.ModifierType state, int n_presses) {
            if (button == 1) hunk_activated (iter.get_line (), iter);
        }
    }

    public class GitDocument : Object {
        private unowned Document doc;
        private unowned GitWorkspace owner;
        private string? head;
        private string? relpath;
        private GitRepo? repo;
        private uint timer;
        private ulong changed_id;
        private ulong loaded_id;
        private LineChange[] changes = {};
        private GitGutter gutter;

        public GitDocument (Document doc, GitWorkspace owner) {
            this.doc = doc;
            this.owner = owner;
            var view = doc.get_view ();
            gutter = new GitGutter ();
            view.get_gutter (Gtk.TextWindowType.LEFT).insert (gutter, 10);
            gutter.hunk_activated.connect ((line, iter) => {
                var c = change_at (line);
                if (c != null) show_hunk (c, iter);
            });
            changed_id = doc.get_buffer ().changed.connect (schedule);
            loaded_id = doc.loaded.connect (() => reload.begin ());
            reload.begin ();
        }

        public void detach () {
            if (timer != 0) Source.remove (timer);
            doc.get_buffer ().disconnect (changed_id);
            doc.disconnect (loaded_id);
            doc.get_view ().get_gutter (Gtk.TextWindowType.LEFT).remove (gutter);
        }

        public async void reload () {
            var file = doc.get_file ();
            head = null;
            if (file == null || file.get_path () == null) {
                clear ();
                return;
            }
            repo = yield owner.repo_for (file);
            if (repo == null) {
                clear ();
                return;
            }
            relpath = repo.relative (file);
            if (yield repo.is_tracked (relpath)) head = yield repo.head_text (relpath);
            else head = "";
            update ();
        }

        private void schedule () {
            if (timer != 0) Source.remove (timer);
            timer = Timeout.add (300, () => {
                timer = 0;
                update ();
                return Source.REMOVE;
            });
        }

        private void clear () {
            gutter.kinds.remove_all ();
            gutter.queue_draw ();
            changes = {};
        }

        private void update () {
            if (head == null) return;
            var buffer = doc.get_buffer ();
            Gtk.TextIter s, e;
            buffer.get_bounds (out s, out e);
            changes = LineDiff.compare (head, buffer.get_text (s, e, false));
            gutter.kinds.remove_all ();
            foreach (var c in changes) {
                if (c.kind == LineChangeKind.DELETED) {
                    gutter.kinds.insert ((uint) int.min (c.start, buffer.get_line_count () - 1), (int) c.kind);
                    continue;
                }
                for (int l = c.start; l < c.start + c.count; l++) gutter.kinds.insert ((uint) l, (int) c.kind);
            }
            gutter.queue_draw ();
        }

        private LineChange? change_at (int line) {
            foreach (var c in changes) {
                if (c.kind == LineChangeKind.DELETED && (line == c.start || line == c.start - 1)) return c;
                if (line >= c.start && line < c.start + int.max (1, c.count)) return c;
            }
            return null;
        }

        private void show_hunk (LineChange c, Gtk.TextIter at) {
            var view = doc.get_view ();
            Gdk.Rectangle r;
            view.get_iter_location (at, out r);
            int wx, wy;
            view.buffer_to_window_coords (Gtk.TextWindowType.WIDGET, r.x, r.y, out wx, out wy);
            r.x = wx;
            r.y = wy;
            var pop = new Popover ();
            pop.set_parent (view);
            pop.pointing_to = r;
            pop.position = PositionType.BOTTOM;
            pop.add_css_class ("edit-git-hunk");
            pop.closed.connect (() => Idle.add (() => {
                pop.unparent ();
                return Source.REMOVE;
            }));
            var box = new Box (Orientation.VERTICAL, 6);
            box.margin_start = box.margin_end = box.margin_top = box.margin_bottom = 6;
            var diff = new DiffView ();
            diff.height_request = int.min (240, 22 * (c.old_lines.length + c.count + 1) + 12);
            diff.width_request = 520;
            var text = new StringBuilder ();
            text.append ("@@ -%d +%d @@\n".printf (c.old_start + 1, c.start + 1));
            foreach (var l in c.old_lines) text.append ("-" + l + "\n");
            var buffer = doc.get_buffer ();
            for (int l = c.start; l < c.start + c.count; l++) {
                Gtk.TextIter ls, le;
                buffer.get_iter_at_line (out ls, l);
                le = ls;
                if (!le.ends_line ()) le.forward_to_line_end ();
                text.append ("+" + buffer.get_text (ls, le, false) + "\n");
            }
            diff.show_diff (text.str);
            box.append (diff);
            var revert = new Button.with_label (_("Revert Change"));
            revert.add_css_class ("pill");
            revert.halign = Align.END;
            revert.clicked.connect (() => {
                pop.popdown ();
                revert_change (c);
            });
            box.append (revert);
            pop.child = box;
            pop.popup ();
        }

        private void revert_change (LineChange c) {
            var buffer = doc.get_buffer ();
            Gtk.TextIter s, e;
            if (c.start >= buffer.get_line_count ()) buffer.get_end_iter (out s);
            else buffer.get_iter_at_line (out s, c.start);
            if (c.count > 0) {
                if (c.start + c.count >= buffer.get_line_count ()) buffer.get_end_iter (out e);
                else buffer.get_iter_at_line (out e, c.start + c.count);
            } else {
                e = s;
            }
            var restored = new StringBuilder ();
            foreach (var l in c.old_lines) {
                restored.append (l);
                restored.append_c ('\n');
            }
            buffer.begin_user_action ();
            buffer.delete (ref s, ref e);
            buffer.insert (ref s, restored.str, -1);
            buffer.end_user_action ();
        }
    }
}

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Edit.Plugin), typeof (EditGit.Plugin));
}
