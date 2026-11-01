#import <AppKit/AppKit.h>

@interface GAAppDelegate : NSObject <NSApplicationDelegate>
- (NSMenu *)viewMenuForContext;
- (NSMenuItem *)savedTextMenuItemForWindow:(NSWindow *)window;
@end
