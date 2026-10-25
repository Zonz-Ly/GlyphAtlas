#import "GABinary.h"
#import <CoreGraphics/CoreGraphics.h>

typedef struct {
    uint32_t start, end;
} GASpan;
NS_INLINE GASpan GASpanMake(uint32_t start, uint32_t end) { return (GASpan){start, end}; }
NS_INLINE BOOL GASpanEmpty(GASpan span) { return span.start >= span.end; }
NS_INLINE BOOL GASpanEqual(GASpan a, GASpan b) { return a.start == b.start && a.end == b.end; }
NS_INLINE GASpan GAUnite(GASpan a, GASpan b) {
    return GASpanMake(MIN(a.start, b.start), MAX(a.end, b.end));
}
FOUNDATION_EXPORT NSString *GASpanKey(GASpan span);
FOUNDATION_EXPORT NSValue *GASpanValue(GASpan span);
FOUNDATION_EXPORT GASpan GASpanFromValue(NSValue *value);

@interface GALayoutItem : NSObject <NSCopying>
@property(nonatomic) GAGlyph glyph;
@property(nonatomic) GASpan source;
@property(nonatomic) uint32_t scalar;
@property(nonatomic) GATag form;
@property(nonatomic) uint64_t identity;
@property(nonatomic) BOOL ignorable;
@property(nonatomic, copy) NSArray<NSValue *> *components;
@property(nonatomic) NSInteger component;
@property(nonatomic) double xAdvance, yAdvance, xOffset, yOffset;
@end
@interface GALayoutCluster : NSObject
@property(nonatomic) GASpan source;
@property(nonatomic, copy) NSArray<NSNumber *> *glyphs;
@end
@interface GALayoutChange : GALayoutCluster
@property(nonatomic, copy) NSString *feature;
@end
FOUNDATION_EXPORT NSMutableArray<GALayoutItem *> *GACopyBuffer(NSArray<GALayoutItem *> *buffer);
FOUNDATION_EXPORT NSArray<GALayoutCluster *> *GAClusters(NSArray<GALayoutItem *> *buffer);
FOUNDATION_EXPORT NSArray<NSNumber *> *GAGlyphIdentifiers(NSArray<GALayoutItem *> *buffer);
@interface GALayoutTrace : NSObject
@property(nonatomic, strong) NSMutableArray<GALayoutChange *> *changes;
@property(nonatomic) BOOL inventory;
- (void)changed:(NSArray<GALayoutItem *> *)before
          after:(NSArray<GALayoutItem *> *)after
        feature:(NSString *)feature;
@end
@interface GALayoutBudget : NSObject
- (instancetype)initWithInput:(NSUInteger)input;
- (void)step;
- (void)growth:(NSUInteger)count;
@end
@interface GALayoutMetrics : NSObject
@property(nonatomic, copy) double (^horizontalAdvance)(GAGlyph);
@property(nonatomic, copy) double (^verticalAdvance)(GAGlyph);
@property(nonatomic, copy) NSArray<NSNumber *> *normalized;
@end
@interface GAGDEF : NSObject
@property(nonatomic, strong) GAClassDef *glyphClasses, *markAttachmentClasses;
@property(nonatomic, copy) NSArray<GACoverage *> *markSets;
@property(nonatomic, strong) GATableView *variations;
- (instancetype)initWithView:(GATableView *)view;
- (BOOL)includes:(GAGlyph)glyph flags:(unsigned)flags markSet:(unsigned)markSet;
@end
FOUNDATION_EXPORT NSArray<NSNumber *> *GAVisible(NSArray<GALayoutItem *> *buffer, GAGDEF *gdef,
                                                 unsigned flags, unsigned markSet);
