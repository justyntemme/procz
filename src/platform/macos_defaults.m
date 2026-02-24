#import <Foundation/Foundation.h>
#include "macos_defaults.h"

static NSString *prefixed_key(const char *key) {
    return [NSString stringWithFormat:@"procz.%s", key];
}

void defaults_set_int(const char *key, int value) {
    [[NSUserDefaults standardUserDefaults] setInteger:value forKey:prefixed_key(key)];
}

int defaults_get_int(const char *key, int default_value) {
    NSString *k = prefixed_key(key);
    if ([[NSUserDefaults standardUserDefaults] objectForKey:k] == nil)
        return default_value;
    return (int)[[NSUserDefaults standardUserDefaults] integerForKey:k];
}

void defaults_set_float(const char *key, float value) {
    [[NSUserDefaults standardUserDefaults] setFloat:value forKey:prefixed_key(key)];
}

float defaults_get_float(const char *key, float default_value) {
    NSString *k = prefixed_key(key);
    if ([[NSUserDefaults standardUserDefaults] objectForKey:k] == nil)
        return default_value;
    return [[NSUserDefaults standardUserDefaults] floatForKey:k];
}

// ---------------------------------------------------------------------------
// Cross-process theme sync via distributed notifications
// ---------------------------------------------------------------------------

static volatile int _pending_theme = -1;

@interface ProcZThemeObserver : NSObject
@end

@implementation ProcZThemeObserver
- (void)themeChanged:(NSNotification *)notification {
    NSNumber *idx = notification.userInfo[@"index"];
    if (idx) _pending_theme = idx.intValue;
}
@end

static ProcZThemeObserver *_theme_observer = nil;

void notify_theme_changed(int theme_index) {
    NSDictionary *info = @{ @"index": @(theme_index) };
    [[NSDistributedNotificationCenter defaultCenter]
        postNotificationName:@"procz.ThemeChanged"
                      object:nil
                    userInfo:info
          deliverImmediately:YES];
}

void register_theme_observer(void) {
    _theme_observer = [[ProcZThemeObserver alloc] init];
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:_theme_observer
           selector:@selector(themeChanged:)
               name:@"procz.ThemeChanged"
             object:nil];
}

int check_theme_notification(void) {
    int val = _pending_theme;
    if (val >= 0) _pending_theme = -1;
    return val;
}
