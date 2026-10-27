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
/// Shift+Return or Shift+double-click: inserts the activated glyph after its
/// own source range instead of replacing the glyph already there.
@property (nonatomic, copy, nullable) void (^onGlyphShiftActivated)(GACharacterGroup *group, GAGlyphVariant *variant);
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSString *selectedGlyphSourceText;
@property (nonatomic, readonly) NSAttributedString *attributedText;
/// Selected range in the field editor, or NSNotFound when the field is not
/// being edited.
@property (nonatomic, readonly) NSRange inputSelectionRange;
/// Whether the sidebar input's field editor is its window's first responder.
@property (nonatomic, readonly, getter=isInputFocused) BOOL inputFocused;

- (void)setAttributedText:(NSAttributedString *)attributedText;
- (void)setGroups:(NSArray<GACharacterGroup *> *)groups;
/// Publishes a text/list snapshot, preserving visible rows across source edits.
- (void)updateGroups:(NSArray<GACharacterGroup *> *)groups sourceText:(NSString *)text;
/// Selects an exact layout glyph sequence and source span without reloading.
/// Does not scroll when the selected row is already fully visible. Otherwise
/// centers its character group, then minimally reveals the selected row.
- (BOOL)selectGlyphIDs:(NSArray<NSNumber *> *)glyphIDs textRange:(NSRange)range;
- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey
                            textRange:(NSRange)textRange;
/// Explicit selection with a scroll policy. `Group` keeps the existing
/// group-centering rules; `SelectedToTopIfNeeded` scrolls only when the
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
/// Return focus to the sidebar glyph list.
- (void)focusGlyphList;
- (void)setGlyphListDimmed:(BOOL)dimmed;

@end

NS_ASSUME_NONNULL_END
