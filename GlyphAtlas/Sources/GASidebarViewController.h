#import <AppKit/AppKit.h>
#import "GAFontEngine.h"

NS_ASSUME_NONNULL_BEGIN

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
- (void)selectGlyphKeyAfterNextReload:(NSString *)glyphKey
                            textRange:(NSRange)textRange;
- (void)focusInput;
- (void)setGlyphListDimmed:(BOOL)dimmed;

@end

NS_ASSUME_NONNULL_END
