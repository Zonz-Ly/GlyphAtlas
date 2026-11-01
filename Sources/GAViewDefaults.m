#import "GAViewDefaults.h"
#import "GAViewMode.h"

NSString *const GAViewModeDefaultKey = @"GADefaultViewMode";
NSString *const GABoundingBoxDefaultKey = @"GADefaultShowsBoundingBox";
NSString *const GAContextualAlternatesDefaultKey = @"GADefaultContextualAlternates";
NSString *const GALigaturesDefaultKey = @"GADefaultLigatures";
NSString *const GAVerticalWritingDefaultKey = @"GADefaultVerticalWriting";

NSInteger GAViewDefaultValue(NSUserDefaults *defaults, NSString *key) {
    NSNumber *value = [defaults objectForKey:key];
    if (value) return value.integerValue;
    if ([key isEqualToString:GAViewModeDefaultKey]) return GAViewModeAllGlyphs;
    return ![key isEqualToString:GAVerticalWritingDefaultKey];
}
