/// Secondary destinations the drawer (or something inside it) can open.
/// Pages the drawer opens; [settingsSearch] is ⚙ held down. 快捷入口 stores
/// these by [Enum.name], so a rename here is a change to stored preferences.
enum DrawerDestination { web, remote, plugins, engine, settings, settingsSearch, features }
