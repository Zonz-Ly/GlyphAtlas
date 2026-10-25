#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface GANativeGlyphHit : NSObject
@property(nonatomic) NSRange range;
@property(nonatomic, copy) NSArray<NSNumber *> *glyphIDs;
@end
/// Reads one displayed TextKit 2 line using identical native attributes and its
/// exact typesetter range. This is hit mapping, never candidate discovery.
FOUNDATION_EXPORT NSArray<GANativeGlyphHit *> *GANativeGlyphHitsForLine(NSTextLineFragment *line,
                                                                        BOOL vertical);
/// Projects display aliases/expanded seeds back to atomic original text spans.
FOUNDATION_EXPORT NSArray<GANativeGlyphHit *> *
GAMapNativeGlyphHits(NSArray<GANativeGlyphHit *> *hits, NSArray<NSNumber *> *sourceIndices,
                     NSArray<NSValue *> *atomicRanges, NSString *sourceText);
NS_ASSUME_NONNULL_END
