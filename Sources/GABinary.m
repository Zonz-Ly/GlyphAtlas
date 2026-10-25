#import "GABinary.h"
GATag GATagFromString(NSString *text) {
    NSData *bytes = [text dataUsingEncoding:NSASCIIStringEncoding];
    if (bytes.length != 4)
        return 0;
    const char *p = bytes.bytes;
    return GATagMake(p[0], p[1], p[2], p[3]);
}
NSString *GATagName(GATag tag) {
    uint8_t bytes[] = {tag >> 24, tag >> 16, tag >> 8, tag};
    return [[NSString alloc] initWithBytes:bytes length:4 encoding:NSISOLatin1StringEncoding];
}
void GAInvalidTable(NSString *message) {
    @throw [NSException exceptionWithName:@"GAInvalidFontTable" reason:message userInfo:nil];
}
@implementation GATableView {
    NSData *_owner;
    NSUInteger _begin;
}
+ (instancetype)data:(NSData *)data {
    GATableView *view = [self new];
    view->_owner = [data copy] ?: NSData.data;
    view->_length = view->_owner.length;
    return view;
}
- (BOOL)present {
    return _length != 0;
}
- (void)require:(NSUInteger)offset count:(NSUInteger)count {
    if (offset > _length || count > _length - offset)
        GAInvalidTable([NSString
            stringWithFormat:@"offset %lu + %lu outside table size %lu", offset, count, _length]);
}
- (void)array:(NSUInteger)offset count:(NSUInteger)count stride:(NSUInteger)stride {
    if (!stride || offset > _length || count > (_length - offset) / stride)
        GAInvalidTable(@"array outside font table");
}
- (uint8_t)u8:(NSUInteger)p {
    [self require:p count:1];
    return ((const uint8_t *)_owner.bytes)[_begin + p];
}
- (uint16_t)u16:(NSUInteger)p {
    [self require:p count:2];
    return ([self u8:p] << 8) | [self u8:p + 1];
}
- (int16_t)s16:(NSUInteger)p {
    return (int16_t)[self u16:p];
}
- (uint32_t)u24:(NSUInteger)p {
    [self require:p count:3];
    return ((uint32_t)[self u16:p] << 8) | [self u8:p + 2];
}
- (uint32_t)u32:(NSUInteger)p {
    [self require:p count:4];
    return ((uint32_t)[self u16:p] << 16) | [self u16:p + 2];
}
- (int32_t)s32:(NSUInteger)p {
    return (int32_t)[self u32:p];
}
- (double)fixed:(NSUInteger)p {
    return [self s32:p] / 65536.0;
}
- (double)f2dot14:(NSUInteger)p {
    return [self s16:p] / 16384.0;
}
- (GATableView *)at:(NSUInteger)p {
    return [self slice:p length:p <= _length ? _length - p : 0];
}
- (GATableView *)slice:(NSUInteger)p length:(NSUInteger)count {
    [self require:p count:count];
    GATableView *v = [GATableView new];
    v->_owner = _owner;
    v->_begin = _begin + p;
    v->_length = count;
    return v;
}
- (GATableView *)offset16:(NSUInteger)p {
    unsigned n = [self u16:p];
    return n ? [self at:n] : [GATableView data:nil];
}
- (GATableView *)offset32:(NSUInteger)p {
    uint32_t n = [self u32:p];
    return n ? [self at:n] : [GATableView data:nil];
}
@end
@implementation GACoverage {
    GATableView *_data;
}
- (instancetype)initWithView:(GATableView *)view {
    if (!(self = [super init]))
        return nil;
    _data = view;
    if (!view.present)
        return self;
    unsigned format = [view u16:0], count = [view u16:2];
    if (format != 1 && format != 2)
        GAInvalidTable(@"unknown coverage format");
    [view array:4 count:count stride:format == 1 ? 2 : 6];
    unsigned previous = 0, index = 0;
    for (unsigned i = 0; i < count; i++) {
        NSUInteger p = 4 + (NSUInteger)i * (format == 1 ? 2 : 6);
        unsigned first = [view u16:p], last = format == 1 ? first : [view u16:p + 2];
        if (first > last || (i && first <= previous))
            GAInvalidTable(@"unordered coverage ranges");
        if (format == 2 && [view u16:p + 4] != index)
            GAInvalidTable(@"noncontiguous coverage indices");
        previous = last;
        index += last - first + 1;
    }
    return self;
}
- (BOOL)present {
    return _data.present;
}
- (NSInteger)index:(GAGlyph)glyph {
    if (!_data.present)
        return -1;
    NSUInteger lo = 0, hi = [_data u16:2];
    unsigned format = [_data u16:0];
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2, p = 4 + mid * (format == 1 ? 2 : 6);
        unsigned first = [_data u16:p], last = format == 1 ? first : [_data u16:p + 2];
        if (glyph < first)
            hi = mid;
        else if (glyph > last)
            lo = mid + 1;
        else
            return format == 1 ? (NSInteger)mid : [_data u16:p + 4] + glyph - first;
    }
    return -1;
}
- (BOOL)contains:(GAGlyph)glyph {
    return [self index:glyph] >= 0;
}
- (NSArray<NSNumber *> *)glyphs {
    NSMutableArray *result = [NSMutableArray array];
    if (!_data.present)
        return result;
    for (unsigned i = 0, n = [_data u16:2]; i < n; i++) {
        if ([_data u16:0] == 1)
            [result addObject:@([_data u16:4 + i * 2])];
        else {
            NSUInteger p = 4 + i * 6;
            unsigned first = [_data u16:p], last = [_data u16:p + 2];
            for (unsigned g = first; g <= last; g++)
                [result addObject:@(g)];
        }
    }
    return result;
}
@end
@implementation GAClassDef {
    GATableView *_data;
}
- (instancetype)initWithView:(GATableView *)view {
    if (!(self = [super init]))
        return nil;
    _data = view;
    if (!view.present)
        return self;
    unsigned format = [view u16:0];
    if (format == 1)
        [view array:6 count:[view u16:4] stride:2];
    else if (format == 2) {
        unsigned count = [view u16:2], previous = 0;
        [view array:4 count:count stride:6];
        for (unsigned i = 0; i < count; i++) {
            NSUInteger p = 4 + (NSUInteger)i * 6;
            unsigned first = [view u16:p], last = [view u16:p + 2];
            if (first > last || (i && first <= previous))
                GAInvalidTable(@"unordered class ranges");
            previous = last;
        }
    } else
        GAInvalidTable(@"unknown class definition format");
    return self;
}
- (unsigned)value:(GAGlyph)glyph {
    if (!_data.present)
        return 0;
    if ([_data u16:0] == 1) {
        unsigned first = [_data u16:2], count = [_data u16:4];
        return glyph >= first && glyph - first < count ? [_data u16:6 + (glyph - first) * 2] : 0;
    }
    NSUInteger lo = 0, hi = [_data u16:2];
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2, p = 4 + mid * 6;
        if (glyph < [_data u16:p])
            hi = mid;
        else if (glyph > [_data u16:p + 2])
            lo = mid + 1;
        else
            return [_data u16:p + 4];
    }
    return 0;
}
@end
