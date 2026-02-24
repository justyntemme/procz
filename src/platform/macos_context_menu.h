#pragma once

// Context menu action identifiers
#define CTX_ACTION_NONE      0
#define CTX_ACTION_KILL      1
#define CTX_ACTION_DETAIL    2

// Show a native right-click context menu for a process row.
// Copy PID / Copy Name are handled internally (clipboard).
// Returns action ID for operations that need Zig-side handling.
int show_process_context_menu(int pid, const char *process_name);
