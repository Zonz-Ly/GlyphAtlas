#import "GACmap.h"
static GAGlyph nominalAt(GATableView *data, uint32_t scalar) {
    unsigned format = [data u16:0];
    if (format == 0)
        return scalar < 256 ? [data u8:6 + scalar] : 0;
    if (format == 2) {
        if (scalar > 0xffff)
            return 0;
        unsigned high = scalar >> 8, low = scalar & 255;
        unsigned key = [data u16:6 + (high ? high : low) * 2];
        if ((high && !key) || (!high && key))
            return 0;
        GATableView *sub = [data at:518 + key];
        unsigned first = [sub u16:0], count = [sub u16:2];
        if (low < first || low - first >= count)
            return 0;
        unsigned offset = [sub u16:6];
        GAGlyph glyph = offset ? [sub u16:6 + offset + (low - first) * 2] : (GAGlyph)(low);
        return glyph ? (GAGlyph)(glyph + [sub s16:4]) : 0;
    }
    if (format == 4) {
        if (scalar > 0xffff)
            return 0;
        unsigned count = [data u16:6] / 2;
        [data array:14 count:count stride:2];
        size_t lo = 0, hi = count;
        while (lo < hi) {
            size_t mid = (lo + hi) / 2;
            if ([data u16:14 + mid * 2] < scalar)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo == count)
            return 0;
        unsigned first = [data u16:16 + count * 2 + lo * 2];
        if (scalar < first)
            return 0;
        int delta = [data s16:16 + count * 4 + lo * 2];
        size_t offsetAt = 16 + count * 6 + lo * 2;
        unsigned offset = [data u16:offsetAt];
        if (!offset)
            return (GAGlyph)(scalar + delta);
        GAGlyph glyph = [data u16:offsetAt + offset + (scalar - first) * 2];
        return glyph ? (GAGlyph)(glyph + delta) : 0;
    }
    if (format == 6) {
        unsigned first = [data u16:6], count = [data u16:8];
        return scalar >= first && scalar - first < count ? [data u16:10 + (scalar - first) * 2] : 0;
    }
    if (format == 10) {
        uint32_t first = [data u32:12], count = [data u32:16];
        return scalar >= first && scalar - first < count
                   ? [data u16:20 + (size_t)(scalar - first) * 2]
                   : 0;
    }
    size_t countAt = format == 8 ? 8204 : 12, recordsAt = countAt + 4;
    uint32_t count = [data u32:countAt];
    [data array:recordsAt count:count stride:12];
    if (format == 8 && scalar > 0xffff) {
        uint32_t v = scalar - 0x10000;
        scalar = ((0xd800 + (v >> 10)) << 16) | (0xdc00 + (v & 1023));
    }
    size_t lo = 0, hi = count;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2, p = recordsAt + mid * 12;
        uint32_t first = [data u32:p], last = [data u32:p + 4];
        if (scalar < first)
            hi = mid;
        else if (scalar > last)
            lo = mid + 1;
        else {
            uint32_t glyph = [data u32:p + 8] + (format == 13 ? 0 : scalar - first);
            return glyph <= 0xffff ? (GAGlyph)(glyph) : 0;
        }
    }
    return 0;
}
static NSInteger macRomanCode(uint32_t scalar) {
    if (scalar < 128)
        return scalar;
    static const uint16_t unicode[] = {
        0xc4,   0xc5,   0xc7,   0xc9,   0xd1,   0xd6,   0xdc,   0xe1,   0xe0,   0xe2,   0xe4,
        0xe3,   0xe5,   0xe7,   0xe9,   0xe8,   0xea,   0xeb,   0xed,   0xec,   0xee,   0xef,
        0xf1,   0xf3,   0xf2,   0xf4,   0xf6,   0xf5,   0xfa,   0xf9,   0xfb,   0xfc,   0x2020,
        0xb0,   0xa2,   0xa3,   0xa7,   0x2022, 0xb6,   0xdf,   0xae,   0xa9,   0x2122, 0xb4,
        0xa8,   0x2260, 0xc6,   0xd8,   0x221e, 0xb1,   0x2264, 0x2265, 0xa5,   0xb5,   0x2202,
        0x2211, 0x220f, 0x3c0,  0x222b, 0xaa,   0xba,   0x3a9,  0xe6,   0xf8,   0xbf,   0xa1,
        0xac,   0x221a, 0x192,  0x2248, 0x2206, 0xab,   0xbb,   0x2026, 0xa0,   0xc0,   0xc3,
        0xd5,   0x152,  0x153,  0x2013, 0x2014, 0x201c, 0x201d, 0x2018, 0x2019, 0xf7,   0x25ca,
        0xff,   0x178,  0x2044, 0x20ac, 0x2039, 0x203a, 0xfb01, 0xfb02, 0x2021, 0xb7,   0x201a,
        0x201e, 0x2030, 0xc2,   0xca,   0xc1,   0xcb,   0xc8,   0xcd,   0xce,   0xcf,   0xcc,
        0xd3,   0xd4,   0xf8ff, 0xd2,   0xda,   0xdb,   0xd9,   0x131,  0x2c6,  0x2dc,  0xaf,
        0x2d8,  0x2d9,  0x2da,  0xb8,   0x2dd,  0x2db,  0x2c7};
    for (unsigned i = 0; i < 128; i++)
        if (unicode[i] == scalar)
            return i + 128;
    return -1;
}

@interface GACmapSubtable : NSObject
@property(nonatomic, strong) GATableView *data;
@property(nonatomic) BOOL symbol, macRoman;
@property(nonatomic) unsigned rank;
@end
@implementation GACmapSubtable
@end
@implementation GACmap {
    NSArray<GACmapSubtable *> *_subtables;
    GATableView *_variation;
}
- (instancetype)initWithView:(GATableView *)table {
    if (!(self = [super init]))
        return nil;
    NSMutableArray *subtables = [NSMutableArray array];
    _variation = [GATableView data:nil];
    if (!table.present) {
        _subtables = @[];
        return self;
    }
    unsigned count = [table u16:2];
    [table array:4 count:count stride:8];
    for (unsigned i = 0; i < count; i++) {
        NSUInteger p = 4 + i * 8;
        unsigned platform = [table u16:p], encoding = [table u16:p + 2];
        GATableView *data = [table offset32:p + 4];
        unsigned format = [data u16:0];
        unsigned length = format == 14 ? [data u32:2]
                          : (format == 8 || format == 10 || format == 12 || format == 13)
                              ? [data u32:4]
                              : [data u16:2];
        data = [data slice:0 length:length];
        if (format == 14) {
            _variation = data;
            continue;
        }
        BOOL macRoman = platform == 1 && encoding == 0;
        if (platform != 0 && !macRoman &&
            !(platform == 3 && (encoding == 0 || encoding == 1 || encoding == 10)))
            continue;
        unsigned rank = (format == 12   ? 60
                         : format == 4  ? 40
                         : format == 13 ? 20
                                        : 10) +
                        (platform == 3 && encoding == 10 ? 5 : 0);
        if (format != 0 && format != 2 && format != 4 && format != 6 && format != 8 &&
            format != 10 && format != 12 && format != 13)
            continue;
        GACmapSubtable *sub = [GACmapSubtable new];
        sub.data = data;
        sub.symbol = platform == 3 && encoding == 0;
        sub.macRoman = macRoman;
        sub.rank = macRoman ? 0 : rank;
        [subtables addObject:sub];
    }
    _subtables = [subtables
        sortedArrayUsingComparator:^NSComparisonResult(GACmapSubtable *a, GACmapSubtable *b) {
            return a.rank > b.rank   ? NSOrderedAscending
                   : a.rank < b.rank ? NSOrderedDescending
                                     : NSOrderedSame;
        }];
    return self;
}
- (GAGlyph)nominal:(uint32_t)scalar {
    for (GACmapSubtable *sub in _subtables) {
        uint32_t code = scalar;
        if (sub.macRoman) {
            NSInteger mapped = macRomanCode(scalar);
            if (mapped < 0)
                continue;
            code = (uint32_t)mapped;
        }
        GAGlyph glyph = nominalAt(sub.data, code);
        if (!glyph && sub.symbol && scalar <= 255)
            glyph = nominalAt(sub.data, scalar + 0xf000);
        if (glyph)
            return glyph;
    }
    return 0;
}
- (NSNumber *)variation:(uint32_t)scalar selector:(uint32_t)selector {
    if (!_variation.present)
        return nil;
    unsigned count = [_variation u32:6];
    [_variation array:10 count:count stride:11];
    NSUInteger lo = 0, hi = count;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2;
        if ([_variation u24:10 + mid * 11] < selector)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == count || [_variation u24:10 + lo * 11] != selector)
        return nil;
    NSUInteger p = 10 + lo * 11;
    GATableView *mappings = [_variation offset32:p + 7];
    if (mappings.present) {
        unsigned n = [mappings u32:0];
        [mappings array:4 count:n stride:5];
        NSUInteger a = 0, b = n;
        while (a < b) {
            NSUInteger mid = (a + b) / 2;
            if ([mappings u24:4 + mid * 5] < scalar)
                a = mid + 1;
            else
                b = mid;
        }
        if (a < n && [mappings u24:4 + a * 5] == scalar)
            return @([mappings u16:7 + a * 5]);
    }
    GATableView *defaults = [_variation offset32:p + 3];
    if (defaults.present) {
        unsigned n = [defaults u32:0];
        [defaults array:4 count:n stride:4];
        NSUInteger a = 0, b = n;
        while (a < b) {
            NSUInteger mid = (a + b) / 2;
            uint32_t first = [defaults u24:4 + mid * 4], last = first + [defaults u8:7 + mid * 4];
            if (scalar < first)
                b = mid;
            else if (scalar > last)
                a = mid + 1;
            else
                return @([self nominal:scalar]);
        }
    }
    return nil;
}
@end
