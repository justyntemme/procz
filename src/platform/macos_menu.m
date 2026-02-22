#import <AppKit/AppKit.h>
#include "macos_menu.h"

// ---------------------------------------------------------------------------
// Delegate handles custom menu actions and routes them back to Zig via flags.
// ---------------------------------------------------------------------------

static volatile int _settings_requested = 0;

@interface ProcZMenuDelegate : NSObject
- (void)openSettings:(id)sender;
@end

@implementation ProcZMenuDelegate
- (void)openSettings:(id)sender {
    (void)sender;
    _settings_requested = 1;
}
@end

static ProcZMenuDelegate *_delegate = nil;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void setup_native_menu(void) {
    _delegate = [[ProcZMenuDelegate alloc] init];

    NSMenu *mainMenu = [[NSMenu alloc] init];

    // ---- App menu (leftmost, named after the app) ----
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"procz"];

    [appMenu addItemWithTitle:@"About procz"
                       action:@selector(orderFrontStandardAboutPanel:)
                keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *settingsItem =
        [[NSMenuItem alloc] initWithTitle:@"Settings\u2026"
                                   action:@selector(openSettings:)
                            keyEquivalent:@","];
    [settingsItem setTarget:_delegate];
    [appMenu addItem:settingsItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hideItem =
        [[NSMenuItem alloc] initWithTitle:@"Hide procz"
                                   action:@selector(hide:)
                            keyEquivalent:@"h"];
    [appMenu addItem:hideItem];

    [appMenu addItemWithTitle:@"Hide Others"
                       action:@selector(hideOtherApplications:)
                keyEquivalent:@""];

    [appMenu addItemWithTitle:@"Show All"
                       action:@selector(unhideAllApplications:)
                keyEquivalent:@""];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem =
        [[NSMenuItem alloc] initWithTitle:@"Quit procz"
                                   action:@selector(terminate:)
                            keyEquivalent:@"q"];
    [appMenu addItem:quitItem];

    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];

    // ---- File menu ----
    NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];

    NSMenuItem *fileSettingsItem =
        [[NSMenuItem alloc] initWithTitle:@"Settings\u2026"
                                   action:@selector(openSettings:)
                            keyEquivalent:@","];
    [fileSettingsItem setTarget:_delegate];
    // Use Cmd+Shift+, to avoid conflict with app menu Cmd+,
    [fileSettingsItem setKeyEquivalentModifierMask:
        NSEventModifierFlagCommand | NSEventModifierFlagShift];
    [fileMenu addItem:fileSettingsItem];

    [fileMenu addItem:[NSMenuItem separatorItem]];

    [fileMenu addItemWithTitle:@"Close Window"
                        action:@selector(performClose:)
                 keyEquivalent:@"w"];

    [fileMenuItem setSubmenu:fileMenu];
    [mainMenu addItem:fileMenuItem];

    // ---- Apply ----
    [[NSApplication sharedApplication] setMainMenu:mainMenu];
}

int check_settings_requested(void) {
    int val = _settings_requested;
    if (val) _settings_requested = 0;
    return val;
}
