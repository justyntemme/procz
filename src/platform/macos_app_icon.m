#import <AppKit/AppKit.h>
#include "macos_app_icon.h"
#include <string.h>

int get_app_icon_rgba(int pid, uint8_t *out_rgba, int size) {
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    if (!app) return 0;

    NSImage *icon = app.icon;
    if (!icon) return 0;

    // Render the icon into an RGBA bitmap of the requested size
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:size
                      pixelsHigh:size
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:size * 4
                    bitsPerPixel:32];

    NSGraphicsContext *ctx =
        [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];

    [icon drawInRect:NSMakeRect(0, 0, size, size)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0];

    [NSGraphicsContext restoreGraphicsState];

    memcpy(out_rgba, rep.bitmapData, (size_t)(size * size * 4));
    return 1;
}
