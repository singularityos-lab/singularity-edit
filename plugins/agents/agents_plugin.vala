using Gtk;
using GLib;
using Singularity.Edit;
using Singularity.Widgets;

namespace EditAgents {

    public class Plugin : Object, Singularity.Edit.Plugin {
        private Host? host;
        private GenericArray<AgentWorkspace> attached = new GenericArray<AgentWorkspace> ();
        private static CssProvider? css;
        private static TypeClass[] kept = {};

        public void activate (Host host) {
            this.host = host;
            if (kept.length == 0) {
                foreach (var t in new Type[] { typeof (AcpReply), typeof (ToolCall), typeof (PermissionRequest), typeof (ChangedFile), typeof (AgentEntry) })
                    kept += t.class_ref ();
            }
            if (css == null) {
                css = new CssProvider ();
                css.load_from_string (PANEL_CSS);
                StyleContext.add_provider_for_display (Gdk.Display.get_default (), css, STYLE_PROVIDER_PRIORITY_USER + 3);
            }
            foreach (var ws in host.workspaces ()) attach (ws);
            host.workspace_added.connect (attach);
            host.workspace_removed.connect (detach);
        }

        public void deactivate () {
            if (host != null) {
                host.workspace_added.disconnect (attach);
                host.workspace_removed.disconnect (detach);
            }
            foreach (var a in attached.data) a.dispose_all ();
            attached = new GenericArray<AgentWorkspace> ();
            host = null;
        }

        private void attach (Workspace ws) {
            foreach (var a in attached.data) if (a.workspace == ws) return;
            attached.add (new AgentWorkspace (ws));
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

    public class AgentWorkspace : Object {
        public unowned Workspace workspace;
        private AgentPanel panel;
        private Button button;
        private CommandPaletteItem open_cmd;
        private SimpleAction toggle_action;
        private McpServer mcp;

        public AgentWorkspace (Workspace ws) {
            workspace = ws;
            mcp = new McpServer (ws);
            panel = new AgentPanel (ws);
            panel.mcp = mcp;
            ws.get_workbench ().register_view (new WorkbenchView ("agent", _("Agent"), WorkbenchRegion.INSPECTOR, panel, 0));
            button = new Button ();
            button.add_css_class ("flat");
            var icon = new Image.from_icon_name ("singularity-agents-symbolic");
            icon.pixel_size = 14;
            button.child = icon;
            button.clicked.connect (() => toggle ());
            ws.get_workbench ().add_status_item (button, StatusAlign.END, _("Agent"));
            open_cmd = new CommandPaletteItem ("singularity-agents-symbolic", _("Agent: Open Panel"), null, "Ctrl+I", _("Agent"), () => toggle ());
            ws.get_workbench ().register_command (open_cmd);
            toggle_action = new SimpleAction ("agent-toggle", null);
            toggle_action.activate.connect (() => toggle ());
            var map = ws.get_toplevel () as ActionMap;
            if (map != null) map.add_action (toggle_action);
            var app = ws.get_toplevel ().application;
            if (app != null) app.set_accels_for_action ("win.agent-toggle", { "<Control>i" });
        }

        public void dispose_all () {
            mcp.stop ();
            var wb = workspace.get_workbench ();
            wb.unregister_view ("agent");
            wb.remove_status_item (button);
            wb.unregister_command (open_cmd);
            var map = workspace.get_toplevel () as ActionMap;
            if (map != null) map.remove_action ("agent-toggle");
        }

        private void toggle () {
            var wb = workspace.get_workbench ();
            if (wb.is_view_visible ("agent")) {
                wb.hide_region (WorkbenchRegion.INSPECTOR);
                return;
            }
            wb.show_view ("agent");
            Idle.add (() => {
                panel.focus_input ();
                return Source.REMOVE;
            });
        }
    }
}

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Singularity.Edit.Plugin), typeof (EditAgents.Plugin));
}
