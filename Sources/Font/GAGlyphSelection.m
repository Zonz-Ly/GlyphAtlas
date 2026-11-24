#import "GAGlyphSelection.h"
NSString *const GAGlyphSelectionAttributeName = @"com.zonz.GlyphAtlas.glyphSelection";

#pragma mark - GAGlyphSelection

@implementation GAGlyphSelection

- (instancetype)initWithSourceText:(NSString *)sourceText
                          glyphIDs:(NSArray<NSNumber *> *)glyphIDs
                    featureSources:(NSArray<NSString *> *)featureSources
                          ligature:(BOOL)ligature {
    return [self initWithSourceText:sourceText glyphIDs:glyphIDs markComponents:@[]
        markLigatures:@[] ligatureStructures:@[] featureSources:featureSources ligature:ligature];
}
- (instancetype)initWithSourceText:(NSString *)sourceText
                          glyphIDs:(NSArray<NSNumber *> *)glyphIDs
                    markComponents:(NSArray<NSNumber *> *)components
                     markLigatures:(NSArray<NSNumber *> *)ligatures
                ligatureStructures:(NSArray<NSArray<NSNumber *> *> *)structures
                    featureSources:(NSArray<NSString *> *)featureSources
                          ligature:(BOOL)ligature {
    self = [super init];
    if (self) {
        _sourceText = [sourceText copy];
        _glyphIDs = [glyphIDs copy];
        _markComponents = [components copy];
        _markLigatures = [ligatures copy];
        _ligatureStructures = [structures copy];
        _featureSources = [featureSources copy];
        _ligature = ligature;
    }
    return self;
}

@end

@implementation GAGlyphSelectionRun
@end
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
        [components addObject:@(run.range.location)];
        [components addObject:@(run.range.length)];
        [components addObject:run.selection.glyphIDs];
        hash = (hash * 31) ^ run.range.location;
        hash = (hash * 31) ^ run.range.length;
        for (NSNumber *glyph in run.selection.glyphIDs)
            hash = (hash * 31) ^ glyph.unsignedIntegerValue;
        hash = (hash * 31) ^ run.selection.glyphIDs.count;
        if (run.selection.markComponents.count) {
            [components addObject:run.selection.markComponents];
            [components addObject:run.selection.markLigatures];
            for (NSNumber *component in run.selection.markComponents)
                hash = (hash * 31) ^ component.unsignedIntegerValue;
            for (NSNumber *owner in run.selection.markLigatures) hash=(hash*31)^owner.unsignedIntegerValue;
        }
        if (run.selection.ligatureStructures.count) {
            [components addObject:run.selection.ligatureStructures];
            for (NSArray<NSNumber *> *structure in run.selection.ligatureStructures)
                for (NSNumber *value in structure) hash = (hash * 31) ^ value.unsignedIntegerValue;
        }
    }
    GAGlyphQueryIdentity *key = [[GAGlyphQueryIdentity alloc] init];
    key.components = components;
    key.contentHash = hash;
    return key;
}
