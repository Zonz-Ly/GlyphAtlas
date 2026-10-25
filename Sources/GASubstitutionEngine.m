#import "GASubstitutionEngine.h"
#import "GAFontProgram.h"
#import "GATextPreparation.h"
#import "GAVariation.h"
#import <math.h>
@implementation GASubstitutionMatch
@end
static void GAMergeMatch(NSMutableDictionary *seen, NSMutableArray *matches, GASpan span,
                         NSArray<NSNumber *> *glyphs, NSString *source, BOOL base) {
    if (GASpanEmpty(span))
        return;
    NSArray *key = @[ @(span.start), @(span.end), glyphs ];
    GASubstitutionMatch *match = seen[key];
    if (!match) {
        match = [GASubstitutionMatch new];
        match.glyphIDs = glyphs;
        match.sourceRange = NSMakeRange(span.start, span.end - span.start);
        match.sources = @[];
        seen[key] = match;
        [matches addObject:match];
    }
    match.base |= base;
    if (source.length && ![match.sources containsObject:source])
        match.sources = [match.sources arrayByAddingObject:source];
}
static NSMutableArray<GALayoutItem *> *GALiteralBuffer(NSArray<NSNumber *> *glyphs) {
    NSMutableArray *buffer = [NSMutableArray array];
    for (NSUInteger i = 0; i < glyphs.count; i++) {
        GALayoutItem *item = [GALayoutItem new];
        item.glyph = glyphs[i].unsignedShortValue;
        item.source = GASpanMake((uint32_t)i, (uint32_t)i + 1);
        item.identity = i + 1;
        [buffer addObject:item];
    }
    return buffer;
}
static void GAReverseItems(NSMutableArray *items) {
    [items setArray:items.reverseObjectEnumerator.allObjects];
}
static NSArray<NSArray<NSNumber *> *> *GAFeaturePlans(GAFontProgram *program,
                                                      GAQueryDomain *domain) {
    NSMutableArray *plans = [NSMutableArray arrayWithObject:@[ @0, @0 ]];
    if (!domain.apple)
        for (GAOTFeature *feature in program.specifications)
            for (unsigned value = 1; value <= feature.maximum; value++)
                [plans addObject:@[ @(feature.name), @(value) ]];
    return plans;
}
@interface GASubstitutionEngine ()
@property(nonatomic, strong) GAFontProgram *program;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *coordinates;
@end
@implementation GASubstitutionEngine {
    CTFontRef _font;
}
- (instancetype)initWithFont:(CTFontRef)font
                 coordinates:(NSDictionary *)coordinates
                     sharing:(GASubstitutionEngine *)source {
    if ((self = [super init])) {
        _font = (CTFontRef)CFRetain(font);
        _program = source.program ?: [[GAFontProgram alloc] initWithFont:font];
        _coordinates = [coordinates copy] ?: @{};
    }
    return self;
}
- (void)dealloc {
    if (_font)
        CFRelease(_font);
}
- (NSArray<NSString *> *)diagnostics {
    @synchronized(_program) {
        return _program.errors.array;
    }
}
- (void)recordError:(NSException *)error {
    if (![error.name isEqual:@"GAInvalidFontTable"])
        @throw error;
    @synchronized(_program) {
        [_program.errors addObject:error.reason ?: @"invalid font table"];
    }
}
#if GA_FONT_LAYOUT_TESTING
- (NSArray *)featureSpecifications {
    NSMutableArray *result = [NSMutableArray array];
    for (GAOTFeature *f in _program.specifications)
        [result addObject:@{@"tag" : GATagName(f.name), @"max" : @(f.maximum)}];
    for (GAQueryDomain *domain in _program.domains)
        if (domain.apple) {
            NSString *name = _program.aat.name;
            if (domain.selector)
                name = [name stringByAppendingFormat:@":%u:%u", domain.selector.type,
                                                     domain.selector.setting];
            [result addObject:@{@"tag" : name, @"max" : @1, @"engine" : _program.aat.name}];
        }
    return result;
}
#endif
- (NSArray<NSDictionary *> *)relatedOutputs:(GAGlyph)glyph {
    NSArray *cached = [_program.relatedCache objectForKey:@(glyph)];
    if (cached)
        return cached;
    NSMutableArray *outputs = [NSMutableArray array];
    @try {
        for (GARelatedSubstitution *output in [_program.gsub relatedSubstitutions:glyph
                                                                             gdef:_program.gdef]) {
            NSString *label = GATagName(output.feature);
            if (output.value > 1)
                label = [label stringByAppendingFormat:@" %u", output.value];
            [outputs addObject:@{
                @"glyphs" : output.glyphs,
                @"source" : label,
                @"family" : @(output.directFamily)
            }];
        }
        if (_program.verticalAAT)
            for (GAQueryDomain *domain in _program.domains) {
                if (!domain.apple || (domain.selector && domain.selector.type != 4))
                    continue;
                NSMutableArray<GALayoutItem *> *input = GALiteralBuffer(@[ @(glyph) ]);
                [_program.aat substituteBuffer:input
                                      selector:domain.selector
                                           rtl:NO
                                      vertical:YES
                                         trace:nil
                                  verticalOnly:YES];
                NSArray *ids = GAGlyphIdentifiers(input);
                if ([ids isEqual:@[ @(glyph) ]])
                    continue;
                NSString *source = _program.aat.name;
                if (domain.selector)
                    source = [source stringByAppendingFormat:@":%u:%u", domain.selector.type,
                                                             domain.selector.setting];
                [outputs addObject:@{@"glyphs" : ids, @"source" : source, @"family" : @YES}];
            }
    } @catch (NSException *error) {
        [self recordError:error];
    }
    [_program.relatedCache setObject:outputs forKey:@(glyph) cost:outputs.count * 128];
    return outputs;
}
- (NSDictionary *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    GAGlyphQueryIdentity *queryKey = GAGlyphQueryKey(text, selections);
    NSDictionary *cached = [_program.cache objectForKey:queryKey];
    if (cached)
        return cached;
    NSArray<GATextRun *> *runs = GAPrepareText(text, _program.cmap, selections);
    NSMutableArray<GASubstitutionMatch *> *matches = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary],
                        *baselines = [NSMutableDictionary dictionary];
    // Project atomic baselines once per distinct input in this request.
    for (GATextRun *run in runs)
        for (GALayoutCluster *cluster in GAClusters(run.glyphs)) {
            BOOL selected = NO;
            for (GAGlyphSelectionRun *selection in selections)
                selected |=
                    NSIntersectionRange(selection.range,
                                        NSMakeRange(cluster.source.start,
                                                    cluster.source.end - cluster.source.start))
                        .length > 0;
            NSArray *key = @[ @(run.script), @(run.level & 1), @(selected), cluster.glyphs ];
            NSDictionary *value = baselines[key];
            if (!value) {
                NSMutableArray<GALayoutItem *> *basis = [NSMutableArray array];
                for (GALayoutItem *item in run.glyphs)
                    if (item.source.start < cluster.source.end &&
                        item.source.end > cluster.source.start) {
                        GALayoutItem *copy = [item copy];
                        if (copy.form)
                            copy.form = GATagMake('i', 's', 'o', 'l');
                        [basis addObject:copy];
                    }
                GALayoutTrace *trace = [GALayoutTrace new];
                GALayoutSettings *settings = [GALayoutSettings new];
                settings.script = run.script;
                settings.rtl = (run.level & 1) != 0;
                if (!selected && _program.domains.count)
                    [_program substitute:basis
                                  domain:_program.domains.firstObject
                                settings:settings
                                   trace:trace];
                if (settings.rtl)
                    GAReverseItems(basis);
                NSMutableOrderedSet *sources = [NSMutableOrderedSet orderedSet];
                for (GALayoutChange *change in trace.changes)
                    [sources addObject:change.feature];
                value = @{@"glyphs" : GAGlyphIdentifiers(basis), @"sources" : sources.array};
                baselines[key] = value;
            }
            GAMergeMatch(seen, matches, cluster.source, value[@"glyphs"], nil, YES);
            for (NSString *source in value[@"sources"])
                GAMergeMatch(seen, matches, cluster.source, value[@"glyphs"], source, YES);
        }
    for (GAQueryDomain *domain in _program.domains)
        for (GATextRun *run in runs) {
            NSMutableOrderedSet<NSNumber *> *scripts =
                [NSMutableOrderedSet orderedSetWithObject:@(run.script)];
            if (!domain.apple)
                for (GAGlyphSelectionRun *selection in selections)
                    if (NSIntersectionRange(
                            selection.range,
                            NSMakeRange(run.source.start, run.source.end - run.source.start))
                            .length) {
                        for (GAOTScript *script in _program.gsub.scripts)
                            [scripts addObject:@(script.name)];
                        break;
                    }
            for (NSNumber *script in scripts)
                for (NSNumber *language in domain.apple
                         ? @[ @0 ]
                         : [_program.gsub languages:script.unsignedIntValue])
                    for (NSArray<NSNumber *> *plan in GAFeaturePlans(_program, domain)) {
                        GALayoutSettings *settings = [GALayoutSettings new];
                        settings.script = script.unsignedIntValue;
                        settings.language = language.unsignedIntValue;
                        settings.rtl = (run.level & 1) != 0;
                        if (plan[0].unsignedIntValue)
                            settings.features[plan[0]] = plan[1];
                        NSMutableArray<GALayoutItem *> *items = GACopyBuffer(run.glyphs);
                        GALayoutTrace *trace = [GALayoutTrace new];
                        trace.inventory = YES;
                        @try {
                            [_program substitute:items domain:domain settings:settings trace:trace];
                        } @catch (NSException *error) {
                            [self recordError:error];
                            items = GACopyBuffer(run.glyphs);
                            trace = [GALayoutTrace new];
                        }
                        for (GALayoutItem *item in items)
                            if (item.glyph >= _program.glyphCount)
                                item.glyph = 0;
                        for (GALayoutChange *change in trace.changes)
                            GAMergeMatch(seen, matches, change.source,
                                         settings.rtl
                                             ? change.glyphs.reverseObjectEnumerator.allObjects
                                             : change.glyphs,
                                         change.feature, NO);
                        if (settings.rtl)
                            GAReverseItems(items);
                        for (GALayoutCluster *cluster in GAClusters(items)) {
                            GAMergeMatch(seen, matches, cluster.source, cluster.glyphs, nil, NO);
                            for (GALayoutChange *change in trace.changes)
                                if (change.source.start < cluster.source.end &&
                                    change.source.end > cluster.source.start)
                                    GAMergeMatch(seen, matches, cluster.source, cluster.glyphs,
                                                 change.feature, NO);
                        }
                        if (!items.count && !GASpanEmpty(run.source)) {
                            GAMergeMatch(seen, matches, run.source, @[], nil, NO);
                            for (GALayoutChange *change in trace.changes)
                                GAMergeMatch(seen, matches, run.source, @[], change.feature, NO);
                        }
                    }
        }
    // A component's contextual forms preserve the rest of its atomic cluster.
    for (GATextRun *run in runs)
        for (GALayoutCluster *cluster in GAClusters(run.glyphs))
            for (NSUInteger i = 0; i < cluster.glyphs.count; i++)
                for (NSDictionary *output in
                     [self relatedOutputs:cluster.glyphs[i].unsignedShortValue]) {
                    NSMutableArray *sequence = [cluster.glyphs mutableCopy];
                    [sequence replaceObjectsInRange:NSMakeRange(i, 1)
                               withObjectsFromArray:output[@"glyphs"]];
                    GAMergeMatch(seen, matches, cluster.source, sequence, output[@"source"], NO);
                }
    for (GASubstitutionMatch *base in [matches copy])
        if (base.base && base.glyphIDs.count == 1)
            for (NSDictionary *output in
                 [self relatedOutputs:base.glyphIDs.firstObject.unsignedShortValue])
                if ([output[@"family"] boolValue])
                    GAMergeMatch(seen, matches,
                                 GASpanMake((uint32_t)base.sourceRange.location,
                                            (uint32_t)NSMaxRange(base.sourceRange)),
                                 output[@"glyphs"], output[@"source"], NO);
    NSDictionary *result = @{@"matches" : matches};
    [_program.cache setObject:result forKey:queryKey cost:text.length * 2 + matches.count * 128];
    return result;
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text {
    return [self discoverText:text selections:@[]];
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text
                                      selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    if (!text.length)
        return @[];
    @try {
        NSMutableArray *matches = [[self discoverContent:text
                                              selections:selections][@"matches"] mutableCopy];
        [matches sortUsingComparator:^NSComparisonResult(GASubstitutionMatch *a,
                                                         GASubstitutionMatch *b) {
            if (a.base != b.base)
                return a.base ? NSOrderedAscending : NSOrderedDescending;
            if (!a.base && a.sourceRange.length != b.sourceRange.length)
                return a.sourceRange.length < b.sourceRange.length ? NSOrderedAscending
                                                                   : NSOrderedDescending;
            if (a.sourceRange.location != b.sourceRange.location)
                return a.sourceRange.location < b.sourceRange.location ? NSOrderedAscending
                                                                       : NSOrderedDescending;
            return NSOrderedSame;
        }];
        return matches;
    } @catch (NSException *error) {
        [self recordError:error];
    }
    return @[];
}
- (NSArray<GAGlyphLayoutRun *> *)layoutRunsForText:(NSString *)text
                                        contextual:(BOOL)contextual
                                         ligatures:(BOOL)ligatures
                                          vertical:(BOOL)vertical {
    NSMutableArray *result = [NSMutableArray array];
    @try {
        NSUInteger branch = [_program.gsub
            variationBranch:GANormalizeCoordinates(_program.fvar, _program.avar, _coordinates)];
        for (GATextRun *run in GAPrepareText(text, _program.cmap, nil)) {
            GALayoutSettings *settings = [GALayoutSettings new];
            settings.script = run.script;
            settings.rtl = (run.level & 1) != 0;
            settings.vertical = vertical;
            settings.features[@(GATagMake('c', 'a', 'l', 't'))] = @(contextual);
            settings.features[@(GATagMake('l', 'i', 'g', 'a'))] = @(ligatures);
            settings.features[@(GATagMake('c', 'l', 'i', 'g'))] = @(ligatures);
            BOOL vrt2 = NO;
            for (GAOTFeature *feature in [_program.gsub features:branch])
                vrt2 |= feature.name == GATagMake('v', 'r', 't', '2');
            settings.features[@(GATagMake('v', 'r', 't', '2'))] = @(vertical && vrt2);
            settings.features[@(GATagMake('v', 'e', 'r', 't'))] = @(vertical && !vrt2);
            NSMutableArray *items = GACopyBuffer(run.glyphs);
            if (!_program.aat.empty)
                [_program.aat applyFeatures:@[
                    [GAAATSelector type:36 setting:contextual ? 0 : 1],
                    [GAAATSelector type:1 setting:ligatures ? 2 : 3],
                    [GAAATSelector type:4 setting:vertical ? 0 : 1]
                ]
                                     buffer:items
                                        rtl:settings.rtl
                                   vertical:vertical
                                      trace:nil
                               verticalOnly:NO];
            else
                [_program.gsub substituteBuffer:items
                                           gdef:_program.gdef
                                       settings:settings
                                         branch:branch
                                          trace:nil];
            if (settings.rtl)
                GAReverseItems(items);
            for (GALayoutCluster *cluster in GAClusters(items)) {
                GAGlyphLayoutRun *hit = [GAGlyphLayoutRun new];
                hit.range =
                    NSMakeRange(cluster.source.start, cluster.source.end - cluster.source.start);
                hit.glyphIDs = cluster.glyphs;
                [result addObject:hit];
            }
        }
    } @catch (NSException *error) {
        [self recordError:error];
    }
    return result;
}
- (GALayoutMetrics *)metrics {
    CTFontRef font = _font;
    double scale = _program.unitsPerEm / CTFontGetSize(font);
    GALayoutMetrics *metrics = [GALayoutMetrics new];
    metrics.horizontalAdvance = ^double(GAGlyph glyph) {
        CGSize advance = CGSizeZero;
        CGGlyph g = glyph;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &g, &advance, 1);
        return advance.width * scale;
    };
    metrics.verticalAdvance = ^double(GAGlyph glyph) {
        CGSize advance = CGSizeZero;
        CGGlyph g = glyph;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationVertical, &g, &advance, 1);
        double value = MAX(fabs(advance.width), fabs(advance.height));
        return value ? value * scale : (CTFontGetAscent(font) + CTFontGetDescent(font)) * scale;
    };
    metrics.normalized = GANormalizeCoordinates(_program.fvar, _program.avar, _coordinates);
    return metrics;
}
- (void)position:(NSMutableArray<GALayoutItem *> *)buffer settings:(GALayoutSettings *)settings {
    GALayoutMetrics *metrics = [self metrics];
    NSArray *nominal = GACopyBuffer(buffer);
    BOOL hasKerning = NO;
    @try {
        NSUInteger branch = [_program.gpos variationBranch:metrics.normalized];
        [_program.gpos positionBuffer:buffer
                                 gdef:_program.gdef
                             settings:settings
                              metrics:metrics
                               branch:branch];
        for (GAOTLookupStep *step in [_program.gpos plan:settings branch:branch])
            if (step.feature == GATagMake('k', 'e', 'r', 'n'))
                hasKerning = YES;
    } @catch (NSException *error) {
        [self recordError:error];
        [buffer setArray:nominal];
        for (GALayoutItem *item in buffer) {
            item.xAdvance = settings.vertical ? 0 : metrics.horizontalAdvance(item.glyph);
            item.yAdvance = settings.vertical ? -metrics.verticalAdvance(item.glyph) : 0;
            item.xOffset = item.yOffset = 0;
        }
    }
    if (!hasKerning) {
        NSArray *before = GACopyBuffer(buffer);
        @try {
            [_program.kerning positionBuffer:buffer settings:settings gdef:_program.gdef];
        } @catch (NSException *error) {
            [self recordError:error];
            [buffer setArray:before];
        }
    }
    for (GALayoutItem *item in buffer)
        if (item.ignorable)
            item.xAdvance = item.yAdvance = 0;
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    return [self positionsForGlyphIDs:glyphIDs content:@""];
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     content:(NSString *)content {
    @try {
        NSArray<GATextRun *> *runs = GAPrepareText(content, _program.cmap, nil);
        GALayoutSettings *settings = [GALayoutSettings new];
        if (runs.count) {
            settings.script = runs.firstObject.script;
            settings.rtl = (runs.firstObject.level & 1) != 0;
        }
        NSMutableArray<GALayoutItem *> *items = GALiteralBuffer(glyphIDs);
        if (settings.rtl)
            GAReverseItems(items);
        [self position:items settings:settings];
        if (settings.rtl)
            GAReverseItems(items);
        double scale = 200.0 / _program.unitsPerEm;
        CGPoint pen = CGPointZero;
        NSMutableArray *positions = [NSMutableArray array];
        for (GALayoutItem *item in items) {
            [positions
                addObject:[NSValue valueWithPoint:NSMakePoint((pen.x + item.xOffset) * scale,
                                                              (pen.y + item.yOffset) * scale)]];
            pen.x += item.xAdvance;
            pen.y += item.yAdvance;
        }
        return positions;
    } @catch (NSException *error) {
        [self recordError:error];
    }
    return @[];
}
- (NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (!glyphIDs.count)
        return @[];
    NSArray *key = @[ @"glyphs", [glyphIDs copy] ];
    NSDictionary *cached = [_program.cache objectForKey:key];
    if (cached)
        return cached[@"matches"];
    @try {
        GASpan whole = GASpanMake(0, (uint32_t)glyphIDs.count);
        NSMutableArray *matches = [NSMutableArray array];
        NSMutableDictionary *seen = [NSMutableDictionary dictionary];
        GAMergeMatch(seen, matches, whole, glyphIDs, nil, YES);
        for (GAQueryDomain *domain in _program.domains) {
            NSMutableArray<NSNumber *> *scripts = [NSMutableArray array];
            if (domain.apple)
                [scripts addObject:@(GATagMake('D', 'F', 'L', 'T'))];
            else
                for (GAOTScript *script in _program.gsub.scripts)
                    [scripts addObject:@(script.name)];
            for (NSNumber *script in scripts)
                for (NSNumber *language in domain.apple
                         ? @[ @0 ]
                         : [_program.gsub languages:script.unsignedIntValue])
                    for (NSArray<NSNumber *> *plan in GAFeaturePlans(_program, domain)) {
                        GALayoutSettings *settings = [GALayoutSettings new];
                        settings.script = script.unsignedIntValue;
                        settings.language = language.unsignedIntValue;
                        if (plan[0].unsignedIntValue)
                            settings.features[plan[0]] = plan[1];
                        NSMutableArray *items = GALiteralBuffer(glyphIDs);
                        GALayoutTrace *trace = [GALayoutTrace new];
                        trace.inventory = YES;
                        [_program substitute:items domain:domain settings:settings trace:trace];
                        GAMergeMatch(seen, matches, whole, GAGlyphIdentifiers(items), nil, NO);
                        for (GALayoutChange *change in trace.changes)
                            GAMergeMatch(seen, matches, whole, GAGlyphIdentifiers(items),
                                         change.feature, NO);
                        for (GALayoutChange *change in trace.changes) {
                            if (change.source.end > glyphIDs.count)
                                continue;
                            NSMutableArray *sequence = [glyphIDs mutableCopy];
                            [sequence replaceObjectsInRange:NSMakeRange(change.source.start,
                                                                        change.source.end -
                                                                            change.source.start)
                                       withObjectsFromArray:change.glyphs];
                            GAMergeMatch(seen, matches, whole, sequence, change.feature, NO);
                        }
                    }
        }
        for (NSUInteger i = 0; i < glyphIDs.count; i++)
            for (NSDictionary *output in [self relatedOutputs:glyphIDs[i].unsignedShortValue]) {
                NSMutableArray *sequence = [glyphIDs mutableCopy];
                [sequence replaceObjectsInRange:NSMakeRange(i, 1)
                           withObjectsFromArray:output[@"glyphs"]];
                GAMergeMatch(seen, matches, whole, sequence, output[@"source"], NO);
            }
        [_program.cache setObject:@{@"matches" : matches}
                           forKey:key
                             cost:glyphIDs.count * 2 + matches.count * 128];
        return matches;
    } @catch (NSException *error) {
        [self recordError:error];
    }
    return @[];
}
- (NSNumber *)verticalGlyph:(uint16_t)glyph {
    @try {
        for (GAQueryDomain *domain in _program.domains) {
            if (domain.apple) {
                if (domain.selector && domain.selector.type != 4)
                    continue;
                NSMutableArray<GALayoutItem *> *items = GALiteralBuffer(@[ @(glyph) ]);
                [_program.aat substituteBuffer:items
                                      selector:domain.selector
                                           rtl:NO
                                      vertical:YES
                                         trace:nil
                                  verticalOnly:YES];
                if (items.count == 1 && items.firstObject.glyph != glyph)
                    return @(items.firstObject.glyph);
            } else
                for (NSString *name in @[ @"vrt2", @"vert" ])
                    for (GAOTFeature *feature in [_program.gsub features:domain.branch]) {
                        if (feature.name != GATagFromString(name))
                            continue;
                        NSMutableArray *steps = [NSMutableArray array];
                        for (NSNumber *lookup in feature.lookups) {
                            GAOTLookupStep *step = [GAOTLookupStep new];
                            step.lookup = lookup.unsignedIntValue;
                            step.feature = feature.name;
                            step.explicitValue = YES;
                            [steps addObject:step];
                        }
                        NSMutableArray<GALayoutItem *> *items = GALiteralBuffer(@[ @(glyph) ]);
                        [_program.gsub substituteLookups:items
                                                    gdef:_program.gdef
                                                   steps:steps
                                                   trace:nil];
                        if (items.count == 1 && items.firstObject.glyph != glyph)
                            return @(items.firstObject.glyph);
                    }
        }
    } @catch (NSException *error) {
        [self recordError:error];
    }
    return nil;
}
#if GA_FONT_LAYOUT_TESTING
- (NSDictionary *)shapeText:(NSString *)text
                   features:(NSDictionary *)features
                     script:(NSString *)script
                   language:(NSString *)language
                     branch:(NSUInteger)branch {
    @try {
        NSArray<GATextRun *> *runs = GAPrepareText(text, _program.cmap, nil);
        NSMutableArray<NSArray<GALayoutItem *> *> *output = [NSMutableArray array];
        GAQueryDomain *domain = _program.domains[branch < _program.domains.count ? branch : 0];
        for (GATextRun *run in runs) {
            GALayoutSettings *settings = [GALayoutSettings new];
            settings.script = script.length ? GAScriptTag(script) : run.script;
            settings.language = GALanguageTag(language);
            settings.rtl = (run.level & 1) != 0;
            for (NSString *name in features)
                settings.features[@(GATagFromString(name))] = features[name];
            NSMutableArray *items = GACopyBuffer(run.glyphs);
            [_program substitute:items domain:domain settings:settings trace:nil];
            [self position:items settings:settings];
            if (settings.rtl)
                GAReverseItems(items);
            [output addObject:items];
        }
        NSMutableArray *glyphs = [NSMutableArray array], *clusters = [NSMutableArray array],
                       *positions = [NSMutableArray array];
        for (NSNumber *index in GAVisualRunOrder(runs))
            for (GALayoutItem *item in output[index.unsignedIntegerValue]) {
                [glyphs addObject:@(item.glyph)];
                [clusters addObject:@(item.source.start)];
                [positions addObject:@[
                    @(item.xAdvance), @(item.yAdvance), @(item.xOffset), @(item.yOffset)
                ]];
            }
        return
            @{@"ok" : @YES, @"glyphs" : glyphs, @"clusters" : clusters, @"positions" : positions};
    } @catch (NSException *error) {
        if (![error.name isEqual:@"GAInvalidFontTable"])
            @throw;
        return @{
            @"ok" : @NO,
            @"error" : error.reason ?: @"invalid font table",
            @"glyphs" : @[],
            @"clusters" : @[],
            @"positions" : @[]
        };
    }
}
#endif
@end
