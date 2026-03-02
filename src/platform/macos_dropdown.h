#pragma once

// Show a native popup menu at the current mouse location with the given items.
// Returns the 0-based index of the selected item, or -1 if cancelled.
// `items` is a null-terminated array of C strings.
int show_dropdown_menu(const char **items, int count, int current_selection);
