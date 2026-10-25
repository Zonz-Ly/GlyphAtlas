#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Input-only widgets, kept independent of the sidebar list controller.
@interface GASearchField : NSSearchField
@end
@interface GASearchFieldEditor : NSTextView
@end

FOUNDATION_EXPORT BOOL GAModifiersAre(NSEventModifierFlags modifiers,
                                      NSEventModifierFlags expected);
FOUNDATION_EXPORT NSString *const GALineBreakAttributeName;
/// A marked U+23CE maps to a real line break; a literal U+23CE remains literal.
FOUNDATION_EXPORT NSAttributedString *
GAModelTextFromFieldText(NSAttributedString *fieldText);
FOUNDATION_EXPORT NSAttributedString *
GAFieldTextFromModelText(NSAttributedString *modelText);
/// Retains app font/color, explicit GID selections, and line-break markers.
FOUNDATION_EXPORT NSAttributedString *
GANormalizedSidebarInput(NSAttributedString *source, NSFont *font,
                         NSColor *color);
NS_ASSUME_NONNULL_END
