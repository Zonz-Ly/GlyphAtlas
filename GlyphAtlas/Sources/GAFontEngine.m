#import "GAFontEngine.h"
#import "GAUnicode.h"
#import <AppKit/AppKit.h>

const CGFloat GAFontShapingSize = 200.0;

static BOOL GAProgressCancelled(NSProgress *progress) {
    return progress != nil && progress.isCancelled;
}

#pragma mark - CoreText helpers

static NSString *GACopyString(CFStringRef _Nullable string) {
    if (string == NULL) {
        return @"";
    }
    return CFBridgingRelease(string);
}

static NSString *GATrimTag(NSString *tag) {
    return [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

static uint16_t GAU16(const uint8_t *bytes, NSUInteger length, NSUInteger offset) {
    if (offset + 2 > length) {
        return 0;
    }
    return (uint16_t)((bytes[offset] << 8) | bytes[offset + 1]);
}

static uint32_t GAU32(const uint8_t *bytes, NSUInteger length, NSUInteger offset) {
    if (offset + 4 > length) {
        return 0;
    }
    return ((uint32_t)bytes[offset] << 24) |
           ((uint32_t)bytes[offset + 1] << 16) |
           ((uint32_t)bytes[offset + 2] << 8) |
           (uint32_t)bytes[offset + 3];
}

#pragma mark - Feature setting

@interface GAFeatureSetting : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy, nullable) NSString *tag;
@property (nonatomic, strong) GAFontBox *fontBox;
@property (nonatomic) BOOL fromAAT;
@property (nonatomic, copy, nullable) NSString *sourceName;
@end

@implementation GAFeatureSetting
@end

#pragma mark - GSUB parser

/// Returns dictionaries with "tag" and "max" keys, preserving the font's
/// feature order. Only AlternateSubst lookups can expose multiple alternates
/// through a feature value; everything else has one selectable state.
static NSArray<NSDictionary *> *GAParseGSUBFeatures(NSData *table) {
    if (table.length < 10) {
        return @[];
    }
    const uint8_t *bytes = table.bytes;
    NSUInteger length = table.length;
    uint16_t featureListOffset = GAU16(bytes, length, 6);
    uint16_t lookupListOffset = GAU16(bytes, length, 8);
    if (featureListOffset == 0 || featureListOffset + 2 > length ||
        lookupListOffset == 0 || lookupListOffset + 2 > length) {
        return @[];
    }

    uint16_t featureCount = GAU16(bytes, length, featureListOffset);
    uint16_t lookupCount = GAU16(bytes, length, lookupListOffset);
    NSMutableDictionary<NSNumber *, NSNumber *> *alternateCounts = [NSMutableDictionary dictionary];

    // Compute the largest AlternateSet in each lookup once.
    for (uint16_t lookupIndex = 0; lookupIndex < lookupCount; lookupIndex++) {
        NSUInteger offsetLocation = (NSUInteger)lookupListOffset + 2 + (NSUInteger)lookupIndex * 2;
        if (offsetLocation + 2 > length) break;
        uint16_t relative = GAU16(bytes, length, offsetLocation);
        NSUInteger lookupOffset = (NSUInteger)lookupListOffset + relative;
        if (lookupOffset + 6 > length) continue;

        uint16_t lookupType = GAU16(bytes, length, lookupOffset);
        uint16_t subtableCount = GAU16(bytes, length, lookupOffset + 4);
        NSUInteger maximum = 0;

        for (uint16_t subIndex = 0; subIndex < subtableCount; subIndex++) {
            NSUInteger subOffsetLocation = lookupOffset + 6 + (NSUInteger)subIndex * 2;
            if (subOffsetLocation + 2 > length) break;
            NSUInteger subtableOffset = lookupOffset + GAU16(bytes, length, subOffsetLocation);
            if (subtableOffset + 6 > length) continue;

            uint16_t actualType = lookupType;
            if (lookupType == 7) {
                uint16_t extensionType = GAU16(bytes, length, subtableOffset + 2);
                uint32_t extensionOffset = GAU32(bytes, length, subtableOffset + 4);
                subtableOffset += extensionOffset;
                actualType = extensionType;
                if (subtableOffset + 6 > length) continue;
            }

            if (actualType != 3) {
                continue;
            }

            uint16_t alternateSetCount = GAU16(bytes, length, subtableOffset + 4);
            for (uint16_t setIndex = 0; setIndex < alternateSetCount; setIndex++) {
                NSUInteger alternateOffsetLocation =
                    subtableOffset + 6 + (NSUInteger)setIndex * 2;
                if (alternateOffsetLocation + 2 > length) break;
                NSUInteger alternateSetOffset =
                    subtableOffset + GAU16(bytes, length, alternateOffsetLocation);
                if (alternateSetOffset + 2 > length) continue;
                uint16_t alternateCount = GAU16(bytes, length, alternateSetOffset);
                if (alternateCount > maximum) {
                    maximum = alternateCount;
                }
            }
        }

        if (maximum > 0) {
            alternateCounts[@(lookupIndex)] = @(maximum);
        }
    }

    NSMutableArray<NSDictionary *> *features = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *aggregated = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];

    for (uint16_t featureIndex = 0; featureIndex < featureCount; featureIndex++) {
        NSUInteger recordOffset =
            (NSUInteger)featureListOffset + 2 + (NSUInteger)featureIndex * 6;
        if (recordOffset + 6 > length) break;

        char tagBytes[5] = {0};
        tagBytes[0] = (char)bytes[recordOffset];
        tagBytes[1] = (char)bytes[recordOffset + 1];
        tagBytes[2] = (char)bytes[recordOffset + 2];
        tagBytes[3] = (char)bytes[recordOffset + 3];
        NSString *tag = [[NSString alloc] initWithBytes:tagBytes
                                                 length:4
                                               encoding:NSISOLatin1StringEncoding];
        tag = GATrimTag(tag ?: @"");
        if (tag.length != 4) {
            continue;
        }

        NSUInteger featureOffset =
            (NSUInteger)featureListOffset + GAU16(bytes, length, recordOffset + 4);
        if (featureOffset + 4 > length) {
            continue;
        }
        uint16_t lookupIndexCount = GAU16(bytes, length, featureOffset + 2);
        NSInteger maximum = 0;
        for (uint16_t lookupIndex = 0; lookupIndex < lookupIndexCount; lookupIndex++) {
            NSUInteger location = featureOffset + 4 + (NSUInteger)lookupIndex * 2;
            if (location + 2 > length) break;
            uint16_t index = GAU16(bytes, length, location);
            NSNumber *count = alternateCounts[@(index)];
            if (count.integerValue > maximum) {
                maximum = count.integerValue;
            }
        }

        NSNumber *previous = aggregated[tag];
        if (previous == nil) {
            [order addObject:tag];
        }
        if (maximum > previous.integerValue) {
            aggregated[tag] = @(maximum);
        }
    }

    for (NSString *tag in order) {
        [features addObject:@{@"tag": tag, @"max": aggregated[tag] ?: @0}];
    }
    return features;
}


static NSInteger GACoverageIndex(const uint8_t *bytes, NSUInteger length,
                                 NSUInteger offset, uint16_t glyph) {
    if (offset + 4 > length) return -1;
    uint16_t format = GAU16(bytes, length, offset);
    if (format == 1) {
        uint16_t count = GAU16(bytes, length, offset + 2);
        for (uint16_t i = 0; i < count; i++) {
            NSUInteger p = offset + 4 + (NSUInteger)i * 2;
            if (p + 2 > length) break;
            if (GAU16(bytes, length, p) == glyph) return i;
        }
        return -1;
    }
    if (format == 2) {
        uint16_t count = GAU16(bytes, length, offset + 2);
        for (uint16_t i = 0; i < count; i++) {
            NSUInteger p = offset + 4 + (NSUInteger)i * 6;
            if (p + 6 > length) break;
            uint16_t start = GAU16(bytes, length, p);
            uint16_t end = GAU16(bytes, length, p + 2);
            uint16_t startIndex = GAU16(bytes, length, p + 4);
            if (glyph >= start && glyph <= end) {
                return (NSInteger)startIndex + (NSInteger)(glyph - start);
            }
        }
    }
    return -1;
}

static void GAGSUBAddSource(NSMutableDictionary<NSNumber *, NSMutableOrderedSet<NSString *> *> *sources,
                            NSMutableArray<NSNumber *> *order,
                            uint16_t glyph, NSString *source) {
    NSNumber *key = @(glyph);
    NSMutableOrderedSet<NSString *> *set = sources[key];
    if (set == nil) {
        set = [NSMutableOrderedSet orderedSet];
        sources[key] = set;
        [order addObject:key];
    }
    [set addObject:source];
}

static void GAGSUBProcessSubtable(const uint8_t *bytes, NSUInteger length,
                                  NSUInteger subtableOffset, uint16_t lookupType,
                                  uint16_t seed, NSString *tag,
                                  NSMutableDictionary<NSNumber *, NSMutableOrderedSet<NSString *> *> *sources,
                                  NSMutableArray<NSNumber *> *order) {
    if (subtableOffset + 6 > length) return;

    if (lookupType == 7) {
        uint16_t extensionType = GAU16(bytes, length, subtableOffset + 2);
        uint32_t extensionOffset = GAU32(bytes, length, subtableOffset + 4);
        NSUInteger actual = subtableOffset + extensionOffset;
        if (actual < length) {
            GAGSUBProcessSubtable(bytes, length, actual, extensionType,
                                  seed, tag, sources, order);
        }
        return;
    }

    uint16_t format = GAU16(bytes, length, subtableOffset);
    uint16_t coverageOffset = GAU16(bytes, length, subtableOffset + 2);
    NSUInteger coverage = subtableOffset + coverageOffset;
    NSInteger coverageIndex = GACoverageIndex(bytes, length, coverage, seed);

    if (lookupType == 1) {
        if (coverageIndex < 0) return;
        uint16_t replacement = 0;
        if (format == 1) {
            int16_t delta = (int16_t)GAU16(bytes, length, subtableOffset + 4);
            replacement = (uint16_t)(seed + delta);
        } else if (format == 2) {
            uint16_t count = GAU16(bytes, length, subtableOffset + 4);
            if ((NSUInteger)coverageIndex >= count) return;
            replacement = GAU16(bytes, length, subtableOffset + 6 +
                                (NSUInteger)coverageIndex * 2);
        } else {
            return;
        }
        if (replacement != seed) {
            GAGSUBAddSource(sources, order, replacement, tag);
        }
        return;
    }

    if (lookupType != 3 || format != 1) return;

    uint16_t setCount = GAU16(bytes, length, subtableOffset + 4);
    BOOL hasCoverage = coverageIndex >= 0;
    for (uint16_t setIndex = 0; setIndex < setCount; setIndex++) {
        NSUInteger setOffsetLocation = subtableOffset + 6 + (NSUInteger)setIndex * 2;
        if (setOffsetLocation + 2 > length) break;
        NSUInteger setOffset = subtableOffset + GAU16(bytes, length, setOffsetLocation);
        if (setOffset + 2 > length) continue;
        uint16_t glyphCount = GAU16(bytes, length, setOffset);
        BOOL include = NO;
        if (hasCoverage) {
            include = ((NSInteger)setIndex == coverageIndex);
        } else {
            // If the seed is only an alternate output, reverse-scan the sets
            // to reveal its alternate family. When the seed is covered, use
            // its own coverage set only; GSUB does not apply other sets.
            for (uint16_t i = 0; i < glyphCount; i++) {
                NSUInteger p = setOffset + 2 + (NSUInteger)i * 2;
                if (p + 2 > length) break;
                if (GAU16(bytes, length, p) == seed) {
                    include = YES;
                    break;
                }
            }
        }
        if (!include) continue;
        for (uint16_t i = 0; i < glyphCount; i++) {
            NSUInteger p = setOffset + 2 + (NSUInteger)i * 2;
            if (p + 2 > length) break;
            uint16_t output = GAU16(bytes, length, p);
            if (output == seed) continue;
            NSString *source = glyphCount > 1
                ? [NSString stringWithFormat:@"%@ %u", tag, (unsigned)(i + 1)]
                : tag;
            GAGSUBAddSource(sources, order, output, source);
        }
    }
}

/// Enumerates GSUB outputs (single/alternate substitutions) associated with a
/// seed glyph. Alternate sets are also scanned in reverse, so a glyph that is
/// only an alternate output can still reveal its alternate family.
static NSDictionary<NSString *, id> *GAGSUBAlternatesForSeed(NSData *gsub, uint16_t seed) {
    if (gsub.length < 10) return nil;
    const uint8_t *bytes = gsub.bytes;
    NSUInteger length = gsub.length;
    uint16_t featureListOffset = GAU16(bytes, length, 6);
    uint16_t lookupListOffset = GAU16(bytes, length, 8);
    if (featureListOffset == 0 || lookupListOffset == 0 ||
        featureListOffset + 2 > length || lookupListOffset + 2 > length) {
        return nil;
    }

    uint16_t featureCount = GAU16(bytes, length, featureListOffset);
    uint16_t lookupCount = GAU16(bytes, length, lookupListOffset);
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *lookupsByTag =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *tagOrder = [NSMutableArray array];

    for (uint16_t featureIndex = 0; featureIndex < featureCount; featureIndex++) {
        NSUInteger recordOffset = (NSUInteger)featureListOffset + 2 +
                                  (NSUInteger)featureIndex * 6;
        if (recordOffset + 6 > length) break;
        char tagBytes[5] = {0};
        tagBytes[0] = (char)bytes[recordOffset];
        tagBytes[1] = (char)bytes[recordOffset + 1];
        tagBytes[2] = (char)bytes[recordOffset + 2];
        tagBytes[3] = (char)bytes[recordOffset + 3];
        NSString *tag = [[NSString alloc] initWithBytes:tagBytes length:4
                                               encoding:NSISOLatin1StringEncoding];
        tag = GATrimTag(tag ?: @"");
        if (tag.length != 4) continue;

        NSUInteger featureOffset = (NSUInteger)featureListOffset +
                                   GAU16(bytes, length, recordOffset + 4);
        if (featureOffset + 4 > length) continue;
        uint16_t lookupIndexCount = GAU16(bytes, length, featureOffset + 2);
        NSMutableArray<NSNumber *> *lookups = lookupsByTag[tag];
        if (lookups == nil) {
            lookups = [NSMutableArray array];
            lookupsByTag[tag] = lookups;
            [tagOrder addObject:tag];
        }
        for (uint16_t i = 0; i < lookupIndexCount; i++) {
            NSUInteger p = featureOffset + 4 + (NSUInteger)i * 2;
            if (p + 2 > length) break;
            NSNumber *index = @(GAU16(bytes, length, p));
            if (![lookups containsObject:index]) [lookups addObject:index];
        }
    }

    NSMutableDictionary<NSNumber *, NSMutableOrderedSet<NSString *> *> *sources =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];

    for (NSString *tag in tagOrder) {
        for (NSNumber *lookupIndex in lookupsByTag[tag]) {
            if (lookupIndex.unsignedIntValue >= lookupCount) continue;
            NSUInteger offsetLocation = (NSUInteger)lookupListOffset + 2 +
                                        lookupIndex.unsignedIntValue * 2;
            if (offsetLocation + 2 > length) continue;
            NSUInteger lookupOffset = (NSUInteger)lookupListOffset +
                                      GAU16(bytes, length, offsetLocation);
            if (lookupOffset + 6 > length) continue;
            uint16_t lookupType = GAU16(bytes, length, lookupOffset);
            uint16_t subtableCount = GAU16(bytes, length, lookupOffset + 4);
            for (uint16_t subIndex = 0; subIndex < subtableCount; subIndex++) {
                NSUInteger subOffsetLocation = lookupOffset + 6 +
                                               (NSUInteger)subIndex * 2;
                if (subOffsetLocation + 2 > length) break;
                NSUInteger subtableOffset = lookupOffset +
                                            GAU16(bytes, length, subOffsetLocation);
                GAGSUBProcessSubtable(bytes, length, subtableOffset, lookupType,
                                      seed, tag, sources, order);
            }
        }
    }

    return @{@"sources": sources, @"order": order};
}

#pragma mark - GAGlyphVariant

@interface GAGlyphVariant ()
@property (nonatomic, strong) NSMutableArray<NSString *> *mutableFeatureSources;
- (void)addFeatureSource:(NSString *)source;
@end

@implementation GAGlyphVariant

- (instancetype)init {
    self = [super init];
    if (self) {
        _glyphIDs = @[];
        _positions = @[];
        _featureSources = @[];
        _unicodeScalars = @[];
        _glyphName = @"";
        _mutableFeatureSources = [NSMutableArray array];
    }
    return self;
}

- (void)addFeatureSource:(NSString *)source {
    if (source.length == 0) {
        return;
    }
    if ([self.mutableFeatureSources containsObject:source]) {
        return;
    }
    NSString *tag = [source componentsSeparatedByString:@" "].firstObject;
    for (NSString *existing in self.mutableFeatureSources) {
        if ([[existing componentsSeparatedByString:@" "].firstObject isEqualToString:tag]) {
            return;
        }
    }
    [self.mutableFeatureSources addObject:source];
    self.featureSources = [self.mutableFeatureSources copy];
}

- (NSString *)glyphKey {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:self.glyphIDs.count];
    for (NSNumber *glyph in self.glyphIDs) {
        [parts addObject:glyph.stringValue];
    }
    return [parts componentsJoinedByString:@","];
}

@end

#pragma mark - GACharacterGroup

@implementation GACharacterGroup
@end

#pragma mark - GAFontBox

@implementation GAFontBox {
    CTFontRef _font;
}

- (instancetype)initWithFont:(CTFontRef)font {
    self = [super init];
    if (self) {
        _font = (CTFontRef)CFRetain(font);
    }
    return self;
}

- (CTFontRef)font {
    return _font;
}

- (void)dealloc {
    if (_font) {
        CFRelease(_font);
        _font = NULL;
    }
}

@end

#pragma mark - GAFontDocument

@implementation GAFontDocument {
    CTFontDescriptorRef _descriptor;
    CTFontRef _font;
    NSArray<GAFeatureSetting *> *_settings;
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *_unicodeMap;
}

- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor
                               URL:(NSURL *)url {
    self = [super init];
    if (!self) {
        return nil;
    }

    NSDictionary *baseAttributes = @{
        (__bridge NSString *)kCTFontCascadeListAttribute: @[],
    };
    _descriptor = CTFontDescriptorCreateCopyWithAttributes(
        descriptor, (__bridge CFDictionaryRef)baseAttributes);
    _font = CTFontCreateWithFontDescriptor(_descriptor, GAFontShapingSize, NULL);
    if (_font == NULL) {
        return nil;
    }

    _fontURL = [url copy];

    _fullName = GACopyString(CTFontCopyFullName(_font));
    if (_fullName.length == 0) {
        NSString *postScriptName = GACopyString(CTFontCopyPostScriptName(_font));
        _fullName = postScriptName.length > 0 ? postScriptName : @"Untitled Font";
    }

    NSData *gsub = CFBridgingRelease(CTFontCopyTable(_font, kCTFontTableGSUB, 0));
    _settings = [self buildSettingsWithGSUB:gsub];

    return self;
}

- (void)dealloc {
    if (_font) CFRelease(_font);
    if (_descriptor) CFRelease(_descriptor);
}

- (NSArray<GAFeatureSetting *> *)buildSettingsWithGSUB:(NSData *)gsub {
    NSMutableArray<GAFeatureSetting *> *settings = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];

    NSArray<NSDictionary *> *features =
        CFBridgingRelease(CTFontCopyFeatures(_font)) ?: @[];
    for (NSDictionary *feature in features) {
        NSNumber *typeNumber = feature[(__bridge NSString *)kCTFontFeatureTypeIdentifierKey];
        if (![typeNumber isKindOfClass:[NSNumber class]]) {
            continue;
        }
        NSInteger type = typeNumber.integerValue;

        NSArray *selectors =
            feature[(__bridge NSString *)kCTFontFeatureTypeSelectorsKey];
        if (![selectors isKindOfClass:[NSArray class]]) {
            continue;
        }

        for (NSDictionary *selector in selectors) {
            NSNumber *selectorNumber =
                selector[(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey];
            if (![selectorNumber isKindOfClass:[NSNumber class]]) {
                continue;
            }
            NSInteger selectorID = selectorNumber.integerValue;
            NSString *key = [NSString stringWithFormat:@"aat:%ld:%ld",
                                                       (long)type, (long)selectorID];
            if ([seen containsObject:key]) {
                continue;
            }
            [seen addObject:key];

            NSDictionary *attributes = @{
                (__bridge NSString *)kCTFontFeatureSettingsAttribute: @[
                    @{
                        (__bridge NSString *)kCTFontFeatureTypeIdentifierKey: @(type),
                        (__bridge NSString *)kCTFontFeatureSelectorIdentifierKey: @(selectorID),
                    }
                ],
            };
            CTFontRef variantFont = [self createFontWithAttributes:attributes];
            if (variantFont == NULL) {
                continue;
            }

            GAFeatureSetting *setting = [[GAFeatureSetting alloc] init];
            setting.key = key;
            setting.fromAAT = YES;
            setting.fontBox = [[GAFontBox alloc] initWithFont:variantFont];
            [settings addObject:setting];
            CFRelease(variantFont);
        }
    }

    NSArray<NSDictionary *> *openTypeFeatures = GAParseGSUBFeatures(gsub);
    for (NSDictionary *feature in openTypeFeatures) {
        NSString *tag = feature[@"tag"];
        NSInteger maximum = MAX(1, [feature[@"max"] integerValue]);
        for (NSInteger value = 1; value <= maximum; value++) {
            NSString *key = [NSString stringWithFormat:@"ot:%@:%ld", tag, (long)value];
            if ([seen containsObject:key]) {
                continue;
            }
            [seen addObject:key];

            NSDictionary *attributes = @{
                (__bridge NSString *)kCTFontFeatureSettingsAttribute: @[
                    @{
                        (__bridge NSString *)kCTFontOpenTypeFeatureTag: tag,
                        (__bridge NSString *)kCTFontOpenTypeFeatureValue: @(value),
                    }
                ],
            };
            CTFontRef variantFont = [self createFontWithAttributes:attributes];
            if (variantFont == NULL) {
                continue;
            }

            GAFeatureSetting *setting = [[GAFeatureSetting alloc] init];
            setting.key = key;
            setting.tag = tag;
            setting.fromAAT = NO;
            setting.sourceName = maximum > 1
                ? [NSString stringWithFormat:@"%@ %ld", tag, (long)value]
                : tag;
            setting.fontBox = [[GAFontBox alloc] initWithFont:variantFont];
            [settings addObject:setting];
            CFRelease(variantFont);
        }
    }

    return settings;
}

- (CTFontRef)createFontWithAttributes:(NSDictionary *)attributes {
    NSMutableDictionary *merged = [@{
        (__bridge NSString *)kCTFontCascadeListAttribute: @[],
    } mutableCopy];
    [merged addEntriesFromDictionary:attributes];

    CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(
        _descriptor, (__bridge CFDictionaryRef)merged);
    CTFontRef font = CTFontCreateWithFontDescriptor(descriptor, GAFontShapingSize, NULL);
    CFRelease(descriptor);
    return font;
}

#pragma mark - Analysis

- (GAGlyphVariant *)shapeString:(NSString *)string
                         fontBox:(GAFontBox *)fontBox
                            base:(BOOL)isBase {
    GAGlyphVariant *variant = [[GAGlyphVariant alloc] init];
    variant.fontBox = fontBox;
    variant.base = isBase;

    NSAttributedString *attributed =
        [[NSAttributedString alloc] initWithString:string
                                        attributes:@{
            NSFontAttributeName: (__bridge id)fontBox.font,
        }];
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)attributed);
    if (line == NULL) {
        return variant;
    }

    NSMutableArray<NSNumber *> *glyphs = [NSMutableArray array];
    NSMutableArray<NSValue *> *positions = [NSMutableArray array];

    CFArrayRef runsRef = CTLineGetGlyphRuns(line);
    NSArray *runs = (__bridge NSArray *)runsRef;
    for (id object in runs) {
        CTRunRef run = (__bridge CTRunRef)object;
        CFIndex count = CTRunGetGlyphCount(run);
        if (count <= 0) {
            continue;
        }

        NSDictionary *runAttributes =
            (__bridge NSDictionary *)CTRunGetAttributes(run);
        id fontObject = runAttributes[(__bridge NSString *)kCTFontAttributeName];
        if (fontObject == nil) {
            fontObject = runAttributes[NSFontAttributeName];
        }
        CTFontRef runFont = fontObject ? (__bridge CTFontRef)fontObject : NULL;
        if (![self runFont:runFont matchesFont:fontBox.font]) {
            continue;
        }
        CGGlyph *runGlyphs = calloc((size_t)count, sizeof(CGGlyph));
        CGPoint *runPositions = calloc((size_t)count, sizeof(CGPoint));
        CTRunGetGlyphs(run, CFRangeMake(0, 0), runGlyphs);
        CTRunGetPositions(run, CFRangeMake(0, 0), runPositions);
        for (CFIndex index = 0; index < count; index++) {
            [glyphs addObject:@(runGlyphs[index])];
            [positions addObject:[NSValue valueWithPoint:NSMakePoint(runPositions[index].x,
                                                                     runPositions[index].y)]];
        }
        free(runGlyphs);
        free(runPositions);
    }
    CFRelease(line);

    // CoreText falls back to another installed font for missing characters even
    // when the cascade list is empty. Keep only runs from the requested face so
    // that the app reports a true missing glyph instead of a borrowed one.
    variant.glyphIDs = glyphs;
    variant.positions = positions;
    if (isBase && glyphs.count == 0) {
        variant.glyphIDs = @[@(0)];
        variant.positions = @[[NSValue valueWithPoint:NSZeroPoint]];
    }
    return variant;
}

- (BOOL)runFont:(CTFontRef)runFont matchesFont:(CTFontRef)font {
    if (runFont == NULL || font == NULL) {
        return NO;
    }
    CFStringRef runName = CTFontCopyPostScriptName(runFont);
    CFStringRef expectedName = CTFontCopyPostScriptName(font);
    BOOL matches = (runName != NULL && expectedName != NULL &&
                    CFStringCompare(runName, expectedName, 0) == kCFCompareEqualTo);
    if (runName) CFRelease(runName);
    if (expectedName) CFRelease(expectedName);
    return matches;
}

- (NSDictionary<NSNumber *, NSArray<NSNumber *> *> *)unicodeMap {
    @synchronized (self) {
        if (_unicodeMap != nil) {
            return _unicodeMap;
        }

        NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *map =
            [NSMutableDictionary dictionary];
        CFCharacterSetRef characterSet = CTFontCopyCharacterSet(_font);
        if (characterSet != NULL) {
            for (uint32_t scalar = 0; scalar <= 0x10FFFF; scalar++) {
                if (scalar >= 0xD800 && scalar <= 0xDFFF) {
                    continue;
                }
                if (!CFCharacterSetIsLongCharacterMember(characterSet, scalar)) {
                    continue;
                }

                UniChar units[2];
                CFIndex length = 1;
                if (scalar <= 0xFFFF) {
                    units[0] = (UniChar)scalar;
                } else {
                    uint32_t value = scalar - 0x10000;
                    units[0] = (UniChar)(0xD800 + (value >> 10));
                    units[1] = (UniChar)(0xDC00 + (value & 0x3FF));
                    length = 2;
                }

                CGGlyph glyphs[2] = {0, 0};
                if (!CTFontGetGlyphsForCharacters(_font, units, glyphs, length)) {
                    continue;
                }
                if (glyphs[0] == 0) {
                    continue;
                }
                NSNumber *key = @(glyphs[0]);
                NSMutableArray<NSNumber *> *scalars = map[key];
                if (scalars == nil) {
                    scalars = [NSMutableArray array];
                    map[key] = scalars;
                }
                [scalars addObject:@(scalar)];
            }
            CFRelease(characterSet);
        }

        NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *frozen =
            [NSMutableDictionary dictionaryWithCapacity:map.count];
        [map enumerateKeysAndObjectsUsingBlock:^(NSNumber *key,
                                                 NSMutableArray<NSNumber *> *value,
                                                 BOOL *stop) {
            (void)stop;
            frozen[key] = [value copy];
        }];
        _unicodeMap = [frozen copy];
        return _unicodeMap;
    }
}

static BOOL GAGlyphNameLooksSynthetic(NSString *name) {
    if (name.length == 0) {
        return YES;
    }
    static NSRegularExpression *gidPattern;
    static NSRegularExpression *temporaryPattern;
    static NSRegularExpression *variationPattern;
    static NSRegularExpression *multiUnicodePattern;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gidPattern = [NSRegularExpression regularExpressionWithPattern:
            @"^(?:gid|glyph)[0-9]+$" options:NSRegularExpressionCaseInsensitive error:nil];
        temporaryPattern = [NSRegularExpression regularExpressionWithPattern:
            @"^uni(?:[0-9a-f]{4,6})+\\.[0-9]+$"
            options:NSRegularExpressionCaseInsensitive error:nil];
        variationPattern = [NSRegularExpression regularExpressionWithPattern:
            @"^uni(?:[0-9a-f]{4,6})*_u[0-9a-f]{4,6}(?:\\.[0-9]+)?$"
            options:NSRegularExpressionCaseInsensitive error:nil];
        multiUnicodePattern = [NSRegularExpression regularExpressionWithPattern:
            @"^uni(?:[0-9a-f]{4,6}){2,}$"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSRange range = NSMakeRange(0, name.length);
    if ([gidPattern firstMatchInString:name options:0 range:range] != nil) {
        return YES;
    }
    if ([temporaryPattern firstMatchInString:name options:0 range:range] != nil) {
        return YES;
    }
    if ([variationPattern firstMatchInString:name options:0 range:range] != nil) {
        return YES;
    }
    if ([multiUnicodePattern firstMatchInString:name options:0 range:range] != nil) {
        return YES;
    }
    return NO;
}

- (void)decorateVariant:(GAGlyphVariant *)variant
          withUnicodeMap:(NSDictionary<NSNumber *, NSArray<NSNumber *> *> *)map {
    NSMutableOrderedSet<NSNumber *> *scalars = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSString *> *glyphNames = [NSMutableArray array];

    for (NSNumber *glyphNumber in variant.glyphIDs) {
        NSArray<NSNumber *> *mapped = map[glyphNumber];
        for (NSNumber *scalar in mapped) {
            [scalars addObject:scalar];
        }

        CGGlyph glyph = (CGGlyph)glyphNumber.unsignedShortValue;
        CFStringRef glyphName = CTFontCopyNameForGlyph(_font, glyph);
        NSString *name = glyphName ? CFBridgingRelease(glyphName) : @"";
        if (name.length > 0 && !GAGlyphNameLooksSynthetic(name)) {
            [glyphNames addObject:name];
        } else {
            [glyphNames addObject:[NSString stringWithFormat:@"GID %@", glyphNumber]];
        }
    }

    NSArray<NSNumber *> *sortedScalars = [scalars.array sortedArrayUsingComparator:
        ^NSComparisonResult(NSNumber *a, NSNumber *b) {
            return [a compare:b];
        }];
    variant.unicodeScalars = sortedScalars;
    variant.glyphName = [glyphNames componentsJoinedByString:@"/"];
}

/// Clusters from shaping the whole input string. Each cluster has a UTF-16
/// range and the glyph sequence CoreText produced for it. A cluster spanning
/// more than one composed character is a ligature / contextual multi-char
/// substitution.
static NSArray<NSDictionary *> *GAWholeTextClusters(NSString *text, CTFontRef font) {
    if (text.length == 0 || font == NULL) return @[];

    NSAttributedString *attributed =
        [[NSAttributedString alloc] initWithString:text
                                        attributes:@{
            NSFontAttributeName: (__bridge id)font,
        }];
    CTLineRef line = CTLineCreateWithAttributedString(
        (__bridge CFAttributedStringRef)attributed);
    if (line == NULL) return @[];

    NSMutableArray<NSNumber *> *glyphs = [NSMutableArray array];
    NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex runIndex = 0; runIndex < CFArrayGetCount(runs); runIndex++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, runIndex);
        CFIndex count = CTRunGetGlyphCount(run);
        if (count <= 0) continue;

        CGGlyph *runGlyphs = calloc((size_t)count, sizeof(CGGlyph));
        CFIndex *runIndices = calloc((size_t)count, sizeof(CFIndex));
        CTRunGetGlyphs(run, CFRangeMake(0, count), runGlyphs);
        CTRunGetStringIndices(run, CFRangeMake(0, count), runIndices);
        for (CFIndex i = 0; i < count; i++) {
            if (runIndices[i] < 0) continue;
            [glyphs addObject:@(runGlyphs[i])];
            [indices addObject:@((NSUInteger)runIndices[i])];
        }
        free(runGlyphs);
        free(runIndices);
    }
    CFRelease(line);

    NSMutableArray<NSNumber *> *clusterStarts = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber *> *> *clusterGlyphs = [NSMutableArray array];
    for (NSUInteger i = 0; i < glyphs.count; i++) {
        NSUInteger start = indices[i].unsignedIntegerValue;
        if (clusterStarts.count == 0 ||
            clusterStarts.lastObject.unsignedIntegerValue != start) {
            [clusterStarts addObject:@(start)];
            [clusterGlyphs addObject:[NSMutableArray array]];
        }
        [clusterGlyphs.lastObject addObject:glyphs[i]];
    }

    NSMutableArray<NSDictionary *> *clusters = [NSMutableArray array];
    for (NSUInteger i = 0; i < clusterStarts.count; i++) {
        NSUInteger start = clusterStarts[i].unsignedIntegerValue;
        NSUInteger end = (i + 1 < clusterStarts.count)
            ? clusterStarts[i + 1].unsignedIntegerValue
            : text.length;
        if (end <= start || start >= text.length) continue;
        end = MIN(end, text.length);
        [clusters addObject:@{
            @"start": @(start),
            @"end": @(end),
            @"glyphs": [clusterGlyphs[i] copy],
        }];
    }
    return clusters;
}

static NSRange GAGroupSpanForCluster(NSArray<GACharacterGroup *> *groups,
                                     NSUInteger start, NSUInteger end) {
    NSInteger first = -1;
    NSInteger last = -1;
    for (NSInteger i = 0; i < (NSInteger)groups.count; i++) {
        NSRange range = groups[(NSUInteger)i].textRange;
        if (range.location == NSNotFound) continue;
        if (start < NSMaxRange(range) && end > range.location) {
            if (first < 0) first = i;
            last = i;
        }
    }
    if (first < 0 || last < first) {
        return NSMakeRange(NSNotFound, 0);
    }
    return NSMakeRange((NSUInteger)first, (NSUInteger)(last - first + 1));
}

- (void)appendWholeTextVariantsToGroups:(NSMutableArray<GACharacterGroup *> *)groups
                                  text:(NSString *)text
                              progress:(nullable NSProgress *)progress {
    if (groups.count < 2 || text.length == 0 || GAProgressCancelled(progress)) return;

    NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, GAGlyphVariant *> *> *byKey =
        [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableArray<GAGlyphVariant *> *> *extras =
        [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < groups.count; i++) {
        GACharacterGroup *group = groups[i];
        NSMutableDictionary<NSString *, GAGlyphVariant *> *keys =
            [NSMutableDictionary dictionary];
        for (GAGlyphVariant *variant in group.variants) {
            if (variant.glyphKey.length > 0) keys[variant.glyphKey] = variant;
        }
        byKey[@(i)] = keys;
        extras[@(i)] = [NSMutableArray array];
    }

    void (^addClusters)(NSArray<NSDictionary *> *, GAFontBox *, NSString *,
                        NSDictionary<NSNumber *, NSDictionary *> *, NSUInteger) =
        ^(NSArray<NSDictionary *> *clusters, GAFontBox *fontBox,
          NSString *source,
          NSDictionary<NSNumber *, NSDictionary *> *baseByStart,
          NSUInteger offset) {
            for (NSDictionary *cluster in clusters) {
                NSUInteger start = [cluster[@"start"] unsignedIntegerValue];
                NSUInteger end = [cluster[@"end"] unsignedIntegerValue];
                NSArray<NSNumber *> *glyphs = cluster[@"glyphs"];
                if (glyphs.count == 0) continue;

                if (baseByStart != nil) {
                    NSDictionary *baseCluster = baseByStart[@(start)];
                    if (baseCluster != nil) {
                        NSUInteger baseEnd = [baseCluster[@"end"] unsignedIntegerValue];
                        NSArray<NSNumber *> *baseGlyphs = baseCluster[@"glyphs"];
                        if (baseEnd == end && [baseGlyphs isEqualToArray:glyphs]) {
                            continue;
                        }
                    }
                }
                NSUInteger absoluteStart = start + offset;
                NSUInteger absoluteEnd = end + offset;
                NSRange span = GAGroupSpanForCluster(groups, absoluteStart, absoluteEnd);
                if (span.location == NSNotFound) continue;
                NSUInteger target = NSMaxRange(span) - 1;

                NSMutableArray<NSString *> *parts =
                    [NSMutableArray arrayWithCapacity:glyphs.count];
                for (NSNumber *glyph in glyphs) {
                    [parts addObject:glyph.stringValue];
                }
                NSString *key = [parts componentsJoinedByString:@","];
                BOOL ligatureSpan = span.length > 1;
                GAGlyphVariant *existing = byKey[@(target)][key];
                if (existing != nil) {
                    if (!existing.isBase) {
                        if (source.length > 0) [existing addFeatureSource:source];
                        if (ligatureSpan) {
                            existing.ligature = YES;
                            existing.sourceTextRange =
                                NSMakeRange(absoluteStart, absoluteEnd - absoluteStart);
                        }
                    }
                    continue;
                }

                GAGlyphVariant *candidate = [[GAGlyphVariant alloc] init];
                candidate.fontBox = fontBox;
                candidate.glyphIDs = glyphs;
                NSMutableArray<NSValue *> *positions = [NSMutableArray array];
                for (NSUInteger i = 0; i < glyphs.count; i++) {
                    [positions addObject:[NSValue valueWithPoint:NSZeroPoint]];
                }
                candidate.positions = positions;
                if (source.length > 0) [candidate addFeatureSource:source];
                if (ligatureSpan) {
                    candidate.ligature = YES;
                    candidate.sourceTextRange =
                        NSMakeRange(absoluteStart, absoluteEnd - absoluteStart);
                }
                [self decorateVariant:candidate withUnicodeMap:self.unicodeMap];
                byKey[@(target)][key] = candidate;
                [extras[@(target)] addObject:candidate];
            }
        };

    GAFontBox *baseBox = [[GAFontBox alloc] initWithFont:_font];
    // Enumerate by end position, from single character to longer suffixes:
    // a, b, ab, c, bc, abc, d, cd, bcd, abcd.
    for (NSUInteger last = 0; last < groups.count; last++) {
        for (NSInteger firstIndex = (NSInteger)last; firstIndex >= 0; firstIndex--) {
            if (GAProgressCancelled(progress)) return;
            NSUInteger first = (NSUInteger)firstIndex;
            NSRange firstRange = groups[first].textRange;
            NSRange lastRange = groups[last].textRange;
            if (firstRange.location == NSNotFound || lastRange.location == NSNotFound) {
                continue;
            }
            NSUInteger start = firstRange.location;
            NSUInteger end = NSMaxRange(lastRange);
            if (end <= start || end > text.length) continue;
            NSRange substringRange = NSMakeRange(start, end - start);
            NSString *substring = [text substringWithRange:substringRange];

            NSArray<NSDictionary *> *baseClusters =
                GAWholeTextClusters(substring, baseBox.font);
            NSMutableDictionary<NSNumber *, NSDictionary *> *baseByStart =
                [NSMutableDictionary dictionary];
            for (NSDictionary *cluster in baseClusters) {
                NSNumber *clusterStart = cluster[@"start"];
                if (clusterStart != nil) baseByStart[clusterStart] = cluster;
            }
            addClusters(baseClusters, baseBox, @"actual", nil, start);
            for (GAFeatureSetting *setting in _settings) {
                NSString *source = nil;
                if (!setting.fromAAT) {
                    source = setting.sourceName;
                    if (source.length == 0) source = setting.tag;
                    if (source.length == 0) source = setting.key;
                }
                // AAT features are only used to discover glyphs. Their
                // type/selector names are transient system metadata, not
                // actual font feature information, so don't label them.
                addClusters(GAWholeTextClusters(substring, setting.fontBox.font),
                            setting.fontBox, source ?: @"", baseByStart, start);
            }
        }
    }

    for (NSNumber *index in extras) {
        NSArray<GAGlyphVariant *> *extra = extras[index];
        if (extra.count == 0) continue;
        GACharacterGroup *group = groups[index.unsignedIntegerValue];
        NSMutableArray<GAGlyphVariant *> *variants = [group.variants mutableCopy];
        [variants addObjectsFromArray:extra];
        group.variants = variants;
    }
}

- (NSArray<GACharacterGroup *> *)analyzeText:(NSString *)text {
    return [self analyzeText:text progress:nil];
}

- (NSArray<GACharacterGroup *> *)analyzeText:(NSString *)text
                                    progress:(nullable NSProgress *)progress {
    if (text.length == 0 || GAProgressCancelled(progress)) {
        return @[];
    }

    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *unicodeMap = [self unicodeMap];
    NSMutableArray<GACharacterGroup *> *groups = [NSMutableArray array];
    NSData *gsub = CFBridgingRelease(CTFontCopyTable(_font, kCTFontTableGSUB, 0));

    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *substring,
                                       NSRange substringRange,
                                       NSRange enclosingRange,
                                       BOOL *stop) {
        (void)enclosingRange;
        if (GAProgressCancelled(progress)) {
            *stop = YES;
            return;
        }
        if (substring.length == 0) {
            return;
        }

        NSMutableArray<NSNumber *> *scalars = [NSMutableArray array];
        for (NSUInteger index = 0; index < substring.length; index++) {
            unichar unit = [substring characterAtIndex:index];
            if (CFStringIsSurrogateHighCharacter(unit) &&
                index + 1 < substring.length &&
                CFStringIsSurrogateLowCharacter([substring characterAtIndex:index + 1])) {
                unichar low = [substring characterAtIndex:index + 1];
                uint32_t scalar =
                    ((uint32_t)(unit - 0xD800) << 10) +
                    (uint32_t)(low - 0xDC00) + 0x10000;
                [scalars addObject:@(scalar)];
                index++;
            } else {
                [scalars addObject:@(unit)];
            }
        }

        GAFontBox *baseFont = [[GAFontBox alloc] initWithFont:_font];
        GAGlyphVariant *baseVariant = [self shapeString:substring
                                                fontBox:baseFont
                                                   base:YES];
        [self decorateVariant:baseVariant withUnicodeMap:unicodeMap];
        if (baseVariant.unicodeScalars.count == 0) {
            baseVariant.unicodeScalars = scalars;
        }

        NSMutableArray<GAGlyphVariant *> *variants = [NSMutableArray arrayWithObject:baseVariant];
        NSMutableDictionary<NSString *, GAGlyphVariant *> *seen =
            [NSMutableDictionary dictionaryWithObject:baseVariant
                                               forKey:baseVariant.glyphKey];

        NSNumber *baseGlyph = baseVariant.glyphIDs.firstObject;
        if (baseGlyph != nil && gsub.length > 0) {
            NSDictionary<NSString *, id> *directInfo = GAGSUBAlternatesForSeed(
                gsub, (uint16_t)baseGlyph.unsignedShortValue);
            NSDictionary<NSNumber *, NSMutableOrderedSet<NSString *> *> *directSources =
                directInfo[@"sources"];
            NSArray<NSNumber *> *directOrder = directInfo[@"order"] ?: @[];
            for (NSNumber *glyphID in directOrder) {
                NSString *key = glyphID.stringValue;
                NSMutableOrderedSet<NSString *> *sources = directSources[glyphID];
                if (seen[key] != nil) {
                    continue;
                }
                GAGlyphVariant *candidate = [[GAGlyphVariant alloc] init];
                candidate.fontBox = baseFont;
                candidate.glyphIDs = @[glyphID];
                candidate.positions = @[[NSValue valueWithPoint:NSZeroPoint]];
                for (NSString *source in sources) {
                    [candidate addFeatureSource:source];
                }
                [self decorateVariant:candidate withUnicodeMap:unicodeMap];
                seen[key] = candidate;
                [variants addObject:candidate];
            }
        }

        for (GAFeatureSetting *setting in _settings) {
            GAGlyphVariant *candidate = [self shapeString:substring
                                                 fontBox:setting.fontBox
                                                    base:NO];
            NSString *key = candidate.glyphKey;
            if (key.length == 0 || [seen objectForKey:key] != nil) {
                GAGlyphVariant *existing = seen[key];
                if (existing != nil && !existing.isBase && key.length > 0) {
                    if (!setting.fromAAT && setting.sourceName.length > 0) {
                        [existing addFeatureSource:setting.sourceName];
                    }
                }
                continue;
            }

            if (!setting.fromAAT && setting.sourceName.length > 0) {
                [candidate addFeatureSource:setting.sourceName];
            }
            [self decorateVariant:candidate withUnicodeMap:unicodeMap];
            seen[key] = candidate;
            [variants addObject:candidate];
        }

        GACharacterGroup *group = [[GACharacterGroup alloc] init];
        group.text = substring;
        group.textRange = substringRange;
        group.variants = variants;
        [groups addObject:group];
    }];

    [self appendWholeTextVariantsToGroups:groups text:text progress:progress];

    return [groups copy];
}

- (NSArray<GACharacterGroup *> *)analyzeGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (glyphIDs.count == 0) {
        return @[];
    }
    NSData *gsub = CFBridgingRelease(CTFontCopyTable(_font, kCTFontTableGSUB, 0));
    NSDictionary<NSString *, id> *info = GAGSUBAlternatesForSeed(
        gsub, (uint16_t)glyphIDs.firstObject.unsignedShortValue);
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *unicodeMap = [self unicodeMap];
    GAFontBox *fontBox = [[GAFontBox alloc] initWithFont:_font];

    GAGlyphVariant *base = [[GAGlyphVariant alloc] init];
    base.fontBox = fontBox;
    base.glyphIDs = glyphIDs;
    NSMutableArray<NSValue *> *basePositions = [NSMutableArray array];
    for (NSUInteger index = 0; index < glyphIDs.count; index++) {
        [basePositions addObject:[NSValue valueWithPoint:NSZeroPoint]];
    }
    base.positions = basePositions;
    base.base = YES;
    [self decorateVariant:base withUnicodeMap:unicodeMap];

    NSMutableArray<GAGlyphVariant *> *variants = [NSMutableArray arrayWithObject:base];
    NSMutableDictionary<NSNumber *, NSMutableOrderedSet<NSString *> *> *sources =
        info[@"sources"];
    NSArray<NSNumber *> *order = info[@"order"] ?: @[];
    for (NSNumber *glyphID in order) {
        GAGlyphVariant *variant = [[GAGlyphVariant alloc] init];
        variant.fontBox = fontBox;
        variant.glyphIDs = @[glyphID];
        variant.positions = @[[NSValue valueWithPoint:NSZeroPoint]];
        NSMutableOrderedSet<NSString *> *variantSources = sources[glyphID];
        for (NSString *source in variantSources) {
            [variant addFeatureSource:source];
        }
        [self decorateVariant:variant withUnicodeMap:unicodeMap];
        [variants addObject:variant];
    }

    GACharacterGroup *group = [[GACharacterGroup alloc] init];
    group.text = @"";
    group.textRange = NSMakeRange(NSNotFound, 0);
    group.variants = variants;
    return @[group];
}

#pragma mark - Drawing

+ (CGRect)inkBoundsForVariant:(GAGlyphVariant *)variant {
    NSUInteger count = variant.glyphIDs.count;
    if (count == 0) {
        return CGRectZero;
    }
    CGGlyph *glyphs = calloc(count, sizeof(CGGlyph));
    for (NSUInteger index = 0; index < count; index++) {
        glyphs[index] = (CGGlyph)variant.glyphIDs[index].unsignedShortValue;
    }
    CGRect *rects = calloc(count, sizeof(CGRect));
    CTFontGetBoundingRectsForGlyphs(variant.fontBox.font,
                                    kCTFontOrientationHorizontal,
                                    glyphs, rects, (CFIndex)count);

    CGRect unionRect = CGRectNull;
    for (NSUInteger index = 0; index < count; index++) {
        CGRect rect = rects[index];
        if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) {
            continue;
        }
        CGPoint position = CGPointZero;
        if (index < variant.positions.count) {
            position = variant.positions[index].pointValue;
        }
        rect.origin.x += position.x;
        rect.origin.y += position.y;
        unionRect = CGRectIsNull(unionRect) ? rect : CGRectUnion(unionRect, rect);
    }
    free(glyphs);
    free(rects);

    if (CGRectIsNull(unionRect) || CGRectIsEmpty(unionRect)) {
        return CGRectZero;
    }
    return unionRect;
}

+ (BOOL)variantHasVerticalMetrics:(GAGlyphVariant *)variant {
    NSData *vmtx = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVmtx, 0));
    NSData *vhea = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVhea, 0));
    return vmtx.length >= 4 && vhea.length >= 36;
}

+ (CGFloat)verticalTopSideBearingForVariant:(GAGlyphVariant *)variant {
    if (variant.glyphIDs.count == 0) {
        return 0;
    }
    NSData *vmtx = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVmtx, 0));
    NSData *vhea = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVhea, 0));
    if (vmtx.length < 4 || vhea.length < 36) {
        return 0;
    }
    const uint8_t *vmtxBytes = vmtx.bytes;
    const uint8_t *vheaBytes = vhea.bytes;
    NSUInteger vmtxLength = vmtx.length;
    uint16_t numberOfVMetrics = (uint16_t)((vheaBytes[34] << 8) | vheaBytes[35]);
    if (numberOfVMetrics == 0) {
        return 0;
    }
    NSUInteger glyphID = variant.glyphIDs.firstObject.unsignedIntegerValue;
    NSUInteger offset;
    if (glyphID < numberOfVMetrics) {
        offset = glyphID * 4 + 2;
    } else {
        offset = (NSUInteger)numberOfVMetrics * 4 +
                 (glyphID - numberOfVMetrics) * 2;
    }
    if (offset + 2 > vmtxLength) {
        return 0;
    }
    return (CGFloat)(int16_t)((vmtxBytes[offset] << 8) | vmtxBytes[offset + 1]);
}

+ (CGSize)advanceInFontUnitsForVariant:(GAGlyphVariant *)variant {
    NSUInteger count = variant.glyphIDs.count;
    if (count == 0) {
        return CGSizeZero;
    }
    unsigned upem = CTFontGetUnitsPerEm(variant.fontBox.font);
    if (upem == 0) {
        upem = 1000;
    }
    CGGlyph *glyphs = calloc(count, sizeof(CGGlyph));
    for (NSUInteger index = 0; index < count; index++) {
        glyphs[index] = (CGGlyph)variant.glyphIDs[index].unsignedShortValue;
    }
    // CGFont advances are raw font units and do not include the trak table's
    // size-dependent tracking that CTFontGetAdvancesForGlyphs applies.
    CGFontRef cgFont = CTFontCopyGraphicsFont(variant.fontBox.font, NULL);
    int *advances = calloc(count, sizeof(int));
    if (cgFont != NULL) {
        CGFontGetGlyphAdvances(cgFont, glyphs, count, advances);
        CFRelease(cgFont);
    }
    CGFloat width = 0;
    for (NSUInteger index = 0; index < count; index++) {
        width += advances[index];
    }
    free(advances);

    CGFloat factor = (CGFloat)upem / GAFontShapingSize;
    CGFloat height = 0;
    if ([self variantHasVerticalMetrics:variant]) {
        CGSize *vAdvances = calloc(count, sizeof(CGSize));
        CTFontGetAdvancesForGlyphs(variant.fontBox.font,
                                   kCTFontOrientationVertical,
                                   glyphs, vAdvances, (CFIndex)count);
        for (NSUInteger index = 0; index < count; index++) {
            // CoreText puts the vertical advance in CGSize.width.
            height += MAX(vAdvances[index].width, vAdvances[index].height);
        }
        free(vAdvances);
    } else {
        height = CTFontGetAscent(variant.fontBox.font) +
                 CTFontGetDescent(variant.fontBox.font);
    }
    free(glyphs);
    return CGSizeMake(width, height * factor);
}

@end
