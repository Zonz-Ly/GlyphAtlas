#import "GAOpenType.h"
@implementation GAOTPredicate
+ (instancetype)exact:(GAGlyph)glyph {
    GAOTPredicate *p = [self new];
    p.value = glyph;
    return p;
}
+ (instancetype)covered:(GATableView *)view {
    GAOTPredicate *p = [self new];
    p.kind = GAPredicateCoverage;
    p.coverage = [[GACoverage alloc] initWithView:view];
    return p;
}
+ (instancetype)classified:(GATableView *)view value:(unsigned)value {
    GAOTPredicate *p = [self new];
    p.kind = GAPredicateClass;
    p.classes = [[GAClassDef alloc] initWithView:view];
    p.value = value;
    return p;
}
- (BOOL)matches:(GAGlyph)glyph {
    switch (_kind) {
    case GAPredicateExact:
        return glyph == _value;
    case GAPredicateCoverage:
        return [_coverage contains:glyph];
    case GAPredicateClass:
        return [_classes value:glyph] == _value;
    }
    return NO;
}
@end
@implementation GAOTAction
@end
@implementation GAOTPattern
- (instancetype)init {
    if ((self = [super init])) {
        _backtrack = [NSMutableArray array];
        _input = [NSMutableArray array];
        _lookahead = [NSMutableArray array];
        _actions = @[];
        _replacement = @[];
    }
    return self;
}
@end
@implementation GAOTSubtable
- (instancetype)init {
    if ((self = [super init])) {
        _patterns = @[];
        _starts = [NSMutableDictionary dictionary];
        _alternateInputs = [NSMutableDictionary dictionary];
    }
    return self;
}
@end
@implementation GAOTLookup
- (instancetype)init {
    if ((self = [super init])) {
        _alternateCount = 1;
        _subtables = @[];
        _references = [NSMutableIndexSet indexSet];
    }
    return self;
}
@end
@implementation GAOTFeature
- (instancetype)init {
    if ((self = [super init])) {
        _lookups = @[];
        _maximum = 1;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    GAOTFeature *f = [[[self class] allocWithZone:zone] init];
    f.name = _name;
    f.lookups = _lookups;
    f.maximum = _maximum;
    return f;
}
@end
@implementation GAOTLanguage
@end
@implementation GAOTScript
@end
@implementation GALayoutSettings
- (instancetype)init {
    if ((self = [super init])) {
        _script = GATagMake('D', 'F', 'L', 'T');
        _features = [NSMutableDictionary dictionary];
    }
    return self;
}
@end
@implementation GARelatedSubstitution
@end
@implementation GAOTLookupStep
- (instancetype)init {
    if ((self = [super init]))
        _value = 1;
    return self;
}
@end
static NSArray<GAOTAction *> *GAReadActions(GATableView *table, NSUInteger at, unsigned count) {
    [table array:at count:count stride:4];
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        GAOTAction *a = [GAOTAction new];
        a.sequence = [table u16:at + i * 4];
        a.lookup = [table u16:at + i * 4 + 2];
        [result addObject:a];
    }
    return result;
}
static void GAReadPredicates(NSMutableArray *result, GATableView *table, NSUInteger at,
                             unsigned count, unsigned format, GATableView *classes) {
    [table array:at count:count stride:2];
    for (unsigned i = 0; i < count; i++) {
        GAOTPredicate *p = format == 1 ? [GAOTPredicate exact:[table u16:at + i * 2]]
                           : format == 2
                               ? [GAOTPredicate classified:classes value:[table u16:at + i * 2]]
                               : [GAOTPredicate covered:[table offset16:at + i * 2]];
        [result addObject:p];
    }
}
static NSArray<GAOTPattern *> *GAReadContexts(GATableView *sub, unsigned type) {
    BOOL chained = type == 6;
    unsigned format = [sub u16:0];
    NSMutableArray *result = [NSMutableArray array];
    if (format == 3) {
        GAOTPattern *p = [GAOTPattern new];
        NSUInteger cursor = 2;
        if (chained) {
            unsigned back = [sub u16:cursor];
            cursor += 2;
            GAReadPredicates(p.backtrack, sub, cursor, back, 3, nil);
            cursor += back * 2;
        }
        unsigned input = [sub u16:cursor];
        cursor += 2;
        if (!input)
            GAInvalidTable(@"empty context input");
        unsigned actions = 0;
        if (!chained) {
            actions = [sub u16:cursor];
            cursor += 2;
        }
        GAReadPredicates(p.input, sub, cursor, input, 3, nil);
        cursor += input * 2;
        if (chained) {
            unsigned look = [sub u16:cursor];
            cursor += 2;
            GAReadPredicates(p.lookahead, sub, cursor, look, 3, nil);
            cursor += look * 2;
            actions = [sub u16:cursor];
            cursor += 2;
        }
        p.actions = GAReadActions(sub, cursor, actions);
        [result addObject:p];
        return result;
    }
    if (format != 1 && format != 2)
        GAInvalidTable(@"unknown contextual lookup format");
    GACoverage *coverage = [[GACoverage alloc] initWithView:[sub offset16:2]];
    NSArray<NSNumber *> *firstGlyphs = format == 1 ? coverage.glyphs : @[];
    GATableView *backClasses = nil, *inputClasses = nil, *lookClasses = nil;
    NSUInteger countAt = 4;
    if (format == 2) {
        if (chained) {
            backClasses = [sub offset16:4];
            inputClasses = [sub offset16:6];
            lookClasses = [sub offset16:8];
            countAt = 10;
        } else {
            inputClasses = [sub offset16:4];
            countAt = 6;
        }
    }
    unsigned sets = [sub u16:countAt];
    [sub array:countAt + 2 count:sets stride:2];
    if (format == 1)
        sets = MIN(sets, firstGlyphs.count);
    for (unsigned si = 0; si < sets; si++) {
        GATableView *set = [sub offset16:countAt + 2 + si * 2];
        if (!set.present)
            continue;
        unsigned count = [set u16:0];
        [set array:2 count:count stride:2];
        for (unsigned ri = 0; ri < count; ri++) {
            if (result.count >= 1000000)
                GAInvalidTable(@"too many contextual rules");
            GATableView *rule = [set offset16:2 + ri * 2];
            if (!rule.present)
                GAInvalidTable(@"null contextual rule");
            GAOTPattern *p = [GAOTPattern new];
            p.firstCoverage = coverage;
            NSUInteger cursor = 0;
            if (chained) {
                unsigned back = [rule u16:cursor];
                cursor += 2;
                GAReadPredicates(p.backtrack, rule, cursor, back, format, backClasses);
                cursor += back * 2;
            }
            unsigned input = [rule u16:cursor];
            cursor += 2;
            if (!input)
                GAInvalidTable(@"empty context input");
            unsigned actions = 0;
            if (!chained) {
                actions = [rule u16:cursor];
                cursor += 2;
            }
            [p.input addObject:format == 1
                                   ? [GAOTPredicate exact:firstGlyphs[si].unsignedShortValue]
                                   : [GAOTPredicate classified:inputClasses value:si]];
            GAReadPredicates(p.input, rule, cursor, input - 1, format, inputClasses);
            cursor += (input - 1) * 2;
            if (chained) {
                unsigned look = [rule u16:cursor];
                cursor += 2;
                GAReadPredicates(p.lookahead, rule, cursor, look, format, lookClasses);
                cursor += look * 2;
                actions = [rule u16:cursor];
                cursor += 2;
            }
            p.actions = GAReadActions(rule, cursor, actions);
            [result addObject:p];
        }
    }
    return result;
}
NSArray<NSNumber *> *GAMatchPattern(GAOTPattern *pattern, NSArray<GALayoutItem *> *buffer,
                                    NSUInteger start, GAGDEF *gdef, unsigned flags,
                                    unsigned markSet, GASpan *scope) {
    if (start >= buffer.count || !pattern.input.count ||
        ![gdef includes:buffer[start].glyph flags:flags markSet:markSet])
        return nil;
    if (pattern.firstCoverage.present && ![pattern.firstCoverage contains:buffer[start].glyph])
        return nil;
    if (![pattern.input.firstObject matches:buffer[start].glyph])
        return nil;
    __block GASpan range = buffer[start].source;
    NSMutableArray *input = [NSMutableArray arrayWithObject:@(start)];
    __block NSUInteger cursor = start;
    for (GAOTPredicate *predicate in pattern.backtrack) {
        BOOL found = NO;
        while (cursor > 0) {
            --cursor;
            if ([gdef includes:buffer[cursor].glyph flags:flags markSet:markSet]) {
                found = YES;
                break;
            }
        }
        if (!found || ![predicate matches:buffer[cursor].glyph])
            return nil;
        range = GAUnite(range, buffer[cursor].source);
    }
    cursor = start;
    BOOL (^advance)(GAOTPredicate *) = ^BOOL(GAOTPredicate *p) {
        do {
            ++cursor;
        } while (cursor < buffer.count && ![gdef includes:buffer[cursor].glyph
                                                    flags:flags
                                                  markSet:markSet]);
        if (cursor >= buffer.count || ![p matches:buffer[cursor].glyph])
            return NO;
        range = GAUnite(range, buffer[cursor].source);
        return YES;
    };
    for (NSUInteger i = 1; i < pattern.input.count; i++) {
        if (!advance(pattern.input[i]))
            return nil;
        [input addObject:@(cursor)];
    }
    for (GAOTPredicate *p in pattern.lookahead)
        if (!advance(p))
            return nil;
    if (scope)
        *scope = range;
    return input;
}
static NSArray<GAOTFeature *> *GAReadFeatures(GATableView *list) {
    if (!list.present)
        return @[];
    unsigned count = [list u16:0];
    [list array:2 count:count stride:6];
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        GAOTFeature *f = [GAOTFeature new];
        f.name = [list u32:2 + i * 6];
        GATableView *table = [list offset16:6 + i * 6];
        unsigned n = [table u16:2];
        [table array:4 count:n stride:2];
        NSMutableArray *lookups = [NSMutableArray array];
        for (unsigned j = 0; j < n; j++)
            [lookups addObject:@([table u16:4 + j * 2])];
        f.lookups = lookups;
        [result addObject:f];
    }
    return result;
}
static GAOTLanguage *GAReadLanguage(GATag name, GATableView *table) {
    GAOTLanguage *lang = [GAOTLanguage new];
    lang.name = name;
    lang.required = [table u16:2];
    unsigned count = [table u16:4];
    [table array:6 count:count stride:2];
    NSMutableArray *features = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++)
        [features addObject:@([table u16:6 + i * 2])];
    lang.features = features;
    return lang;
}
static NSArray<GAOTScript *> *GAReadScripts(GATableView *list) {
    if (!list.present)
        return @[];
    unsigned count = [list u16:0];
    [list array:2 count:count stride:6];
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        GAOTScript *script = [GAOTScript new];
        script.name = [list u32:2 + i * 6];
        GATableView *table = [list offset16:6 + i * 6];
        NSMutableArray *languages = [NSMutableArray array];
        GATableView *def = [table offset16:0];
        if (def.present)
            [languages addObject:GAReadLanguage(0, def)];
        unsigned n = [table u16:2];
        [table array:4 count:n stride:6];
        for (unsigned j = 0; j < n; j++)
            [languages addObject:GAReadLanguage([table u32:4 + j * 6], [table offset16:8 + j * 6])];
        script.languages = languages;
        [result addObject:script];
    }
    return result;
}
static void GAIndexPatterns(GAOTSubtable *sub) {
    for (NSUInteger i = 0; i < sub.patterns.count; i++) {
        GAOTPattern *p = sub.patterns[i];
        GAOTPredicate *first = p.input.firstObject;
        if (!first)
            continue;
        NSArray *glyphs = first.kind == GAPredicateExact      ? @[ @(first.value) ]
                          : first.kind == GAPredicateCoverage ? first.coverage.glyphs
                                                              : p.firstCoverage.glyphs;
        for (NSNumber *number in glyphs) {
            GAGlyph g = number.unsignedShortValue;
            if ([first matches:g] && (!p.firstCoverage.present || [p.firstCoverage contains:g])) {
                if (!sub.starts[number])
                    sub.starts[number] = [NSMutableArray array];
                [sub.starts[number] addObject:@(i)];
            }
        }
    }
}
static GAOTSubtable *GAReadSubtable(GATableView *data, unsigned type, BOOL positioning,
                                    unsigned depth) {
    if (depth && type == (positioning ? 9 : 7))
        GAInvalidTable(@"nested extension lookup");
    if (type == (positioning ? 9 : 7)) {
        if ([data u16:0] != 1)
            GAInvalidTable(@"unknown extension format");
        return GAReadSubtable([data offset32:4], [data u16:2], positioning, depth + 1);
    }
    GAOTSubtable *sub = [GAOTSubtable new];
    sub.type = type;
    sub.data = data;
    if (positioning) {
        if (type == 7 || type == 8)
            sub.patterns = GAReadContexts(data, type == 7 ? 5 : 6);
        else if (type >= 1 && type <= 6)
            sub.coverage = [[GACoverage alloc] initWithView:[data offset16:2]];
        else
            GAInvalidTable(@"unknown positioning lookup");
        GAIndexPatterns(sub);
        return sub;
    }
    if (type == 5 || type == 6)
        sub.patterns = GAReadContexts(data, type);
    else if ((type >= 1 && type <= 4) || type == 8)
        sub.coverage = [[GACoverage alloc] initWithView:[data offset16:2]];
    else
        GAInvalidTable(@"unknown substitution lookup");
    NSMutableArray *patterns = [sub.patterns mutableCopy];
    if (type == 4) {
        if ([data u16:0] != 1)
            GAInvalidTable(@"unknown ligature format");
        NSArray<NSNumber *> *glyphs = sub.coverage.glyphs;
        unsigned count = [data u16:4];
        [data array:6 count:count stride:2];
        if (count > glyphs.count)
            GAInvalidTable(@"ligature set exceeds coverage");
        for (unsigned i = 0; i < count; i++) {
            GATableView *set = [data offset16:6 + i * 2];
            if (!set.present)
                continue;
            unsigned n = [set u16:0];
            [set array:2 count:n stride:2];
            for (unsigned j = 0; j < n; j++) {
                GATableView *lig = [set offset16:2 + j * 2];
                GAOTPattern *p = [GAOTPattern new];
                [p.input addObject:[GAOTPredicate exact:glyphs[i].unsignedShortValue]];
                unsigned length = [lig u16:2];
                if (!length)
                    GAInvalidTable(@"empty ligature");
                GAReadPredicates(p.input, lig, 4, length - 1, 1, nil);
                p.replacement = @[ @([lig u16:0]) ];
                [patterns addObject:p];
            }
        }
    }
    if (type == 8) {
        if ([data u16:0] != 1)
            GAInvalidTable(@"unknown reverse chaining format");
        GAOTPattern *p = [GAOTPattern new];
        [p.input addObject:[GAOTPredicate covered:[data offset16:2]]];
        NSUInteger at = 4;
        unsigned back = [data u16:at];
        at += 2;
        GAReadPredicates(p.backtrack, data, at, back, 3, nil);
        at += back * 2;
        unsigned look = [data u16:at];
        at += 2;
        GAReadPredicates(p.lookahead, data, at, look, 3, nil);
        [patterns addObject:p];
    }
    sub.patterns = patterns;
    GAIndexPatterns(sub);
    return sub;
}
@implementation GAOpenType {
    BOOL _positioning;
    GATableView *_data;
    NSArray<NSArray<GAOTFeature *> *> *_branches;
}
- (instancetype)initWithView:(GATableView *)table positioning:(BOOL)positioning {
    if (!(self = [super init]))
        return nil;
    _positioning = positioning;
    _data = table;
    _scripts = @[];
    _lookups = @[];
    _branches = @[ @[] ];
    if (!table.present)
        return self;
    [table require:0 count:10];
    _scripts = GAReadScripts([table offset16:4]);
    NSMutableArray<NSArray<GAOTFeature *> *> *branches =
        [NSMutableArray arrayWithObject:GAReadFeatures([table offset16:6])];
    GATableView *list = [table offset16:8];
    unsigned count = [list u16:0];
    [list array:2 count:count stride:2];
    NSMutableArray *lookups = [NSMutableArray array];
    NSUInteger familyEntries = 0;
    for (unsigned i = 0; i < count; i++) {
        GATableView *data = [list offset16:2 + i * 2];
        GAOTLookup *lookup = [GAOTLookup new];
        unsigned type = [data u16:0];
        lookup.flags = [data u16:2];
        unsigned n = [data u16:4];
        [data array:6 count:n stride:2];
        if (lookup.flags & 16)
            lookup.markSet = [data u16:6 + n * 2];
        NSMutableArray *subtables = [NSMutableArray array];
        for (unsigned j = 0; j < n; j++) {
            GAOTSubtable *sub = GAReadSubtable([data offset16:6 + j * 2], type, positioning, 0);
            for (GAOTPattern *pattern in sub.patterns)
                for (GAOTAction *action in pattern.actions)
                    [lookup.references addIndex:action.lookup];
            if (!positioning && sub.type == 3) {
                unsigned sets = [sub.data u16:4];
                [sub.data array:6 count:sets stride:2];
                for (unsigned k = 0; k < sets; k++) {
                    GATableView *alternate = [sub.data offset16:6 + k * 2];
                    unsigned size = [alternate u16:0];
                    [alternate array:2 count:size stride:2];
                    lookup.alternateCount = MAX(lookup.alternateCount, size);
                }
                for (NSNumber *input in sub.coverage.glyphs)
                    for (NSNumber *output in GASubstitutionOutputs(sub, input.unsignedShortValue)) {
                        if ([sub.coverage contains:output.unsignedShortValue])
                            continue;
                        NSMutableArray *inputs = sub.alternateInputs[output];
                        if (!inputs) {
                            inputs = [NSMutableArray array];
                            sub.alternateInputs[output] = inputs;
                        }
                        if (![inputs.lastObject isEqual:input]) {
                            if (++familyEntries > 2000000)
                                GAInvalidTable(@"alternate family index exceeds resource budget");
                            [inputs addObject:input];
                        }
                    }
            }
            lookup.reverse |= !positioning && sub.type == 8;
            [subtables addObject:sub];
        }
        lookup.subtables = subtables;
        [lookups addObject:lookup];
    }
    _lookups = lookups;
    if ([table u32:0] == 0x10001) {
        GATableView *variations = [table offset32:10];
        if (variations.present) {
            unsigned n = [variations u32:4];
            [variations array:8 count:n stride:8];
            for (unsigned i = 0; i < n; i++) {
                NSMutableArray<GAOTFeature *> *features = [NSMutableArray array];
                for (GAOTFeature *f in branches.firstObject)
                    [features addObject:[f copy]];
                GATableView *replacement = [variations offset32:12 + i * 8];
                unsigned replacements = [replacement u16:4];
                [replacement array:6 count:replacements stride:6];
                for (unsigned j = 0; j < replacements; j++) {
                    unsigned fi = [replacement u16:6 + j * 6];
                    if (fi >= features.count)
                        GAInvalidTable(@"variation feature index outside list");
                    GATableView *alt = [replacement offset32:8 + j * 6];
                    unsigned k = [alt u16:2];
                    [alt array:4 count:k stride:2];
                    NSMutableArray *indices = [NSMutableArray array];
                    for (unsigned q = 0; q < k; q++)
                        [indices addObject:@([alt u16:4 + q * 2])];
                    features[fi].lookups = indices;
                }
                [branches addObject:features];
            }
        }
    }
    for (NSArray<GAOTFeature *> *branch in branches)
        for (GAOTFeature *feature in branch) {
            NSMutableArray<NSNumber *> *queue = [feature.lookups mutableCopy];
            NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
            for (NSUInteger i = 0; i < queue.count; i++) {
                unsigned li = queue[i].unsignedIntValue;
                if (li >= _lookups.count || [seen containsIndex:li])
                    continue;
                [seen addIndex:li];
                GAOTLookup *lookup = _lookups[li];
                feature.maximum = MAX(feature.maximum, lookup.alternateCount);
                [lookup.references enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
                    (void)stop;
                    [queue addObject:@(idx)];
                }];
            }
        }
    _branches = branches;
    return self;
}
- (BOOL)positioning {
    return _positioning;
}
- (NSUInteger)branchCount {
    return _branches.count;
}
- (NSArray<GAOTFeature *> *)features:(NSUInteger)branch {
    return _branches[branch < _branches.count ? branch : 0];
}
static GAOTScript *GASelectScript(NSArray<GAOTScript *> *scripts, GATag wanted) {
    for (NSNumber *name in
         @[ @(wanted), @(GATagMake('D', 'F', 'L', 'T')), @(GATagMake('l', 'a', 't', 'n')) ])
        for (GAOTScript *s in scripts)
            if (s.name == name.unsignedIntValue)
                return s;
    return nil;
}
- (NSArray<NSNumber *> *)languages:(GATag)script {
    NSMutableArray *result = [NSMutableArray arrayWithObject:@0];
    for (GAOTLanguage *l in GASelectScript(_scripts, script).languages)
        if (l.name)
            [result addObject:@(l.name)];
    return result;
}
static BOOL GADefaultFeature(GATag value, BOOL positioning) {
    NSArray *names =
        positioning ? @[ @"kern", @"mark", @"mkmk", @"curs", @"dist", @"abvm", @"blwm" ] : @[
            @"ccmp", @"locl", @"rlig", @"liga", @"clig", @"calt", @"rclt", @"ljmo", @"vjmo",
            @"tjmo", @"isol", @"init", @"medi", @"fina"
        ];
    return [names containsObject:GATagName(value)];
}
- (NSArray<GAOTLookupStep *> *)plan:(GALayoutSettings *)settings branch:(NSUInteger)branch {
    NSMutableArray *result = [NSMutableArray array];
    GAOTScript *script = GASelectScript(_scripts, settings.script);
    if (!script)
        return result;
    GAOTLanguage *language = nil;
    for (NSNumber *wanted in @[ @(settings.language), @0 ]) {
        for (GAOTLanguage *l in script.languages)
            if (l.name == wanted.unsignedIntValue) {
                language = l;
                break;
            }
        if (language)
            break;
    }
    if (!language)
        return result;
    NSArray<GAOTFeature *> *all = [self features:branch];
    NSMutableArray *indices = [language.features mutableCopy];
    if (language.required != 0xffff)
        [indices addObject:@(language.required)];
    NSMutableDictionary<NSNumber *, GAOTLookupStep *> *enabled = [NSMutableDictionary dictionary];
    for (NSNumber *number in indices) {
        unsigned fi = number.unsignedIntValue;
        if (fi >= all.count)
            GAInvalidTable(@"language feature index outside list");
        GAOTFeature *f = all[fi];
        NSNumber *explicit = settings.features[@(f.name)];
        unsigned value = explicit                                 ? explicit.unsignedIntValue
                         : GADefaultFeature(f.name, _positioning) ? 1
                                                                  : 0;
        if (fi == language.required)
            value = MAX(value, 1u);
        if (!value)
            continue;
        for (NSNumber *li in f.lookups) {
            if (li.unsignedIntValue >= _lookups.count)
                GAInvalidTable(@"feature lookup index outside list");
            GAOTLookupStep *step = [GAOTLookupStep new];
            step.lookup = li.unsignedIntValue;
            step.value = value;
            step.feature = f.name;
            step.explicitValue = explicit != nil;
            if (!enabled[li] || step.explicitValue)
                enabled[li] = step;
        }
    }
    NSArray<NSNumber *> *ordered = [enabled.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *stage in @[ @"ccmp", @"locl" ])
        for (NSNumber *li in ordered)
            if (enabled[li].feature == GATagFromString(stage)) {
                [result addObject:enabled[li]];
                [enabled removeObjectForKey:li];
            }
    for (NSNumber *li in ordered)
        if (enabled[li])
            [result addObject:enabled[li]];
    return result;
}
- (NSUInteger)variationBranch:(NSArray<NSNumber *> *)normalized {
    if (!_data.present || [_data u32:0] != 0x10001)
        return 0;
    GATableView *variations = [_data offset32:10];
    if (!variations.present)
        return 0;
    unsigned count = [variations u32:4];
    for (unsigned i = 0; i < count; i++) {
        GATableView *set = [variations offset32:8 + i * 8];
        BOOL matches = YES;
        if (set.present) {
            unsigned n = [set u16:0];
            [set array:2 count:n stride:4];
            for (unsigned j = 0; j < n; j++) {
                GATableView *condition = [set offset32:2 + j * 4];
                if (!condition.present)
                    continue;
                if ([condition u16:0] != 1)
                    GAInvalidTable(@"unknown feature variation condition");
                unsigned axis = [condition u16:2];
                double value = axis < normalized.count ? normalized[axis].doubleValue : 0;
                if (value < [condition f2dot14:4] || value > [condition f2dot14:6]) {
                    matches = NO;
                    break;
                }
            }
        }
        if (matches)
            return i + 1;
    }
    return 0;
}
@end
NSArray<NSNumber *> *GASubstitutionOutputs(GAOTSubtable *sub, GAGlyph glyph) {
    NSInteger index = [sub.coverage index:glyph];
    if (index < 0)
        return @[];
    GATableView *data = sub.data;
    if (sub.type == 1) {
        unsigned format = [data u16:0];
        if (format == 1)
            return @[ @((GAGlyph)(glyph + [data s16:4])) ];
        if (format == 2) {
            if ((NSUInteger)index >= [data u16:4])
                GAInvalidTable(@"single substitute exceeds coverage");
            return @[ @([data u16:6 + index * 2]) ];
        }
    }
    if (sub.type == 2 || sub.type == 3) {
        if ([data u16:0] != 1)
            GAInvalidTable(@"unknown sequence format");
        if ((NSUInteger)index >= [data u16:4])
            GAInvalidTable(@"sequence exceeds coverage");
        GATableView *seq = [data offset16:6 + index * 2];
        unsigned n = [seq u16:0];
        [seq array:2 count:n stride:2];
        NSMutableArray *result = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++)
            [result addObject:@([seq u16:2 + i * 2])];
        return result;
    }
    return @[];
}
