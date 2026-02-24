#pragma once

// Persistent preferences via NSUserDefaults (keys are auto-prefixed with "procz.").

void defaults_set_int(const char *key, int value);
int defaults_get_int(const char *key, int default_value);

void defaults_set_float(const char *key, float value);
float defaults_get_float(const char *key, float default_value);

// Cross-process theme sync via NSDistributedNotificationCenter.
// Post: broadcasts theme index to all procz processes.
void notify_theme_changed(int theme_index);

// Observe: registers a listener for theme change notifications.
void register_theme_observer(void);

// Returns the new theme index if a change was received, or -1 if none pending.
int check_theme_notification(void);
