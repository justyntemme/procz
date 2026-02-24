#pragma once
#include <stdint.h>

// Get the application icon for a PID as RGBA pixel data.
// Writes into out_rgba (must be at least size*size*4 bytes).
// Returns 1 on success, 0 if no icon available for this PID.
int get_app_icon_rgba(int pid, uint8_t *out_rgba, int size);
