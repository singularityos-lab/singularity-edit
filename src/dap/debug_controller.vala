using Gtk;
using GLib;
using Singularity.Widgets;
using Singularity.Edit;

namespace Singularity.Apps {

    public class DebugController : Object {
        private unowned EditWindow win;
        private DebugSession? session;
        private Box strip;
        private ContextRibbon ribbon;
        private RibbonButton continue_btn;
        private RibbonButton step_over_btn;
        private RibbonButton step_into_btn;
        private RibbonButton step_out_btn;
        private Label where;
        private DebugVariablesView vars;
        private DebugStackView stack;
        private DebugConsoleView console;
        private bool views_registered = false;
        private EditorTab? marked_tab;

        public DebugController (EditWindow win) {
            this.win = win;
            vars = new DebugVariablesView ();
            stack = new DebugStackView ();
            console = new DebugConsoleView ();
            build_ribbon ();
        }

        public bool active { get { return session != null && session.state != DebugSession.State.ENDED; } }

        private void build_ribbon () {
            ribbon = new ContextRibbon ("dev.sinty.edit");
            var ctx = ribbon.add_context ("debug", _("Debug"), "edit-debug-symbolic");
            continue_btn = ctx.add_button ("media-playback-pause-symbolic", _("Pause"), _("Continue or Pause (F5)"));
            continue_btn.activated.connect (() => start_or_continue ());
            step_over_btn = ctx.add_button ("edit-redo-symbolic", _("Step Over"), _("Step Over (F10)"));
            step_over_btn.activated.connect (() => step ("next"));
            step_into_btn = ctx.add_button ("go-down-symbolic", _("Step Into"), _("Step Into (F11)"));
            step_into_btn.activated.connect (() => step ("stepIn"));
            step_out_btn = ctx.add_button ("go-up-symbolic", _("Step Out"), _("Step Out (Shift+F11)"));
            step_out_btn.activated.connect (() => step ("stepOut"));
            ctx.add_separator ();
            var restart = ctx.add_button ("view-refresh-symbolic", _("Restart"), _("Restart (Ctrl+Shift+F5)"));
            restart.activated.connect (() => this.restart ());
            var stop_btn = ctx.add_button ("media-playback-stop-symbolic", _("Stop"), _("Stop (Shift+F5)"));
            stop_btn.activated.connect (() => stop ());
            ctx.add_separator ();
            where = new Label (null);
            where.add_css_class ("dim-label");
            where.ellipsize = Pango.EllipsizeMode.END;
            ctx.add_widget (where);
            strip = new Box (Orientation.VERTICAL, 0);
            strip.add_css_class ("edit-debug-strip");
            strip.margin_end = 320;
            strip.append (ribbon);
        }

        private void sync_ribbon () {
            bool stopped = session != null && session.state == DebugSession.State.STOPPED;
            continue_btn.icon_name = stopped ? "media-playback-start-symbolic" : "media-playback-pause-symbolic";
            continue_btn.label = stopped ? _("Continue") : _("Pause");
            step_over_btn.widget.sensitive = stopped;
            step_into_btn.widget.sensitive = stopped;
            step_out_btn.widget.sensitive = stopped;
            where.label = session != null ? session.status : "";
            if (stopped && session.current_frame >= 0 && session.current_frame < session.frames.length) {
                var f = session.frames[session.current_frame];
                if (f.path != null) where.label = "%s · %s:%d".printf (session.status, Path.get_basename (f.path), f.line);
            }
        }

        private void register_views () {
            if (views_registered) return;
            views_registered = true;
            var wb = win.get_workbench ();
            wb.register_view (new WorkbenchView ("debug-console", _("Console"), WorkbenchRegion.PANEL, console, 10));
            wb.register_view (new WorkbenchView ("debug-variables", _("Variables"), WorkbenchRegion.PANEL, vars, 11));
            wb.register_view (new WorkbenchView ("debug-stack", _("Call Stack"), WorkbenchRegion.PANEL, stack, 12));
        }

        public void start_or_continue () {
            if (session != null && session.state == DebugSession.State.STOPPED) {
                session.resume ();
                return;
            }
            if (session != null && session.state == DebugSession.State.RUNNING) {
                session.pause ();
                return;
            }
            if (active) return;
            var tab = win.get_current_tab ();
            if (tab == null) return;
            DebugTarget target;
            try {
                foreach (var d in win.documents ()) DebugManager.get_default ().capture ((EditorTab) d);
                if (tab.modified) tab.save ();
                target = DebugTargets.resolve (tab);
            } catch (Error e) {
                win.notify_user (e.message);
                return;
            }
            begin (target);
        }

        private void begin (DebugTarget target) {
            session = new DebugSession (target);
            DebugManager.get_default ().begin_session (session);
            register_views ();
            console.bind (session);
            vars.bind (session);
            stack.bind (session);
            session.notify["status"].connect (() => sync_ribbon ());
            session.notify["state"].connect (() => sync_ribbon ());
            session.stopped_at.connect (on_stopped_at);
            session.finished.connect (() => {
                clear_marker ();
                sync_ribbon ();
                Timeout.add (1200, () => {
                    if (!active) win.set_overlay_strip (null);
                    return Source.REMOVE;
                });
            });
            sync_ribbon ();
            win.set_overlay_strip (strip);
            win.get_workbench ().show_view ("debug-console");
            session.start.begin ();
        }

        private void on_stopped_at (DebugFrame? frame) {
            clear_marker ();
            sync_ribbon ();
            if (frame == null || frame.path == null) return;
            var file = File.new_for_path (frame.path);
            if (!file.query_exists ()) return;
            var doc = win.open_file (file, int.max (0, frame.line - 1), int.max (0, frame.column - 1)) as EditorTab;
            if (doc == null) return;
            marked_tab = doc;
            Gtk.TextIter s, e;
            doc.buffer.get_iter_at_line (out s, int.max (0, frame.line - 1));
            e = s;
            e.forward_line ();
            doc.buffer.apply_tag (current_tag (doc), s, e);
            doc.buffer.create_source_mark (null, DebugManager.CURRENT, s);
            if (session.state == DebugSession.State.STOPPED && !win.get_workbench ().is_view_visible ("debug-stack"))
                win.get_workbench ().show_view ("debug-variables");
        }

        private Gtk.TextTag current_tag (EditorTab tab) {
            var t = tab.buffer.tag_table.lookup ("edit-debug-line");
            if (t != null) return t;
            t = tab.buffer.create_tag ("edit-debug-line");
            var c = Gdk.RGBA ();
            c.parse ("rgba(212,167,44,0.24)");
            t.paragraph_background_rgba = c;
            return t;
        }

        private void clear_marker () {
            if (marked_tab == null) return;
            Gtk.TextIter s, e;
            marked_tab.buffer.get_bounds (out s, out e);
            var t = marked_tab.buffer.tag_table.lookup ("edit-debug-line");
            if (t != null) marked_tab.buffer.remove_tag (t, s, e);
            marked_tab.buffer.remove_source_marks (s, e, DebugManager.CURRENT);
            marked_tab = null;
        }

        public void step (string command) {
            if (session != null) session.step (command);
        }

        public void stop () {
            if (session != null) session.terminate ();
        }

        public void restart () {
            if (session == null) {
                start_or_continue ();
                return;
            }
            var target = session.target;
            if (active) {
                session.finished.connect (() => Idle.add (() => {
                    begin (target);
                    return Source.REMOVE;
                }));
                session.terminate ();
            } else {
                begin (target);
            }
        }

        public void toggle_breakpoint () {
            var tab = win.get_current_tab ();
            if (tab == null) return;
            Gtk.TextIter it;
            tab.buffer.get_iter_at_mark (out it, tab.buffer.get_insert ());
            DebugManager.get_default ().toggle (tab, it.get_line ());
        }
    }
}
