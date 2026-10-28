#import "GAFontEngine.h"
#import "FontLayout/GASubstitutionEngine.h"
#import <AppKit/AppKit.h>

const CGFloat GAFontShapingSize = 200.0;

#pragma mark - GAAllGlyphEntry

@implementation GAAllGlyphEntry
@end

#pragma mark - GAGlyphVariant

@interface GAGlyphVariant ()
- (void)addFeatureSource:(NSString *)source;
@end

@implementation GAGlyphVariant {
    NSMutableArray<NSString *> *_mutableFeatureSources;
}

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
    NSString *tag = [source componentsSeparatedByString:@" "].firstObject;
    for (NSString *existing in _mutableFeatureSources) {
        if ([[existing componentsSeparatedByString:@" "].firstObject isEqualToString:tag]) {
            return;
        }
    }
    [_mutableFeatureSources addObject:source];
    _featureSources = [_mutableFeatureSources copy];
}

- (void)addFeatureSources:(NSArray<NSString *> *)sources {
    for (NSString *source in sources) {
        [self addFeatureSource:source];
    }
}

- (NSString *)glyphKey {
    NSArray<NSNumber *> *glyphIDs = self.glyphIDs;
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:glyphIDs.count];
    for (NSNumber *glyph in glyphIDs) {
        [parts addObject:glyph.stringValue];
    }
    return parts.count ? [parts componentsJoinedByString:@","] : @"∅";
}

@end

void GADrawGlyphVariant(GAGlyphVariant *variant, CGContextRef context) {
    NSUInteger count = variant.glyphIDs.count;
    CGGlyph *glyphs = calloc(count, sizeof(CGGlyph));
    CGPoint *positions = calloc(count, sizeof(CGPoint));
    for (NSUInteger index = 0; index < count; index++) {
        glyphs[index] = (CGGlyph)variant.glyphIDs[index].unsignedShortValue;
        positions[index] = index < variant.positions.count
            ? variant.positions[index].pointValue
            : CGPointZero;
    }
    CTFontDrawGlyphs(variant.fontBox.font, glyphs, positions, count, context);
    free(glyphs);
    free(positions);
}

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

/// The shared immutable substitution program owns table bytes, not this document.
@interface GAFontDocument ()
- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor URL:(NSURL *)url
                    sourceDocument:(GAFontDocument *)source NS_DESIGNATED_INITIALIZER;
/// Raw ink bounding box of a nonempty variant, from glyf/CFF through
/// CTFontGetBoundingRectsForGlyphs. Returns CGRectZero for zero-ink glyphs.
+ (CGRect)inkBoundsForVariant:(GAGlyphVariant *)variant;

/// Advance width/height of a nonempty variant in font units.
/// Width is the horizontal advance.
/// Requires vmtx/vhea; the caller checks their presence before using this method.
+ (CGSize)advanceInFontUnitsForVariant:(GAGlyphVariant *)variant;

/// Requires a nonempty variant. Reports vmtx/vhea availability and the first
/// glyph's top bearing; missing bearing records yield zero.
+ (BOOL)verticalMetricsForVariant:(GAGlyphVariant *)variant
                 topSideBearing:(CGFloat *)topSideBearing;
@end

@implementation GAFontDocument {
    CTFontRef _font;
    GAFontBox *_fontBox;
    GASubstitutionEngine *_substitutionEngine;
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *_unicodeMap;
    NSArray<GAAllGlyphEntry *> *_allGlyphEntries;
}

- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor URL:(NSURL *)url {
    return [self initWithDescriptor:descriptor URL:url sourceDocument:nil];
}
- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor
                               URL:(NSURL *)url
                    sourceDocument:(GAFontDocument *)source {
    self = [super init];
    if (!self)
        return nil;
    CTFontDescriptorRef configured = CTFontDescriptorCreateCopyWithAttributes(
        descriptor,
        (__bridge CFDictionaryRef) @{(__bridge NSString *)kCTFontCascadeListAttribute : @[]});
    _font = CTFontCreateWithFontDescriptor(configured, GAFontShapingSize, NULL);
    if (configured)
        CFRelease(configured);
    if (_font == NULL)
        return nil;
    _fontBox = [[GAFontBox alloc] initWithFont:_font];
    _fontURL = [url copy];
    _fullName = CFBridgingRelease(CTFontCopyDisplayName(_font));
    if (!_fullName.length)
        _fullName = CFBridgingRelease(CTFontCopyPostScriptName(_font));
    if (!_fullName.length)
        _fullName = NSLocalizedString(@"Untitled Font", @"Font name fallback");
    NSDictionary *coordinates =
        CFBridgingRelease(CTFontDescriptorCopyAttribute(descriptor, kCTFontVariationAttribute));
    _substitutionEngine =
        [[GASubstitutionEngine alloc] initWithFont:_font
                                       coordinates:coordinates
                                           sharing:source ? source->_substitutionEngine : nil];
    if (source) {
        @synchronized(source) {
            _unicodeMap = source->_unicodeMap;
            _allGlyphEntries = source->_allGlyphEntries;
        }
    }
    return self;
}
- (void)dealloc {
    if (_font)
        CFRelease(_font);
}
- (GAFontDocument *)documentWithDescriptor:(CTFontDescriptorRef)descriptor {
    return [[GAFontDocument alloc] initWithDescriptor:descriptor URL:_fontURL sourceDocument:self];
}
- (GARawScanResult *)rebindResult:(GARawScanResult *)result content:(NSString *)content {
    NSMutableArray *candidates = [NSMutableArray arrayWithCapacity:result.candidates.count];
    for (GAScanCandidate *old in result.candidates) {
        GAScanCandidate *c = [[GAScanCandidate alloc] init];
        c.glyphIDs = old.glyphIDs;
        NSString *source = NSMaxRange(old.sourceRange) <= content.length
                               ? [content substringWithRange:old.sourceRange]
                               : content;
        c.positions = [_substitutionEngine positionsForGlyphIDs:c.glyphIDs content:source];
        c.sources = old.sources;
        c.base = old.base;
        c.ligature = old.ligature;
        c.fromGlyphSeed = old.fromGlyphSeed;
        c.sourceRange = old.sourceRange;
        c.targetGroupIndex = old.targetGroupIndex;
        [candidates addObject:c];
    }
    GARawScanResult *rebound = [[GARawScanResult alloc] init];
    rebound.candidates = candidates;
    return rebound;
}
- (GAGlyphVariant *)rebindVariant:(GAGlyphVariant *)old content:(NSString *)content {
    GAGlyphVariant *v = [[GAGlyphVariant alloc] init];
    v.fontBox = _fontBox;
    v.glyphIDs = old.glyphIDs;
    v.positions = [_substitutionEngine positionsForGlyphIDs:v.glyphIDs content:content];
    [v addFeatureSources:old.featureSources];
    v.base = old.base;
    v.unicodeScalars = old.unicodeScalars;
    v.glyphName = old.glyphName;
    v.ligature = old.ligature;
    v.fromGlyphSeed = old.fromGlyphSeed;
    v.sourceTextRange = old.sourceTextRange;
    return v;
}

- (NSDictionary<NSNumber *, NSArray<NSNumber *> *> *)unicodeMap {
    @synchronized(self) {
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

/// Checks a nonempty glyph name; the caller handles missing names.
static BOOL GAGlyphNameLooksSynthetic(NSString *name) {
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
    return [gidPattern firstMatchInString:name options:0 range:range] != nil ||
           [temporaryPattern firstMatchInString:name options:0 range:range] != nil ||
           [variationPattern firstMatchInString:name options:0 range:range] != nil ||
           [multiUnicodePattern firstMatchInString:name options:0 range:range] != nil;
}

- (void)decorateVariant:(GAGlyphVariant *)variant
          withUnicodeMap:(NSDictionary<NSNumber *, NSArray<NSNumber *> *> *)map {
    NSMutableSet<NSNumber *> *scalars = [NSMutableSet set];
    NSMutableArray<NSString *> *glyphNames = [NSMutableArray array];

    for (NSNumber *glyphNumber in variant.glyphIDs) {
        NSArray<NSNumber *> *mapped = map[glyphNumber];
        for (NSNumber *scalar in mapped) {
            [scalars addObject:scalar];
        }

        CGGlyph glyph = (CGGlyph)glyphNumber.unsignedShortValue;
        NSString *name = CFBridgingRelease(CTFontCopyNameForGlyph(_font, glyph));
        if (name.length > 0 && !GAGlyphNameLooksSynthetic(name)) {
            [glyphNames addObject:name];
        } else {
            [glyphNames addObject:[NSString stringWithFormat:@"GID %@", glyphNumber]];
        }
    }

    NSArray<NSNumber *> *sortedScalars =
        [scalars.allObjects sortedArrayUsingSelector:@selector(compare:)];
    variant.unicodeScalars = sortedScalars;
    variant.glyphName = [glyphNames componentsJoinedByString:@"/"];
}

#pragma mark - Font substitution discovery

- (GARawScanResult *)rawScanContent:(NSString *)content
                         selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    NSArray<GACharacterGroup *> *groups = GAGroupsForText(content);
    NSArray<GASubstitutionMatch *> *matches = [_substitutionEngine discoverText:content
                                                                     selections:selections];
    NSMutableArray *candidates = [NSMutableArray array];
    for (GASubstitutionMatch *match in matches) {
        if (!match.sourceRange.length || NSMaxRange(match.sourceRange) > content.length)
            continue;
        NSUInteger lo = 0, hi = groups.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (NSMaxRange(groups[mid].textRange) <= match.sourceRange.location)
                lo = mid + 1;
            else
                hi = mid;
        }
        NSUInteger first = lo;
        hi = groups.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (groups[mid].textRange.location < NSMaxRange(match.sourceRange))
                lo = mid + 1;
            else
                hi = mid;
        }
        NSUInteger last = lo ? lo - 1 : NSNotFound;
        if (first >= groups.count)
            continue;
        GAScanCandidate *c = [[GAScanCandidate alloc] init];
        c.glyphIDs = match.glyphIDs;
        c.positions = [_substitutionEngine
            positionsForGlyphIDs:c.glyphIDs
                         content:[content substringWithRange:match.sourceRange]];
        c.sources = match.sources;
        c.sourceRange = match.sourceRange;
        c.fromGlyphSeed = selections.count > 0;
        c.targetGroupIndex = last;
        c.ligature = first != last;
        c.base = match.base && first == last;
        [candidates addObject:c];
    }
    GARawScanResult *result = [[GARawScanResult alloc] init];
    result.candidates = candidates;
    return result;
}

- (void)applyRawResult:(GARawScanResult *)result
                groups:(NSArray<GACharacterGroup *> *)groups {
    for (GAScanCandidate *candidate in result.candidates) {
        NSUInteger target = candidate.targetGroupIndex;
        if (target >= groups.count) {
            continue;
        }
        GACharacterGroup *group = groups[target];
        NSMutableArray<GAGlyphVariant *> *variants =
            [group.variants mutableCopy];
        GAGlyphVariant *existing = nil;
        for (GAGlyphVariant *variant in variants) {
            if (![variant.glyphIDs isEqualToArray:candidate.glyphIDs] ||
                variant.isLigature != candidate.isLigature)
                continue;
            if (candidate.isLigature && !NSEqualRanges(variant.sourceTextRange, candidate.sourceRange))
                continue;
            existing = variant;
            break;
        }
        if (existing != nil) {
            if (candidate.fromGlyphSeed) {
                existing.fromGlyphSeed = YES;
                existing.sourceTextRange = candidate.sourceRange;
            }
            [existing addFeatureSources:candidate.sources];
            continue;
        }
        GAGlyphVariant *variant = [[GAGlyphVariant alloc] init];
        variant.fontBox = _fontBox;
        variant.glyphIDs = candidate.glyphIDs;
        variant.positions = candidate.positions;
        [variant addFeatureSources:candidate.sources];
        variant.base = candidate.isBase;
        variant.fromGlyphSeed = candidate.fromGlyphSeed;
        if (candidate.fromGlyphSeed || candidate.ligature)
            variant.sourceTextRange = candidate.sourceRange;
        if (candidate.ligature) {
            variant.ligature = YES;
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
    return [_substitutionEngine verticalGlyph:glyph];
}
- (NSArray<GACharacterGroup *> *)analyzeGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (!glyphIDs.count)
        return @[];
    NSMutableArray *variants = [NSMutableArray array];
    for (GASubstitutionMatch *match in [_substitutionEngine discoverGlyphIDs:glyphIDs]) {
        GAGlyphVariant *v = [[GAGlyphVariant alloc] init];
        v.fontBox = _fontBox;
        v.glyphIDs = match.glyphIDs;
        v.positions = [_substitutionEngine positionsForGlyphIDs:v.glyphIDs content:@""];
        [v addFeatureSources:match.sources];
        v.base = match.base;
        [self decorateVariant:v withUnicodeMap:self.unicodeMap];
        [variants addObject:v];
    }
    GACharacterGroup *group = [[GACharacterGroup alloc] init];
    group.text = @"";
    group.variants = variants;
    return @[ group ];
}

#pragma mark - Drawing

+ (CGRect)inkBoundsForVariant:(GAGlyphVariant *)variant {
    NSUInteger count = variant.glyphIDs.count;
    CGGlyph *glyphs = calloc(count, sizeof(CGGlyph));
    for (NSUInteger index = 0; index < count; index++) {
        glyphs[index] = (CGGlyph)variant.glyphIDs[index].unsignedShortValue;
    }
    CGRect *rects = calloc(count, sizeof(CGRect));
    CTFontGetBoundingRectsForGlyphs(variant.fontBox.font, kCTFontOrientationHorizontal, glyphs,
                                    rects, (CFIndex)count);

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
    ink = CGRectMake(CGRectGetMinX(ink) * shapeToUnits,
                     CGRectGetMinY(ink) * shapeToUnits,
                     CGRectGetWidth(ink) * shapeToUnits,
                     CGRectGetHeight(ink) * shapeToUnits);
    BOOL hasInk = !CGRectIsEmpty(ink);

    CGFloat topSideBearing;
    BOOL hasVertical = usesVerticalMetrics &&
        [self verticalMetricsForVariant:variant topSideBearing:&topSideBearing];
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
        baseline = height - topSideBearing - CGRectGetMaxY(ink);
    } else {
        baseline = CTFontGetDescent(font) * shapeToUnits;
    }

    page.size = CGSizeMake(width, height);
    page.baseline = baseline;
    page.ink = ink;
    return page;
}

+ (BOOL)verticalMetricsForVariant:(GAGlyphVariant *)variant
                 topSideBearing:(CGFloat *)topSideBearing {
    *topSideBearing = 0;
    NSData *vmtx = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVmtx, 0));
    NSData *vhea = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVhea, 0));
    if (vmtx.length < 4 || vhea.length < 36) {
        return NO;
    }
    const uint8_t *vmtxBytes = vmtx.bytes;
    const uint8_t *vheaBytes = vhea.bytes;
    NSUInteger vmtxLength = vmtx.length;
    uint16_t numberOfVMetrics = (uint16_t)((vheaBytes[34] << 8) | vheaBytes[35]);
    if (numberOfVMetrics == 0) {
        return YES;
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
        return YES;
    }
    *topSideBearing = (CGFloat)(int16_t)((vmtxBytes[offset] << 8) | vmtxBytes[offset + 1]);
    return YES;
}

+ (CGSize)advanceInFontUnitsForVariant:(GAGlyphVariant *)variant {
    NSUInteger count = variant.glyphIDs.count;
    CTFontRef font = variant.fontBox.font;
    CGFloat factor = CTFontGetUnitsPerEm(font) / GAFontShapingSize;
    CGFloat width = GAAdvanceWidthInFontUnits(font, variant.glyphIDs);

    CGFloat height = 0;
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
    return CGSizeMake(width, height * factor);
}

@end
