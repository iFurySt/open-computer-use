#import "OpenComputerUseVirtualDisplayShim.h"

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

// Method surfaces of the private classes, declared as protocols so messaging
// is typed for ARC without creating link-time class references.
@protocol OCUVirtualDisplayMode <NSObject>
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@protocol OCUVirtualDisplay <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

int ocu_virtual_display_is_supported(void) {
    return NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

uint32_t ocu_virtual_display_create(const char *name, uint32_t width, uint32_t height, double refresh_rate, void **handle_out) {
    if (handle_out == NULL || !ocu_virtual_display_is_supported()) {
        return 0;
    }
    *handle_out = NULL;

    @try {
        @autoreleasepool {
            Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
            Class displayClass = NSClassFromString(@"CGVirtualDisplay");
            Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
            Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");

            // Scalars go through KVC so the runtime boxes them with the property's
            // real type encoding instead of a guessed C type.
            NSObject *descriptor = [[descriptorClass alloc] init];
            [descriptor setValue:[NSString stringWithUTF8String:name ?: "Open Computer Use"] forKey:@"name"];
            [descriptor setValue:@(width) forKey:@"maxPixelsWide"];
            [descriptor setValue:@(height) forKey:@"maxPixelsHigh"];
            [descriptor setValue:[NSValue valueWithSize:NSMakeSize(width * 0.26, height * 0.26)] forKey:@"sizeInMillimeters"];
            [descriptor setValue:@(0x0CAC) forKey:@"productID"];
            [descriptor setValue:@(0x0CAC) forKey:@"vendorID"];
            [descriptor setValue:@(1) forKey:@"serialNum"];
            [descriptor setValue:dispatch_get_main_queue() forKey:@"queue"];

            id<OCUVirtualDisplay> display = [[displayClass alloc] initWithDescriptor:descriptor];
            if (display == nil) {
                return 0;
            }

            id<OCUVirtualDisplayMode> mode = [[modeClass alloc] initWithWidth:width height:height refreshRate:refresh_rate];
            NSObject *settings = [[settingsClass alloc] init];
            // 1x only. The active mode is 1x either way; hiDPI=1 only adds scaled
            // modes, and one of those picked later would back the same points with
            // four times the pixels.
            [settings setValue:@(0) forKey:@"hiDPI"];
            [settings setValue:@[mode] forKey:@"modes"];
            if (![display applySettings:settings]) {
                return 0;
            }

            uint32_t displayID = [[(NSObject *)display valueForKey:@"displayID"] unsignedIntValue];
            if (displayID == 0) {
                return 0;
            }
            *handle_out = (void *)CFBridgingRetain(display);
            return displayID;
        }
    } @catch (NSException *exception) {
        // Private KVC keys and selector signatures can change between macOS
        // releases. Treat that as an unavailable capability, not a crash.
        (void)exception;
        return 0;
    }
}

void ocu_virtual_display_destroy(void *handle) {
    if (handle == NULL) {
        return;
    }
    @try {
        @autoreleasepool {
            id display = CFBridgingRelease(handle);
            display = nil;
        }
    } @catch (NSException *exception) {
        // Destruction is best-effort; there is no safe recovery operation for
        // an opaque private object after its teardown throws.
        (void)exception;
    }
}
