#import <AppKit/AppKit.h>
#import "Font/GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, GAPendingSelectionScroll) {
    GAPendingSelectionScrollGroup = 0,
    GAPendingSelectionScrollSelectedToTopIfNeeded,
};

@interface GASidebarViewController : NSViewController

/// Requests analysis after native input or an append prepares its pending selection.
@property (nonatomic, copy, nullable) void (^onTextChanged)(void);
@property (nonatomic, copy, nullable) void (^onInputUndoRedo)(void);
@property (nonatomic, copy, nullable) void (^onSelectionChanged)(GAGlyphVariant * _Nullable variant, BOOL quickReveal);
/// Shift+Return and Shift+double-click insert after the row's source range.
@property (nonatomic, copy, nullable) void (^onGlyphActivated)(GACharacterGroup *group, GAGlyphVariant *variant, BOOL insert);
@property (nonatomic, readonly) NSString *text;
@property (nonatomic, readonly) NSString *selectedGlyphSourceText;
@property (nonatomic, readonly) NSAttributedString *attributedText;
/// Selected range in the field editor, or NSNotFound when the field is not
/// being edited.
@property (nonatomic, readonly) NSRange inputSelectionRange;
/// Whether the sidebar input's field editor is its window's first responder.
@property (nonatomic, readonly, getter=isInputFocused) BOOL inputFocused;

- (void)updateGlyphSelectionsFromText:(NSAttributedString *)text
                              ranges:(NSArray<NSValue *> *)ranges;
- (BOOL)commitGlyphInput:(NSAttributedString *)attributedText actionName:(NSString *)actionName;
/// Replaces the whole input through its native editor, retaining native undo
/// and the existing plain-text/newline conversion.
- (void)replaceInputText:(NSString *)text;
- (void)clearGroups;
/// Publishes a text/list snapshot, preserving visible rows across source edits.
/// A selected temporary row is rebound while its source and parent survive.
- (void)updateGroups:(NSArray<GACharacterGroup *> *)groups
           sourceText:(NSString *)text
         fontDocument:(GAFontDocument *)document;
/// Tracks an unchanged source span through recorded edits since the visible snapshot.
- (NSRange)currentInputRangeForDisplayedRange:(NSRange)range;
/// Selects an exact layout glyph sequence and source span. A miss leaves the
/// list, selection and scroll position untouched while lazy resolution runs.
/// Does not scroll when the selected row is already fully visible. Otherwise
/// centers its character group, then minimally reveals the selected row.
- (BOOL)selectGlyphIDs:(NSArray<NSNumber *> *)glyphIDs textRange:(NSRange)range;
/// Replaces the previous temporary row and selects the result in one update.
/// The new row sits immediately below its existing parent.
- (void)showGlyphResolution:(GAGlyphResolution *)resolution;
- (void)selectBaseForTextRange:(NSRange)range;
/// Explicit selection with a scroll policy. `Group` keeps the existing
/// group-centering rules; `SelectedToTopIfNeeded` scrolls only when the
/// selected row is completely outside the visible area, aligning it to the top.
/// Empty glyph IDs select the source group's base; nil cancels the request.
- (void)selectGlyphIDsAfterNextReload:(nullable NSArray<NSNumber *> *)glyphIDs
                            textRange:(NSRange)textRange
                               scroll:(GAPendingSelectionScroll)scroll;
/// Appends text with an optional selection run, prepares the requested glyph
/// selection, requests analysis, then focuses the input. A failed edit does none
/// of the follow-up work. Empty glyph IDs request the source group's base.
- (void)appendInputString:(NSString *)string
               selection:(nullable GAGlyphSelection *)selection
       selectingGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
              actionName:(NSString *)actionName;
/// Returns the custom field editor when \c control is the active input, so
/// the window can keep line breaks as marked U+23CE characters.
- (nullable NSTextView *)fieldEditorForControl:(id _Nullable)control;
- (void)focusInput;
/// Return focus to the glyph list or to the window when the sidebar is hidden.
- (void)focusGlyphList;
/// Selects the toolbar input, or the sidebar input when the container is nil.
- (void)useInputInToolbarContainer:(nullable NSView *)container;
/// Shown only while the toolbar input is empty; never becomes query text.
- (void)setToolbarInputPlaceholder:(NSString *)placeholder;
- (void)setSidebarContentTopPinned:(BOOL)pinned;
- (void)enableScrollEdgeEffectForSplitViewItem:(NSSplitViewItem *)item API_AVAILABLE(macos(26.0));
- (void)restoreInputSelection:(NSRange)selection;
- (void)setGlyphListDimmed:(BOOL)dimmed;

@end

NS_ASSUME_NONNULL_END
