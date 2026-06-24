
[GtkTemplate (ui = "/com/absolking/Codex/app_menu.ui")]
public class Codex.AppMenu : Adw.Bin {

	[GtkChild] unowned Gtk.PopoverMenu popover;

	construct {
		popover.add_child (new ThemeSelector (), "theme");
	}
}
