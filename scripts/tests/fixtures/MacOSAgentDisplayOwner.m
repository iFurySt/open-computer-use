#import <Foundation/Foundation.h>
#import "OpenComputerUseVirtualDisplayShim.h"

// Own only a disposable virtual display. The live test kills this process to
// reproduce loss of an owner without the normal OCU restore/exit cleanup.
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) return 2;
        void *handle = NULL;
        uint32_t display = ocu_virtual_display_create("Open Computer Use", 1920, 1080, 60, &handle);
        if (display == 0) return 3;
        NSString *identifier = [NSString stringWithFormat:@"%u", display];
        if (![identifier writeToFile:[NSString stringWithUTF8String:argv[1]] atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 4;
        while (true) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
    }
}
