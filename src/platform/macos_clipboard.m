#import <AppKit/AppKit.h>
#include "macos_clipboard.h"
#include <string.h>

void clipboard_set_string(const char *text, int len) {
    if (!text || len <= 0) return;
    NSString *str = [[NSString alloc] initWithBytes:text
                                             length:(NSUInteger)len
                                           encoding:NSUTF8StringEncoding];
    if (!str) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:str forType:NSPasteboardTypeString];
}

int clipboard_get_string(char *buf, int max_len) {
    if (!buf || max_len <= 0) return 0;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *str = [pb stringForType:NSPasteboardTypeString];
    if (!str) return 0;
    const char *utf8 = [str UTF8String];
    if (!utf8) return 0;
    int slen = (int)strlen(utf8);
    if (slen > max_len) slen = max_len;
    memcpy(buf, utf8, (size_t)slen);
    return slen;
}
