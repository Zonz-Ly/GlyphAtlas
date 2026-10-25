#import "GAKerning.h"
static NSNumber *GAKernPair(GATableView *body, GAGlyph first, GAGlyph second, BOOL extended) {
    unsigned count = extended ? [body u32:0] : [body u16:0];
    NSUInteger start = extended ? 16 : 8;
    [body array:start count:count stride:6];
    uint32_t key = ((uint32_t)first << 16) | second;
    NSUInteger lo = 0, hi = count;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2, p = start + mid * 6;
        uint32_t found = [body u32:p];
        if (found < key)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < count && [body u32:start + lo * 6] == key ? @([body s16:start + lo * 6 + 4]) : nil;
}
static unsigned GAKernClass(GATableView *table, NSUInteger offset, GAGlyph glyph,
                            unsigned fallback) {
    unsigned first = [table u16:offset], count = [table u16:offset + 2];
    return glyph >= first && glyph - first < count
               ? [table u16:offset + 4 + (NSUInteger)(glyph - first) * 2]
               : fallback;
}
static void GAKernAdjust(NSArray<GALayoutItem *> *buffer, NSUInteger first, NSUInteger second,
                         double value, BOOL vertical, BOOL cross, BOOL overrideValue) {
    GALayoutItem *a = buffer[first], *b = buffer[second];
    double target =
        cross ? (vertical ? b.xOffset : b.yOffset) : (vertical ? a.yAdvance : a.xAdvance);
    if (cross && value == -32768)
        target = 0;
    else {
        if (vertical && !cross)
            value = -value;
        target = overrideValue ? value : target + value;
    }
    if (cross) {
        if (vertical)
            b.xOffset = target;
        else
            b.yOffset = target;
    } else if (vertical)
        a.yAdvance = target;
    else
        a.xAdvance = target;
}
static void GAKernTable(GATableView *table, BOOL extended, NSArray<GALayoutItem *> *buffer,
                        GALayoutSettings *settings, GAGDEF *gdef) {
    if (!table.present)
        return;
    BOOL apple = extended || [table u16:0] != 0;
    unsigned count = apple ? [table u32:4] : [table u16:2];
    NSUInteger at = apple ? 8 : 4;
    for (unsigned si = 0; si < count; si++) {
        GATableView *rest = [table at:at];
        unsigned header = extended ? 12 : apple ? 8 : 6;
        NSUInteger size = extended || apple ? [rest u32:0] : [rest u16:2];
        if (size < header)
            GAInvalidTable(@"short kerning subtable");
        GATableView *sub = [rest slice:0 length:size], *body = [sub at:header];
        at += size;
        uint32_t coverage = extended ? [sub u32:4] : [sub u16:4];
        unsigned format = extended || apple ? coverage & 255 : coverage >> 8;
        BOOL vertical = extended ? (coverage & 0x80000000) != 0
                        : apple  ? (coverage & 0x8000) != 0
                                 : !(coverage & 1),
             cross = extended ? (coverage & 0x40000000) != 0
                     : apple  ? (coverage & 0x4000) != 0
                              : (coverage & 4) != 0;
        if (vertical != settings.vertical || (!apple && (coverage & 2)))
            continue;
        BOOL overrideValue = !apple && (coverage & 8);
        if ((extended && (coverage & 0x20000000)) || (apple && !extended && (coverage & 0x2000)))
            GAInvalidTable(@"variation kerning requires tuple data");
        for (NSUInteger i = 0; i < buffer.count; i++) {
            if ([gdef.glyphClasses value:buffer[i].glyph] == 3)
                continue;
            NSUInteger j = i + 1;
            while (j < buffer.count && [gdef.glyphClasses value:buffer[j].glyph] == 3)
                j++;
            if (j >= buffer.count)
                break;
            NSNumber *value = nil;
            if (format == 0)
                value = GAKernPair(body, buffer[i].glyph, buffer[j].glyph, extended);
            else if (format == 2) {
                unsigned row = extended ? [body u32:0] : [body u16:0],
                         left = extended ? [body u32:4] : [body u16:2],
                         right = extended ? [body u32:8] : [body u16:4],
                         array = extended ? [body u32:12] : [body u16:6];
                if (!row)
                    GAInvalidTable(@"zero kerning row width");
                unsigned a = extended
                                 ? GAAATLookup([sub at:left], buffer[i].glyph, 2).unsignedIntValue
                                 : GAKernClass(sub, left, buffer[i].glyph, array),
                         b = extended
                                 ? GAAATLookup([sub at:right], buffer[j].glyph, 2).unsignedIntValue
                                 : GAKernClass(sub, right, buffer[j].glyph, 0);
                value = @([sub s16:extended ? array + (NSUInteger)a + b : (NSUInteger)a + b]);
            } else if (format == 3 && !extended) {
                unsigned glyphs = [body u16:0], values = [body u8:2], left = [body u8:3],
                         right = [body u8:4];
                NSUInteger leftAt = 6 + values * 2, rightAt = leftAt + glyphs,
                           indexAt = rightAt + glyphs;
                if (buffer[i].glyph >= glyphs || buffer[j].glyph >= glyphs)
                    continue;
                unsigned a = [body u8:leftAt + buffer[i].glyph],
                         b = [body u8:rightAt + buffer[j].glyph];
                if (a >= left || b >= right)
                    GAInvalidTable(@"kerning class exceeds matrix");
                unsigned index = [body u8:indexAt + (NSUInteger)a * right + b];
                if (index >= values)
                    GAInvalidTable(@"kerning value outside list");
                value = @([body s16:6 + index * 2]);
            } else
                GAInvalidTable(@"unsupported kerning subtable format");
            if (value)
                GAKernAdjust(buffer, i, j, value.doubleValue, vertical, cross, overrideValue);
        }
    }
}
@implementation GAKerning {
    GATableView *_kern, *_kerx;
}
- (instancetype)initWithKern:(GATableView *)kern kerx:(GATableView *)kerx {
    if ((self = [super init])) {
        _kern = kern;
        _kerx = kerx;
    }
    return self;
}
- (BOOL)empty {
    return !_kern.present && !_kerx.present;
}
- (void)positionBuffer:(NSMutableArray<GALayoutItem *> *)buffer
              settings:(GALayoutSettings *)settings
                  gdef:(GAGDEF *)gdef {
    NSNumber *kern = settings.features[@(GATagMake('k', 'e', 'r', 'n'))];
    if (kern && !kern.unsignedIntValue)
        return;
    if (_kerx.present)
        GAKernTable(_kerx, YES, buffer, settings, gdef);
    else
        GAKernTable(_kern, NO, buffer, settings, gdef);
}
@end
