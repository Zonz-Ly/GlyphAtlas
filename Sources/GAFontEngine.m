#import "GAFontEngine.h"
#import "GAUnicode.h"
#import "GASubstitutionEngine.h"
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
    return parts.count ? [parts componentsJoinedByString:@","] : @"∅";
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

/// The shared immutable substitution program owns table bytes, not this document.
@interface GAFontDocument ()
- (instancetype)initWithDescriptor:(CTFontDescriptorRef)descriptor URL:(NSURL *)url
                    sourceDocument:(GAFontDocument *)source NS_DESIGNATED_INITIALIZER;
@end

@implementation GAFontDocument {
    CTFontDescriptorRef _descriptor;
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
    _descriptor = CTFontDescriptorCreateCopyWithAttributes(
        descriptor,
        (__bridge CFDictionaryRef) @{(__bridge NSString *)kCTFontCascadeListAttribute : @[]});
    _font = CTFontCreateWithFontDescriptor(_descriptor, GAFontShapingSize, NULL);
    if (_font == NULL)
        return nil;
    _fontBox = [[GAFontBox alloc] initWithFont:_font];
    _fontURL = [url copy];
    _fullName = GACopyString(CTFontCopyFullName(_font));
    if (!_fullName.length)
        _fullName = GACopyString(CTFontCopyPostScriptName(_font));
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
    if (_descriptor)
        CFRelease(_descriptor);
}
- (BOOL)hasFeatureVariations {
    return _substitutionEngine.hasFeatureVariations;
}
- (GAFontDocument *)documentWithDescriptor:(CTFontDescriptorRef)descriptor {
    return [[GAFontDocument alloc] initWithDescriptor:descriptor URL:_fontURL sourceDocument:self];
}
- (GARawScanResult *)rebindResult:(GARawScanResult *)result content:(NSString *)content {
    NSMutableArray *candidates = [NSMutableArray arrayWithCapacity:result.candidates.count];
    for (GAScanCandidate *old in result.candidates) {
        GAScanCandidate *c = [[GAScanCandidate alloc] init];
        c.glyphIDs = old.glyphIDs;
        c.fontBox = _fontBox;
        NSString *source = NSMaxRange(old.sourceRange) <= content.length
                               ? [content substringWithRange:old.sourceRange]
                               : content;
        c.positions = [_substitutionEngine positionsForGlyphIDs:c.glyphIDs content:source];
        c.sources = old.sources;
        c.base = old.base;
        c.ligature = old.ligature;
        c.sourceRange = old.sourceRange;
        c.targetOffset = old.targetOffset;
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
    variant.glyphName = glyphNames.count ? [glyphNames componentsJoinedByString:@"/"] : @"∅";
}

#pragma mark - Font substitution discovery

- (GARawScanResult *)rawScanContent:(NSString *)content {
    NSArray<GACharacterGroup *> *groups = GAGroupsForText(content);
    NSArray<GASubstitutionMatch *> *matches = [_substitutionEngine discoverText:content];
    NSMutableArray *candidates = [NSMutableArray array];
    BOOL single = groups.count == 1;
    if (single) {
        NSMutableArray *baseGlyphs = [NSMutableArray array];
        for (GASubstitutionMatch *match in matches)
            if (match.base)
                [baseGlyphs addObjectsFromArray:match.glyphIDs];
        GAScanCandidate *base = [[GAScanCandidate alloc] init];
        base.glyphIDs = baseGlyphs;
        base.fontBox = _fontBox;
        base.positions = [_substitutionEngine positionsForGlyphIDs:base.glyphIDs content:content];
        base.sources = @[];
        base.base = YES;
        base.sourceRange = NSMakeRange(0, content.length);
        base.targetOffset = 0;
        [candidates addObject:base];
    }
    for (GASubstitutionMatch *match in matches) {
        if (single && match.base)
            continue;
        if (!match.sourceRange.length || NSMaxRange(match.sourceRange) > content.length)
            continue;
        if (single && !NSEqualRanges(match.sourceRange, NSMakeRange(0, content.length)))
            continue;
        NSUInteger first = NSNotFound, last = NSNotFound;
        NSUInteger lo = 0, hi = groups.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (NSMaxRange(groups[mid].textRange) <= match.sourceRange.location)
                lo = mid + 1;
            else
                hi = mid;
        }
        first = lo;
        lo = first;
        hi = groups.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (groups[mid].textRange.location < NSMaxRange(match.sourceRange))
                lo = mid + 1;
            else
                hi = mid;
        }
        last = lo ? lo - 1 : NSNotFound;
        if (first >= groups.count)
            first = NSNotFound;
        if (first == NSNotFound)
            continue;
        GAScanCandidate *c = [[GAScanCandidate alloc] init];
        c.glyphIDs = match.glyphIDs;
        c.fontBox = _fontBox;
        c.positions = [_substitutionEngine
            positionsForGlyphIDs:c.glyphIDs
                         content:[content substringWithRange:match.sourceRange]];
        c.sources = match.sources.count ? match.sources : @[ @"actual" ];
        c.sourceRange = match.sourceRange;
        c.targetOffset = last;
        c.ligature = first != last;
        c.base = NO;
        [candidates addObject:c];
    }
    GARawScanResult *result = [[GARawScanResult alloc] init];
    result.candidates = candidates;
    return result;
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
            if (parts.length > 0)
                [parts appendString:@","];
            [parts appendString:glyph.stringValue];
        }
        NSString *key = parts.length ? parts : @"∅";
        NSRange sourceRange = NSMakeRange(0, 0);
        if (candidate.ligature)
            sourceRange = NSMakeRange(contentRange.location + candidate.sourceRange.location,
                                      candidate.sourceRange.length);
        GAGlyphVariant *existing = nil;
        for (GAGlyphVariant *variant in variants) {
            if (![variant.glyphKey isEqualToString:key] ||
                variant.isLigature != candidate.isLigature)
                continue;
            if (candidate.isLigature && !NSEqualRanges(variant.sourceTextRange, sourceRange))
                continue;
            existing = variant;
            break;
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
        v.positions = [_substitutionEngine positionsForGlyphIDs:v.glyphIDs];
        [v addFeatureSources:match.sources];
        v.base = match.base;
        [self decorateVariant:v withUnicodeMap:self.unicodeMap];
        [variants addObject:v];
    }
    GACharacterGroup *group = [[GACharacterGroup alloc] init];
    group.text = @"";
    group.textRange = NSMakeRange(0, 0);
    group.variants = variants;
    return @[ group ];
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
