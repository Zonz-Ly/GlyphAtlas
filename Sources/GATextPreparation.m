#import "GATextPreparation.h"
int32_t uscript_getScript(int32_t, int32_t *);
const char *uscript_getShortName(int32_t);
int32_t u_getPropertyEnum(const char *);
int32_t u_getPropertyValueEnum(int32_t, const char *);
int32_t u_getIntPropertyValue(int32_t, int32_t);
void *ubidi_openSized(int32_t, int32_t, int32_t *);
void ubidi_setPara(void *, const uint16_t *, int32_t, uint8_t, const uint8_t *, int32_t *);
uint8_t ubidi_getLevelAt(const void *, int32_t);
void ubidi_close(void *);
@implementation GATextRun
- (instancetype)init {
    if ((self = [super init]))
        _glyphs = [NSMutableArray array];
    return self;
}
@end
GATag GAScriptTag(NSString *name) {
    NSString *s = name.lowercaseString;
    if (s.length != 4)
        return GATagMake('D', 'F', 'L', 'T');
    NSDictionary *exceptions = @{
        @"hira" : @"kana",
        @"laoo" : @"lao ",
        @"yiii" : @"yi  ",
        @"nkoo" : @"nko ",
        @"vaii" : @"vai "
    };
    if (exceptions[s])
        s = exceptions[s];
    if ([@[ @"zyyy", @"zinh", @"zzzz", @"dflt" ] containsObject:s])
        return GATagMake('D', 'F', 'L', 'T');
    return GATagFromString(s);
}
GATag GALanguageTag(NSString *name) {
    if (!name.length)
        return 0;
    if (name.length == 4)
        return GATagFromString(name.uppercaseString);
    NSDictionary *known = @{
        @"en" : @"ENG ",
        @"ja" : @"JAN ",
        @"ko" : @"KOR ",
        @"zh" : @"ZHS ",
        @"zh-Hans" : @"ZHS ",
        @"zh-Hant" : @"ZHT ",
        @"zh-TW" : @"ZHT ",
        @"zh-HK" : @"ZHH ",
        @"bg" : @"BGR ",
        @"sr" : @"SRB ",
        @"ru" : @"RUS ",
        @"ar" : @"ARA ",
        @"fa" : @"FAR ",
        @"ur" : @"URD ",
        @"he" : @"IWR ",
        @"tr" : @"TRK ",
        @"de" : @"DEU ",
        @"fr" : @"FRA ",
        @"el" : @"ELL ",
        @"hi" : @"HIN ",
        @"th" : @"THA ",
        @"vi" : @"VIT ",
        @"es" : @"ESP ",
        @"it" : @"ITA ",
        @"pt" : @"PTG ",
        @"pl" : @"PLK ",
        @"nl" : @"NLD ",
        @"ro" : @"ROM "
    };
    return GATagFromString(known[name]);
}
static NSArray<NSNumber *> *GATextScalars(NSString *text) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < text.length; i++) {
        uint32_t scalar = [text characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(scalar) && i + 1 < text.length &&
            CFStringIsSurrogateLowCharacter([text characterAtIndex:i + 1]))
            scalar = CFStringGetLongCharacterForSurrogatePair(scalar, [text characterAtIndex:++i]);
        [result addObject:@(scalar)];
    }
    return result;
}
static BOOL GAIsVariationSelector(uint32_t scalar) {
    return (scalar >= 0xfe00 && scalar <= 0xfe0f) || (scalar >= 0xe0100 && scalar <= 0xe01ef);
}
static GATag GAScalarScript(uint32_t scalar) {
    int32_t error = 0, script = uscript_getScript(scalar, &error);
    const char *name = error > 0 ? NULL : uscript_getShortName(script);
    return name ? GAScriptTag(@(name)) : GATagMake('D', 'F', 'L', 'T');
}
NSArray<GATextRun *> *GAPrepareText(NSString *text, GACmap *cmap,
                                    NSArray<GAGlyphSelectionRun *> *selections) {
    if (!text.length)
        return @[];
    if (text.length > INT32_MAX)
        GAInvalidTable(@"text exceeds Unicode index range");
    NSMutableArray<GATextRun *> *groups = [NSMutableArray array];
    NSMutableData *units = [NSMutableData dataWithLength:text.length * sizeof(unichar)];
    [text getCharacters:units.mutableBytes range:NSMakeRange(0, text.length)];
    int32_t status = 0;
    void *bidi = ubidi_openSized((int32_t)text.length, 0, &status);
    if (!bidi)
        GAInvalidTable(@"Unicode bidi allocation failed");
    uint64_t identity = 1;
    @try {
        ubidi_setPara(bidi, units.bytes, (int32_t)text.length, 0xfe, NULL, &status);
        if (status > 0)
            GAInvalidTable(@"Unicode bidi analysis failed");
        int32_t ignorable = u_getPropertyEnum("Default_Ignorable_Code_Point");
        for (NSUInteger start = 0; start < text.length;) {
            NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:start];
            NSString *source = [text substringWithRange:range];
            start = NSMaxRange(range);
            NSString *composed = source.precomposedStringWithCanonicalMapping;
            NSArray<NSNumber *> *original = GATextScalars(source);
            // Preserve encoded compatibility characters and explicitly represented
            // UVS bases.
            if (original.count && [cmap nominal:original.firstObject.unsignedIntValue] &&
                (original.count == 1 ||
                 (original.count > 1 && GAIsVariationSelector(original[1].unsignedIntValue))))
                composed = source;
            NSArray<NSNumber *> *values = GATextScalars(composed);
            BOOL supported = YES;
            for (NSNumber *number in values) {
                uint32_t scalar = number.unsignedIntValue;
                if (!GAIsVariationSelector(scalar) && !u_getIntPropertyValue(scalar, ignorable) &&
                    ![cmap nominal:scalar]) {
                    supported = NO;
                    break;
                }
            }
            if (!supported)
                values = GATextScalars(source.decomposedStringWithCanonicalMapping);
            GATextRun *group = [GATextRun new];
            group.source = GASpanMake((uint32_t)range.location, (uint32_t)NSMaxRange(range));
            group.level = ubidi_getLevelAt(bidi, (int32_t)range.location);
            for (NSUInteger i = 0; i < values.count; i++) {
                uint32_t scalar = values[i].unsignedIntValue;
                if (GAIsVariationSelector(scalar))
                    continue;
                GALayoutItem *item = [GALayoutItem new];
                item.scalar = scalar;
                item.source = group.source;
                item.glyph = [cmap nominal:scalar];
                item.identity = identity++;
                if (i + 1 < values.count && GAIsVariationSelector(values[i + 1].unsignedIntValue)) {
                    NSNumber *variant = [cmap variation:scalar
                                               selector:values[i + 1].unsignedIntValue];
                    if (variant)
                        item.glyph = variant.unsignedShortValue;
                    i++;
                }
                item.ignorable = u_getIntPropertyValue(scalar, ignorable) != 0;
                GATag script = GAScalarScript(scalar);
                if (!group.script && script != GATagMake('D', 'F', 'L', 'T'))
                    group.script = script;
                [group.glyphs addObject:item];
            }
            [groups addObject:group];
        }
    } @finally {
        ubidi_close(bidi);
    }
    uint32_t previousEnd = 0;
    for (GAGlyphSelectionRun *selection in selections) {
        NSRange range = selection.range;
        if (!range.length || range.location < previousEnd || range.location > text.length ||
            range.length > text.length - range.location)
            GAInvalidTable(@"invalid glyph selection range");
        GASpan span = GASpanMake((uint32_t)range.location, (uint32_t)NSMaxRange(range));
        NSUInteger first = 0;
        while (first < groups.count && groups[first].source.end <= span.start)
            first++;
        NSUInteger last = first;
        while (last < groups.count && groups[last].source.start < span.end)
            last++;
        if (first == last || groups[first].source.start != span.start ||
            groups[last - 1].source.end != span.end)
            GAInvalidTable(@"glyph selection splits a grapheme");
        GATextRun *replacement = [GATextRun new];
        replacement.source = span;
        replacement.level = groups[first].level;
        replacement.script = groups[first].script;
        for (NSNumber *identifier in selection.selection.glyphIDs) {
            GALayoutItem *item = [GALayoutItem new];
            item.glyph = identifier.unsignedShortValue;
            item.source = span;
            item.identity = identity++;
            [replacement.glyphs addObject:item];
        }
        [groups replaceObjectsInRange:NSMakeRange(first, last - first)
                 withObjectsFromArray:@[ replacement ]];
        previousEnd = span.end;
    }
    GATag previous = 0;
    for (NSUInteger i = 0; i < groups.count; i++) {
        if (!groups[i].script) {
            groups[i].script = previous;
            if (!groups[i].script)
                for (NSUInteger j = i + 1; j < groups.count; j++)
                    if (groups[j].script) {
                        groups[i].script = groups[j].script;
                        break;
                    }
        }
        if (!groups[i].script)
            groups[i].script = GATagMake('D', 'F', 'L', 'T');
        previous = groups[i].script;
    }
    NSMutableArray<GATextRun *> *runs = [NSMutableArray array];
    BOOL paragraphStart = YES;
    for (GATextRun *group in groups) {
        BOOL newline = NO;
        for (GALayoutItem *item in group.glyphs)
            newline |= item.scalar == '\n' || item.scalar == '\r' || item.scalar == 0x2028 ||
                       item.scalar == 0x2029;
        if (newline) {
            paragraphStart = YES;
            continue;
        }
        GATextRun *run = runs.lastObject;
        if (paragraphStart || !run || run.script != group.script || run.level != group.level) {
            run = [GATextRun new];
            run.source = group.source;
            run.script = group.script;
            run.level = group.level;
            [runs addObject:run];
        }
        paragraphStart = NO;
        run.source = GAUnite(run.source, group.source);
        [run.glyphs addObjectsFromArray:group.glyphs];
    }
    int32_t joining = u_getPropertyEnum("Joining_Type"),
            dual = u_getPropertyValueEnum(joining, "D"),
            right = u_getPropertyValueEnum(joining, "R"),
            left = u_getPropertyValueEnum(joining, "L"),
            causing = u_getPropertyValueEnum(joining, "C"),
            transparent = u_getPropertyValueEnum(joining, "T");
    BOOL (^connectsBefore)(int) = ^BOOL(int type) {
        return type == dual || type == right || type == causing;
    };
    BOOL (^connectsAfter)(int) = ^BOOL(int type) {
        return type == dual || type == left || type == causing;
    };
    for (GATextRun *run in runs) {
        NSArray<GALayoutItem *> *items = run.glyphs;
        for (NSUInteger i = 0; i < items.count; i++) {
            int value = u_getIntPropertyValue(items[i].scalar, joining);
            if (value == transparent)
                continue;
            BOOL before = NO, after = NO;
            for (NSUInteger p = i; p > 0;) {
                int jt = u_getIntPropertyValue(items[--p].scalar, joining);
                if (jt == transparent)
                    continue;
                before = connectsBefore(value) && connectsAfter(jt);
                break;
            }
            for (NSUInteger p = i + 1; p < items.count; p++) {
                int jt = u_getIntPropertyValue(items[p].scalar, joining);
                if (jt == transparent)
                    continue;
                after = connectsAfter(value) && connectsBefore(jt);
                break;
            }
            if (connectsBefore(value) || connectsAfter(value))
                items[i].form =
                    before
                        ? (after ? GATagMake('m', 'e', 'd', 'i') : GATagMake('f', 'i', 'n', 'a'))
                        : (after ? GATagMake('i', 'n', 'i', 't') : GATagMake('i', 's', 'o', 'l'));
        }
    }
    return runs;
}
NSArray<NSNumber *> *GAVisualRunOrder(NSArray<GATextRun *> *runs) {
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    unsigned highest = 0, lowestOdd = UINT_MAX;
    for (NSUInteger i = 0; i < runs.count; i++) {
        [result addObject:@(i)];
        highest = MAX(highest, runs[i].level);
        if (runs[i].level & 1)
            lowestOdd = MIN(lowestOdd, runs[i].level);
    }
    if (lowestOdd == UINT_MAX)
        return result;
    for (unsigned level = highest;; level--) {
        for (NSUInteger start = 0; start < result.count;) {
            while (start < result.count && runs[result[start].unsignedIntegerValue].level < level)
                start++;
            NSUInteger end = start;
            while (end < result.count && runs[result[end].unsignedIntegerValue].level >= level)
                end++;
            for (NSUInteger a = start, b = end; a < b && a < --b; a++)
                [result exchangeObjectAtIndex:a withObjectAtIndex:b];
            start = end;
        }
        if (level == lowestOdd)
            break;
    }
    return result;
}
