#import "GAOpenType.h"
@interface GACatalogueOutput : NSObject
@property(nonatomic) unsigned position, value;
@property(nonatomic, copy) NSArray<NSNumber *> *glyphs;
@property(nonatomic) BOOL directFamily;
@end
@implementation GACatalogueOutput
@end
/// Traverses table edges, preserving which input slot owns each nested action.
@interface GASubstitutionCatalogue : NSObject {
    NSArray<GAOTLookup *> *_lookups;
    GAGDEF *_gdef;
    GAGlyph _seed;
    GALayoutBudget *_budget;
    NSMutableDictionary<NSNumber *, NSArray<GACatalogueOutput *> *> *_memo;
    NSMutableIndexSet *_active;
}
- (instancetype)initWithLookups:(NSArray<GAOTLookup *> *)lookups
                           gdef:(GAGDEF *)gdef
                           seed:(GAGlyph)seed;
- (NSArray<GACatalogueOutput *> *)lookup:(unsigned)index;
@end
@implementation GASubstitutionCatalogue
- (instancetype)initWithLookups:(NSArray<GAOTLookup *> *)lookups
                           gdef:(GAGDEF *)gdef
                           seed:(GAGlyph)seed {
    if ((self = [super init])) {
        _lookups = lookups;
        _gdef = gdef;
        _seed = seed;
        _budget = [[GALayoutBudget alloc] initWithInput:1];
        _memo = [NSMutableDictionary dictionary];
        _active = [NSMutableIndexSet indexSet];
    }
    return self;
}
- (void)append:(NSMutableArray<GACatalogueOutput *> *)outputs
      position:(unsigned)position
        glyphs:(NSArray<NSNumber *> *)glyphs
         value:(unsigned)value
        family:(BOOL)family {
    for (GACatalogueOutput *output in outputs)
        if (output.position == position && output.value == value &&
            [output.glyphs isEqual:glyphs]) {
            output.directFamily |= family;
            return;
        }
    GACatalogueOutput *output = [GACatalogueOutput new];
    output.position = position;
    output.glyphs = glyphs;
    output.value = value;
    output.directFamily = family;
    [outputs addObject:output];
}
- (void)updateSlots:(NSMutableArray<NSNumber *> *)slots
                 at:(unsigned)at
             lookup:(unsigned)lookup
            pattern:(GAOTPattern *)pattern {
    if (lookup >= _lookups.count || at >= slots.count)
        return;
    unsigned owner = slots[at].unsignedIntValue;
    if (owner >= pattern.input.count)
        return;
    GAOTPredicate *predicate = pattern.input[owner];
    GAGlyph glyph;
    if (predicate.kind == GAPredicateExact)
        glyph = predicate.value;
    else if (predicate.kind == GAPredicateCoverage) {
        NSArray<NSNumber *> *glyphs = predicate.coverage.glyphs;
        if (glyphs.count != 1)
            return;
        glyph = glyphs.firstObject.unsignedShortValue;
    } else
        return;
    GAOTLookup *program = _lookups[lookup];
    if (![_gdef includes:glyph flags:program.flags markSet:program.markSet])
        return;
    for (GAOTSubtable *sub in program.subtables) {
        if (![sub.coverage contains:glyph])
            continue;
        if (sub.type != 2)
            return;
        NSUInteger count = GASubstitutionOutputs(sub, glyph).count;
        [_budget growth:slots.count - 1 + count];
        NSMutableArray *replacement = [NSMutableArray array];
        for (NSUInteger i = 0; i < count; i++)
            [replacement addObject:@(owner)];
        [slots replaceObjectsInRange:NSMakeRange(at, 1) withObjectsFromArray:replacement];
        return;
    }
}
- (NSArray<GACatalogueOutput *> *)lookup:(unsigned)index {
    [_budget step];
    if (index >= _lookups.count || [_active containsIndex:index] || _active.count >= 64)
        return @[];
    NSArray *cached = _memo[@(index)];
    if (cached)
        return cached;
    [_active addIndex:index];
    NSMutableArray *outputs = [NSMutableArray array];
    GAOTLookup *program = _lookups[index];
    for (GAOTSubtable *sub in program.subtables) {
        if (sub.type <= 3) {
            if (![_gdef includes:_seed flags:program.flags markSet:program.markSet] ||
                ![sub.coverage contains:_seed])
                continue;
            NSArray<NSNumber *> *glyphs = GASubstitutionOutputs(sub, _seed);
            if (sub.type == 3) {
                for (unsigned i = 0; i < glyphs.count; i++)
                    [self append:outputs position:0 glyphs:@[ glyphs[i] ] value:i + 1 family:YES];
            } else
                [self append:outputs position:0 glyphs:glyphs value:1 family:sub.type == 1];
        } else if (sub.type == 4) {
            // Complete-input ligatures belong to execution, never a component's
            // catalogue.
            continue;
        } else if (sub.type == 8) {
            if (![_gdef includes:_seed flags:program.flags markSet:program.markSet])
                continue;
            NSInteger ci = [sub.coverage index:_seed];
            if (ci < 0)
                continue;
            GATableView *data = sub.data;
            NSUInteger at = 6 + [data u16:4] * 2;
            at += 2 + [data u16:at] * 2;
            if ((NSUInteger)ci >= [data u16:at])
                GAInvalidTable(@"reverse substitute exceeds coverage");
            [self append:outputs
                position:0
                  glyphs:@[ @([data u16:at + 2 + ci * 2]) ]
                   value:1
                  family:NO];
        } else
            for (GAOTPattern *pattern in sub.patterns) {
                NSMutableArray<NSNumber *> *slots = [NSMutableArray array];
                for (NSUInteger i = 0; i < pattern.input.count; i++)
                    [slots addObject:@(i)];
                for (GAOTAction *action in pattern.actions) {
                    [_budget step];
                    if (action.sequence >= slots.count)
                        continue;
                    for (GACatalogueOutput *child in [self lookup:action.lookup]) {
                        NSUInteger position = (NSUInteger)action.sequence + child.position;
                        unsigned owner =
                            position < slots.count
                                ? slots[position].unsignedIntValue
                                : (unsigned)(pattern.input.count + position - slots.count);
                        if (owner < pattern.input.count) {
                            if (![pattern.input[owner] matches:_seed])
                                continue;
                            if (owner == 0 && pattern.firstCoverage.present &&
                                ![pattern.firstCoverage contains:_seed])
                                continue;
                            if (![_gdef includes:_seed flags:program.flags markSet:program.markSet])
                                continue;
                        } else if (owner - pattern.input.count < pattern.lookahead.count &&
                                   ![pattern.lookahead[owner - pattern.input.count] matches:_seed])
                            continue;
                        [self append:outputs
                            position:owner
                              glyphs:child.glyphs
                               value:child.value
                              family:NO];
                    }
                    [self updateSlots:slots
                                   at:action.sequence
                               lookup:action.lookup
                              pattern:pattern];
                }
            }
    }
    [_active removeIndex:index];
    _memo[@(index)] = outputs;
    return outputs;
}
@end
@implementation GAOpenType (Candidates)
- (NSArray<GARelatedSubstitution *> *)relatedSubstitutions:(GAGlyph)seed gdef:(GAGDEF *)gdef {
    if (self.positioning)
        GAInvalidTable(@"positioning program used as substitution catalogue");
    GASubstitutionCatalogue *catalogue =
        [[GASubstitutionCatalogue alloc] initWithLookups:self.lookups gdef:gdef seed:seed];
    NSMutableArray<GARelatedSubstitution *> *result = [NSMutableArray array];
    NSMutableDictionary<NSArray *, GARelatedSubstitution *> *seen =
        [NSMutableDictionary dictionary];
    void (^add)(NSArray<NSNumber *> *, GATag, unsigned, BOOL) =
        ^(NSArray<NSNumber *> *glyphs, GATag feature, unsigned value, BOOL family) {
            if ([glyphs isEqual:@[ @(seed) ]])
                return;
            NSArray *key = @[ @(feature), @(value), glyphs ];
            GARelatedSubstitution *output = seen[key];
            if (output) {
                output.directFamily |= family;
                return;
            }
            output = [GARelatedSubstitution new];
            output.glyphs = glyphs;
            output.feature = feature;
            output.value = value;
            output.directFamily = family;
            seen[key] = output;
            [result addObject:output];
        };
    for (NSUInteger branch = 0; branch < self.branchCount; branch++)
        for (GAOTFeature *feature in [self features:branch])
            for (NSNumber *number in feature.lookups) {
                unsigned index = number.unsignedIntValue;
                for (GACatalogueOutput *output in [catalogue lookup:index])
                    add(output.glyphs, feature.name, output.value, output.directFamily);
                if (index >= self.lookups.count)
                    continue;
                GAOTLookup *lookup = self.lookups[index];
                for (GAOTSubtable *sub in lookup.subtables)
                    if (sub.type == 3)
                        for (NSNumber *input in sub.alternateInputs[@(seed)]) {
                            if (![gdef includes:input.unsignedShortValue
                                          flags:lookup.flags
                                        markSet:lookup.markSet])
                                continue;
                            NSArray<NSNumber *> *glyphs =
                                GASubstitutionOutputs(sub, input.unsignedShortValue);
                            for (unsigned i = 0; i < glyphs.count; i++)
                                add(@[ glyphs[i] ], feature.name, i + 1, YES);
                        }
            }
    return result;
}
@end
