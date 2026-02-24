#pragma once

// Show a native kill-process confirmation dialog (NSAlert).
// Returns 1 if user confirmed "Terminate", 0 if cancelled.
int show_kill_confirm(int pid, const char *process_name);
