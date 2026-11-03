#import <AppKit/AppKit.h>

@interface GAAppDelegate : NSObject <NSApplicationDelegate>
- (NSMenu *)viewMenuForContextInView:(NSView *)view;
- (NSMenuItem *)savedTextMenuItemForWindow:(NSWindow *)window;
@end
