#import "GAFontEngine.h"
#import "GAUnicode.h"
#import <AppKit/AppKit.h>

const CGFloat GAFontShapingSize = 200.0;
NSString * const GAGlyphSelectionAttributeName =
    @"com.zonz.GlyphAtlas.glyphSelection";

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

static BOOL GAFontsMatch(CTFontRef runFont, CTFontRef font) {
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

#pragma mark - Feature variation conditions

/// Parsed once per resource. Lookup offsets remain relative to the original
/// GSUB bytes; the existing feature/lookup parser consumes the selected overrides.
/// Subtract one inclusive condition box from another, retaining disjoint pieces.
static NSArray *GASubtractConditionBox(NSArray *box, NSArray *cut) {
    NSMutableArray *intersection = [NSMutableArray array];
    for (NSUInteger i = 0; i < box.count; i++) {
        NSInteger low = MAX([box[i][0] integerValue], [cut[i][0] integerValue]);
        NSInteger high = MIN([box[i][1] integerValue], [cut[i][1] integerValue]);
        if (low > high) return @[box];
        [intersection addObject:@[@(low), @(high)]];
    }
    NSMutableArray *pieces = [NSMutableArray array];
    NSMutableArray *rest = [box mutableCopy];
    for (NSUInteger i = 0; i < box.count; i++) {
        NSInteger low = [rest[i][0] integerValue], high = [rest[i][1] integerValue];
        NSInteger innerLow = [intersection[i][0] integerValue], innerHigh = [intersection[i][1] integerValue];
        if (low < innerLow) {
            NSMutableArray *piece = [rest mutableCopy];
            piece[i] = @[@(low), @(innerLow - 1)];
            [pieces addObject:piece];
        }
        if (high > innerHigh) {
            NSMutableArray *piece = [rest mutableCopy];
            piece[i] = @[@(innerHigh + 1), @(high)];
            [pieces addObject:piece];
        }
        rest[i] = intersection[i];
    }
    return pieces;
}

@interface GAFeatureVariations : NSObject
@property (nonatomic, copy) NSArray<NSDictionary *> *axes;
@property (nonatomic, copy) NSArray<NSArray<NSArray<NSNumber *> *> *> *maps;
@property (nonatomic, copy) NSArray<NSDictionary *> *records;
@property (nonatomic) BOOL supported;
- (instancetype)initWithGSUB:(NSData *)gsub font:(CTFontRef)font;
- (NSDictionary *)selectionForFont:(CTFontRef)font coordinates:(NSDictionary *)requested;
- (NSArray<NSDictionary *> *)discoveryCoordinates;
@end

@implementation GAFeatureVariations
- (instancetype)initWithGSUB:(NSData *)gsub font:(CTFontRef)font {
    self = [super init];
    if (!self) return nil;
    _supported = YES;
    _records = @[];
    _axes = @[];
    _maps = @[];
    const uint8_t *b = gsub.bytes;
    NSUInteger length = gsub.length;
    if (length < 14 || GAU32(b, length, 0) != 0x00010001) return self;
    NSUInteger start = GAU32(b, length, 10);
    if (start == 0) return self;
    if (start + 8 > length || GAU16(b, length, start) != 1) {
        _supported = NO;
        return self;
    }
    NSData *fvar = CFBridgingRelease(CTFontCopyTable(font, kCTFontTableFvar, 0));
    const uint8_t *fb = fvar.bytes;
    NSUInteger axisStart = GAU16(fb, fvar.length, 4);
    NSUInteger axisCount = GAU16(fb, fvar.length, 8);
    NSUInteger axisSize = GAU16(fb, fvar.length, 10);
    if (fvar.length < 16 || axisSize < 20 || axisStart + axisSize * axisCount > fvar.length) {
        _supported = NO;
        return self;
    }
    NSMutableArray *axes = [NSMutableArray array];
    for (NSUInteger i = 0; i < axisCount; i++) {
        NSUInteger p = axisStart + i * axisSize;
        [axes addObject:@{
            @"tag": @(GAU32(fb, fvar.length, p)),
            @"min": @((int32_t)GAU32(fb, fvar.length, p + 4) / 65536.0),
            @"default": @((int32_t)GAU32(fb, fvar.length, p + 8) / 65536.0),
            @"max": @((int32_t)GAU32(fb, fvar.length, p + 12) / 65536.0),
        }];
    }
    _axes = axes;
    NSData *avar = CFBridgingRelease(CTFontCopyTable(font, kCTFontTableAvar, 0));
    NSMutableArray *maps = [NSMutableArray array];
    if (avar.length > 0) {
        const uint8_t *ab = avar.bytes;
        if (avar.length < 8 || GAU16(ab, avar.length, 0) != 1 || GAU16(ab, avar.length, 6) != axisCount) {
            // Unimplemented coordinate mappings must never share scan results
            // across distinct coordinates. CoreText still performs the shaping.
            _supported = NO;
        } else {
            NSUInteger p = 8;
            for (NSUInteger i = 0; i < axisCount; i++) {
                NSUInteger count = GAU16(ab, avar.length, p);
                p += 2;
                if (p + count * 4 > avar.length) { _supported = NO; break; }
                NSMutableArray *map = [NSMutableArray array];
                for (NSUInteger j = 0; j < count; j++, p += 4) {
                    double from = (int16_t)GAU16(ab, avar.length, p) / 16384.0;
                    double to = (int16_t)GAU16(ab, avar.length, p + 2) / 16384.0;
                    if (map.count && (from <= [map.lastObject[0] doubleValue] || to < [map.lastObject[1] doubleValue])) _supported = NO;
                    [map addObject:@[@(from), @(to)]];
                }
                if (map.count && (![map containsObject:@[@(-1), @(-1)]] ||
                                  ![map containsObject:@[@0, @0]] || ![map containsObject:@[@1, @1]])) _supported = NO;
                [maps addObject:map];
            }
        }
    }
    _maps = maps;
    NSUInteger recordCount = GAU32(b, length, start + 4);
    if (start + 8 + recordCount * 8 > length) { _supported = NO; return self; }
    NSMutableArray *records = [NSMutableArray array];
    NSUInteger featureCount = GAU16(b, length, GAU16(b, length, 6));
    for (NSUInteger i = 0; i < recordCount; i++) {
        NSUInteger p = start + 8 + i * 8;
        NSUInteger conditions = start + GAU32(b, length, p);
        NSUInteger substitutions = start + GAU32(b, length, p + 4);
        if (conditions + 2 > length || substitutions + 6 > length ||
            GAU16(b, length, substitutions) != 1) { _supported = NO; continue; }
        NSUInteger count = GAU16(b, length, conditions);
        if (conditions + 2 + count * 4 > length) { _supported = NO; continue; }
        NSMutableArray *tests = [NSMutableArray array];
        for (NSUInteger j = 0; j < count; j++) {
            NSUInteger c = conditions + GAU32(b, length, conditions + 2 + j * 4);
            if (c + 8 > length || GAU16(b, length, c) != 1 || GAU16(b, length, c + 2) >= axisCount) {
                _supported = NO;
                continue;
            }
            [tests addObject:@{
                @"axis": @(GAU16(b, length, c + 2)),
                @"min": @((int16_t)GAU16(b, length, c + 4)),
                @"max": @((int16_t)GAU16(b, length, c + 6)),
            }];
        }
        NSUInteger substitutionCount = GAU16(b, length, substitutions + 4);
        if (substitutions + 6 + substitutionCount * 6 > length) { _supported = NO; continue; }
        NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
        for (NSUInteger j = 0; j < substitutionCount; j++) {
            NSUInteger sub = substitutions + 6 + j * 6;
            NSUInteger feature = GAU16(b, length, sub);
            NSUInteger alternate = substitutions + GAU32(b, length, sub + 2);
            if (feature >= featureCount || alternate + 4 > length ||
                alternate + 4 + GAU16(b, length, alternate + 2) * 2 > length) {
                _supported = NO;
                continue;
            }
            overrides[@(feature)] = @(alternate);
        }
        [records addObject:@{@"index": @(i), @"conditions": tests, @"overrides": overrides}];
    }
    _records = records;
    return self;
}

- (NSArray<NSDictionary *> *)discoveryCoordinates {
    if (!self.supported) return @[];
    NSMutableArray *previous = [NSMutableArray array];
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *record in self.records) {
        NSMutableArray *box = [NSMutableArray array];
        for (NSUInteger i = 0; i < self.axes.count; i++) [box addObject:@[@(-16384), @16384]];
        BOOL valid = YES;
        for (NSDictionary *test in record[@"conditions"]) {
            NSUInteger i = [test[@"axis"] unsignedIntegerValue];
            NSInteger low = MAX([box[i][0] integerValue], [test[@"min"] integerValue]);
            NSInteger high = MIN([box[i][1] integerValue], [test[@"max"] integerValue]);
            if (low > high) { valid = NO; break; }
            box[i] = @[@(low), @(high)];
        }
        if (!valid) continue;
        NSArray *pieces = @[box];
        // Only the first matching record takes effect. Remove regions already
        // claimed by an earlier record before selecting a representative point.
        for (NSArray *earlier in previous) {
            NSMutableArray *remaining = [NSMutableArray array];
            for (NSArray *piece in pieces) [remaining addObjectsFromArray:GASubtractConditionBox(piece, earlier)];
            pieces = remaining;
            if (pieces.count == 0) break;
        }
        [previous addObject:box];
        if (pieces.count == 0) continue;
        NSArray *piece = pieces.firstObject;
        NSMutableDictionary *coordinates = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < self.axes.count; i++) {
            double normalized = floor(([piece[i][0] doubleValue] + [piece[i][1] doubleValue]) * 0.5) / 16384.0;
            NSArray *map = i < self.maps.count ? self.maps[i] : @[];
            for (NSUInteger j = 1; j < map.count; j++) {
                double y0 = [map[j - 1][1] doubleValue], y1 = [map[j][1] doubleValue];
                if (normalized >= y0 && normalized <= y1) {
                    double x0 = [map[j - 1][0] doubleValue], x1 = [map[j][0] doubleValue];
                    normalized = y0 == y1 ? (x0 + x1) * 0.5 : x0 + (normalized - y0) * (x1 - x0) / (y1 - y0);
                    break;
                }
            }
            NSDictionary *axis = self.axes[i];
            double def = [axis[@"default"] doubleValue];
            double value = def + normalized * (normalized < 0 ? def - [axis[@"min"] doubleValue] : [axis[@"max"] doubleValue] - def);
            coordinates[axis[@"tag"]] = @(value);
        }
        [result addObject:@{@"key": [record[@"index"] stringValue], @"coordinates": coordinates}];
    }
    return result;
}

- (NSDictionary *)selectionForFont:(CTFontRef)font coordinates:(NSDictionary *)requested {
    NSMutableDictionary *coordinates = [CFBridgingRelease(CTFontCopyVariation(font)) mutableCopy] ?: [NSMutableDictionary dictionary];
    // CTFontCopyVariation may truncate decimals. Explicit descriptor values
    // preserve the coordinates actually requested by the slider/number field.
    if (requested != nil) [coordinates addEntriesFromDictionary:requested];
    if (!self.supported) {
        NSMutableArray *values = [NSMutableArray array];
        for (NSDictionary *axis in self.axes) [values addObject:coordinates[axis[@"tag"]] ?: axis[@"default"]];
        return @{@"key": [NSString stringWithFormat:@"coordinates:%@:%@", values, coordinates], @"overrides": @{}};
    }
    NSMutableArray<NSNumber *> *normalized = [NSMutableArray array];
    for (NSUInteger i = 0; i < self.axes.count; i++) {
        NSDictionary *axis = self.axes[i];
        double minimum = [axis[@"min"] doubleValue], maximum = [axis[@"max"] doubleValue];
        double def = [axis[@"default"] doubleValue];
        double value = [coordinates[axis[@"tag"]] ?: axis[@"default"] doubleValue];
        value = MIN(maximum, MAX(minimum, trunc(value * 65536.0) / 65536.0));
        double n = value < def ? (value - def) / (def - minimum)
                 : value > def ? (value - def) / (maximum - def) : 0;
        n = trunc(n * 65536.0) / 65536.0;
        NSArray<NSArray<NSNumber *> *> *map = i < self.maps.count ? self.maps[i] : @[];
        for (NSUInteger j = 1; j < map.count; j++) {
            double x0 = map[j - 1][0].doubleValue, x1 = map[j][0].doubleValue;
            if (n >= x0 && n <= x1) {
                double ratio = floor(((n - x0) / (x1 - x0)) * 65536.0 + 0.5) / 65536.0;
                // Fixed-point multiplication discards the low product word
                // before the final 2.14 rounding used by condition comparisons.
                double delta = map[j][1].doubleValue - map[j - 1][1].doubleValue;
                n = map[j - 1][1].doubleValue + floor(ratio * delta * 65536.0) / 65536.0;
                break;
            }
        }
        int32_t fixed = (int32_t)floor(MIN(1, MAX(-1, n)) * 65536.0 + 0.5);
        [normalized addObject:@((fixed + 2) >> 2)];
    }
    for (NSDictionary *record in self.records) {
        BOOL matches = YES;
        for (NSDictionary *test in record[@"conditions"]) {
            NSInteger n = normalized[[test[@"axis"] unsignedIntegerValue]].integerValue;
            if (n < [test[@"min"] integerValue] || n > [test[@"max"] integerValue]) { matches = NO; break; }
        }
        if (matches) return @{@"key": [record[@"index"] stringValue], @"overrides": record[@"overrides"]};
    }
    return @{@"key": @"default", @"overrides": @{}};
}
@end

#pragma mark - GSUB parser

/// Reads the GSUB FeatureList once. Features with the same tag are merged in
/// first-occurrence order, and lookup indices are deduplicated.
static NSArray<NSDictionary<NSString *, id> *> *GAGSUBFeatures(NSData *table, NSDictionary *overrides) {
    if (table.length < 10) {
        return @[];
    }
    const uint8_t *bytes = table.bytes;
    NSUInteger length = table.length;
    uint16_t featureListOffset = GAU16(bytes, length, 6);
    if (featureListOffset == 0 || featureListOffset + 2 > length) {
        return @[];
    }
    uint16_t featureCount = GAU16(bytes, length, featureListOffset);
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *lookupsByTag =
        [NSMutableDictionary dictionary];

    for (uint16_t featureIndex = 0; featureIndex < featureCount; featureIndex++) {
        NSUInteger recordOffset = (NSUInteger)featureListOffset + 2 +
                                  (NSUInteger)featureIndex * 6;
        if (recordOffset + 6 > length) {
            break;
        }
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

        NSUInteger featureOffset = (NSUInteger)featureListOffset +
                                   GAU16(bytes, length, recordOffset + 4);
        NSNumber *alternateOffset = overrides[@(featureIndex)];
        if (alternateOffset != nil) featureOffset = alternateOffset.unsignedIntegerValue;
        if (featureOffset + 4 > length) {
            continue;
        }
        NSMutableArray<NSNumber *> *lookups = lookupsByTag[tag];
        if (lookups == nil) {
            lookups = [NSMutableArray array];
            lookupsByTag[tag] = lookups;
            [order addObject:tag];
        }
        uint16_t lookupIndexCount = GAU16(bytes, length, featureOffset + 2);
        for (uint16_t index = 0; index < lookupIndexCount; index++) {
            NSUInteger location = featureOffset + 4 + (NSUInteger)index * 2;
            if (location + 2 > length) {
                break;
            }
            NSNumber *lookup = @(GAU16(bytes, length, location));
            if (![lookups containsObject:lookup]) {
                [lookups addObject:lookup];
            }
        }
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *features = [NSMutableArray array];
    for (NSString *tag in order) {
        [features addObject:@{@"tag": tag, @"lookups": lookupsByTag[tag]}];
    }
    return features;
}

/// Returns dictionaries with "tag" and "max" keys, preserving the font's
/// feature order. Only AlternateSubst lookups can expose multiple alternates
/// through a feature value; everything else has one selectable state.
static NSArray<NSDictionary *> *GAParseGSUBFeatures(NSData *table, NSDictionary *overrides) {
    if (table.length < 10) {
        return @[];
    }
    const uint8_t *bytes = table.bytes;
    NSUInteger length = table.length;
    uint16_t lookupListOffset = GAU16(bytes, length, 8);
    if (lookupListOffset == 0 || lookupListOffset + 2 > length) {
        return @[];
    }
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
    for (NSDictionary<NSString *, id> *feature in GAGSUBFeatures(table, overrides)) {
        NSInteger maximum = 0;
        for (NSNumber *lookupIndex in feature[@"lookups"]) {
            NSNumber *count = alternateCounts[lookupIndex];
            if (count.integerValue > maximum) {
                maximum = count.integerValue;
            }
        }
        [features addObject:@{@"tag": feature[@"tag"], @"max": @(maximum)}];
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

/// Single-substitution replacement for one subtable, or nil when the glyph is
/// not covered, the format is unsupported, or the substitution is identity.
static NSNumber *GASingleSubstitution(const uint8_t *bytes, NSUInteger length,
                                      NSUInteger subtableOffset, uint16_t glyph) {
    if (subtableOffset + 6 > length) {
        return nil;
    }
    uint16_t format = GAU16(bytes, length, subtableOffset);
    uint16_t coverageOffset = GAU16(bytes, length, subtableOffset + 2);
    NSInteger coverageIndex = GACoverageIndex(
        bytes, length, subtableOffset + coverageOffset, glyph);
    if (coverageIndex < 0) {
        return nil;
    }
    uint16_t replacement = 0;
    if (format == 1) {
        int16_t delta = (int16_t)GAU16(bytes, length, subtableOffset + 4);
        replacement = (uint16_t)(glyph + delta);
    } else if (format == 2) {
        uint16_t count = GAU16(bytes, length, subtableOffset + 4);
        if ((NSUInteger)coverageIndex >= count) {
            return nil;
        }
        replacement = GAU16(bytes, length, subtableOffset + 6 +
                            (NSUInteger)coverageIndex * 2);
    } else {
        return nil;
    }
    return replacement != glyph ? @(replacement) : nil;
}

/// Lookup indices belonging to the OpenType `vert` feature.
static NSIndexSet *GAVerticalLookupIndices(NSData *table, NSDictionary *overrides) {
    NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
    for (NSDictionary<NSString *, id> *feature in GAGSUBFeatures(table, overrides)) {
        if (![feature[@"tag"] isEqualToString:@"vert"]) {
            continue;
        }
        for (NSNumber *lookupIndex in feature[@"lookups"]) {
            [indices addIndex:lookupIndex.unsignedIntValue];
        }
    }
    return indices;
}

/// Returns the GSUB single-substitution target of the `vert` feature, if it
/// covers this glyph. Only type 1 lookups (and type 7 extensions of them) can
/// supply a vertical form; alternate substitutions are left alone.
static NSNumber *GAVerticalSubstituteForGlyph(NSData *table, uint16_t glyph, NSDictionary *overrides) {
    if (table.length < 10) {
        return nil;
    }
    NSIndexSet *lookupIndices = GAVerticalLookupIndices(table, overrides);
    if (lookupIndices.count == 0) {
        return nil;
    }
    const uint8_t *bytes = table.bytes;
    NSUInteger length = table.length;
    uint16_t lookupListOffset = GAU16(bytes, length, 8);
    if (lookupListOffset == 0 || lookupListOffset + 2 > length) {
        return nil;
    }
    __block NSNumber *result = nil;
    [lookupIndices enumerateIndexesUsingBlock:^(NSUInteger lookupIndex, BOOL *stop) {
        NSUInteger offsetLocation = (NSUInteger)lookupListOffset + 2 +
                                    lookupIndex * 2;
        if (offsetLocation + 2 > length) {
            return;
        }
        NSUInteger lookupOffset = (NSUInteger)lookupListOffset +
                                  GAU16(bytes, length, offsetLocation);
        if (lookupOffset + 6 > length) {
            return;
        }
        uint16_t lookupType = GAU16(bytes, length, lookupOffset);
        uint16_t subtableCount = GAU16(bytes, length, lookupOffset + 4);
        for (uint16_t subIndex = 0; subIndex < subtableCount; subIndex++) {
            NSUInteger subOffsetLocation = lookupOffset + 6 +
                                           (NSUInteger)subIndex * 2;
            if (subOffsetLocation + 2 > length) {
                break;
            }
            NSUInteger subtableOffset = lookupOffset +
                                        GAU16(bytes, length, subOffsetLocation);
            uint16_t actualType = lookupType;
            if (actualType == 7) {
                if (subtableOffset + 6 > length) {
                    continue;
                }
                actualType = GAU16(bytes, length, subtableOffset + 2);
                subtableOffset += GAU32(bytes, length, subtableOffset + 4);
            }
            if (actualType != 1) {
                continue;
            }
            NSNumber *replacement = GASingleSubstitution(
                bytes, length, subtableOffset, glyph);
            if (replacement != nil) {
                result = replacement;
                *stop = YES;
                return;
            }
        }
    }];
    return result;
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

    if (lookupType == 1) {
        NSNumber *replacement = GASingleSubstitution(
            bytes, length, subtableOffset, seed);
        if (replacement != nil) {
            GAGSUBAddSource(sources, order, replacement.unsignedShortValue, tag);
        }
        return;
    }

    uint16_t format = GAU16(bytes, length, subtableOffset);
    uint16_t coverageOffset = GAU16(bytes, length, subtableOffset + 2);
    NSUInteger coverage = subtableOffset + coverageOffset;
    NSInteger coverageIndex = GACoverageIndex(bytes, length, coverage, seed);

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
static NSDictionary<NSString *, id> *GAGSUBAlternatesForSeed(NSData *gsub, uint16_t seed, NSDictionary *overrides) {
    if (gsub.length < 10) return nil;
    const uint8_t *bytes = gsub.bytes;
    NSUInteger length = gsub.length;
    uint16_t lookupListOffset = GAU16(bytes, length, 8);
    if (lookupListOffset == 0 || lookupListOffset + 2 > length) {
        return nil;
    }
    uint16_t lookupCount = GAU16(bytes, length, lookupListOffset);

    NSMutableDictionary<NSNumber *, NSMutableOrderedSet<NSString *> *> *sources =
        [NSMutableDictionary dictionary];
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];

    for (NSDictionary<NSString *, id> *feature in GAGSUBFeatures(gsub, overrides)) {
        NSString *tag = feature[@"tag"];
        for (NSNumber *lookupIndex in feature[@"lookups"]) {
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

#pragma mark - GAGlyphSelection

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

#pragma mark - GAAllGlyphEntry

@implementation GAAllGlyphEntry
@end

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

- (void)addFeatureSources:(NSArray<NSString *> *)sources {
    for (NSString *source in sources) {
        [self addFeatureSource:source];
    }
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

@implementation GAScanCandidate
@end

@implementation GARawScanResult
@end

static NSArray<NSNumber *> *GAScalarsForString(NSString *string) {
    NSMutableArray<NSNumber *> *scalars = [NSMutableArray array];
    for (NSUInteger index = 0; index < string.length; index++) {
        unichar unit = [string characterAtIndex:index];
        if (CFStringIsSurrogateHighCharacter(unit) &&
            index + 1 < string.length &&
            CFStringIsSurrogateLowCharacter([string characterAtIndex:index + 1])) {
            unichar low = [string characterAtIndex:index + 1];
            uint32_t scalar = ((uint32_t)(unit - 0xD800) << 10) +
                              (uint32_t)(low - 0xDC00) + 0x10000;
            [scalars addObject:@(scalar)];
            index++;
        } else {
            [scalars addObject:@(unit)];
        }
    }
    return scalars;
}

NSArray<GACharacterGroup *> *GAGroupsForText(NSString *text) {
    NSMutableArray<GACharacterGroup *> *groups = [NSMutableArray array];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *substring, NSRange substringRange,
                                       NSRange enclosingRange, BOOL *stop) {
        (void)enclosingRange;
        (void)stop;
        GACharacterGroup *group = [[GACharacterGroup alloc] init];
        group.text = substring;
        group.textRange = substringRange;
        group.variants = @[];
        [groups addObject:group];
    }];
    return groups;
}

/// Resource-owned discovery fonts do not reference this owner, avoiding a cycle.
@interface GADiscoveryFonts : NSObject
@property (nonatomic, copy) NSArray<GAFontDocument *> *documents;
@end
@implementation GADiscoveryFonts
@end

@interface GAFontDocument ()
- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor URL:(NSURL *)url
                    sourceDocument:(GAFontDocument *)source discoveryFont:(BOOL)discovery NS_DESIGNATED_INITIALIZER;
@end

@implementation GAFontDocument {
    CTFontDescriptorRef _descriptor;
    CTFontRef _font;
    GAFontBox *_fontBox;
    NSArray<GAFeatureSetting *> *_settings;
    NSData *_gsub;
    GAFeatureVariations *_variations;
    GADiscoveryFonts *_discoveryFonts;
    BOOL _discoveryFont;
    NSString *_effectiveVariationKey;
    NSDictionary *_variationFeatureOffsets;
    NSMapTable<GAFontBox *, GAFontBox *> *_reboundFontBoxes;
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *_unicodeMap;
    NSArray<GAAllGlyphEntry *> *_allGlyphEntries;
}

- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor
                               URL:(NSURL *)url {
    return [self initWithDescriptor:descriptor URL:url sourceDocument:nil discoveryFont:NO];
}

- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor URL:(NSURL *)url
                    sourceDocument:(GAFontDocument *)source discoveryFont:(BOOL)discovery {
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
    _fontBox = [[GAFontBox alloc] initWithFont:_font];

    _fontURL = [url copy];

    _fullName = GACopyString(CTFontCopyFullName(_font));
    if (_fullName.length == 0) {
        NSString *postScriptName = GACopyString(CTFontCopyPostScriptName(_font));
        _fullName = postScriptName.length > 0 ? postScriptName : NSLocalizedString(@"Untitled Font", @"Untitled Font");
    }

    _gsub = source != nil ? source->_gsub : CFBridgingRelease(CTFontCopyTable(_font, kCTFontTableGSUB, 0));
    _variations = source != nil ? source->_variations : [[GAFeatureVariations alloc] initWithGSUB:_gsub font:_font];
    NSDictionary *requestedCoordinates = CFBridgingRelease(CTFontDescriptorCopyAttribute(descriptor, kCTFontVariationAttribute));
    NSDictionary *selection = [_variations selectionForFont:_font coordinates:requestedCoordinates];
    _effectiveVariationKey = selection[@"key"];
    _discoveryFont = discovery;
    _discoveryFonts = discovery ? nil : (source != nil ? source->_discoveryFonts : [[GADiscoveryFonts alloc] init]);
    _variationFeatureOffsets = selection[@"overrides"];
    _hasFeatureVariations = _variations.records.count > 0 || !_variations.supported;
    _settings = [self buildSettingsWithGSUB:_gsub];
    _reboundFontBoxes = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality
                                           valueOptions:NSPointerFunctionsStrongMemory];
    [_reboundFontBoxes setObject:_fontBox forKey:_fontBox];
    for (GAFeatureSetting *setting in _settings) [_reboundFontBoxes setObject:setting.fontBox forKey:setting.fontBox];
    if (source != nil) {
        @synchronized (source) {
            _unicodeMap = source->_unicodeMap;
            _allGlyphEntries = source->_allGlyphEntries;
        }
    }

    return self;
}

- (void)dealloc {
    if (_font) CFRelease(_font);
    if (_descriptor) CFRelease(_descriptor);
}

- (GAFontDocument *)documentWithDescriptor:(CTFontDescriptorRef)descriptor {
    return [[GAFontDocument alloc] initWithDescriptor:descriptor URL:_fontURL sourceDocument:self discoveryFont:NO];
}

- (GAFontBox *)rebindFontBox:(GAFontBox *)old {
    @synchronized (self) {
        GAFontBox *box = [_reboundFontBoxes objectForKey:old];
        if (box != nil) return box;
        NSDictionary *coordinates = CFBridgingRelease(CTFontDescriptorCopyAttribute(_descriptor, kCTFontVariationAttribute)) ?: @{};
        CTFontDescriptorRef attributes = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{
            (__bridge NSString *)kCTFontVariationAttribute: coordinates,
            (__bridge NSString *)kCTFontOpticalSizeAttribute: @"none",
        });
        CTFontRef font = CTFontCreateCopyWithAttributes(old.font, GAFontShapingSize, NULL, attributes);
        CFRelease(attributes);
        box = [[GAFontBox alloc] initWithFont:font];
        CFRelease(font);
        [_reboundFontBoxes setObject:box forKey:old];
        [_reboundFontBoxes setObject:box forKey:box];
        return box;
    }
}

/// Single zero origins and empty origins are coordinate-independent. Only
/// positioned multi-glyph/mark results need layout refreshed; this does not
/// enumerate feature settings or discover substitutions again.
- (NSArray<NSValue *> *)rebindPositions:(NSArray<NSValue *> *)positions
                                content:(NSString *)content fontBox:(GAFontBox *)box {
    if (positions.count == 0 || (positions.count == 1 && NSEqualPoints(positions.firstObject.pointValue, NSZeroPoint))) return positions;
    return [self shapeString:content fontBox:box base:NO].positions ?: @[];
}

- (GARawScanResult *)rebindResult:(GARawScanResult *)result content:(NSString *)content {
    NSMutableArray *candidates = [NSMutableArray arrayWithCapacity:result.candidates.count];
    for (GAScanCandidate *old in result.candidates) {
        GAFontBox *box = [self rebindFontBox:old.fontBox];
        if (box == old.fontBox) { [candidates addObject:old]; continue; }
        GAScanCandidate *candidate = [[GAScanCandidate alloc] init];
        candidate.glyphIDs = old.glyphIDs;
        candidate.positions = [self rebindPositions:old.positions content:content fontBox:box];
        candidate.fontBox = box;
        candidate.sources = old.sources;
        candidate.base = old.base;
        candidate.ligature = old.ligature;
        candidate.sourceRange = old.sourceRange;
        candidate.targetOffset = old.targetOffset;
        [candidates addObject:candidate];
    }
    GARawScanResult *rebound = [[GARawScanResult alloc] init];
    rebound.candidates = candidates;
    return rebound;
}

- (GAGlyphVariant *)rebindVariant:(GAGlyphVariant *)old content:(NSString *)content {
    GAGlyphVariant *variant = [[GAGlyphVariant alloc] init];
    variant.fontBox = [self rebindFontBox:old.fontBox];
    variant.glyphIDs = old.glyphIDs;
    variant.positions = [self rebindPositions:old.positions content:content fontBox:variant.fontBox];
    [variant addFeatureSources:old.featureSources];
    variant.base = old.base;
    variant.unicodeScalars = old.unicodeScalars;
    variant.glyphName = old.glyphName;
    variant.ligature = old.ligature;
    variant.sourceTextRange = old.sourceTextRange;
    return variant;
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
            GAFeatureSetting *setting =
                [self createSettingWithKey:key attributes:attributes fromAAT:YES];
            if (setting != nil) {
                [settings addObject:setting];
            }
        }
    }

    NSArray<NSDictionary *> *openTypeFeatures = GAParseGSUBFeatures(gsub, _variationFeatureOffsets);
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
            GAFeatureSetting *setting =
                [self createSettingWithKey:key attributes:attributes fromAAT:NO];
            if (setting != nil) {
                setting.tag = tag;
                setting.sourceName = maximum > 1
                    ? [NSString stringWithFormat:@"%@ %ld", tag, (long)value]
                    : tag;
                [settings addObject:setting];
            }
        }
    }

    return settings;
}

- (nullable GAFeatureSetting *)createSettingWithKey:(NSString *)key
                                         attributes:(NSDictionary *)attributes
                                            fromAAT:(BOOL)fromAAT {
    CTFontRef variantFont = [self createFontWithAttributes:attributes];
    if (variantFont == NULL) {
        return nil;
    }
    GAFeatureSetting *setting = [[GAFeatureSetting alloc] init];
    setting.key = key;
    setting.fromAAT = fromAAT;
    setting.fontBox = [[GAFontBox alloc] initWithFont:variantFont];
    CFRelease(variantFont);
    return setting;
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
        if (!GAFontsMatch(runFont, fontBox.font)) {
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
    }
    return variant;
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

    NSMutableArray<NSDictionary *> *clusters = [NSMutableArray array];
    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex runIndex = 0; runIndex < CFArrayGetCount(runs); runIndex++) {
        CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, runIndex);
        CFIndex count = CTRunGetGlyphCount(run);
        if (count <= 0) continue;

        NSDictionary *runAttributes =
            (__bridge NSDictionary *)CTRunGetAttributes(run);
        id fontObject = runAttributes[(__bridge NSString *)kCTFontAttributeName];
        if (fontObject == nil) {
            fontObject = runAttributes[NSFontAttributeName];
        }
        CTFontRef runFont = fontObject ? (__bridge CTFontRef)fontObject : NULL;
        if (!GAFontsMatch(runFont, font)) {
            continue;
        }

        CFRange stringRange = CTRunGetStringRange(run);
        if (stringRange.location == kCFNotFound || stringRange.length <= 0) {
            continue;
        }
        NSUInteger runStart = (NSUInteger)stringRange.location;
        NSUInteger runEnd = MIN(runStart + (NSUInteger)stringRange.length, text.length);
        if (runEnd <= runStart) continue;

        CGGlyph *runGlyphs = calloc((size_t)count, sizeof(CGGlyph));
        CFIndex *runIndices = calloc((size_t)count, sizeof(CFIndex));
        CTRunGetGlyphs(run, CFRangeMake(0, count), runGlyphs);
        CTRunGetStringIndices(run, CFRangeMake(0, count), runIndices);

        NSMutableArray<NSNumber *> *clusterStarts = [NSMutableArray array];
        NSMutableArray<NSMutableArray<NSNumber *> *> *clusterGlyphs =
            [NSMutableArray array];
        for (CFIndex i = 0; i < count; i++) {
            if (runIndices[i] < 0) continue;
            NSUInteger start = (NSUInteger)runIndices[i];
            if (start >= text.length) continue;
            if (clusterStarts.count == 0 ||
                clusterStarts.lastObject.unsignedIntegerValue != start) {
                [clusterStarts addObject:@(start)];
                [clusterGlyphs addObject:[NSMutableArray array]];
            }
            [clusterGlyphs.lastObject addObject:@(runGlyphs[i])];
        }
        free(runGlyphs);
        free(runIndices);

        for (NSUInteger i = 0; i < clusterStarts.count; i++) {
            NSUInteger start = clusterStarts[i].unsignedIntegerValue;
            NSUInteger end = (i + 1 < clusterStarts.count)
                ? clusterStarts[i + 1].unsignedIntegerValue
                : runEnd;
            if (end <= start || start >= text.length) continue;
            end = MIN(end, text.length);
            [clusters addObject:@{
                @"start": @(start),
                @"end": @(end),
                @"glyphs": [clusterGlyphs[i] copy],
            }];
        }
    }
    CFRelease(line);
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

/// A line break is layout, not a glyph. It stays a group so text ranges keep
/// their offsets, but the whole-text scan does not cross it.
- (NSArray<GAGlyphVariant *> *)characterVariantsForContent:(NSString *)substring {
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *unicodeMap = [self unicodeMap];
    NSArray<NSNumber *> *scalars = GAScalarsForString(substring);

    GAFontBox *baseFont = _fontBox;
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
    if (baseGlyph != nil && _gsub.length > 0) {
        NSDictionary<NSString *, id> *directInfo = GAGSUBAlternatesForSeed(
            _gsub, (uint16_t)baseGlyph.unsignedShortValue, _variationFeatureOffsets);
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

    return variants;
}

- (GARawScanResult *)rawSingleCharacterResultForContent:(NSString *)content {
    NSMutableArray<GAScanCandidate *> *candidates = [NSMutableArray array];
    for (GAGlyphVariant *variant in [self characterVariantsForContent:content]) {
        GAScanCandidate *candidate = [[GAScanCandidate alloc] init];
        candidate.glyphIDs = variant.glyphIDs;
        candidate.positions = variant.positions;
        candidate.fontBox = variant.fontBox;
        candidate.sources = variant.featureSources ?: @[];
        candidate.base = variant.isBase;
        candidate.ligature = NO;
        candidate.sourceRange = NSMakeRange(0, content.length);
        candidate.targetOffset = 0;
        [candidates addObject:candidate];
    }
    GARawScanResult *result = [[GARawScanResult alloc] init];
    result.candidates = candidates;
    return result;
}

- (void)addRawClusters:(NSArray<NSDictionary *> *)clusters
               fontBox:(GAFontBox *)fontBox
                source:(NSString *)source
                actual:(BOOL)actual
            baseByStart:(nullable NSDictionary<NSNumber *, NSDictionary *> *)baseByStart
                 groups:(NSArray<GACharacterGroup *> *)groups
             candidates:(NSMutableArray<GAScanCandidate *> *)candidates
               keyIndex:(NSMutableDictionary<NSString *, GAScanCandidate *> *)keyIndex {
    for (NSDictionary *cluster in clusters) {
        NSUInteger start = [cluster[@"start"] unsignedIntegerValue];
        NSUInteger end = [cluster[@"end"] unsignedIntegerValue];
        NSArray<NSNumber *> *glyphs = cluster[@"glyphs"];
        if (glyphs.count == 0) {
            continue;
        }
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
        NSRange span = GAGroupSpanForCluster(groups, start, end);
        if (span.location == NSNotFound) {
            continue;
        }
        NSUInteger target = NSMaxRange(span) - 1;
        NSMutableString *parts = [NSMutableString string];
        for (NSNumber *glyph in glyphs) {
            if (parts.length > 0) [parts appendString:@","];
            [parts appendString:glyph.stringValue];
        }
        NSString *key = [NSString stringWithFormat:@"%lu:%@", (unsigned long)target, parts];
        BOOL ligature = span.length > 1;
        NSRange sourceRange = NSMakeRange(start, end - start);
        NSString *sourceName = actual ? @"actual" : (source ?: @"");
        GAScanCandidate *existing = keyIndex[key];
        if (existing != nil) {
            if (!existing.isBase) {
                if (sourceName.length > 0) {
                    NSMutableOrderedSet<NSString *> *sources =
                        [NSMutableOrderedSet orderedSetWithArray:existing.sources ?: @[]];
                    [sources addObject:sourceName];
                    existing.sources = sources.array;
                }
                if (ligature) {
                    existing.ligature = YES;
                    existing.sourceRange = sourceRange;
                }
            }
            continue;
        }
        GAScanCandidate *candidate = [[GAScanCandidate alloc] init];
        candidate.glyphIDs = glyphs;
        candidate.positions = @[];
        candidate.fontBox = fontBox;
        candidate.sources = sourceName.length > 0 ? @[sourceName] : @[];
        candidate.base = NO;
        candidate.ligature = ligature;
        candidate.sourceRange = sourceRange;
        candidate.targetOffset = target;
        keyIndex[key] = candidate;
        [candidates addObject:candidate];
    }
}

- (GARawScanResult *)rawContextResultForContent:(NSString *)content
                                         groups:(NSArray<GACharacterGroup *> *)groups {
    GAFontBox *baseBox = _fontBox;
    NSArray<NSDictionary *> *baseClusters = GAWholeTextClusters(content, baseBox.font);
    NSMutableDictionary<NSNumber *, NSDictionary *> *baseByStart = [NSMutableDictionary dictionary];
    for (NSDictionary *cluster in baseClusters) {
        NSNumber *start = cluster[@"start"];
        if (start != nil) {
            baseByStart[start] = cluster;
        }
    }
    NSMutableArray<GAScanCandidate *> *candidates = [NSMutableArray array];
    NSMutableDictionary<NSString *, GAScanCandidate *> *keyIndex = [NSMutableDictionary dictionary];
    [self addRawClusters:baseClusters
                 fontBox:baseBox
                  source:@"actual"
                  actual:YES
              baseByStart:nil
                   groups:groups
               candidates:candidates
                 keyIndex:keyIndex];
    for (GAFeatureSetting *setting in _settings) {
        NSString *source = nil;
        if (!setting.fromAAT) {
            source = setting.sourceName;
            if (source.length == 0) source = setting.tag;
            if (source.length == 0) source = setting.key;
        }
        [self addRawClusters:GAWholeTextClusters(content, setting.fontBox.font)
                     fontBox:setting.fontBox
                      source:source ?: @""
                      actual:NO
                  baseByStart:baseByStart
                       groups:groups
                   candidates:candidates
                     keyIndex:keyIndex];
    }
    GARawScanResult *result = [[GARawScanResult alloc] init];
    result.candidates = candidates;
    return result;
}

- (NSDictionary *)directAlternatesForSeed:(uint16_t)seed {
    if (_discoveryFont || _variations.records.count == 0) return GAGSUBAlternatesForSeed(_gsub, seed, _variationFeatureOffsets);
    NSMutableArray *configurations = [NSMutableArray arrayWithObject:@{}];
    for (NSDictionary *record in _variations.records) [configurations addObject:record[@"overrides"]];
    NSMutableDictionary *sources = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *overrides in configurations) {
        NSDictionary *info = GAGSUBAlternatesForSeed(_gsub, seed, overrides);
        for (NSNumber *glyph in info[@"order"]) {
            NSMutableOrderedSet *tags = sources[glyph];
            if (tags == nil) { tags = [NSMutableOrderedSet orderedSet]; sources[glyph] = tags; [order addObject:glyph]; }
            [tags unionOrderedSet:info[@"sources"][glyph]];
        }
    }
    return @{@"sources": sources, @"order": order};
}

- (NSArray<GAFontDocument *> *)discoveryDocuments {
    @synchronized (_discoveryFonts) {
        if (_discoveryFonts.documents != nil) return _discoveryFonts.documents;
        NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
        NSArray *axes = CFBridgingRelease(CTFontCopyVariationAxes(_font));
        for (NSDictionary *axis in axes) defaults[axis[(__bridge NSString *)kCTFontVariationAxisIdentifierKey]] = axis[(__bridge NSString *)kCTFontVariationAxisDefaultValueKey];
        NSMutableArray *configurations = [NSMutableArray arrayWithObject:@{@"coordinates": defaults}];
        [configurations addObjectsFromArray:[_variations discoveryCoordinates]];
        NSMutableArray *documents = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *configuration in configurations) {
            CTFontDescriptorRef descriptor = CTFontDescriptorCreateCopyWithAttributes(_descriptor, (__bridge CFDictionaryRef)@{
                (__bridge NSString *)kCTFontVariationAttribute: configuration[@"coordinates"],
                (__bridge NSString *)kCTFontOpticalSizeAttribute: @"none",
            });
            GAFontDocument *document = [[GAFontDocument alloc] initWithDescriptor:descriptor URL:_fontURL sourceDocument:self discoveryFont:YES];
            CFRelease(descriptor);
            NSString *key = document->_effectiveVariationKey;
            if (configuration[@"key"] != nil && ![key isEqualToString:configuration[@"key"]]) continue;
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            [documents addObject:document];
        }
        _discoveryFonts.documents = documents;
        return _discoveryFonts.documents;
    }
}

- (GARawScanResult *)rawScanContent:(NSString *)content {
    if (!self.hasFeatureVariations || _discoveryFont) return [self rawScanAtCurrentCoordinates:content];
    NSMutableArray<GAScanCandidate *> *candidates = [NSMutableArray array];
    NSMutableDictionary<NSString *, GAScanCandidate *> *seen = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *baseGlyphs = [NSMutableDictionary dictionary];
    NSArray<GAFontDocument *> *documents = [self discoveryDocuments];
    for (NSUInteger i = 0; i < documents.count; i++) {
        GAFontDocument *discovery = documents[i];
        GARawScanResult *raw = [discovery rawScanAtCurrentCoordinates:content];
        for (GAScanCandidate *source in raw.candidates) {
            if (i == 0 && source.isBase && source.glyphIDs.count == 1) baseGlyphs[@(source.targetOffset)] = source.glyphIDs.firstObject;
            NSArray *tags = source.sources ?: @[];
            if (i > 0 && source.isBase && tags.count == 0) {
                NSNumber *base = baseGlyphs[@(source.targetOffset)];
                NSDictionary *direct = base != nil ? GAGSUBAlternatesForSeed(_gsub, base.unsignedShortValue, discovery->_variationFeatureOffsets) : nil;
                NSOrderedSet *known = source.glyphIDs.count == 1 ? direct[@"sources"][source.glyphIDs.firstObject] : nil;
                tags = known.count > 0 ? known.array : @[@"actual"];
            }
            NSString *key = [NSString stringWithFormat:@"%lu:%@", (unsigned long)source.targetOffset, source.glyphIDs];
            GAScanCandidate *existing = seen[key];
            if (existing != nil) {
                if (!existing.isBase) {
                    NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:existing.sources];
                    [merged addObjectsFromArray:tags];
                    existing.sources = merged.array;
                    if (source.isLigature) { existing.ligature = YES; existing.sourceRange = source.sourceRange; }
                }
                continue;
            }
            GAScanCandidate *candidate = [[GAScanCandidate alloc] init];
            candidate.glyphIDs = source.glyphIDs;
            candidate.positions = source.positions;
            candidate.fontBox = source.fontBox;
            candidate.sources = tags;
            candidate.base = i == 0 && source.isBase;
            candidate.ligature = source.isLigature;
            candidate.sourceRange = source.sourceRange;
            candidate.targetOffset = source.targetOffset;
            seen[key] = candidate;
            [candidates addObject:candidate];
        }
    }
    // Single/alternate lookups remain enumerable even when no representative
    // coordinate can be constructed for a newer condition or axis-map format.
    if (GAGroupsForText(content).count == 1) {
        NSNumber *base = baseGlyphs[@0];
        if (base != nil) {
            NSDictionary *direct = [self directAlternatesForSeed:base.unsignedShortValue];
            for (NSNumber *glyph in direct[@"order"]) {
                NSString *key = [NSString stringWithFormat:@"0:%@", @[glyph]];
                NSOrderedSet *tags = direct[@"sources"][glyph];
                GAScanCandidate *candidate = seen[key];
                if (candidate != nil) {
                    if (!candidate.isBase) {
                        NSMutableOrderedSet *merged = [NSMutableOrderedSet orderedSetWithArray:candidate.sources];
                        [merged unionOrderedSet:tags];
                        candidate.sources = merged.array;
                    }
                    continue;
                }
                candidate = [[GAScanCandidate alloc] init];
                candidate.glyphIDs = @[glyph];
                candidate.positions = @[];
                candidate.fontBox = _fontBox;
                candidate.sources = tags.array;
                candidate.sourceRange = NSMakeRange(0, content.length);
                candidate.targetOffset = 0;
                [candidates addObject:candidate];
            }
        }
    }
    GARawScanResult *result = [[GARawScanResult alloc] init];
    result.candidates = candidates;
    return [self rebindResult:result content:content];
}

- (GARawScanResult *)rawScanAtCurrentCoordinates:(NSString *)content {
    NSArray<GACharacterGroup *> *groups = GAGroupsForText(content);
    if (groups.count <= 1) {
        return [self rawSingleCharacterResultForContent:content];
    }
    return [self rawContextResultForContent:content groups:groups];
}

- (void)applyRawResult:(GARawScanResult *)result
          contentRange:(NSRange)contentRange
       startGroupIndex:(NSUInteger)startGroupIndex
                groups:(NSArray<GACharacterGroup *> *)groups {
    for (GAScanCandidate *candidate in result.candidates) {
        NSUInteger target = startGroupIndex + candidate.targetOffset;
        if (target >= groups.count) {
            continue;
        }
        GACharacterGroup *group = groups[target];
        NSMutableArray<GAGlyphVariant *> *variants =
            [group.variants mutableCopy] ?: [NSMutableArray array];
        NSMutableString *parts = [NSMutableString string];
        for (NSNumber *glyph in candidate.glyphIDs) {
            if (parts.length > 0) [parts appendString:@","];
            [parts appendString:glyph.stringValue];
        }
        NSString *key = parts;
        GAGlyphVariant *existing = nil;
        for (GAGlyphVariant *variant in variants) {
            if ([variant.glyphKey isEqualToString:key]) {
                existing = variant;
                break;
            }
        }
        NSRange sourceRange = NSMakeRange(0, 0);
        if (candidate.ligature) {
            sourceRange = NSMakeRange(contentRange.location +
                                      candidate.sourceRange.location,
                                      candidate.sourceRange.length);
        }
        if (existing != nil) {
            if (!existing.isBase) {
                if (candidate.sources.count > 0) {
                    [existing addFeatureSources:candidate.sources];
                }
                if (candidate.ligature) {
                    existing.ligature = YES;
                    existing.sourceTextRange = sourceRange;
                }
            }
            continue;
        }
        GAGlyphVariant *variant = [[GAGlyphVariant alloc] init];
        variant.fontBox = candidate.fontBox;
        variant.glyphIDs = candidate.glyphIDs;
        variant.positions = candidate.positions ?: @[];
        [variant addFeatureSources:candidate.sources ?: @[]];
        variant.base = candidate.isBase;
        if (candidate.ligature) {
            variant.ligature = YES;
            variant.sourceTextRange = sourceRange;
        }
        [self decorateVariant:variant withUnicodeMap:self.unicodeMap];
        if (candidate.isBase && variant.unicodeScalars.count == 0) {
            variant.unicodeScalars = GAScalarsForString(group.text);
        }
        [variants addObject:variant];
        group.variants = variants;
    }
}

- (NSArray<GAAllGlyphEntry *> *)allGlyphEntries {
    if (_allGlyphEntries != nil) {
        return _allGlyphEntries;
    }
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *map = [self unicodeMap];
    CFIndex glyphCount = CTFontGetGlyphCount(_font);
    NSMutableArray<GAAllGlyphEntry *> *entries =
        [NSMutableArray arrayWithCapacity:(NSUInteger)MAX(0, glyphCount)];
    for (CFIndex glyph = 0; glyph < glyphCount; glyph++) {
        GAAllGlyphEntry *entry = [[GAAllGlyphEntry alloc] init];
        entry.glyphID = @(glyph);
        entry.unicodeScalars = map[@(glyph)] ?: @[];
        [entries addObject:entry];
    }
    _allGlyphEntries = [entries copy];
    return _allGlyphEntries;
}

- (NSNumber *)verticalSubstituteForGlyph:(CGGlyph)glyph {
    return GAVerticalSubstituteForGlyph(_gsub, glyph, _variationFeatureOffsets);
}

- (NSArray<GACharacterGroup *> *)analyzeGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (glyphIDs.count == 0) {
        return @[];
    }
    NSDictionary<NSString *, id> *info = [self directAlternatesForSeed:(uint16_t)glyphIDs.firstObject.unsignedShortValue];
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *unicodeMap = [self unicodeMap];
    GAFontBox *fontBox = _fontBox;

    GAGlyphVariant *base = [[GAGlyphVariant alloc] init];
    base.fontBox = fontBox;
    base.glyphIDs = glyphIDs;
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

/// Sum of the horizontal advances in font units. CGFont advances are raw font
/// units and do not include the trak table's size-dependent tracking.
static CGFloat GAAdvanceWidthInFontUnits(CTFontRef font,
                                         NSArray<NSNumber *> *glyphIDs) {
    NSUInteger count = glyphIDs.count;
    if (count == 0 || font == NULL) {
        return 0;
    }
    CGGlyph *glyphs = calloc(count, sizeof(CGGlyph));
    for (NSUInteger index = 0; index < count; index++) {
        glyphs[index] = (CGGlyph)glyphIDs[index].unsignedShortValue;
    }
    int *advances = calloc(count, sizeof(int));
    CGFontRef cgFont = CTFontCopyGraphicsFont(font, NULL);
    if (cgFont != NULL) {
        CGFontGetGlyphAdvances(cgFont, glyphs, count, advances);
        CFRelease(cgFont);
    }
    CGFloat width = 0;
    for (NSUInteger index = 0; index < count; index++) {
        width += advances[index];
    }
    free(advances);
    free(glyphs);
    return width;
}

+ (GAGlyphPage)pageForVariant:(GAGlyphVariant *)variant
           usesVerticalMetrics:(BOOL)usesVerticalMetrics {
    GAGlyphPage page = { CGSizeZero, 0, CGRectZero };
    if (variant.glyphIDs.count == 0) {
        return page;
    }
    CTFontRef font = variant.fontBox.font;
    CGFloat unitsPerEm = CTFontGetUnitsPerEm(font);
    CGFloat shapeToUnits = unitsPerEm / GAFontShapingSize;

    // inkBoundsForVariant works in shaping points; the page is in font units.
    CGRect ink = [self inkBoundsForVariant:variant];
    if (CGRectIsNull(ink) || CGRectIsEmpty(ink)) {
        ink = CGRectZero;
    } else {
        ink = CGRectMake(CGRectGetMinX(ink) * shapeToUnits,
                         CGRectGetMinY(ink) * shapeToUnits,
                         CGRectGetWidth(ink) * shapeToUnits,
                         CGRectGetHeight(ink) * shapeToUnits);
    }
    BOOL hasInk = !CGRectIsEmpty(ink);

    BOOL hasVertical = usesVerticalMetrics &&
        [self variantHasVerticalMetrics:variant];
    CGFloat width;
    CGFloat height;
    if (hasVertical) {
        CGSize advance = [self advanceInFontUnitsForVariant:variant];
        width = advance.width;
        height = advance.height;
    } else {
        // The width-only page: advance width × ascent + descent. It must not
        // read vmtx, so the grid and sidebar do not pay for vertical metrics.
        width = GAAdvanceWidthInFontUnits(font, variant.glyphIDs);
        height = (CTFontGetAscent(font) + CTFontGetDescent(font)) * shapeToUnits;
    }
    if (width <= 0) {
        width = hasInk ? CGRectGetWidth(ink) : unitsPerEm * 0.01;
    }
    if (height <= 0) {
        height = hasInk ? CGRectGetHeight(ink) : unitsPerEm;
    }

    CGFloat baseline;
    if (hasVertical) {
        CGFloat topSideBearing = [self verticalTopSideBearingForVariant:variant];
        baseline = height - topSideBearing - CGRectGetMaxY(ink);
    } else {
        baseline = CTFontGetDescent(font) * shapeToUnits;
    }

    page.size = CGSizeMake(width, height);
    page.baseline = baseline;
    page.ink = ink;
    return page;
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
    CTFontRef font = variant.fontBox.font;
    CGFloat factor = CTFontGetUnitsPerEm(font) / GAFontShapingSize;
    CGFloat width = GAAdvanceWidthInFontUnits(font, variant.glyphIDs);

    CGFloat height = 0;
    if ([self variantHasVerticalMetrics:variant]) {
        CGGlyph *glyphs = calloc(count, sizeof(CGGlyph));
        for (NSUInteger index = 0; index < count; index++) {
            glyphs[index] = (CGGlyph)variant.glyphIDs[index].unsignedShortValue;
        }
        CGSize *vAdvances = calloc(count, sizeof(CGSize));
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationVertical,
                                   glyphs, vAdvances, (CFIndex)count);
        for (NSUInteger index = 0; index < count; index++) {
            // CoreText puts the vertical advance in CGSize.width.
            height += MAX(vAdvances[index].width, vAdvances[index].height);
        }
        free(vAdvances);
        free(glyphs);
    } else {
        height = CTFontGetAscent(font) + CTFontGetDescent(font);
    }
    return CGSizeMake(width, height * factor);
}

@end
