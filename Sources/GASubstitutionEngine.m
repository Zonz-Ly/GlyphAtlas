#import "GASubstitutionEngine.h"
#import "../Vendor/harfbuzz/src/hb-aat.h"
#import "../Vendor/harfbuzz/src/hb-ot.h"
#import "../Vendor/harfbuzz/src/hb.h"
// The system ICU ABI, as used by GAUnicode; no external ICU headers/runtime.
extern void *ubidi_openSized(int32_t, int32_t, int32_t *);
extern void ubidi_setPara(void *, const uint16_t *, int32_t, uint8_t, const uint8_t *, int32_t *);
extern uint8_t ubidi_getLevelAt(const void *, int32_t);
extern void ubidi_close(void *);

@implementation GASubstitutionMatch
@end

/// Every binary read is bounded. HarfBuzz additionally sanitizes tables before
/// executing them, so malformed indices cannot become unchecked memory reads.
static uint16_t U16(NSData *d, NSUInteger p) {
    if (p > d.length || d.length - p < 2)
        return 0;
    const uint8_t *b = d.bytes;
    return (uint16_t)((b[p] << 8) | b[p + 1]);
}
static uint32_t U32(NSData *d, NSUInteger p) { return ((uint32_t)U16(d, p) << 16) | U16(d, p + 2); }
static void Put32(NSMutableData *d, NSUInteger p, uint32_t v) {
    if (p > d.length || d.length - p < 4)
        return;
    uint8_t *b = d.mutableBytes;
    b[p] = v >> 24;
    b[p + 1] = v >> 16;
    b[p + 2] = v >> 8;
    b[p + 3] = v;
}
static NSString *Tag(uint32_t tag) {
    char b[4] = {(char)(tag >> 24), (char)(tag >> 16), (char)(tag >> 8), (char)tag};
    return [[NSString alloc] initWithBytes:b length:4 encoding:NSISOLatin1StringEncoding] ?: @"";
}
static uint32_t TagValue(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSISOLatin1StringEncoding];
    if (d.length != 4)
        return 0;
    const uint8_t *b = d.bytes;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

@interface GAOTFace : NSObject {
  @public
    hb_face_t *face;
}
@property(nonatomic) CTFontRef resource;
@property(nonatomic, strong) NSData *gsub;
@property(nonatomic) BOOL literal;
@property(nonatomic, copy) NSString *aatTag;
@property(nonatomic, strong) NSData *aatData;
@property(nonatomic, copy) NSString *label;
@end
static hb_blob_t *ReferenceTable(hb_face_t *unused, hb_tag_t tag, void *data) {
    (void)unused;
    GAOTFace *owner = (__bridge GAOTFace *)data;
    NSData *bytes;
    if (tag == HB_OT_TAG_GSUB)
        bytes = owner.literal ? [NSData data] : owner.gsub;
    else if (tag == HB_TAG('m', 'o', 'r', 'x') || tag == HB_TAG('m', 'o', 'r', 't'))
        bytes = !owner.literal && [owner.aatTag isEqualToString:Tag(tag)] ? owner.aatData : nil;
    else
        bytes = CFBridgingRelease(CTFontCopyTable(owner.resource, (CTFontTableTag)tag, 0));
    return bytes.length ? hb_blob_create(bytes.bytes, (unsigned)bytes.length,
                                         HB_MEMORY_MODE_DUPLICATE, NULL, NULL)
                        : hb_blob_get_empty();
}
@implementation GAOTFace
- (instancetype)init {
    self = [super init];
    if (self)
        face = NULL;
    return self;
}
- (void)dealloc {
    if (face)
        hb_face_destroy(face);
    if (_resource)
        CFRelease(_resource);
}
@end

// The table callback outlives the Objective-C face wrapper whenever a font or
// shape-plan cache retains hb_face_t. Give it a separate retained table owner;
// that owner has no hb_face_t, so there is no reference cycle.
static void ReleaseTableOwner(void *context) { CFBridgingRelease(context); }
static hb_face_t *CreateFace(GAOTFace *owner) {
    GAOTFace *tables = [[GAOTFace alloc] init];
    tables.resource = (CTFontRef)CFRetain(owner.resource);
    tables.gsub = owner.gsub;
    tables.literal = owner.literal;
    tables.aatTag = owner.aatTag;
    tables.aatData = owner.aatData;
    hb_face_t *face = hb_face_create_for_tables(ReferenceTable, (__bridge_retained void *)tables,
                                                ReleaseTableOwner);
    hb_face_make_immutable(face);
    return face;
}

@interface GAOTLookup : NSObject
@property(nonatomic) unsigned type;
@property(nonatomic) unsigned flags;
@property(nonatomic) unsigned markSet;
@property(nonatomic) NSUInteger offset;
@property(nonatomic, copy) NSArray<NSArray<NSNumber *> *> *widths;
@property(nonatomic, strong) NSSet<NSNumber *> *inputs;
@property(nonatomic, copy) NSSet<NSNumber *> *references;
@property(nonatomic, strong) NSDictionary<NSNumber *, NSArray<NSNumber *> *> *alternates;
@property(nonatomic, strong) NSDictionary<NSNumber *, NSArray<NSNumber *> *> *reverseAlternates;
@end
@implementation GAOTLookup
@end

static void AddWidth(NSMutableOrderedSet *widths, NSUInteger back, NSUInteger input,
                     NSUInteger look) {
    if (input > 0)
        [widths addObject:@[ @(back), @(input), @(look) ]];
}
static void AddReferences(NSData *d, NSUInteger records, unsigned count, NSMutableSet *refs) {
    for (unsigned i = 0; i < count && records + i * 4 + 4 <= d.length; i++)
        [refs addObject:@(U16(d, records + i * 4 + 2))];
}
static void ParseWidths(NSData *d, NSUInteger sub, unsigned type, NSMutableOrderedSet *widths,
                        NSMutableSet *refs, unsigned depth) {
    if (sub > d.length || d.length - sub < 6 || depth > 1)
        return;
    unsigned format = U16(d, sub);
    if (type == 7) {
        if (format == 1)
            ParseWidths(d, sub + U32(d, sub + 4), U16(d, sub + 2), widths, refs, depth + 1);
        return;
    }
    if (type <= 3) {
        AddWidth(widths, 0, 1, 0);
        return;
    }
    if (type == 4 && format == 1) {
        unsigned sets = U16(d, sub + 4);
        for (unsigned i = 0; i < sets && sub + 6 + i * 2 + 2 <= d.length; i++) {
            NSUInteger set = sub + U16(d, sub + 6 + i * 2);
            unsigned count = U16(d, set);
            for (unsigned j = 0; j < count && set + 2 + j * 2 + 2 <= d.length; j++)
                AddWidth(widths, 0, U16(d, set + U16(d, set + 2 + j * 2) + 2), 0);
        }
    } else if ((type == 5 || type == 6) && (format == 1 || format == 2)) {
        NSUInteger countPos = sub + (format == 1 ? 4 : (type == 5 ? 6 : 10));
        unsigned sets = U16(d, countPos);
        for (unsigned i = 0; i < sets && countPos + 2 + i * 2 + 2 <= d.length; i++) {
            unsigned relative = U16(d, countPos + 2 + i * 2);
            if (!relative)
                continue;
            NSUInteger set = sub + relative;
            unsigned count = U16(d, set);
            for (unsigned j = 0; j < count && set + 2 + j * 2 + 2 <= d.length; j++) {
                NSUInteger rule = set + U16(d, set + 2 + j * 2);
                if (type == 5) {
                    unsigned input = U16(d, rule);
                    AddWidth(widths, 0, input, 0);
                    AddReferences(d, rule + 4 + (input ? input - 1 : 0) * 2, U16(d, rule + 2),
                                  refs);
                } else {
                    unsigned back = U16(d, rule);
                    NSUInteger p = rule + 2 + back * 2;
                    unsigned input = U16(d, p);
                    p += 2 + (input ? input - 1 : 0) * 2;
                    AddWidth(widths, back, input, U16(d, p));
                    p += 2 + U16(d, p) * 2;
                    AddReferences(d, p + 2, U16(d, p), refs);
                }
            }
        }
    } else if (type == 5 && format == 3) {
        unsigned input = U16(d, sub + 2);
        AddWidth(widths, 0, input, 0);
        AddReferences(d, sub + 6 + input * 2, U16(d, sub + 4), refs);
    } else if (type == 6 && format == 3) {
        unsigned back = U16(d, sub + 2);
        NSUInteger p = sub + 4 + back * 2;
        unsigned input = U16(d, p);
        p += 2 + input * 2;
        AddWidth(widths, back, input, U16(d, p));
        p += 2 + U16(d, p) * 2;
        AddReferences(d, p + 2, U16(d, p), refs);
    } else if (type == 8 && format == 1) {
        unsigned back = U16(d, sub + 4);
        NSUInteger p = sub + 6 + back * 2;
        AddWidth(widths, back, 1, U16(d, p));
    }
}
static int CoverageIndex(NSData *d, NSUInteger p, unsigned glyph) {
    unsigned format = U16(d, p), count = U16(d, p + 2);
    if (format == 1) {
        unsigned lo = 0, hi = count;
        while (lo < hi) {
            unsigned mid = (lo + hi) / 2, g = U16(d, p + 4 + mid * 2);
            if (g < glyph)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo < count && U16(d, p + 4 + lo * 2) == glyph ? (int)lo : -1;
    }
    if (format == 2)
        for (unsigned i = 0; i < count && p + 4 + i * 6 + 6 <= d.length; i++) {
            NSUInteger q = p + 4 + i * 6;
            unsigned start = U16(d, q), end = U16(d, q + 2);
            if (glyph >= start && glyph <= end)
                return U16(d, q + 4) + (int)glyph - start;
        }
    return -1;
}
static unsigned ClassValue(NSData *d, NSUInteger p, unsigned glyph) {
    if (!p)
        return 0;
    unsigned format = U16(d, p);
    if (format == 1) {
        unsigned start = U16(d, p + 2), count = U16(d, p + 4);
        return glyph >= start && glyph - start < count ? U16(d, p + 6 + (glyph - start) * 2) : 0;
    }
    if (format == 2)
        for (unsigned i = 0, n = U16(d, p + 2); i < n && p + 4 + i * 6 + 6 <= d.length; i++) {
            NSUInteger q = p + 4 + i * 6;
            if (glyph >= U16(d, q) && glyph <= U16(d, q + 2))
                return U16(d, q + 4);
        }
    return 0;
}

@interface GAOTProgram : NSObject
@property(nonatomic, strong) NSArray<GAOTFace *> *faces;
@property(nonatomic, strong) GAOTFace *literalFace;
@property(nonatomic, strong) NSArray<GAOTLookup *> *lookups;
@property(nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *branchFeatures;
@property(nonatomic, strong) NSArray<NSDictionary *> *features;
@property(nonatomic, strong) NSData *gdef;
@property(nonatomic, strong) NSCache<NSString *, NSDictionary *> *cache;
@property(nonatomic) BOOL hasFeatureVariations;
- (instancetype)initWithFont:(CTFontRef)font;
@end
static BOOL Included(GAOTProgram *program, GAOTLookup *lookup, unsigned glyph);

@implementation GAOTProgram
- (instancetype)initWithFont:(CTFontRef)font {
    self = [super init];
    if (!self)
        return nil;
    _cache = [[NSCache alloc] init];
    _cache.countLimit = 2048;
    _cache.totalCostLimit = 32 * 1024 * 1024;
    NSData *gsub = CFBridgingRelease(CTFontCopyTable(font, kCTFontTableGSUB, 0)) ?: [NSData data];
    _gdef = CFBridgingRelease(CTFontCopyTable(font, kCTFontTableGDEF, 0)) ?: [NSData data];
    NSMutableArray *substitutions = [NSMutableArray arrayWithObject:@{}];
    NSUInteger fv = gsub.length >= 14 && U32(gsub, 0) == 0x10001 ? U32(gsub, 10) : 0;
    if (fv && fv + 8 <= gsub.length) {
        _hasFeatureVariations = U32(gsub, fv + 4) > 0;
        unsigned count = U32(gsub, fv + 4);
        for (unsigned i = 0; i < count && fv + 8 + i * 8 + 8 <= gsub.length; i++) {
            NSUInteger base = fv + U32(gsub, fv + 12 + i * 8);
            NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
            unsigned n = U16(gsub, base + 4);
            for (unsigned j = 0; j < n && base + 6 + j * 6 + 6 <= gsub.length; j++) {
                NSUInteger p = base + 6 + j * 6, alt = base + U32(gsub, p + 2);
                if (alt + 4 <= gsub.length)
                    overrides[@(U16(gsub, p))] = @(alt);
            }
            [substitutions addObject:overrides];
        }
    }
    NSMutableArray *faces = [NSMutableArray array], *branches = [NSMutableArray array];
    NSMutableOrderedSet *tagOrder = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary *maxValues = [NSMutableDictionary dictionary];
    NSUInteger featureList = U16(gsub, 6), lookupList = U16(gsub, 8);
    for (NSUInteger branch = 0; branch < substitutions.count; branch++) {
        NSMutableData *bytes = [gsub mutableCopy];
        if (fv && fv + 8 <= bytes.length) {
            Put32(bytes, fv + 4, branch ? 1 : 0);
            if (branch) {
                Put32(bytes, fv + 8, 0);
                Put32(bytes, fv + 12, U32(gsub, fv + 12 + (branch - 1) * 8));
            }
        }
        GAOTFace *owner = [[GAOTFace alloc] init];
        owner.resource = (CTFontRef)CFRetain(font);
        owner.gsub = bytes;
        owner->face = CreateFace(owner);
        [faces addObject:owner];
        NSMutableArray *features = [NSMutableArray array];
        NSDictionary *overrides = substitutions[branch];
        for (unsigned i = 0, n = U16(gsub, featureList);
             i < n && featureList + 2 + i * 6 + 6 <= gsub.length; i++) {
            NSUInteger p = featureList + 2 + i * 6,
                       offset = overrides[@(i)] ? [overrides[@(i)] unsignedIntegerValue]
                                                : featureList + U16(gsub, p + 4);
            NSString *tag = Tag(U32(gsub, p));
            NSMutableArray *indices = [NSMutableArray array];
            for (unsigned j = 0, c = U16(gsub, offset + 2);
                 j < c && offset + 4 + j * 2 + 2 <= gsub.length; j++)
                [indices addObject:@(U16(gsub, offset + 4 + j * 2))];
            [features addObject:@{@"tag" : tag, @"lookups" : indices}];
            [tagOrder addObject:tag];
            maxValues[tag] = @1;
        }
        [branches addObject:features];
    }
    _faces = faces;
    _branchFeatures = branches;
    GAOTFace *literal = [[GAOTFace alloc] init];
    literal.resource = (CTFontRef)CFRetain(font);
    literal.literal = YES;
    literal->face = CreateFace(literal);
    _literalFace = literal;
    NSMutableArray *lookups = [NSMutableArray array];
    for (unsigned i = 0, n = U16(gsub, lookupList);
         i < n && lookupList + 2 + i * 2 + 2 <= gsub.length; i++) {
        NSUInteger offset = lookupList + U16(gsub, lookupList + 2 + i * 2);
        GAOTLookup *lookup = [[GAOTLookup alloc] init];
        lookup.offset = offset;
        lookup.type = U16(gsub, offset);
        lookup.flags = U16(gsub, offset + 2);
        unsigned count = U16(gsub, offset + 4);
        lookup.markSet = U16(gsub, offset + 6 + count * 2);
        NSMutableOrderedSet *widths = [NSMutableOrderedSet orderedSet];
        NSMutableSet *refs = [NSMutableSet set];
        for (unsigned j = 0; j < count && offset + 6 + j * 2 + 2 <= gsub.length; j++)
            ParseWidths(gsub, offset + U16(gsub, offset + 6 + j * 2), lookup.type, widths, refs, 0);
        lookup.widths = widths.array;
        lookup.references = refs;
        hb_set_t *inputs = hb_set_create();
        hb_ot_layout_lookup_collect_glyphs(((GAOTFace *)faces.firstObject)->face, HB_OT_TAG_GSUB, i,
                                           NULL, inputs, NULL, NULL);
        NSMutableSet *set = [NSMutableSet set];
        hb_codepoint_t g = HB_SET_VALUE_INVALID;
        NSMutableDictionary *alternates = [NSMutableDictionary dictionary],
                            *reverse = [NSMutableDictionary dictionary];
        while (hb_set_next(inputs, &g)) {
            [set addObject:@(g)];
            if (!Included(self, lookup, g))
                continue;
            unsigned total = hb_ot_layout_lookup_get_glyph_alternates(
                ((GAOTFace *)faces.firstObject)->face, i, g, 0, NULL, NULL);
            if (!total)
                continue;
            hb_codepoint_t *values = calloc(total, sizeof(*values));
            unsigned got = total;
            hb_ot_layout_lookup_get_glyph_alternates(((GAOTFace *)faces.firstObject)->face, i, g, 0,
                                                     &got, values);
            NSMutableArray *array = [NSMutableArray array];
            for (unsigned k = 0; k < got; k++)
                [array addObject:@(values[k])];
            free(values);
            alternates[@(g)] = array;
            for (NSNumber *output in array) {
                NSMutableArray *siblings = reverse[output];
                if (!siblings) {
                    siblings = [NSMutableArray array];
                    reverse[output] = siblings;
                }
                for (NSNumber *sibling in array)
                    if (![siblings containsObject:sibling])
                        [siblings addObject:sibling];
            }
        }
        hb_set_destroy(inputs);
        lookup.inputs = set;
        lookup.alternates = alternates;
        lookup.reverseAlternates = reverse;
        [lookups addObject:lookup];
    }
    _lookups = lookups;
    for (NSArray *features in branches)
        for (NSDictionary *feature in features) {
            NSMutableArray *queue = [feature[@"lookups"] mutableCopy];
            NSMutableSet *visited = [NSMutableSet set];
            for (NSUInteger i = 0; i < queue.count; i++) {
                NSNumber *index = queue[i];
                if ([visited containsObject:index] || index.unsignedIntegerValue >= lookups.count)
                    continue;
                [visited addObject:index];
                GAOTLookup *lookup = lookups[index.unsignedIntegerValue];
                for (NSArray *outputs in lookup.alternates.allValues)
                    if (outputs.count > [maxValues[feature[@"tag"]] unsignedIntegerValue])
                        maxValues[feature[@"tag"]] = @(outputs.count);
                [queue addObjectsFromArray:lookup.references.allObjects];
            }
        }
    NSMutableArray *features = [NSMutableArray array];
    for (NSString *tag in tagOrder)
        [features addObject:@{@"tag" : tag, @"max" : maxValues[tag]}];
    _features = features;
    NSMutableArray *aatFaces = [NSMutableArray array];
    for (NSString *aatTag in @[ @"morx", @"mort" ]) {
        NSData *table = CFBridgingRelease(CTFontCopyTable(font, TagValue(aatTag), 0));
        if (table.length < 8)
            continue;
        BOOL extended = [aatTag isEqualToString:@"morx"];
        NSUInteger chain = 8;
        NSMutableArray<NSNumber *> *chains = [NSMutableArray array];
        NSMutableOrderedSet<NSString *> *selectors = [NSMutableOrderedSet orderedSet];
        for (unsigned ci = 0, n = U32(table, 4); ci < n; ci++) {
            NSUInteger header = extended ? 16 : 12;
            if (chain > table.length || table.length - chain < header)
                break;
            NSUInteger size = U32(table, chain + 4);
            if (size < header || size > table.length - chain)
                break;
            [chains addObject:@(chain)];
            unsigned count = extended ? U32(table, chain + 8) : U16(table, chain + 8);
            for (unsigned j = 0; j < count && header + j * 12 + 12 <= size; j++) {
                NSUInteger r = chain + header + j * 12;
                unsigned type = U16(table, r), setting = U16(table, r + 2);
                [selectors addObject:[NSString stringWithFormat:@"%u:%u", type, setting]];
            }
            chain += size;
        }
        NSMutableArray *plans = [NSMutableArray arrayWithObject:@""];
        [plans addObjectsFromArray:selectors.array];
        for (NSString *selector in plans) {
            NSArray *pair = [selector componentsSeparatedByString:@":"];
            NSMutableData *patched = [table mutableCopy];
            for (NSNumber *position in chains) {
                NSUInteger c = position.unsignedIntegerValue, header = extended ? 16 : 12,
                           size = U32(table, c + 4);
                unsigned count = extended ? U32(table, c + 8) : U16(table, c + 8);
                uint32_t flags = U32(table, c);
                for (unsigned j = 0; j < count && header + j * 12 + 12 <= size; j++) {
                    NSUInteger r = c + header + j * 12;
                    if (pair.count == 2 && U16(table, r) == [pair[0] intValue] &&
                        U16(table, r + 2) == [pair[1] intValue])
                        flags = (flags & U32(table, r + 8)) | U32(table, r + 4);
                    uint8_t *b = patched.mutableBytes;
                    b[r] = 255;
                    b[r + 1] = 255;
                    b[r + 2] = 255;
                    b[r + 3] = 255;
                }
                Put32(patched, c, flags);
            }
            GAOTFace *owner = [[GAOTFace alloc] init];
            owner.resource = (CTFontRef)CFRetain(font);
            owner.aatTag = aatTag;
            owner.aatData = patched;
            owner.label =
                selector.length ? [aatTag stringByAppendingFormat:@":%@", selector] : aatTag;
            owner->face = CreateFace(owner);
            if (hb_aat_layout_has_substitution(owner->face))
                [aatFaces addObject:owner];
        }
        // morx supersedes mort when both are present in a resource.
        if (aatFaces.count)
            break;
    }
    if (aatFaces.count) {
        if (gsub.length)
            [aatFaces addObjectsFromArray:faces];
        _faces = aatFaces;
    }

    return self;
}
@end

@interface GASubstitutionEngine ()
@property(nonatomic, strong) GAOTProgram *program;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *coordinates;
@end

static hb_font_t *CreateFont(GAOTFace *owner, NSDictionary *coordinates) {
    hb_font_t *font = hb_font_create(owner->face);
    hb_ot_font_set_funcs(font);
    unsigned upem = hb_face_get_upem(owner->face);
    hb_font_set_scale(font, (int)upem, (int)upem);
    NSUInteger n = coordinates.count;
    hb_variation_t *variations = calloc(n, sizeof(*variations));
    NSUInteger i = 0;
    for (NSNumber *axis in coordinates) {
        variations[i].tag = axis.unsignedIntValue;
        variations[i++].value = [coordinates[axis] floatValue];
    }
    hb_font_set_variations(font, variations, (unsigned)n);
    free(variations);
    return font;
}
static NSArray<NSDictionary *> *Clusters(hb_buffer_t *buffer, NSUInteger length) {
    unsigned count = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
    NSMutableDictionary<NSNumber *, NSMutableArray *> *byStart = [NSMutableDictionary dictionary];
    for (unsigned i = 0; i < count; i++) {
        if (info[i].cluster >= length)
            continue;
        NSNumber *key = @(info[i].cluster);
        if (!byStart[key])
            byStart[key] = [NSMutableArray array];
        if (info[i].codepoint != 0xFFFF)
            [byStart[key] addObject:@(info[i].codepoint)];
    }
    NSArray<NSNumber *> *starts = [byStart.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < starts.count; i++) {
        NSUInteger start = starts[i].unsignedIntegerValue,
                   end = i + 1 < starts.count ? starts[i + 1].unsignedIntegerValue : length;
        [result addObject:@{
            @"range" : [NSValue valueWithRange:NSMakeRange(start, end - start)],
            @"glyphs" : byStart[starts[i]]
        }];
    }
    return result;
}
static NSString *MatchKey(NSRange range, NSArray *glyphs) {
    return [NSString stringWithFormat:@"%lu:%lu:%@", (unsigned long)range.location,
                                      (unsigned long)range.length, glyphs];
}
static void MergeMatch(NSMutableDictionary *seen, NSMutableArray *matches, NSRange range,
                       NSArray *glyphs, NSString *source, BOOL base) {
    NSString *key = MatchKey(range, glyphs);
    GASubstitutionMatch *match = seen[key];
    if (!match) {
        match = [[GASubstitutionMatch alloc] init];
        match.glyphIDs = glyphs;
        match.sourceRange = range;
        match.sources = @[];
        match.base = base;
        seen[key] = match;
        [matches addObject:match];
    }
    match.base |= base;
    if (source.length && !match.base && ![match.sources containsObject:source])
        match.sources = [match.sources arrayByAddingObject:source];
    if (match.base)
        match.sources = @[];
}

@interface GAOTTrace : NSObject
@property(nonatomic, strong) GAOTProgram *program;
@property(nonatomic) NSUInteger length;
@property(nonatomic, strong) NSMutableArray<GASubstitutionMatch *> *matches;
@property(nonatomic, strong) NSMutableDictionary *seen;
@property(nonatomic, strong) NSMutableSet<NSValue *> *spans;
@property(nonatomic, strong) NSArray<NSDictionary *> *before;
@property(nonatomic, copy) NSString *requested;
@property(nonatomic) unsigned value;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *currentSource;
@property(nonatomic, strong) NSMutableArray<NSValue *> *deleted;
@property(nonatomic) BOOL inGSUB;
@property(nonatomic, copy) NSString *aatTable;
@end
@implementation GAOTTrace
@end
static BOOL Included(GAOTProgram *program, GAOTLookup *lookup, unsigned glyph) {
    unsigned cls = ClassValue(program.gdef, U16(program.gdef, 4), glyph);
    if ((cls == 1 && (lookup.flags & 2)) || (cls == 2 && (lookup.flags & 4)) ||
        (cls == 3 && (lookup.flags & 8)))
        return NO;
    if (cls == 3) {
        if (lookup.flags & 0x10) {
            NSUInteger set = U16(program.gdef, 12);
            unsigned n = U16(program.gdef, set + 2);
            if (lookup.markSet >= n ||
                CoverageIndex(program.gdef, set + U32(program.gdef, set + 4 + lookup.markSet * 4),
                              glyph) < 0)
                return NO;
        } else if (lookup.flags & 0xFF00) {
            if (ClassValue(program.gdef, U16(program.gdef, 10), glyph) != (lookup.flags >> 8))
                return NO;
        }
    }
    return YES;
}
static void CollectSpans(GAOTTrace *trace, hb_buffer_t *buffer, unsigned index) {
    if (index >= trace.program.lookups.count)
        return;
    GAOTLookup *lookup = trace.program.lookups[index];
    unsigned count = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
    NSArray *clusters = Clusters(buffer, trace.length);
    NSMutableDictionary *ends = [NSMutableDictionary dictionary];
    for (NSDictionary *cluster in clusters) {
        NSRange r = [cluster[@"range"] rangeValue];
        ends[@(r.location)] = @(NSMaxRange(r));
    }
    NSMutableArray<NSNumber *> *visible = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++)
        if (Included(trace.program, lookup, info[i].codepoint))
            [visible addObject:@(i)];
    for (NSUInteger p = 0; p < visible.count; p++) {
        if (![lookup.inputs containsObject:@(info[visible[p].unsignedIntValue].codepoint)])
            continue;
        for (NSArray<NSNumber *> *width in lookup.widths) {
            NSUInteger back = width[0].unsignedIntegerValue, n = width[1].unsignedIntegerValue,
                       look = width[2].unsignedIntegerValue;
            if (p < back || n + look > visible.count - p)
                continue;
            NSUInteger low = trace.length, high = 0;
            for (NSUInteger j = p - back; j < p + n + look; j++) {
                unsigned cluster = info[visible[j].unsignedIntValue].cluster;
                low = MIN(low, cluster);
                high = MAX(high, [ends[@(cluster)] unsignedIntegerValue]);
            }
            if (high > low && high <= trace.length)
                [trace.spans addObject:[NSValue valueWithRange:NSMakeRange(low, high - low)]];
        }
    }
}
/// AAT state machines have unbounded context, unlike GSUB rule widths. Only
/// enumerate windows inside dependency islands reported by the engine. A font
/// may deliberately make a whole run interdependent; no arbitrary length cap
/// is used in that case. The same cache/visited set deduplicates equal windows.
static void CollectAATSpans(GAOTTrace *trace, hb_buffer_t *buffer) {
    unsigned count = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
    if (!count)
        return;
    NSMutableSet *unsafe = [NSMutableSet set];
    for (unsigned i = 0; i < count; i++)
        if (hb_glyph_info_get_glyph_flags(&info[i]) & HB_GLYPH_FLAG_UNSAFE_TO_BREAK)
            [unsafe addObject:@(info[i].cluster)];
    NSArray *clusters = Clusters(buffer, trace.length);
    NSUInteger start = NSNotFound,
               end = clusters.count
                         ? [[clusters.firstObject objectForKey:@"range"] rangeValue].location
                         : 0;
    for (NSDictionary *c in clusters) {
        NSRange r = [c[@"range"] rangeValue];
        BOOL dependent = r.length > 1 || [unsafe containsObject:@(r.location)];
        if (dependent) {
            if (start == NSNotFound)
                start = end;
            end = NSMaxRange(r);
        } else {
            if (start != NSNotFound && end > start)
                [trace.spans addObject:[NSValue valueWithRange:NSMakeRange(start, end - start)]];
            start = NSNotFound;
            end = NSMaxRange(r);
        }
    }
    if (start != NSNotFound && end > start)
        [trace.spans addObject:[NSValue valueWithRange:NSMakeRange(start, end - start)]];
}
static hb_bool_t TraceMessage(hb_buffer_t *buffer, hb_font_t *font, const char *message,
                              void *user) {
    (void)font;
    GAOTTrace *trace = (__bridge GAOTTrace *)user;
    if (strncmp(message, "start table GSUB", 16) == 0)
        trace.inGSUB = YES;
    if (strncmp(message, "end table GSUB", 14) == 0)
        trace.inGSUB = NO;
    if (strncmp(message, "start table morx", 16) == 0 ||
        strncmp(message, "start table mort", 16) == 0) {
        trace.aatTable = [NSString stringWithUTF8String:message + 12];
        return YES;
    }
    if (trace.aatTable.length) {
        unsigned subtable = 0;
        if (sscanf(message, "start chainsubtable %u", &subtable) == 1) {
            trace.before = Clusters(buffer, trace.length);
            trace.currentSource = trace.requested.length ? trace.requested : trace.aatTable;
        }
        if (sscanf(message, "end chainsubtable %u", &subtable) == 1) {
            NSArray *after = Clusters(buffer, trace.length);
            NSMutableSet *old = [NSMutableSet set];
            for (NSDictionary *c in trace.before)
                [old addObject:MatchKey([c[@"range"] rangeValue], c[@"glyphs"])];
            for (NSDictionary *c in after) {
                NSRange r = [c[@"range"] rangeValue];
                if (![old containsObject:MatchKey(r, c[@"glyphs"])])
                    MergeMatch(trace.seen, trace.matches, r, c[@"glyphs"], trace.currentSource, NO);
            }
            CollectAATSpans(trace, buffer);
        }
        if (strncmp(message, "end table mor", 13) == 0) {
            CollectAATSpans(trace, buffer);
            trace.aatTable = nil;
        }
        return YES;
    }
    if (!trace.inGSUB)
        return YES;
    unsigned lookup = 0;
    char tag[5] = {0};
    if (sscanf(message, "start lookup %u feature '%4[^']'", &lookup, tag) == 2) {
        trace.before = Clusters(buffer, trace.length);
        trace.deleted = [NSMutableArray array];
        trace.currentSource = [@(tag) isEqualToString:trace.requested] ? trace.label : @(tag);
        CollectSpans(trace, buffer, lookup);
    } else if (sscanf(message, "start recursing to lookup %u", &lookup) == 1)
        CollectSpans(trace, buffer, lookup);
    else if (sscanf(message, "deleting glyph at %u", &lookup) == 1) {
        unsigned count = 0;
        hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
        if (lookup < count) {
            unsigned start = info[lookup].cluster;
            for (NSDictionary *c in Clusters(buffer, trace.length)) {
                NSRange r = [c[@"range"] rangeValue];
                if (r.location == start) {
                    [trace.deleted addObject:[NSValue valueWithRange:r]];
                    MergeMatch(trace.seen, trace.matches, r, @[], trace.currentSource, NO);
                    break;
                }
            }
        }
    } else if (sscanf(message, "end lookup %u feature '%4[^']'", &lookup, tag) == 2) {
        NSArray *after = Clusters(buffer, trace.length);
        NSMutableSet *previous = [NSMutableSet set];
        for (NSDictionary *c in trace.before)
            [previous addObject:MatchKey([c[@"range"] rangeValue], c[@"glyphs"])];
        NSString *source = trace.currentSource;
        for (NSDictionary *c in after) {
            NSRange r = [c[@"range"] rangeValue];
            BOOL unchanged = [previous containsObject:MatchKey(r, c[@"glyphs"])];
            if (!unchanged && trace.deleted.count)
                for (NSDictionary *old in trace.before) {
                    NSRange o = [old[@"range"] rangeValue];
                    if (o.location != r.location || ![old[@"glyphs"] isEqual:c[@"glyphs"]])
                        continue;
                    for (NSValue *d in trace.deleted)
                        if (NSIntersectionRange(r, d.rangeValue).length)
                            o = NSUnionRange(o, d.rangeValue);
                    if (NSEqualRanges(o, r)) {
                        unchanged = YES;
                        break;
                    }
                }
            if (!unchanged)
                MergeMatch(trace.seen, trace.matches, r, c[@"glyphs"], source, NO);
        }
        for (NSDictionary *c in trace.before) {
            NSRange r = [c[@"range"] rangeValue];
            BOOL remains = NO;
            for (NSDictionary *a in after)
                if (NSIntersectionRange(r, [a[@"range"] rangeValue]).length) {
                    remains = YES;
                    break;
                }
            if (!remains)
                MergeMatch(trace.seen, trace.matches, r, @[], source, NO);
        }
    }
    return YES;
}

static NSArray<NSDictionary *> *ScriptRuns(NSString *text) {
    NSUInteger length = text.length;
    if (!length)
        return @[];
    UniChar *chars = calloc(length, sizeof(*chars));
    [text getCharacters:chars range:NSMakeRange(0, length)];
    int32_t status = 0;
    void *bidi = ubidi_openSized((int32_t)length, 0, &status);
    ubidi_setPara(bidi, (uint16_t *)chars, (int32_t)length, 0xfe, NULL, &status);
    if (status > 0 || bidi == NULL) {
        if (bidi)
            ubidi_close(bidi);
        free(chars);
        [NSException raise:@"GAGSUBExecutionError"
                    format:@"Unicode bidi analysis failed (%d)", status];
    }
    NSMutableArray *result = [NSMutableArray array];
    hb_script_t previous = HB_SCRIPT_COMMON;
    NSUInteger start = 0;
    unsigned level = ubidi_getLevelAt(bidi, 0);
    for (NSUInteger i = 0; i < length;) {
        NSUInteger next = i + 1;
        uint32_t scalar = chars[i];
        if (CFStringIsSurrogateHighCharacter(chars[i]) && next < length &&
            CFStringIsSurrogateLowCharacter(chars[next])) {
            scalar = CFStringGetLongCharacterForSurrogatePair(chars[i], chars[next]);
            next++;
        }
        hb_script_t script = hb_unicode_script(hb_unicode_funcs_get_default(), scalar);
        if (script == HB_SCRIPT_COMMON || script == HB_SCRIPT_INHERITED) {
            script = previous;
            if (script == HB_SCRIPT_COMMON) {
                for (NSUInteger j = next; j < length; j++) {
                    uint32_t look = chars[j];
                    if (CFStringIsSurrogateHighCharacter(chars[j]) && j + 1 < length &&
                        CFStringIsSurrogateLowCharacter(chars[j + 1]))
                        look = CFStringGetLongCharacterForSurrogatePair(chars[j], chars[j + 1]);
                    hb_script_t s = hb_unicode_script(hb_unicode_funcs_get_default(), look);
                    if (s != HB_SCRIPT_COMMON && s != HB_SCRIPT_INHERITED &&
                        s != HB_SCRIPT_UNKNOWN) {
                        script = s;
                        break;
                    }
                }
            }
        }
        unsigned current = ubidi_getLevelAt(bidi, (int32_t)i);
        if (i > start && (script != previous || ((current ^ level) & 1))) {
            [result addObject:@{
                @"range" : [NSValue valueWithRange:NSMakeRange(start, i - start)],
                @"script" : @(previous),
                @"rtl" : @((level & 1) != 0)
            }];
            start = i;
            level = current;
        }
        previous = script;
        i = next;
    }
    [result addObject:@{
        @"range" : [NSValue valueWithRange:NSMakeRange(start, length - start)],
        @"script" : @(previous),
        @"rtl" : @((level & 1) != 0)
    }];
    ubidi_close(bidi);
    free(chars);
    return result;
}

@implementation GASubstitutionEngine
- (instancetype)initWithFont:(CTFontRef)font
                 coordinates:(NSDictionary *)coordinates
                     sharing:(GASubstitutionEngine *)source {
    self = [super init];
    if (self) {
        _program = source.program ?: [[GAOTProgram alloc] initWithFont:font];
        _coordinates = [coordinates copy] ?: @{};
    }
    return self;
}
- (BOOL)hasFeatureVariations {
    return self.program.hasFeatureVariations;
}
- (NSArray *)featureSpecifications {
    NSMutableArray *features = [self.program.features mutableCopy];
    for (GAOTFace *face in self.program.faces)
        if (face.aatTag.length)
            [features addObject:@{@"tag" : face.label, @"max" : @1, @"engine" : face.aatTag}];
    return features;
}

- (NSDictionary *)runContent:(NSString *)text {
    @synchronized(self.program.cache) {
        NSDictionary *cached = [self.program.cache objectForKey:text];
        if (cached)
            return cached;
    }
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSMutableSet *spans = [NSMutableSet set], *baseline = [NSMutableSet set];
    NSUInteger length = text.length;
    UniChar *chars = calloc(MAX(1, length), sizeof(*chars));
    [text getCharacters:chars range:NSMakeRange(0, length)];
    NSArray *runs = ScriptRuns(text);
    for (NSUInteger branch = 0; branch < self.program.faces.count; branch++) {
        hb_font_t *font = CreateFont(self.program.faces[branch], @{});
        for (NSDictionary *run in runs) {
            NSRange runRange = [run[@"range"] rangeValue];
            hb_script_t hbScript = [run[@"script"] unsignedIntValue];
            NSMutableOrderedSet<NSString *> *languages =
                [NSMutableOrderedSet orderedSetWithObject:@""];
            hb_tag_t scriptTags[HB_OT_MAX_TAGS_PER_SCRIPT];
            unsigned scriptCount = HB_OT_MAX_TAGS_PER_SCRIPT;
            hb_ot_tags_from_script_and_language(hbScript, HB_LANGUAGE_INVALID, &scriptCount,
                                                scriptTags, NULL, NULL);
            for (unsigned s = 0; s < scriptCount; s++) {
                unsigned scriptIndex = 0;
                if (!hb_ot_layout_table_find_script(self.program.faces[branch]->face,
                                                    HB_OT_TAG_GSUB, scriptTags[s], &scriptIndex))
                    continue;
                unsigned total = hb_ot_layout_script_get_language_tags(
                    self.program.faces[branch]->face, HB_OT_TAG_GSUB, scriptIndex, 0, NULL, NULL);
                hb_tag_t *tags = calloc(total, sizeof(*tags));
                unsigned n = total;
                hb_ot_layout_script_get_language_tags(self.program.faces[branch]->face,
                                                      HB_OT_TAG_GSUB, scriptIndex, 0, &n, tags);
                for (unsigned j = 0; j < n; j++) {
                    hb_language_t l = hb_ot_tag_to_language(tags[j]);
                    if (l)
                        [languages addObject:@(hb_language_to_string(l))];
                }
                free(tags);
            }
            NSMutableArray *plans = [NSMutableArray arrayWithObject:@{@"tag" : @"", @"value" : @0}];
            if (!self.program.faces[branch].aatTag.length)
                for (NSDictionary *feature in self.program.features)
                    for (unsigned v = 1; v <= [feature[@"max"] unsignedIntValue]; v++)
                        [plans addObject:@{@"tag" : feature[@"tag"], @"value" : @(v)}];
            for (NSString *language in languages)
                for (NSDictionary *plan in plans) {
                    hb_buffer_t *buffer = hb_buffer_create();
                    hb_buffer_set_cluster_level(buffer, HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES);
                    hb_buffer_set_flags(buffer, HB_BUFFER_FLAG_PRODUCE_UNSAFE_TO_CONCAT);
                    hb_buffer_add_utf16(buffer, (uint16_t *)chars, (int)length,
                                        (unsigned)runRange.location, (int)runRange.length);
                    hb_buffer_set_script(buffer, hbScript);
                    hb_buffer_set_direction(buffer, [run[@"rtl"] boolValue] ? HB_DIRECTION_RTL
                                                                            : HB_DIRECTION_LTR);
                    hb_buffer_set_language(
                        buffer, language.length ? hb_language_from_string(language.UTF8String, -1)
                                                : hb_language_get_default());
                    GAOTTrace *trace = [[GAOTTrace alloc] init];
                    trace.program = self.program;
                    trace.length = NSMaxRange(runRange);
                    trace.matches = matches;
                    trace.seen = seen;
                    trace.spans = spans;
                    trace.requested = self.program.faces[branch].aatTag.length
                                          ? self.program.faces[branch].label
                                          : plan[@"tag"];
                    trace.value = [plan[@"value"] unsignedIntValue];
                    trace.label = trace.value > 1 ? [trace.requested
                                                        stringByAppendingFormat:@" %u", trace.value]
                                                  : trace.requested;
                    hb_buffer_set_message_func(buffer, TraceMessage, (__bridge void *)trace, NULL);
                    hb_feature_t feature = {TagValue(trace.requested), trace.value, 0,
                                            HB_FEATURE_GLOBAL_END};
                    const char *shapers[] = {"ot", NULL};
                    BOOL ok = hb_shape_full(font, buffer, [plan[@"tag"] length] ? &feature : NULL,
                                            [plan[@"tag"] length] ? 1 : 0, shapers);
                    if (!ok || !hb_buffer_allocation_successful(buffer)) {
                        hb_buffer_destroy(buffer);
                        hb_font_destroy(font);
                        free(chars);
                        [NSException
                             raise:@"GAGSUBExecutionError"
                            format:@"OpenType execution could not complete for %lu UTF-16 units",
                                   (unsigned long)length];
                    }
                    NSArray *clusters = Clusters(buffer, NSMaxRange(runRange));
                    BOOL base = branch == 0 && [plan[@"tag"] length] == 0 && language.length == 0;
                    for (NSDictionary *c in clusters) {
                        NSRange r = [c[@"range"] rangeValue];
                        NSString *fingerprint = [NSString
                            stringWithFormat:@"%lu:%@", (unsigned long)r.location, c[@"glyphs"]];
                        if (base) {
                            [baseline addObject:fingerprint];
                            MergeMatch(seen, matches, r, c[@"glyphs"], nil, YES);
                        } else if (![baseline containsObject:fingerprint])
                            MergeMatch(seen, matches, r, c[@"glyphs"],
                                       trace.requested.length ? trace.label : @"actual", NO);
                    }
                    if (!clusters.count && runRange.length)
                        MergeMatch(seen, matches, runRange, @[], trace.requested, base);
                    hb_buffer_destroy(buffer);
                }
        }
        hb_font_destroy(font);
    }
    free(chars);
    // Encoded and unencoded alternate families are also indexed directly;
    // they need not be reachable through the font's default language system.
    NSArray *baseMatches = [matches copy];
    for (GASubstitutionMatch *base in baseMatches)
        if (base.base && base.glyphIDs.count == 1) {
            unsigned seed = base.glyphIDs.firstObject.unsignedIntValue;
            for (NSArray *features in self.program.branchFeatures)
                for (NSDictionary *feature in features)
                    for (NSNumber *index in feature[@"lookups"]) {
                        if (index.unsignedIntegerValue >= self.program.lookups.count)
                            continue;
                        GAOTLookup *lookup = self.program.lookups[index.unsignedIntegerValue];
                        NSArray *outputs =
                            lookup.alternates[@(seed)] ?: lookup.reverseAlternates[@(seed)];
                        for (NSUInteger i = 0; i < outputs.count; i++) {
                            NSNumber *g = outputs[i];
                            if (g.unsignedIntValue == seed)
                                continue;
                            NSString *tag = feature[@"tag"];
                            if (i > 0)
                                tag = [tag stringByAppendingFormat:@" %lu", (unsigned long)i + 1];
                            MergeMatch(seen, matches, base.sourceRange, @[ g ], tag, NO);
                        }
                    }
        }
    NSDictionary *result = @{@"matches" : matches, @"spans" : spans.allObjects};
    @synchronized(self.program.cache) {
        [self.program.cache setObject:result
                               forKey:text
                                 cost:text.length * 2 + matches.count * 128];
    }
    return result;
}

- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text {
    if (!text.length)
        return @[];
    NSMutableArray<NSValue *> *queue =
        [NSMutableArray arrayWithObject:[NSValue valueWithRange:NSMakeRange(0, text.length)]];
    NSMutableSet *visited = [NSMutableSet setWithArray:queue];
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < queue.count; i++) {
        NSRange outer = queue[i].rangeValue;
        NSString *content = [text substringWithRange:outer];
        NSDictionary *run = [self runContent:content];
        for (GASubstitutionMatch *m in run[@"matches"]) {
            NSRange range = m.sourceRange;
            range.location += outer.location;
            MergeMatch(seen, matches, range, m.glyphIDs,
                       (m.sources.firstObject ?: (m.base ? @"actual" : nil)),
                       m.base && NSEqualRanges(outer, NSMakeRange(0, text.length)));
            GASubstitutionMatch *merged = seen[MatchKey(range, m.glyphIDs)];
            if (!merged.base) {
                NSMutableOrderedSet *tags =
                    [NSMutableOrderedSet orderedSetWithArray:merged.sources];
                [tags addObjectsFromArray:m.sources];
                merged.sources = tags.array;
            }
        }
        NSMutableArray *windows = [run[@"spans"] mutableCopy];
        if (self.program.faces.firstObject.aatTag.length)
            for (NSValue *span in run[@"spans"]) {
                NSRange island = span.rangeValue;
                if (NSMaxRange(island) > content.length)
                    continue;
                NSMutableArray *bounds = [NSMutableArray array];
                [[content substringWithRange:island]
                    enumerateSubstringsInRange:NSMakeRange(0, island.length)
                                       options:NSStringEnumerationByComposedCharacterSequences
                                    usingBlock:^(NSString *str, NSRange r, NSRange e, BOOL *stop) {
                                      (void)str;
                                      (void)e;
                                      (void)stop;
                                      [bounds
                                          addObject:[NSValue
                                                        valueWithRange:NSMakeRange(island.location +
                                                                                       r.location,
                                                                                   r.length)]];
                                    }];
                for (NSUInteger a = 0; a < bounds.count; a++)
                    for (NSUInteger b = a; b < bounds.count; b++) {
                        NSRange x = [bounds[a] rangeValue], y = [bounds[b] rangeValue];
                        [windows addObject:[NSValue valueWithRange:NSMakeRange(x.location,
                                                                               NSMaxRange(y) -
                                                                                   x.location)]];
                    }
            }
        for (NSValue *span in windows) {
            NSRange r = span.rangeValue;
            r.location += outer.location;
            if (!r.length || NSMaxRange(r) > text.length)
                continue;
            NSValue *value = [NSValue valueWithRange:r];
            if (![visited containsObject:value]) {
                [visited addObject:value];
                [queue addObject:value];
            }
        }
    }
    [matches
        sortUsingComparator:^NSComparisonResult(GASubstitutionMatch *a, GASubstitutionMatch *b) {
          if (a.base != b.base)
              return a.base ? NSOrderedAscending : NSOrderedDescending;
          if (a.base && a.sourceRange.location != b.sourceRange.location)
              return a.sourceRange.location < b.sourceRange.location ? NSOrderedAscending
                                                                     : NSOrderedDescending;
          if (a.sourceRange.length != b.sourceRange.length)
              return a.sourceRange.length < b.sourceRange.length ? NSOrderedAscending
                                                                 : NSOrderedDescending;
          if (a.sourceRange.location != b.sourceRange.location)
              return a.sourceRange.location < b.sourceRange.location ? NSOrderedAscending
                                                                     : NSOrderedDescending;
          return NSOrderedSame;
        }];
    return matches;
}

static hb_bool_t LiteralGlyph(hb_font_t *font, void *data, hb_codepoint_t unicode,
                              hb_codepoint_t *glyph, void *user) {
    (void)font;
    (void)data;
    (void)user;
    if (unicode >= 0xF0000 && unicode <= 0xFFFFF) {
        *glyph = unicode - 0xF0000;
        return YES;
    }
    return NO;
}
/// The synthetic Unicode values are an identity cmap, never re-substituted for
/// positioning. GDEF still supplies mark classes and all original GPOS tables
/// remain available. Reverse input for RTL so the *output* keeps the chosen GIDs.
static hb_font_t *LiteralFont(GAOTFace *owner, NSDictionary *coordinates) {
    hb_font_t *parent = CreateFont(owner, coordinates), *font = hb_font_create_sub_font(parent);
    hb_font_funcs_t *funcs = hb_font_funcs_create();
    hb_font_funcs_set_nominal_glyph_func(funcs, LiteralGlyph, NULL, NULL);
    hb_font_funcs_make_immutable(funcs);
    hb_font_set_funcs(font, funcs, NULL, NULL);
    hb_font_funcs_destroy(funcs);
    hb_font_destroy(parent);
    return font;
}
static hb_buffer_t *LiteralBuffer(NSArray<NSNumber *> *glyphs, hb_script_t script,
                                  hb_language_t language, BOOL rtl) {
    hb_buffer_t *buffer = hb_buffer_create();
    for (NSUInteger i = 0; i < glyphs.count; i++) {
        NSUInteger index = rtl ? glyphs.count - 1 - i : i;
        hb_buffer_add(buffer, 0xF0000 + glyphs[index].unsignedIntValue, (unsigned)i);
    }
    hb_buffer_set_content_type(buffer, HB_BUFFER_CONTENT_TYPE_UNICODE);
    hb_buffer_set_script(buffer, script);
    hb_buffer_set_direction(buffer, rtl ? HB_DIRECTION_RTL : HB_DIRECTION_LTR);
    hb_buffer_set_language(buffer, language);
    hb_buffer_set_flags(buffer, HB_BUFFER_FLAG_DO_NOT_INSERT_DOTTED_CIRCLE |
                                    HB_BUFFER_FLAG_PRESERVE_DEFAULT_IGNORABLES);
    return buffer;
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    return [self positionsForGlyphIDs:glyphIDs content:@""];
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     content:(NSString *)content {
    if (!glyphIDs.count)
        return @[];
    NSArray *runs = ScriptRuns(content);
    NSDictionary *run = runs.firstObject;
    hb_script_t script = run ? [run[@"script"] unsignedIntValue] : HB_SCRIPT_UNKNOWN;
    BOOL rtl = [run[@"rtl"] boolValue];
    hb_font_t *font = LiteralFont(self.program.literalFace, self.coordinates);
    hb_buffer_t *buffer = LiteralBuffer(glyphIDs, script, HB_LANGUAGE_INVALID, rtl);
    const char *shapers[] = {"ot", NULL};
    BOOL ok = hb_shape_full(font, buffer, NULL, 0, shapers);
    unsigned count = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
    hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, NULL);
    BOOL identity = ok && count == glyphIDs.count;
    for (unsigned i = 0; identity && i < count; i++)
        identity = info[i].codepoint == glyphIDs[i].unsignedIntValue;
    if (!identity) {
        hb_buffer_destroy(buffer);
        hb_font_destroy(font);
        [NSException raise:@"GAGSUBExecutionError"
                    format:@"Literal positioning changed the selected glyph sequence"];
    }
    double scale = 200.0 / hb_face_get_upem(self.program.literalFace->face);
    double x = 0, y = 0;
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        [result
            addObject:[NSValue valueWithPoint:NSMakePoint((x + positions[i].x_offset) * scale,
                                                          (y + positions[i].y_offset) * scale)]];
        x += positions[i].x_advance;
        y += positions[i].y_advance;
    }
    hb_buffer_destroy(buffer);
    hb_font_destroy(font);
    return result;
}
- (NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (!glyphIDs.count)
        return @[];
    NSMutableArray *result = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSRange whole = NSMakeRange(0, glyphIDs.count);
    MergeMatch(seen, result, whole, glyphIDs, nil, YES);
    for (NSUInteger branch = 0; branch < self.program.faces.count; branch++) {
        GAOTFace *owner = self.program.faces[branch];
        hb_font_t *font = LiteralFont(owner, @{});
        unsigned total =
            hb_ot_layout_table_get_script_tags(owner->face, HB_OT_TAG_GSUB, 0, NULL, NULL);
        hb_tag_t *tags = calloc(MAX(1, total), sizeof(*tags));
        unsigned n = total;
        hb_ot_layout_table_get_script_tags(owner->face, HB_OT_TAG_GSUB, 0, &n, tags);
        for (unsigned si = 0; si < MAX(1, n); si++) {
            hb_script_t script = n ? hb_ot_tag_to_script(tags[si]) : HB_SCRIPT_UNKNOWN;
            NSMutableOrderedSet *languages = [NSMutableOrderedSet orderedSetWithObject:@""];
            unsigned lt = hb_ot_layout_script_get_language_tags(owner->face, HB_OT_TAG_GSUB, si, 0,
                                                                NULL, NULL),
                     ln = lt;
            hb_tag_t *langs = calloc(MAX(1, lt), sizeof(*langs));
            hb_ot_layout_script_get_language_tags(owner->face, HB_OT_TAG_GSUB, si, 0, &ln, langs);
            for (unsigned li = 0; li < ln; li++) {
                hb_language_t language = hb_ot_tag_to_language(langs[li]);
                if (language)
                    [languages addObject:@(hb_language_to_string(language))];
            }
            free(langs);
            NSArray *specifications = owner.aatTag.length
                                          ? @[ @{@"tag" : owner.label, @"max" : @1} ]
                                          : self.program.features;
            for (NSString *language in languages)
                for (NSDictionary *spec in specifications)
                    for (unsigned value = 1; value <= [spec[@"max"] unsignedIntValue]; value++) {
                        NSString *tag = spec[@"tag"],
                                 *label =
                                     value > 1 ? [tag stringByAppendingFormat:@" %u", value] : tag;
                        hb_buffer_t *buffer = LiteralBuffer(
                            glyphIDs, script,
                            language.length ? hb_language_from_string(language.UTF8String, -1)
                                            : HB_LANGUAGE_INVALID,
                            NO);
                        NSMutableArray *changes = [NSMutableArray array];
                        NSMutableDictionary *localSeen = [NSMutableDictionary dictionary];
                        GAOTTrace *trace = [[GAOTTrace alloc] init];
                        trace.program = self.program;
                        trace.length = glyphIDs.count;
                        trace.matches = changes;
                        trace.seen = localSeen;
                        trace.spans = [NSMutableSet set];
                        trace.requested = tag;
                        trace.value = value;
                        trace.label = label;
                        hb_buffer_set_message_func(buffer, TraceMessage, (__bridge void *)trace,
                                                   NULL);
                        hb_feature_t feature = {TagValue(tag), value, 0, HB_FEATURE_GLOBAL_END};
                        const char *shapers[] = {"ot", NULL};
                        BOOL ok = hb_shape_full(font, buffer, owner.aatTag.length ? NULL : &feature,
                                                owner.aatTag.length ? 0 : 1, shapers);
                        unsigned count = 0;
                        hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
                        NSMutableArray *final = [NSMutableArray array];
                        for (unsigned k = 0; k < count; k++)
                            [final addObject:@(info[k].codepoint)];
                        if (ok)
                            MergeMatch(seen, result, whole, final, label, NO);
                        for (GASubstitutionMatch *m in changes) {
                            if (NSMaxRange(m.sourceRange) > glyphIDs.count)
                                continue;
                            NSMutableArray *sequence = [glyphIDs mutableCopy];
                            [sequence replaceObjectsInRange:m.sourceRange
                                       withObjectsFromArray:m.glyphIDs];
                            for (NSString *source in m.sources)
                                MergeMatch(seen, result, whole, sequence, source, NO);
                        }
                        hb_buffer_destroy(buffer);
                        if (!ok) {
                            free(tags);
                            hb_font_destroy(font);
                            [NSException raise:@"GAGSUBExecutionError"
                                        format:@"OpenType GID execution failed"];
                        }
                    }
        }
        free(tags);
        hb_font_destroy(font);
    }
    // A seed may itself be an alternate output. Keep its siblings available;
    // unlike shaping, this is a family index and does not pretend to invert GSUB.
    for (NSUInteger component = 0; component < glyphIDs.count; component++)
        for (NSArray *features in self.program.branchFeatures)
            for (NSDictionary *feature in features)
                for (NSNumber *index in feature[@"lookups"]) {
                    if (index.unsignedIntegerValue >= self.program.lookups.count)
                        continue;
                    GAOTLookup *lookup = self.program.lookups[index.unsignedIntegerValue];
                    NSNumber *seed = glyphIDs[component];
                    NSArray *outputs = lookup.alternates[seed] ?: lookup.reverseAlternates[seed];
                    for (NSUInteger i = 0; i < outputs.count; i++) {
                        NSNumber *g = outputs[i];
                        if ([g isEqual:seed])
                            continue;
                        NSString *tag = feature[@"tag"];
                        if (i > 0)
                            tag = [tag stringByAppendingFormat:@" %lu", (unsigned long)i + 1];
                        NSMutableArray *sequence = [glyphIDs mutableCopy];
                        sequence[component] = g;
                        MergeMatch(seen, result, whole, sequence, tag, NO);
                    }
                }
    return result;
}
- (NSNumber *)verticalGlyph:(uint16_t)glyph {
    for (GAOTFace *owner in self.program.faces)
        if (owner.aatTag.length &&
            (owner == self.program.faces.firstObject || [owner.label containsString:@":4:"])) {
            hb_font_t *font = LiteralFont(owner, self.coordinates);
            hb_buffer_t *buffer =
                LiteralBuffer(@[ @(glyph) ], HB_SCRIPT_UNKNOWN, HB_LANGUAGE_INVALID, NO);
            hb_buffer_set_direction(buffer, HB_DIRECTION_TTB);
            const char *shapers[] = {"ot", NULL};
            BOOL ok = hb_shape_full(font, buffer, NULL, 0, shapers);
            unsigned count = 0;
            hb_glyph_info_t *info = hb_buffer_get_glyph_infos(buffer, &count);
            NSNumber *result =
                ok && count == 1 && info[0].codepoint != glyph ? @(info[0].codepoint) : nil;
            hb_buffer_destroy(buffer);
            hb_font_destroy(font);
            if (result)
                return result;
        }
    for (NSArray *features in self.program.branchFeatures)
        for (NSDictionary *feature in features)
            if ([feature[@"tag"] isEqualToString:@"vert"] ||
                [feature[@"tag"] isEqualToString:@"vrt2"])
                for (NSNumber *index in feature[@"lookups"]) {
                    if (index.unsignedIntegerValue < self.program.lookups.count) {
                        NSArray *a =
                            self.program.lookups[index.unsignedIntegerValue].alternates[@(glyph)];
                        if (a.count)
                            return a.firstObject;
                    }
                }
    return nil;
}
- (NSDictionary *)shapeText:(NSString *)text
                   features:(NSDictionary *)features
                     script:(NSString *)script
                   language:(NSString *)language
                     branch:(NSUInteger)branch {
    if (branch >= self.program.faces.count)
        branch = 0;
    GAOTFace *owner = self.program.faces[branch];
    if (owner.aatTag.length && features.count) {
        GAOTFace *native = [[GAOTFace alloc] init];
        native.resource = (CTFontRef)CFRetain(owner.resource);
        native.aatTag = owner.aatTag;
        native.aatData =
            CFBridgingRelease(CTFontCopyTable(owner.resource, TagValue(owner.aatTag), 0));
        native->face = CreateFace(native);
        owner = native;
    }
    hb_font_t *font = CreateFont(owner, self.coordinates);
    hb_buffer_t *b = hb_buffer_create();
    UniChar *chars = calloc(MAX(1, text.length), sizeof(*chars));
    [text getCharacters:chars range:NSMakeRange(0, text.length)];
    hb_buffer_add_utf16(b, (uint16_t *)chars, (int)text.length, 0, (int)text.length);
    free(chars);
    if (script.length)
        hb_buffer_set_script(b, hb_script_from_string(script.UTF8String, -1));
    if (language.length)
        hb_buffer_set_language(b, hb_language_from_string(language.UTF8String, -1));
    hb_buffer_guess_segment_properties(b);
    hb_feature_t *settings = calloc(features.count, sizeof(*settings));
    unsigned i = 0;
    for (NSString *tag in features)
        settings[i++] = (hb_feature_t){TagValue(tag), [features[tag] unsignedIntValue], 0,
                                       HB_FEATURE_GLOBAL_END};
    const char *shapers[] = {"ot", NULL};
    BOOL ok = hb_shape_full(font, b, settings, i, shapers);
    free(settings);
    unsigned count = 0;
    hb_glyph_info_t *info = hb_buffer_get_glyph_infos(b, &count);
    hb_glyph_position_t *pos = hb_buffer_get_glyph_positions(b, NULL);
    NSMutableArray *glyphs = [NSMutableArray array], *clusters = [NSMutableArray array],
                   *positions = [NSMutableArray array];
    for (unsigned j = 0; j < count; j++) {
        [glyphs addObject:@(info[j].codepoint)];
        [clusters addObject:@(info[j].cluster)];
        [positions addObject:@[
            @(pos[j].x_advance), @(pos[j].y_advance), @(pos[j].x_offset), @(pos[j].y_offset)
        ]];
    }
    hb_buffer_destroy(b);
    hb_font_destroy(font);
    return @{@"ok" : @(ok), @"glyphs" : glyphs, @"clusters" : clusters, @"positions" : positions};
}
@end
