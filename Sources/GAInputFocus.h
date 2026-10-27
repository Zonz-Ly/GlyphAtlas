#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Object is the original NSEvent. One application-wide mouse monitor posts
/// blank-area left-mouse-down events while editing is active.
FOUNDATION_EXPORT NSNotificationName const GAInputBlankClickNotification;

/// Let AppKit validate and end field editing outside the clicked window.
FOUNDATION_EXPORT BOOL GAEndInputEditingOutsideWindow(NSWindow *window);

/// Native controls/cells with editing-lifetime hooks only; appearance is inherited.
@interface GAInputTextField : NSTextField
@end

@interface GAInputSearchFieldCell : NSSearchFieldCell
@end

NS_ASSUME_NONNULL_END
