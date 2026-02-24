#pragma once

// Apply modern macOS titlebar styling (transparent, full-size content view).
// Call once after sokol_app init().
void setup_window_style(void);

// Returns 1 if the system is in dark mode, 0 for light mode.
int is_system_dark_mode(void);

// Register for system appearance change notifications.
// After calling, check_appearance_changed() returns 1 once per change.
void register_appearance_observer(void);

// Returns 1 and clears the flag if the system appearance changed since last check.
int check_appearance_changed(void);
