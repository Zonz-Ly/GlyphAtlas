#import "GACmap.h"
#import "GAGlyphSelection.h"
#import "GAOpenType.h"
@interface GATextRun : NSObject
@property(nonatomic, strong) NSMutableArray<GALayoutItem *> *glyphs;
@property(nonatomic) GASpan source;
@property(nonatomic) GATag script;
@property(nonatomic) uint8_t level;
@end
FOUNDATION_EXPORT NSArray<GATextRun *> *GAPrepareText(NSString *text, GACmap *cmap,
                                                      NSArray<GAGlyphSelectionRun *> *selections);
FOUNDATION_EXPORT GATag GAScriptTag(NSString *name);
FOUNDATION_EXPORT GATag GALanguageTag(NSString *name);
FOUNDATION_EXPORT NSArray<NSNumber *> *GAVisualRunOrder(NSArray<GATextRun *> *runs);
