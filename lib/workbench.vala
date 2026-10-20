using Gtk;
using GLib;
using Singularity.Widgets;

namespace Singularity.Edit {

    public enum WorkbenchRegion {
        SIDEBAR,
        INSPECTOR,
        PANEL
    }

    public enum StatusAlign {
        START,
        END
    }

    public class WorkbenchView : Object {
        public string id { get; construct; }
        public string title { get; construct; }
        public WorkbenchRegion region { get; construct; }
        public Widget widget { get; construct; }
        public int priority { get; construct; }
        public string? plugin_id { get; set; }

        public WorkbenchView (string id, string title, WorkbenchRegion region,
                              Widget widget, int priority = 50) {
            Object (id: id, title: title, region: region, widget: widget, priority: priority);
        }
    }

    public class WorkbenchRegionHost : Box {
        public WorkbenchRegion region { get; construct; }
        public signal void close_requested ();

        private Box header;
        private SidebarTabs? tabs;
        private Label single_title;
        private Stack stack;
        private InspectorPanel? inspector;
        private GenericArray<WorkbenchView> views = new GenericArray<WorkbenchView> ();

        public WorkbenchRegionHost (WorkbenchRegion region) {
            Object (orientation: Orientation.VERTICAL, spacing: 0, region: region);
        }

        construct {
            add_css_class ("edit-region");
            add_css_class (region_class ());

            if (region == WorkbenchRegion.INSPECTOR) {
                inspector = new InspectorPanel (360);
                inspector.vexpand = true;
                inspector.page_chosen.connect ((name) => inspector.page = name);
                append (inspector);
                return;
            }

            header = new Box (Orientation.HORIZONTAL, 6);
            header.add_css_class ("edit-region-header");
            single_title = new Label (null);
            single_title.xalign = 0;
            single_title.hexpand = true;
            single_title.add_css_class ("heading");
            single_title.visible = false;
            header.append (single_title);
            if (region == WorkbenchRegion.PANEL) {
                var close = new Button.from_icon_name ("window-close-symbolic");
                close.add_css_class ("flat");
                close.valign = Align.CENTER;
                close.tooltip_text = _("Hide Panel");
                close.clicked.connect (() => close_requested ());
                header.append (close);
            }
            append (header);

            stack = new Stack ();
            stack.transition_type = StackTransitionType.CROSSFADE;
            stack.transition_duration = 120;
            stack.vexpand = true;
            stack.hhomogeneous = false;
            stack.vhomogeneous = false;
            append (stack);
        }

        private string region_class () {
            switch (region) {
                case WorkbenchRegion.SIDEBAR: return "edit-region-sidebar";
                case WorkbenchRegion.INSPECTOR: return "edit-region-inspector";
                default: return "edit-region-panel";
            }
        }

        public void add_view (WorkbenchView view) {
            int index = 0;
            while (index < (int) views.length && views[index].priority <= view.priority)
                index++;
            views.insert (index, view);
            if (inspector != null) {
                inspector.add_page (view.id, view.title, "", view.widget, index < 3);
                if (views.length == 1) inspector.page = view.id;
                inspector.switcher.visible = views.length > 1;
                return;
            }
            stack.add_named (view.widget, view.id);
            if (views.length == 1) stack.visible_child_name = view.id;
            rebuild_tabs ();
        }

        public void remove_view (string id) {
            for (uint i = 0; i < views.length; i++) {
                if (views[i].id != id) continue;
                if (stack != null) stack.remove (views[i].widget);
                views.remove_index (i);
                break;
            }
            if (inspector == null) rebuild_tabs ();
        }

        private void rebuild_tabs () {
            if (tabs != null) header.remove (tabs);
            tabs = null;
            bool many = views.length > 1;
            header.visible = many;
            single_title.visible = !many && views.length == 1;
            if (views.length == 1) single_title.label = views[0].title;
            if (!many) return;
            tabs = new SidebarTabs ();
            tabs.margin_bottom = region == WorkbenchRegion.SIDEBAR ? 8 : 0;
            if (region == WorkbenchRegion.PANEL) {
                tabs.homogeneous = false;
                tabs.hexpand = false;
                tabs.halign = Align.START;
                single_title.visible = true;
                single_title.label = "";
            }
            foreach (var view in views.data)
                tabs.add_option (view.id, view.title);
            tabs.set_active (stack.visible_child_name);
            tabs.selected.connect ((name) => stack.visible_child_name = name);
            header.prepend (tabs);
        }

        public void show_view (string id) {
            if (inspector != null) {
                inspector.page = id;
                return;
            }
            if (stack.get_child_by_name (id) == null) return;
            stack.visible_child_name = id;
            if (tabs != null) tabs.set_active (id);
        }

        public uint view_count { get { return views.length; } }
    }

    public class Workbench : Object {
        public signal void view_shown (WorkbenchView view);

        public WorkbenchRegionHost sidebar { get; private set; }
        public WorkbenchRegionHost inspector { get; private set; }
        public WorkbenchRegionHost panel { get; private set; }
        public Revealer inspector_revealer { get; private set; }
        public Revealer panel_revealer { get; private set; }
        public Box status_start { get; private set; }
        public Box status_end { get; private set; }

        private GenericArray<CommandPaletteItem> commands = new GenericArray<CommandPaletteItem> ();

        public signal void commands_changed ();

        public void register_command (CommandPaletteItem item) {
            commands.add (item);
            commands_changed ();
        }

        public void unregister_command (CommandPaletteItem item) {
            commands.remove (item);
            commands_changed ();
        }

        public CommandPaletteItem[] get_commands () {
            return commands.data;
        }

        private HashTable<string, WorkbenchView> by_id =
            new HashTable<string, WorkbenchView> (str_hash, str_equal);

        public Workbench () {
            sidebar = new WorkbenchRegionHost (WorkbenchRegion.SIDEBAR);
            inspector = new WorkbenchRegionHost (WorkbenchRegion.INSPECTOR);
            panel = new WorkbenchRegionHost (WorkbenchRegion.PANEL);

            inspector_revealer = new Revealer ();
            inspector_revealer.transition_type = RevealerTransitionType.SLIDE_LEFT;
            inspector_revealer.transition_duration = 180;
            inspector_revealer.set_child (inspector);
            inspector.close_requested.connect (() => inspector_revealer.reveal_child = false);

            panel.vexpand = false;
            panel.height_request = 210;
            panel_revealer = new Revealer ();
            panel_revealer.vexpand = false;
            panel_revealer.transition_type = RevealerTransitionType.SLIDE_UP;
            panel_revealer.transition_duration = 180;
            panel_revealer.set_child (panel);
            panel.close_requested.connect (() => panel_revealer.reveal_child = false);

            status_start = new Box (Orientation.HORIZONTAL, 0);
            status_end = new Box (Orientation.HORIZONTAL, 0);
        }

        private WorkbenchRegionHost host_for (WorkbenchRegion region) {
            switch (region) {
                case WorkbenchRegion.SIDEBAR: return sidebar;
                case WorkbenchRegion.INSPECTOR: return inspector;
                default: return panel;
            }
        }

        public void register_view (WorkbenchView view) {
            if (by_id.contains (view.id)) return;
            by_id.insert (view.id, view);
            host_for (view.region).add_view (view);
        }

        public void unregister_view (string id) {
            var view = by_id.lookup (id);
            if (view == null) return;
            host_for (view.region).remove_view (id);
            by_id.remove (id);
        }

        public void show_view (string id) {
            var view = by_id.lookup (id);
            if (view == null) return;
            host_for (view.region).show_view (id);
            if (view.region == WorkbenchRegion.INSPECTOR)
                inspector_revealer.reveal_child = true;
            else if (view.region == WorkbenchRegion.PANEL)
                panel_revealer.reveal_child = true;
            view_shown (view);
        }

        public Widget add_status_item (Widget item, StatusAlign align, string? tooltip = null) {
            item.add_css_class ("edit-status-item");
            if (tooltip != null) item.tooltip_text = tooltip;
            if (align == StatusAlign.START) status_start.append (item);
            else status_end.append (item);
            return item;
        }

        public void remove_status_item (Widget item) {
            var parent = item.get_parent ();
            if (parent == status_start) status_start.remove (item);
            else if (parent == status_end) status_end.remove (item);
        }

        public bool is_view_visible (string id) {
            var view = by_id.lookup (id);
            if (view == null) return false;
            if (view.region == WorkbenchRegion.PANEL && !panel_revealer.reveal_child) return false;
            if (view.region == WorkbenchRegion.INSPECTOR && !inspector_revealer.reveal_child) return false;
            return view.widget.get_mapped ();
        }

        public void hide_region (WorkbenchRegion region) {
            if (region == WorkbenchRegion.PANEL) panel_revealer.reveal_child = false;
            else if (region == WorkbenchRegion.INSPECTOR) inspector_revealer.reveal_child = false;
        }
    }
}
