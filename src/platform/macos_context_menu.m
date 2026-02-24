#import <AppKit/AppKit.h>
#include "macos_context_menu.h"

// ---------------------------------------------------------------------------
// Delegate receives menu item actions and records the selection.
// ---------------------------------------------------------------------------

@interface ProcZContextMenuDelegate : NSObject
@property (nonatomic) int selectedAction;
@end

@implementation ProcZContextMenuDelegate

- (void)copyPID:(id)sender {
    (void)sender;
    // Handled below after menu closes — tag stored in menu item
    self.selectedAction = -1; // sentinel for "copy PID"
}

- (void)copyName:(id)sender {
    (void)sender;
    self.selectedAction = -2; // sentinel for "copy name"
}

- (void)killProcess:(id)sender {
    (void)sender;
    self.selectedAction = CTX_ACTION_KILL;
}

- (void)openDetail:(id)sender {
    (void)sender;
    self.selectedAction = CTX_ACTION_DETAIL;
}

@end

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

int show_process_context_menu(int pid, const char *process_name) {
    ProcZContextMenuDelegate *delegate = [[ProcZContextMenuDelegate alloc] init];
    delegate.selectedAction = CTX_ACTION_NONE;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Process"];
    NSString *nameStr = [NSString stringWithUTF8String:process_name];

    // Header: process name (disabled, informational)
    NSMenuItem *header = [[NSMenuItem alloc]
        initWithTitle:nameStr action:nil keyEquivalent:@""];
    header.enabled = NO;
    [menu addItem:header];
    [menu addItem:[NSMenuItem separatorItem]];

    // Copy PID
    NSMenuItem *copyPid = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"Copy PID (%d)", pid]
               action:@selector(copyPID:)
        keyEquivalent:@""];
    [copyPid setTarget:delegate];
    [menu addItem:copyPid];

    // Copy Name
    NSMenuItem *copyName = [[NSMenuItem alloc]
        initWithTitle:@"Copy Name"
               action:@selector(copyName:)
        keyEquivalent:@""];
    [copyName setTarget:delegate];
    [menu addItem:copyName];

    [menu addItem:[NSMenuItem separatorItem]];

    // Open Detail Window
    NSMenuItem *detail = [[NSMenuItem alloc]
        initWithTitle:@"Open Detail Window"
               action:@selector(openDetail:)
        keyEquivalent:@""];
    [detail setTarget:delegate];
    [menu addItem:detail];

    [menu addItem:[NSMenuItem separatorItem]];

    // Terminate Process
    NSMenuItem *kill = [[NSMenuItem alloc]
        initWithTitle:@"Terminate Process"
               action:@selector(killProcess:)
        keyEquivalent:@""];
    [kill setTarget:delegate];
    [menu addItem:kill];

    // Show at current mouse location (blocks until dismissed)
    NSPoint loc = [NSEvent mouseLocation];
    [menu popUpMenuPositioningItem:nil atLocation:loc inView:nil];

    // Handle clipboard actions internally
    if (delegate.selectedAction == -1) {
        // Copy PID
        NSString *pidStr = [NSString stringWithFormat:@"%d", pid];
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:pidStr forType:NSPasteboardTypeString];
        return CTX_ACTION_NONE;
    }
    if (delegate.selectedAction == -2) {
        // Copy Name
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:nameStr forType:NSPasteboardTypeString];
        return CTX_ACTION_NONE;
    }

    return delegate.selectedAction;
}
