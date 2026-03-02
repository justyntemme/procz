#pragma once

typedef struct {
    const char *label;
    const char *program;
    int pid;            // -1 if not running
    int run_at_load;
    int keep_alive;
    int is_user_agent;  // 1=agent, 0=daemon
} StartupItemC;

typedef struct {
    StartupItemC *items;
    int count;
} StartupItemList;

StartupItemList get_startup_items(void);
void free_startup_items(StartupItemList list);
