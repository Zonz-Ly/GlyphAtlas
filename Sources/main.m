#import <AppKit/AppKit.h>
#import "GAAppDelegate.h"

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        GAAppDelegate *delegate = [[GAAppDelegate alloc] init];
        application.delegate = delegate;
        [application setActivationPolicy:NSApplicationActivationPolicyRegular];
        [application run];
    }
    return 0;
}
