#import "GAFontEngine.h"
#import "FontLayout/GASubstitutionEngine.h"
#import <AppKit/AppKit.h>

const CGFloat GAFontShapingSize = 200.0;

#pragma mark - GAAllGlyphEntry

@implementation GAAllGlyphEntry
@end

@implementation GAGlyphResolution
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
    if (glyphIDs.count < 2) return glyphIDs.firstObject.stringValue ?: @"∅";
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:glyphIDs.count];
    for (NSNumber *glyph in glyphIDs) {
        [parts addObject:glyph.stringValue];
    }
    return [parts componentsJoinedByString:@","];
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

/// Page metrics used only by `pageForVariant:` in this file. Keeping the
/// initializer and typo values private avoids exposing page internals through
/// the public GAFontBox API.
@interface GAFontBox ()
/// OS/2 sTypo metrics in font units for this coordinate instance, adjusted by
/// MVAR hasc/hdsc. The descender keeps the font's sign; page code uses its
/// magnitude because some fonts store it as a positive depth.
@property (nonatomic, readonly) BOOL hasTypoMetrics;
@property (nonatomic, readonly) CGFloat typoAscender;
@property (nonatomic, readonly) CGFloat typoDescender;
- (instancetype)initWithFont:(CTFontRef)font
                typoAscender:(CGFloat)typoAscender
               typoDescender:(CGFloat)typoDescender
              hasTypoMetrics:(BOOL)hasTypoMetrics;
@end

@implementation GAFontBox {
    CTFontRef _font;
}

- (instancetype)initWithFont:(CTFontRef)font
                typoAscender:(CGFloat)typoAscender
               typoDescender:(CGFloat)typoDescender
              hasTypoMetrics:(BOOL)hasTypoMetrics {
    self = [super init];
    if (self) {
        _font = (CTFontRef)CFRetain(font);
        _typoAscender = typoAscender;
        _typoDescender = typoDescender;
        _hasTypoMetrics = hasTypoMetrics;
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
            uint32_t scalar = CFStringGetLongCharacterForSurrogatePair(unit, low);
            [scalars addObject:@(scalar)];
            index++;
        } else {
            [scalars addObject:@(unit)];
        }
    }
    return scalars;
}

NSArray<GACharacterGroup *> *GAGroupsForScanResult(NSString *text, GARawScanResult *result) {
    NSMutableArray *groups = [NSMutableArray arrayWithCapacity:result.sourceRanges.count];
    for (NSValue *value in result.sourceRanges) {
        GACharacterGroup *group = [[GACharacterGroup alloc] init];
        group.textRange = value.rangeValue;
        group.text = [text substringWithRange:group.textRange];
        group.variants = @[];
        [groups addObject:group];
    }
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

/// Requires a nonempty variant. Reports vmtx/vhea availability.
+ (BOOL)hasVerticalMetricsForVariant:(GAGlyphVariant *)variant;
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
    _fontURL = [url copy];
    NSArray<NSString *> *languages = CFBridgingRelease(CTFontCopySupportedLanguages(_font));
    for (NSString *language in languages) {
        if ([NSLocale characterDirectionForLanguage:language] == NSLocaleLanguageDirectionRightToLeft) {
            _hasRightToLeftLanguages = YES;
            break;
        }
    }
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
    _typesettingLanguageTags = [_substitutionEngine languageTags];
    CGFloat typoAscender = 0;
    CGFloat typoDescender = 0;
    BOOL hasTypoMetrics = [_substitutionEngine typoMetricsAscender:&typoAscender
                                                         descender:&typoDescender];
    _fontBox = [[GAFontBox alloc] initWithFont:_font
                                  typoAscender:typoAscender
                                 typoDescender:typoDescender
                                hasTypoMetrics:hasTypoMetrics];
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
- (GARawScanResult *)rebindResult:(GARawScanResult *)result content:(NSString *)content
                       cancelled:(BOOL (^)(void))cancelled {
    NSMutableArray *candidates = [NSMutableArray arrayWithCapacity:result.candidates.count];
    for (GAScanCandidate *old in result.candidates) {
        if (cancelled && cancelled())
            return nil;
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
    rebound.incomplete = result.incomplete;
    rebound.candidates = candidates;
    rebound.sourceRanges = result.sourceRanges;
    return cancelled && cancelled() ? nil : rebound;
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
    v.temporary = old.temporary;
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
                // Native character sets report empty planes without scanning
                // every scalar; nominal glyph mapping remains CoreText-owned.
                if ((scalar & 0xFFFF) == 0 &&
                    !CFCharacterSetHasMemberInPlane(characterSet, scalar >> 16)) {
                    scalar += 0xFFFF;
                    continue;
                }
                if (scalar >= 0xD800 && scalar <= 0xDFFF) {
                    continue;
                }
                if (!CFCharacterSetIsLongCharacterMember(characterSet, scalar)) {
                    continue;
                }

                UniChar units[2];
                CFIndex length = CFStringGetSurrogatePairForLongCharacter(scalar, units) ? 2 : 1;

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

- (void)decorateVariant:(GAGlyphVariant *)variant {
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *map = self.unicodeMap;
    NSMutableSet<NSNumber *> *scalars = [NSMutableSet set];
    NSMutableArray<NSString *> *glyphNames = [NSMutableArray array];

    for (NSNumber *glyphNumber in variant.glyphIDs) {
        NSArray<NSNumber *> *mapped = map[glyphNumber];
        for (NSNumber *scalar in mapped) {
            [scalars addObject:scalar];
        }

        CGGlyph glyph = (CGGlyph)glyphNumber.unsignedShortValue;
        NSString *name = CFBridgingRelease(CTFontCopyNameForGlyph(_font, glyph));
        if (!name.length || GAGlyphNameLooksSynthetic(name)) {
            name = [NSString stringWithFormat:@"GID %@", glyphNumber];
        }
        [glyphNames addObject:name];
    }

    NSArray<NSNumber *> *sortedScalars =
        [scalars.allObjects sortedArrayUsingSelector:@selector(compare:)];
    variant.unicodeScalars = sortedScalars;
    variant.glyphName = [glyphNames componentsJoinedByString:@"/"];
}

#pragma mark - Font substitution discovery

- (GAGlyphResolution *)resolveGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                            textRange:(NSRange)range
                                 text:(NSString *)text
                           selections:(NSArray<GAGlyphSelectionRun *> *)selections
                               groups:(NSArray<GACharacterGroup *> *)groups
                             vertical:(BOOL)vertical
                 featureSettings:(NSArray<NSDictionary *> *)featureSettings
            baseWritingDirection:(NSInteger)direction
                     languageTag:(NSString *)languageTag
                            cancelled:(BOOL (^)(void))cancelled {
    NSMutableArray<GAGlyphVariant *> *parents = [NSMutableArray array];
    NSMutableArray *sequences = [NSMutableArray array];
    for (GACharacterGroup *group in groups) {
        if (!NSEqualRanges(group.textRange, range)) continue;
        for (GAGlyphVariant *variant in group.variants) {
            [parents addObject:variant];
            [sequences addObject:variant.glyphIDs];
        }
    }
    GASubstitutionOrigin *source = [_substitutionEngine originForGlyphIDs:glyphIDs
        sourceRange:range text:text selections:selections candidates:sequences
        vertical:vertical featureSettings:featureSettings
        baseWritingDirection:direction
        languageTag:languageTag
        cancelled:cancelled];
    if (!source || cancelled()) return nil;
    GAGlyphVariant *parent = parents[source.sourceIndex];
    GAGlyphVariant *variant = [[GAGlyphVariant alloc] init];
    variant.fontBox = _fontBox;
    variant.glyphIDs = glyphIDs;
    variant.positions = [_substitutionEngine positionsForGlyphIDs:glyphIDs
        content:[text substringWithRange:range]];
    [variant addFeatureSources:source.sources];
    variant.sourceTextRange = range;
    variant.ligature = parent.isLigature;
    variant.fromGlyphSeed = parent.fromGlyphSeed;
    variant.temporary = YES;
    [self decorateVariant:variant];
    GAGlyphResolution *result = [[GAGlyphResolution alloc] init];
    result.parent = parent;
    result.variant = variant;
    return result;
}

- (GARawScanResult *)rawScanContent:(NSString *)content
                         selections:(NSArray<GAGlyphSelectionRun *> *)selections
                          cancelled:(BOOL (^)(void))cancelled {
    BOOL incomplete = NO;
    NSArray<GASubstitutionMatch *> *matches = [_substitutionEngine discoverText:content
                                                                     selections:selections
                                                                     incomplete:&incomplete
                                                                      cancelled:cancelled];
    if (!matches)
        return nil;
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    for (GASubstitutionMatch *match in matches)
        if (match.base) [ranges addObject:[NSValue valueWithRange:match.sourceRange]];
    NSComparator order = ^NSComparisonResult(NSValue *a, NSValue *b) {
        return a.rangeValue.location < b.rangeValue.location ? NSOrderedAscending
             : a.rangeValue.location > b.rangeValue.location ? NSOrderedDescending : NSOrderedSame;
    };
    [ranges sortUsingComparator:order];
    NSArray<NSValue *> *roots = [ranges copy];
    __block NSUInteger root = 0;
    [content enumerateSubstringsInRange:NSMakeRange(0, content.length)
                                options:NSStringEnumerationByComposedCharacterSequences |
                                        NSStringEnumerationSubstringNotRequired
                             usingBlock:^(NSString *substring, NSRange range,
                                          NSRange enclosingRange, BOOL *stop) {
        (void)substring;
        (void)enclosingRange;
        (void)stop;
        while (root < roots.count && NSMaxRange(roots[root].rangeValue) <= range.location)
            root++;
        if (root == roots.count || roots[root].rangeValue.location >= NSMaxRange(range))
            [ranges addObject:[NSValue valueWithRange:range]];
    }];
    [ranges sortUsingComparator:order];
    GARawScanResult *result = [[GARawScanResult alloc] init];
    result.incomplete = incomplete;
    result.sourceRanges = ranges;
    if (cancelled && cancelled())
        return nil;
    NSArray<NSValue *> *sourceRanges = result.sourceRanges;
    NSMutableArray *candidates = [NSMutableArray array];
    for (GASubstitutionMatch *match in matches) {
        if (cancelled && cancelled())
            return nil;
        if (!match.sourceRange.length || NSMaxRange(match.sourceRange) > content.length)
            continue;
        NSUInteger lo = 0, hi = sourceRanges.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (NSMaxRange(sourceRanges[mid].rangeValue) <= match.sourceRange.location)
                lo = mid + 1;
            else
                hi = mid;
        }
        NSUInteger first = lo;
        hi = sourceRanges.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (sourceRanges[mid].rangeValue.location < NSMaxRange(match.sourceRange))
                lo = mid + 1;
            else
                hi = mid;
        }
        NSUInteger last = lo ? lo - 1 : NSNotFound;
        if (first >= sourceRanges.count)
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
    result.candidates = candidates;
    return cancelled && cancelled() ? nil : result;
}

- (BOOL)applyRawResult:(GARawScanResult *)result
                groups:(NSArray<GACharacterGroup *> *)groups
             cancelled:(BOOL (^)(void))cancelled {
    for (GAScanCandidate *candidate in result.candidates) {
        if (cancelled && cancelled())
            return NO;
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
        variant.sourceTextRange = candidate.sourceRange;
        if (candidate.ligature) {
            variant.ligature = YES;
        }
        [self decorateVariant:variant];
        if (candidate.isBase && variant.unicodeScalars.count == 0) {
            variant.unicodeScalars = GAScalarsForString(group.text);
        }
        [variants addObject:variant];
        group.variants = variants;
    }
    return !cancelled || !cancelled();
}

- (NSArray<NSString *> *)glyphFeatureTags {
    return [_substitutionEngine glyphFeatureTags];
}

- (NSIndexSet *)glyphOutputsForFeatureTag:(NSString *)tag cancelled:(BOOL (^)(void))cancelled {
    return [_substitutionEngine glyphOutputsForFeatureTag:tag cancelled:cancelled];
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
- (NSArray<GAGlyphVariant *> *)variantsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                        cancelled:(BOOL (^)(void))cancelled {
    if (!glyphIDs.count)
        return @[];
    NSArray<GASubstitutionMatch *> *matches = [_substitutionEngine discoverGlyphIDs:glyphIDs
                                                                             cancelled:cancelled];
    if (!matches)
        return nil;
    NSMutableArray *variants = [NSMutableArray array];
    for (GASubstitutionMatch *match in matches) {
        if (cancelled && cancelled())
            return nil;
        GAGlyphVariant *v = [[GAGlyphVariant alloc] init];
        v.fontBox = _fontBox;
        v.glyphIDs = match.glyphIDs;
        v.positions = [_substitutionEngine positionsForGlyphIDs:v.glyphIDs content:@""];
        [v addFeatureSources:match.sources];
        v.base = match.base;
        [self decorateVariant:v];
        [variants addObject:v];
    }
    return [variants copy];
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

    BOOL hasVertical = usesVerticalMetrics && [self hasVerticalMetricsForVariant:variant];
    CGFloat originUnits = 0;
    if (hasVertical) {
        // CoreText exposes the per-glyph vertical origin (VORG for CFF, a
        // font-wide origin for TrueType). It is stable across variation axes
        // when the font defines no origin variation.
        CGGlyph glyph = (CGGlyph)variant.glyphIDs.firstObject.unsignedShortValue;
        CGSize translation = CGSizeZero;
        CTFontGetVerticalTranslationsForGlyphs(font, &glyph, &translation, 1);
        originUnits = -translation.height * shapeToUnits;
    }
    CGFloat width;
    CGFloat height;
    BOOL hasTypoMetrics = variant.fontBox.hasTypoMetrics;
    CGFloat typoDescender = fabs(variant.fontBox.typoDescender);
    if (hasVertical) {
        CGSize advance = [self advanceInFontUnitsForVariant:variant];
        width = advance.width;
        height = advance.height;
    } else {
        // The width-only page: advance width × typographic height. It must not
        // read vmtx, so the grid and sidebar do not pay for vertical metrics.
        // OS/2 typo metrics win when present; the descender magnitude is used
        // because some fonts store it as a positive depth.
        width = GAAdvanceWidthInFontUnits(font, variant.glyphIDs);
        if (hasTypoMetrics) {
            height = variant.fontBox.typoAscender + typoDescender;
        } else {
            height = (CTFontGetAscent(font) + CTFontGetDescent(font)) * shapeToUnits;
        }
    }
    if (width <= 0) {
        width = hasInk ? CGRectGetWidth(ink) : unitsPerEm * 0.01;
    }
    if (height <= 0) {
        height = hasInk ? CGRectGetHeight(ink) : unitsPerEm;
    }

    CGFloat baseline;
    if (hasVertical) {
        baseline = height - originUnits;
    } else if (hasTypoMetrics) {
        baseline = typoDescender;
    } else {
        baseline = CTFontGetDescent(font) * shapeToUnits;
    }

    page.size = CGSizeMake(width, height);
    page.baseline = baseline;
    page.ink = ink;
    return page;
}

+ (BOOL)hasVerticalMetricsForVariant:(GAGlyphVariant *)variant {
    NSData *vmtx = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVmtx, 0));
    NSData *vhea = CFBridgingRelease(CTFontCopyTable(variant.fontBox.font,
                                                     kCTFontTableVhea, 0));
    return vmtx.length >= 4 && vhea.length >= 36;
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
