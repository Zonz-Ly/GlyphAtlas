#import "GAGlyphSelection.h"
NSString *const GAGlyphSelectionAttributeName = @"com.zonz.GlyphAtlas.glyphSelection";

#pragma mark - GAGlyphSelection

@implementation GAGlyphLayoutRun
@end

@implementation GAGlyphSelection

- (instancetype)initWithSourceText:(NSString *)sourceText
                          glyphIDs:(NSArray<NSNumber *> *)glyphIDs
                    featureSources:(NSArray<NSString *> *)featureSources
                          ligature:(BOOL)ligature {
    self = [super init];
    if (self) {
        _sourceText = [sourceText copy];
        _glyphIDs = [glyphIDs copy];
        _featureSources = [featureSources copy];
        _ligature = ligature;
    }
    return self;
}

@end

@implementation GAGlyphSelectionRun
@end
NSArray<GAGlyphSelectionRun *> *GAGlyphSelectionsInRange(NSArray<GAGlyphSelectionRun *> *runs,
                                                         NSRange range) {
    NSMutableArray *result = [NSMutableArray array];
    for (GAGlyphSelectionRun *run in runs) {
        if (run.range.location < range.location || run.range.length == 0)
            continue;
        NSUInteger offset = run.range.location - range.location;
        if (offset > range.length || run.range.length > range.length - offset)
            continue;
        GAGlyphSelectionRun *copy = [[GAGlyphSelectionRun alloc] init];
        copy.range = NSMakeRange(offset, run.range.length);
        copy.selection = run.selection;
        [result addObject:copy];
    }
    [result
        sortUsingComparator:^NSComparisonResult(GAGlyphSelectionRun *a, GAGlyphSelectionRun *b) {
          return a.range.location < b.range.location   ? NSOrderedAscending
                 : a.range.location > b.range.location ? NSOrderedDescending
                                                       : NSOrderedSame;
        }];
    return result;
}
@interface GAGlyphQueryIdentity ()
@property(nonatomic, copy) NSArray *components;
@property(nonatomic) NSUInteger contentHash;
@end
@implementation GAGlyphQueryIdentity
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self;
}
- (NSUInteger)hash {
    return self.contentHash;
}
- (BOOL)isEqual:(id)object {
    return self == object ||
           ([object isKindOfClass:GAGlyphQueryIdentity.class] &&
            [self.components isEqual:((GAGlyphQueryIdentity *)object).components]);
}
@end
GAGlyphQueryIdentity *GAGlyphQueryKey(NSString *text, NSArray<GAGlyphSelectionRun *> *runs) {
    NSMutableArray *components = [NSMutableArray arrayWithObject:[text copy]];
    NSUInteger hash = text.hash;
    for (GAGlyphSelectionRun *run in runs) {
        [components
            addObject:@[ @(run.range.location), @(run.range.length), run.selection.glyphIDs ]];
        hash = (hash * 31) ^ run.range.location;
        hash = (hash * 31) ^ run.range.length;
        for (NSNumber *glyph in run.selection.glyphIDs)
            hash = (hash * 31) ^ glyph.unsignedIntegerValue;
        hash = (hash * 31) ^ run.selection.glyphIDs.count;
    }
    GAGlyphQueryIdentity *key = [[GAGlyphQueryIdentity alloc] init];
    key.components = components;
    key.contentHash = hash;
    return key;
}
