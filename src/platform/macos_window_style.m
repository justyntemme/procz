#import <AppKit/AppKit.h>
#include "macos_window_style.h"

// ---------------------------------------------------------------------------
// Appearance change observer
// ---------------------------------------------------------------------------

static volatile int _appearance_changed = 0;

@interface ProcZAppearanceObserver : NSObject
@end

@implementation ProcZAppearanceObserver
- (void)appearanceChanged:(NSNotification *)notification {
    (void)notification;
    _appearance_changed = 1;
}
@end

static ProcZAppearanceObserver *_observer = nil;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

void setup_window_style(void) {
    // Standard macOS window chrome — no custom titlebar styling.
    // Kept as a hook for future enhancements (e.g. toolbar items).
}

int is_system_dark_mode(void) {
    NSAppearance *appearance = [NSApp effectiveAppearance];
    NSAppearanceName name = [appearance bestMatchFromAppearancesWithNames:@[
        NSAppearanceNameAqua, NSAppearanceNameDarkAqua
    ]];
    return [name isEqualToString:NSAppearanceNameDarkAqua] ? 1 : 0;
}

void register_appearance_observer(void) {
    _observer = [[ProcZAppearanceObserver alloc] init];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:_observer
           selector:@selector(appearanceChanged:)
               name:@"AppleInterfaceThemeChangedNotification"
             object:nil];
}

int check_appearance_changed(void) {
    int val = _appearance_changed;
    if (val) _appearance_changed = 0;
    return val;
}
