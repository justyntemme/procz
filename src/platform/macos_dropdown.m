#import <AppKit/AppKit.h>
#include "macos_dropdown.h"

// ---------------------------------------------------------------------------
// Delegate to capture menu selection.
// ---------------------------------------------------------------------------

@interface ProcZDropdownDelegate : NSObject
@property (nonatomic) int selectedIndex;
@end

@implementation ProcZDropdownDelegate

- (void)menuItemSelected:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    self.selectedIndex = (int)item.tag;
}

@end

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

int show_dropdown_menu(const char **items, int count, int current_selection) {
    ProcZDropdownDelegate *delegate = [[ProcZDropdownDelegate alloc] init];
    delegate.selectedIndex = -1;

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];

    for (int i = 0; i < count; i++) {
        NSString *title = [NSString stringWithUTF8String:items[i]];
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:title
                   action:@selector(menuItemSelected:)
            keyEquivalent:@""];
        [item setTarget:delegate];
        [item setTag:i];
        if (i == current_selection) {
            [item setState:NSControlStateValueOn];
        }
        [menu addItem:item];
    }

    // Show at current mouse location (blocks until dismissed)
    NSPoint loc = [NSEvent mouseLocation];
    [menu popUpMenuPositioningItem:nil atLocation:loc inView:nil];

    return delegate.selectedIndex;
}
