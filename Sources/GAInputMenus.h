#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
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
