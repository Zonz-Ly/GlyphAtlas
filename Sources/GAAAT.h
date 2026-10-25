#import "GAGlyphBuffer.h"
FOUNDATION_EXPORT NSNumber *GAAATLookup(GATableView *table, GAGlyph glyph, unsigned valueSize);
@interface GAAATSelector : NSObject
@property(nonatomic) unsigned type, setting;
+ (instancetype)type:(unsigned)type setting:(unsigned)setting;
@end
@interface GAAAT : NSObject
- (instancetype)initWithView:(GATableView *)table extended:(BOOL)extended;
@property(nonatomic, readonly) BOOL empty, hasVerticalSubstitutions;
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSArray<GAAATSelector *> *selectors;
- (void)substituteBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                selector:(GAAATSelector *)selector
                     rtl:(BOOL)rtl
                vertical:(BOOL)vertical
                   trace:(GALayoutTrace *)trace
            verticalOnly:(BOOL)verticalOnly;
- (void)applyFeatures:(NSArray<GAAATSelector *> *)selectors
               buffer:(NSMutableArray<GALayoutItem *> *)buffer
                  rtl:(BOOL)rtl
             vertical:(BOOL)vertical
                trace:(GALayoutTrace *)trace
         verticalOnly:(BOOL)verticalOnly;
@end
