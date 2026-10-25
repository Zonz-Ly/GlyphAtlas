#import "GAGlyphBuffer.h"
NSString *GASpanKey(GASpan span) {
    return [NSString stringWithFormat:@"%u:%u", span.start, span.end];
}
NSValue *GASpanValue(GASpan span) {
    return [NSValue valueWithRange:NSMakeRange(span.start, span.end - span.start)];
}
GASpan GASpanFromValue(NSValue *value) {
    NSRange r = value.rangeValue;
    return GASpanMake((uint32_t)r.location, (uint32_t)NSMaxRange(r));
}
@implementation GALayoutItem
- (instancetype)init {
    if ((self = [super init])) {
        _components = @[];
        _component = -1;
    }
    return self;
}
- (id)copyWithZone:(NSZone *)zone {
    GALayoutItem *item = [[[self class] allocWithZone:zone] init];
    item.glyph = _glyph;
    item.source = _source;
    item.scalar = _scalar;
    item.form = _form;
    item.identity = _identity;
    item.ignorable = _ignorable;
    item.components = _components;
    item.component = _component;
    item.xAdvance = _xAdvance;
    item.yAdvance = _yAdvance;
    item.xOffset = _xOffset;
    item.yOffset = _yOffset;
    return item;
}
@end
@implementation GALayoutCluster
@end
@implementation GALayoutChange
@end
NSMutableArray<GALayoutItem *> *GACopyBuffer(NSArray<GALayoutItem *> *buffer) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:buffer.count];
    for (GALayoutItem *item in buffer)
        [result addObject:[item copy]];
    return result;
}
NSArray<NSNumber *> *GAGlyphIdentifiers(NSArray<GALayoutItem *> *buffer) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:buffer.count];
    for (GALayoutItem *item in buffer)
        [result addObject:@(item.glyph)];
    return result;
}
NSArray<GALayoutCluster *> *GAClusters(NSArray<GALayoutItem *> *buffer) {
    NSArray *sorted =
        [buffer sortedArrayUsingComparator:^NSComparisonResult(GALayoutItem *a, GALayoutItem *b) {
            if (a.source.start != b.source.start)
                return a.source.start < b.source.start ? NSOrderedAscending : NSOrderedDescending;
            return a.source.end < b.source.end   ? NSOrderedAscending
                   : a.source.end > b.source.end ? NSOrderedDescending
                                                 : NSOrderedSame;
        }];
    NSMutableArray<GALayoutCluster *> *result = [NSMutableArray array];
    for (GALayoutItem *item in sorted) {
        GALayoutCluster *last = result.lastObject;
        if (last && item.source.start < last.source.end)
            last.source = GAUnite(last.source, item.source);
        else {
            GALayoutCluster *cluster = [GALayoutCluster new];
            cluster.source = item.source;
            cluster.glyphs = @[];
            [result addObject:cluster];
        }
    }
    NSMutableArray<NSMutableArray *> *glyphs = [NSMutableArray arrayWithCapacity:result.count];
    for (NSUInteger i = 0; i < result.count; i++)
        [glyphs addObject:[NSMutableArray array]];
    for (GALayoutItem *item in buffer) {
        NSUInteger lo = 0, hi = result.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (result[mid].source.start <= item.source.start)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo && item.glyph != 0xffff)
            [glyphs[lo - 1] addObject:@(item.glyph)];
    }
    for (NSUInteger i = 0; i < result.count; i++)
        result[i].glyphs = glyphs[i];
    return result;
}
@implementation GALayoutTrace
- (instancetype)init {
    if ((self = [super init]))
        _changes = [NSMutableArray array];
    return self;
}
- (void)changed:(NSArray<GALayoutItem *> *)before
          after:(NSArray<GALayoutItem *> *)after
        feature:(NSString *)feature {
    NSArray<GALayoutCluster *> *old = GAClusters(before), *next = GAClusters(after);
    NSMutableDictionary *prior = [NSMutableDictionary dictionary];
    for (GALayoutCluster *cluster in old)
        prior[GASpanKey(cluster.source)] = cluster.glyphs;
    for (GALayoutCluster *cluster in next)
        if (![prior[GASpanKey(cluster.source)] isEqual:cluster.glyphs]) {
            GALayoutChange *change = [GALayoutChange new];
            change.source = cluster.source;
            change.glyphs = cluster.glyphs;
            change.feature = feature;
            [_changes addObject:change];
        }
    NSMutableArray<NSNumber *> *ends = [NSMutableArray array];
    uint32_t maximum = 0;
    for (GALayoutCluster *cluster in next) {
        maximum = MAX(maximum, cluster.source.end);
        [ends addObject:@(maximum)];
    }
    for (GALayoutCluster *cluster in old) {
        NSUInteger lo = 0, hi = next.count;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2;
            if (next[mid].source.start < cluster.source.end)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (!lo || ends[lo - 1].unsignedIntValue <= cluster.source.start) {
            GALayoutChange *change = [GALayoutChange new];
            change.source = cluster.source;
            change.glyphs = @[];
            change.feature = feature;
            [_changes addObject:change];
        }
    }
}
@end
@implementation GALayoutBudget {
    NSUInteger _remaining, _maxGlyphs;
}
- (instancetype)initWithInput:(NSUInteger)input {
    if ((self = [super init])) {
        _remaining = 1000000 + MIN(input, 1000000UL) * 10000;
        _maxGlyphs = MAX(65536UL, MIN(1000000UL, MIN(input, 1000000UL) * 64));
    }
    return self;
}
- (void)step {
    if (!_remaining)
        GAInvalidTable(@"font execution budget exhausted");
    --_remaining;
}
- (void)growth:(NSUInteger)count {
    if (count > _maxGlyphs)
        GAInvalidTable(@"font output exceeds glyph budget");
}
@end
@implementation GALayoutMetrics
@end
@implementation GAGDEF
- (instancetype)initWithView:(GATableView *)table {
    if (!(self = [super init]))
        return nil;
    GATableView *empty = [GATableView data:nil];
    _glyphClasses = [[GAClassDef alloc] initWithView:empty];
    _markAttachmentClasses = [[GAClassDef alloc] initWithView:empty];
    _markSets = @[];
    _variations = empty;
    if (!table.present)
        return self;
    [table require:0 count:12];
    _glyphClasses = [[GAClassDef alloc] initWithView:[table offset16:4]];
    _markAttachmentClasses = [[GAClassDef alloc] initWithView:[table offset16:10]];
    if ([table u32:0] >= 0x10002) {
        GATableView *sets = [table offset16:12];
        if (sets.present) {
            unsigned count = [sets u16:2];
            [sets array:4 count:count stride:4];
            NSMutableArray *values = [NSMutableArray array];
            for (unsigned i = 0; i < count; i++)
                [values addObject:[[GACoverage alloc] initWithView:[sets offset32:4 + i * 4]]];
            _markSets = values;
        }
    }
    if ([table u32:0] >= 0x10003)
        _variations = [table offset32:14];
    return self;
}
- (BOOL)includes:(GAGlyph)glyph flags:(unsigned)flags markSet:(unsigned)markSet {
    unsigned cls = [_glyphClasses value:glyph];
    if ((cls == 1 && (flags & 2)) || (cls == 2 && (flags & 4)) || (cls == 3 && (flags & 8)))
        return NO;
    if (cls == 3) {
        if (flags & 16)
            return markSet < _markSets.count && [_markSets[markSet] contains:glyph];
        if (flags & 0xff00)
            return [_markAttachmentClasses value:glyph] == (flags >> 8);
    }
    return YES;
}
@end
NSArray<NSNumber *> *GAVisible(NSArray<GALayoutItem *> *buffer, GAGDEF *gdef, unsigned flags,
                               unsigned markSet) {
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < buffer.count; i++)
        if ([gdef includes:buffer[i].glyph flags:flags markSet:markSet])
            [result addObject:@(i)];
    return result;
}
