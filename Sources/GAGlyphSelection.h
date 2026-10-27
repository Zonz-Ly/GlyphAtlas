#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Attribute stored on a selected, unencoded replacement in the input text.
/// The value is a GAGlyphSelection. A run may cover one character or, for a
/// ligature, all of its source characters.
FOUNDATION_EXPORT NSString *const GAGlyphSelectionAttributeName;

/// The persistent metadata for one selected replacement run. It deliberately
/// stores no text offsets: the attributed-string range is the position. The
/// exact glyph IDs are enough because the font does not change for this window.
@interface GAGlyphSelection : NSObject
@property(nonatomic, copy, readonly) NSString *sourceText;
@property(nonatomic, copy, readonly) NSArray<NSNumber *> *glyphIDs;
/// Feature labels for the glyph list, not a shaping recipe.
@property(nonatomic, copy, readonly) NSArray<NSString *> *featureSources;
@property(nonatomic, readonly, getter=isLigature) BOOL ligature;
- (instancetype)initWithSourceText:(NSString *)sourceText
                          glyphIDs:(NSArray<NSNumber *> *)glyphIDs
                    featureSources:(NSArray<NSString *> *)featureSources
                          ligature:(BOOL)ligature NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface GAGlyphSelectionRun : NSObject
@property(nonatomic) NSRange range;
@property(nonatomic, strong) GAGlyphSelection *selection;
@end

/// Immutable query identity: text plus ranges and literal GIDs, without labels.
@interface GAGlyphQueryIdentity : NSObject <NSCopying>
@end
FOUNDATION_EXPORT GAGlyphQueryIdentity *GAGlyphQueryKey(NSString *text,
                                                        NSArray<GAGlyphSelectionRun *> *runs);
NS_ASSUME_NONNULL_END
