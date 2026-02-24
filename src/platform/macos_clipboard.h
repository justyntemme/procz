#pragma once

// Copy text to system clipboard.
void clipboard_set_string(const char *text, int len);

// Paste text from system clipboard into buf (up to max_len bytes).
// Returns number of bytes written, or 0 if clipboard is empty/non-text.
int clipboard_get_string(char *buf, int max_len);
