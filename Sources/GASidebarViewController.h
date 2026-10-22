#import <AppKit/AppKit.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GAPendingSelectionScroll) {
    GAPendingSelectionScrollGroup = 0,
    GAPendingSelectionScrollSelectedToTopIfNeeded,
};

@interface GASidebarViewController : NSViewController

@property (nonatomic, copy, nullable) void (^onTextChanged)(void);
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(GAGlyphVariant * _Nullable variant);
@property (nonatomic, copy, nullable) void (^onGlyphActivated)(GACharacterGroup *group, GAGlyphVariant *variant);
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSAttributedString *attributedText;
/// Selected range in the field editor, or NSNotFound when the field is not
/// being edited.
@property (nonatomic, readonly) NSRange inputSelectionRange;

- (void)setAttributedText:(NSAttributedString *)attributedText;
- (void)setGroups:(NSArray<GACharacterGroup *> *)groups;
/// Replaces the list with an intermediate analysis result. A normal restore
/// keeps the selected row without notifying the delegate. A pending selection
/// is resolved when its group/row appears, scrolled into view, and notifies the
/// delegate once; otherwise it waits without restoring the old selection.
- (void)applyStreamedGroups:(NSArray<GACharacterGroup *> *)groups;
- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey
                            textRange:(NSRange)textRange;
/// Explicit selection with a scroll policy. `Group` keeps the existing
/// character-group rules; `SelectedToTopIfNeeded` scrolls only when the
/// selected row is completely outside the visible area, aligning it to the top.
- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey
                            textRange:(NSRange)textRange
                               scroll:(GAPendingSelectionScroll)scroll;
/// Appends text and optionally marks it as a selection run. Returns the range
/// of the appended text, or NSMakeRange(NSNotFound, 0) when nothing was added.
- (NSRange)appendInputString:(NSString *)string
                   selection:(nullable GAGlyphSelection *)selection;
/// Returns the custom field editor when \c control is the search field, so
/// the window can keep line breaks as marked U+23CE characters.
- (nullable NSTextView *)fieldEditorForControl:(id _Nullable)control;
- (void)focusInput;
- (void)setGlyphListDimmed:(BOOL)dimmed;

@end

NS_ASSUME_NONNULL_END
