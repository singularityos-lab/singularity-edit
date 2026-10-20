namespace Singularity.Edit {

    public interface Document : Object {
        public signal void saved ();
        public signal void loaded ();

        public abstract File? get_file ();
        public abstract string? get_language_id ();
        public abstract GtkSource.Buffer get_buffer ();
        public abstract GtkSource.View get_view ();
        public abstract bool get_modified ();
        public abstract string[] get_diagnostics ();
        public abstract void goto_position (int line, int column);
        public abstract void save ();
    }

    public interface Workspace : Object {
        public signal void document_added (Document document);
        public signal void document_removed (Document document);
        public signal void active_document_changed ();

        public abstract Workbench get_workbench ();
        public abstract Gtk.Window get_toplevel ();
        public abstract Document? get_active_document ();
        public abstract File? get_project_root ();
        public abstract Document[] documents ();
        public abstract Document? open_file (File file, int line = -1, int column = -1);
        public abstract void notify_user (string message);
        public abstract void set_overlay_strip (Gtk.Widget? widget);
    }

    public interface Host : Object {
        public signal void workspace_added (Workspace workspace);
        public signal void workspace_removed (Workspace workspace);

        public abstract Workspace[] workspaces ();
        public abstract Gtk.Application get_host_application ();
    }

    public interface Plugin : Object {
        public abstract void activate (Host host);
        public abstract void deactivate ();
    }
}
