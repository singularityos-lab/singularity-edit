int main () {
    var settings = Singularity.AppPluginHost.desktop_settings ();
    int found = 0;
    foreach (var info in Singularity.AppPluginHost.catalog ()) {
        if (!Singularity.AppPluginHost.is_hosted_by (info, "dev.sinty.edit")) continue;
        print ("%s %s %s\n", info.get_module_name (), info.get_name (), Singularity.AppPluginHost.catalog_enabled (settings, info) ? "on" : "off");
        found++;
    }
    return found >= 3 ? 0 : 1;
}
