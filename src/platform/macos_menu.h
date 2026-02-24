#pragma once

// Setup the native macOS menu bar (App menu + File menu with Settings).
// Call once after sokol_app init.
void setup_native_menu(void);

// Setup a minimal menu bar for detail windows (no Settings item).
void setup_detail_menu(void);

// Returns 1 and clears the flag if Settings was requested from the menu.
int check_settings_requested(void);
