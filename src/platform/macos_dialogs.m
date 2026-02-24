#import <AppKit/AppKit.h>
#include "macos_dialogs.h"

int show_kill_confirm(int pid, const char *process_name) {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Terminate \"%s\"?", process_name];
    alert.informativeText = [NSString stringWithFormat:
        @"PID %d will be sent SIGTERM. This may cause unsaved data to be lost.", pid];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Terminate"];
    [alert addButtonWithTitle:@"Cancel"];

    NSModalResponse response = [alert runModal];
    return (response == NSAlertFirstButtonReturn) ? 1 : 0;
}
