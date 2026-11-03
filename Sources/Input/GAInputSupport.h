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

typedef NS_OPTIONS(NSUInteger, GAInputMenuOptions) {
    GAInputMenuFont = 1 << 0,
    GAInputMenuSpelling = 1 << 1,
    GAInputMenuSubstitutions = 1 << 2,
};
/// Removes the requested native text feature groups.
FOUNDATION_EXPORT void GAFilterInputMenu(NSMenu *menu, GAInputMenuOptions options);
/// Places a related command directly after the native text editing commands.
FOUNDATION_EXPORT void GAInsertTextMenuItem(NSMenu *menu, NSMenuItem *item);
NS_ASSUME_NONNULL_END
