#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Object is the original NSEvent. One application-wide mouse monitor posts
/// blank-area left-mouse-down events while editing is active.
FOUNDATION_EXPORT NSNotificationName const GAInputBlankClickNotification;

/// Let AppKit validate and end field editing outside the clicked window.
FOUNDATION_EXPORT BOOL GAEndInputEditingOutsideWindow(NSWindow *window);

/// Native numeric control with editing-lifetime hooks.
@interface GAInputTextField : NSTextField
@end

@interface GASearchField : NSSearchField
@end
@interface GAGlyphInputField : NSTextField
@end
@interface GAGlyphInputEditor : NSTextView
@property (nonatomic, weak, nullable) NSUndoManager *inputUndoManager;
@end

FOUNDATION_EXPORT BOOL GAModifiersAre(NSEventModifierFlags modifiers,
                                      NSEventModifierFlags expected);
FOUNDATION_EXPORT NSString *const GALineBreakAttributeName;
/// Returns the visible symbol for a separator, or 0 for ordinary text.
FOUNDATION_EXPORT unichar GAInputSeparatorMarker(unichar separator);
/// Restores the original separators recorded on the visible markers.
FOUNDATION_EXPORT NSAttributedString *
GAModelTextFromFieldText(NSAttributedString *fieldText);
FOUNDATION_EXPORT NSString *GAModelStringFromFieldText(NSAttributedString *fieldText);
FOUNDATION_EXPORT NSAttributedString *
GAFieldTextFromModelText(NSAttributedString *modelText);
/// Retains app font/color, explicit GID selections, and line-break markers.
FOUNDATION_EXPORT NSAttributedString *
GANormalizedSidebarInput(NSAttributedString *source, NSFont *font,
                         NSColor *color);
NS_ASSUME_NONNULL_END
