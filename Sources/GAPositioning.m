#import "GAOpenType.h"
#import "GAVariation.h"
static NSUInteger GAValueSize(unsigned format) {
    if (format & 0xff00)
        GAInvalidTable(@"reserved positioning value bits");
    return (NSUInteger)__builtin_popcount(format) * 2;
}
static void GAReadValue(GALayoutItem *item, GATableView *parent, NSUInteger at, unsigned format,
                        GAGDEF *gdef, GALayoutMetrics *metrics) {
    double value[4] = {0};
    [parent require:at count:GAValueSize(format)];
    for (unsigned bit = 0; bit < 8; bit++)
        if (format & (1u << bit)) {
            if (bit < 4)
                value[bit] += [parent s16:at];
            else
                value[bit - 4] +=
                    GADeviceDelta([parent offset16:at], gdef.variations, metrics.normalized);
            at += 2;
        }
    item.xOffset += value[0];
    item.yOffset += value[1];
    item.xAdvance += value[2];
    item.yAdvance += value[3];
}
typedef struct {
    BOOL valid;
    CGPoint point;
} GAAnchor;
static GAAnchor GAReadAnchor(GATableView *table, GAGDEF *gdef, GALayoutMetrics *metrics) {
    if (!table.present)
        return (GAAnchor){NO, CGPointZero};
    unsigned format = [table u16:0];
    if (format < 1 || format > 3)
        GAInvalidTable(@"unknown anchor format");
    CGPoint p = CGPointMake([table s16:2], [table s16:4]);
    if (format == 2)
        [table require:6 count:2];
    if (format == 3) {
        p.x += GADeviceDelta([table offset16:6], gdef.variations, metrics.normalized);
        p.y += GADeviceDelta([table offset16:8], gdef.variations, metrics.normalized);
    }
    return (GAAnchor){YES, p};
}
@interface GAPositionAttachment : NSObject
@property(nonatomic) NSUInteger parent;
@property(nonatomic) CGPoint delta;
@property(nonatomic) BOOL cursive;
@end
@implementation GAPositionAttachment
@end
typedef struct {
    BOOL matched;
    NSUInteger next;
} GAPositionResult;
NS_INLINE GAPositionResult GAPositionMiss(void) { return (GAPositionResult){NO, 0}; }
NS_INLINE GAPositionResult GAPositionHit(NSUInteger next) { return (GAPositionResult){YES, next}; }
@interface GAPositionRunner : NSObject {
    NSArray<GAOTLookup *> *_lookups;
    GAGDEF *_gdef;
    GALayoutMetrics *_metrics;
    GALayoutSettings *_settings;
    NSMutableArray<GALayoutItem *> *_buffer;
    GALayoutBudget *_budget;
    NSMutableDictionary<NSNumber *, GAPositionAttachment *> *_attachments;
    NSMutableSet<NSArray *> *_active;
}
- (instancetype)initWithLookups:(NSArray<GAOTLookup *> *)lookups
                           gdef:(GAGDEF *)gdef
                       settings:(GALayoutSettings *)settings
                        metrics:(GALayoutMetrics *)metrics
                         buffer:(NSMutableArray<GALayoutItem *> *)buffer;
- (void)run:(NSArray<GAOTLookupStep *> *)plan;
@end
@implementation GAPositionRunner
- (instancetype)initWithLookups:(NSArray<GAOTLookup *> *)lookups
                           gdef:(GAGDEF *)gdef
                       settings:(GALayoutSettings *)settings
                        metrics:(GALayoutMetrics *)metrics
                         buffer:(NSMutableArray<GALayoutItem *> *)buffer {
    if ((self = [super init])) {
        _lookups = lookups;
        _gdef = gdef;
        _settings = settings;
        _metrics = metrics;
        _buffer = buffer;
        _budget = [[GALayoutBudget alloc] initWithInput:buffer.count];
        _attachments = [NSMutableDictionary dictionary];
        _active = [NSMutableSet set];
    }
    return self;
}
- (NSUInteger)next:(NSUInteger)at lookup:(GAOTLookup *)lookup {
    for (NSUInteger i = at + 1; i < _buffer.count; i++)
        if ([_gdef includes:_buffer[i].glyph flags:lookup.flags markSet:lookup.markSet])
            return i;
    return NSNotFound;
}
- (GAPositionResult)pair:(GAOTSubtable *)sub lookup:(GAOTLookup *)lookup at:(NSUInteger)at {
    NSUInteger second = [self next:at lookup:lookup];
    if (second == NSNotFound)
        return GAPositionMiss();
    GATableView *data = sub.data;
    NSInteger ci = [sub.coverage index:_buffer[at].glyph];
    if (ci < 0)
        return GAPositionMiss();
    unsigned f1 = [data u16:4], f2 = [data u16:6];
    NSUInteger size1 = GAValueSize(f1), size2 = GAValueSize(f2);
    if ([data u16:0] == 1) {
        if ((NSUInteger)ci >= [data u16:8])
            return GAPositionMiss();
        GATableView *set = [data offset16:10 + ci * 2];
        unsigned count = [set u16:0];
        NSUInteger stride = 2 + size1 + size2;
        [set array:2 count:count stride:stride];
        NSUInteger lo = 0, hi = count;
        GAGlyph wanted = _buffer[second].glyph;
        while (lo < hi) {
            NSUInteger mid = (lo + hi) / 2, p = 2 + mid * stride;
            GAGlyph g = [set u16:p];
            if (g < wanted)
                lo = mid + 1;
            else
                hi = mid;
        }
        if (lo >= count || [set u16:2 + lo * stride] != wanted)
            return GAPositionMiss();
        NSUInteger p = 4 + lo * stride;
        GAReadValue(_buffer[at], set, p, f1, _gdef, _metrics);
        GAReadValue(_buffer[second], set, p + size1, f2, _gdef, _metrics);
    } else if ([data u16:0] == 2) {
        unsigned c1 = [[[GAClassDef alloc] initWithView:[data offset16:8]] value:_buffer[at].glyph],
                 c2 = [[[GAClassDef alloc] initWithView:[data offset16:10]]
                     value:_buffer[second].glyph],
                 n1 = [data u16:12], n2 = [data u16:14];
        if (c1 >= n1 || c2 >= n2)
            return GAPositionMiss();
        NSUInteger p = 16 + ((NSUInteger)c1 * n2 + c2) * (size1 + size2);
        GAReadValue(_buffer[at], data, p, f1, _gdef, _metrics);
        GAReadValue(_buffer[second], data, p + size1, f2, _gdef, _metrics);
    } else
        GAInvalidTable(@"unknown pair positioning format");
    return GAPositionHit(f2 ? second + 1 : at + 1);
}
- (void)attach:(NSUInteger)child
        parent:(NSUInteger)parent
         delta:(CGPoint)delta
       cursive:(BOOL)cursive {
    GAPositionAttachment *attachment = [GAPositionAttachment new];
    attachment.parent = parent;
    attachment.delta = delta;
    attachment.cursive = cursive;
    _attachments[@(child)] = attachment;
}
- (GAPositionResult)cursive:(GAOTSubtable *)sub lookup:(GAOTLookup *)lookup at:(NSUInteger)at {
    NSUInteger second = [self next:at lookup:lookup];
    if (second == NSNotFound)
        return GAPositionMiss();
    GATableView *data = sub.data;
    if ([data u16:0] != 1)
        GAInvalidTable(@"unknown cursive format");
    NSInteger a = [sub.coverage index:_buffer[at].glyph],
              b = [sub.coverage index:_buffer[second].glyph];
    if (a < 0 || b < 0 || (NSUInteger)a >= [data u16:4] || (NSUInteger)b >= [data u16:4])
        return GAPositionMiss();
    GAAnchor exit = GAReadAnchor([data offset16:8 + a * 4], _gdef, _metrics),
             entry = GAReadAnchor([data offset16:6 + b * 4], _gdef, _metrics);
    if (!exit.valid || !entry.valid)
        return GAPositionMiss();
    GALayoutItem *first = _buffer[at], *last = _buffer[second];
    if (_settings.vertical) {
        double firstY = exit.point.y + first.yOffset, secondY = entry.point.y + last.yOffset;
        if (!_settings.rtl) {
            first.yAdvance = firstY;
            last.yAdvance -= secondY;
            last.yOffset -= secondY;
        } else {
            first.yAdvance -= firstY;
            first.yOffset -= firstY;
            last.yAdvance = secondY;
        }
    } else if (!_settings.rtl) {
        first.xAdvance = exit.point.x + first.xOffset;
        double delta = entry.point.x + last.xOffset;
        last.xAdvance -= delta;
        last.xOffset -= delta;
    } else {
        double delta = exit.point.x + first.xOffset;
        first.xAdvance -= delta;
        first.xOffset -= delta;
        last.xAdvance = entry.point.x + last.xOffset;
    }
    if (lookup.flags & 1)
        [self attach:at
              parent:second
               delta:CGPointMake(entry.point.x - exit.point.x, entry.point.y - exit.point.y)
             cursive:YES];
    else
        [self attach:second
              parent:at
               delta:CGPointMake(exit.point.x - entry.point.x, exit.point.y - entry.point.y)
             cursive:YES];
    return GAPositionHit(at + 1);
}
- (GAPositionResult)mark:(GAOTSubtable *)sub at:(NSUInteger)at {
    GATableView *data = sub.data;
    if ([data u16:0] != 1)
        GAInvalidTable(@"unknown mark positioning format");
    NSInteger ci = [sub.coverage index:_buffer[at].glyph];
    if (ci < 0)
        return GAPositionMiss();
    GACoverage *targets = [[GACoverage alloc] initWithView:[data offset16:4]];
    unsigned classes = [data u16:6];
    GATableView *marks = [data offset16:8];
    if ((NSUInteger)ci >= [marks u16:0])
        return GAPositionMiss();
    unsigned markClass = [marks u16:2 + ci * 4];
    if (markClass >= classes)
        return GAPositionMiss();
    GAAnchor markAnchor = GAReadAnchor([marks offset16:4 + ci * 4], _gdef, _metrics);
    if (!markAnchor.valid)
        return GAPositionMiss();
    NSUInteger parent = NSNotFound;
    for (NSUInteger p = at; p > 0;) {
        --p;
        unsigned glyphClass = [_gdef.glyphClasses value:_buffer[p].glyph];
        if (sub.type != 6 && glyphClass == 3)
            continue;
        if (sub.type == 6 && glyphClass != 3)
            break;
        if ([targets contains:_buffer[p].glyph]) {
            parent = p;
            break;
        }
        if (sub.type != 6)
            break;
    }
    if (parent == NSNotFound)
        return GAPositionMiss();
    NSInteger targetIndex = [targets index:_buffer[parent].glyph];
    GATableView *array = [data offset16:10];
    if ((NSUInteger)targetIndex >= [array u16:0])
        return GAPositionMiss();
    GAAnchor base;
    if (sub.type == 5) {
        GATableView *ligature = [array offset16:2 + targetIndex * 2];
        unsigned components = [ligature u16:0];
        if (!components)
            return GAPositionMiss();
        unsigned component =
            _buffer[at].component >= 0 ? (unsigned)_buffer[at].component : components - 1;
        component = MIN(component, components - 1);
        base =
            GAReadAnchor([ligature offset16:2 + ((NSUInteger)component * classes + markClass) * 2],
                         _gdef, _metrics);
    } else
        base =
            GAReadAnchor([array offset16:2 + ((NSUInteger)targetIndex * classes + markClass) * 2],
                         _gdef, _metrics);
    if (!base.valid)
        return GAPositionMiss();
    [self attach:at
          parent:parent
           delta:CGPointMake(base.point.x - markAnchor.point.x, base.point.y - markAnchor.point.y)
         cursive:NO];
    return GAPositionHit(at + 1);
}
- (GAPositionResult)subtable:(GAOTSubtable *)sub lookup:(GAOTLookup *)lookup at:(NSUInteger)at {
    GATableView *data = sub.data;
    if (sub.type == 1) {
        NSInteger ci = [sub.coverage index:_buffer[at].glyph];
        if (ci < 0)
            return GAPositionMiss();
        unsigned format = [data u16:0], valueFormat = [data u16:4];
        NSUInteger p = 6;
        if (format == 2) {
            if ((NSUInteger)ci >= [data u16:6])
                return GAPositionMiss();
            p = 8 + (NSUInteger)ci * GAValueSize(valueFormat);
        } else if (format != 1)
            GAInvalidTable(@"unknown single positioning format");
        GAReadValue(_buffer[at], data, p, valueFormat, _gdef, _metrics);
        return GAPositionHit(at + 1);
    }
    if (sub.type == 2)
        return [self pair:sub lookup:lookup at:at];
    if (sub.type == 3)
        return [self cursive:sub lookup:lookup at:at];
    if (sub.type >= 4 && sub.type <= 6)
        return [self mark:sub at:at];
    for (NSNumber *number in sub.starts[@(_buffer[at].glyph)]) {
        [_budget step];
        GAOTPattern *pattern = sub.patterns[number.unsignedIntegerValue];
        NSArray<NSNumber *> *positions =
            GAMatchPattern(pattern, _buffer, at, _gdef, lookup.flags, lookup.markSet, NULL);
        if (!positions)
            continue;
        NSUInteger end = positions.lastObject.unsignedIntegerValue + 1;
        for (GAOTAction *record in pattern.actions)
            if (record.sequence < positions.count) {
                GAPositionResult nested =
                    [self apply:record.lookup at:positions[record.sequence].unsignedIntegerValue];
                if (nested.matched)
                    end = MAX(end, nested.next);
            }
        return GAPositionHit(end);
    }
    return GAPositionMiss();
}
- (GAPositionResult)apply:(unsigned)index at:(NSUInteger)at {
    [_budget step];
    NSArray *key = @[ @(index), @(at) ];
    if (index >= _lookups.count || at >= _buffer.count || _active.count >= 64 ||
        [_active containsObject:key])
        return GAPositionMiss();
    [_active addObject:key];
    GAOTLookup *lookup = _lookups[index];
    GAPositionResult result = GAPositionMiss();
    if ([_gdef includes:_buffer[at].glyph flags:lookup.flags markSet:lookup.markSet])
        for (GAOTSubtable *sub in lookup.subtables) {
            result = [self subtable:sub lookup:lookup at:at];
            if (result.matched)
                break;
        }
    [_active removeObject:key];
    return result;
}
- (CGPoint)pen:(NSUInteger)index {
    CGPoint point = CGPointZero;
    NSUInteger first = _settings.rtl ? index + 1 : 0, last = _settings.rtl ? _buffer.count : index;
    for (NSUInteger i = first; i < last; i++) {
        point.x += _buffer[i].xAdvance;
        point.y += _buffer[i].yAdvance;
    }
    return point;
}
- (void)resolve:(NSUInteger)index path:(NSMutableIndexSet *)path done:(NSMutableIndexSet *)done {
    if ([done containsIndex:index])
        return;
    GAPositionAttachment *attachment = _attachments[@(index)];
    if (!attachment)
        return;
    if ([path containsIndex:index]) {
        [_attachments removeObjectForKey:@(index)];
        return;
    }
    [path addIndex:index];
    [self resolve:attachment.parent path:path done:done];
    GALayoutItem *item = _buffer[index], *parent = _buffer[attachment.parent];
    if (attachment.cursive) {
        if (_settings.vertical)
            item.xOffset += parent.xOffset + attachment.delta.x;
        else
            item.yOffset += parent.yOffset + attachment.delta.y;
    } else {
        CGPoint p = [self pen:index], base = [self pen:attachment.parent];
        item.xOffset = base.x + parent.xOffset + attachment.delta.x - p.x;
        item.yOffset = base.y + parent.yOffset + attachment.delta.y - p.y;
    }
    [path removeIndex:index];
    [done addIndex:index];
}
- (void)run:(NSArray<GAOTLookupStep *> *)plan {
    for (GALayoutItem *item in _buffer) {
        item.xOffset = item.yOffset = 0;
        item.xAdvance = _settings.vertical ? 0 : _metrics.horizontalAdvance(item.glyph);
        item.yAdvance = _settings.vertical ? -_metrics.verticalAdvance(item.glyph) : 0;
        if ([_gdef.glyphClasses value:item.glyph] == 3)
            item.xAdvance = item.yAdvance = 0;
    }
    for (GAOTLookupStep *step in plan)
        for (NSUInteger i = 0; i < _buffer.count;) {
            GAPositionResult result = [self apply:step.lookup at:i];
            i = result.matched ? result.next : i + 1;
        }
    NSMutableIndexSet *done = [NSMutableIndexSet indexSet], *path = [NSMutableIndexSet indexSet];
    NSArray *keys = [_attachments.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *index in keys)
        [self resolve:index.unsignedIntegerValue path:path done:done];
}
@end
@implementation GAOpenType (Positioning)
- (void)positionBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                  gdef:(GAGDEF *)gdef
              settings:(GALayoutSettings *)settings
               metrics:(GALayoutMetrics *)metrics
                branch:(NSUInteger)branch {
    if (!self.positioning)
        GAInvalidTable(@"substitution program used for positioning");
    [[[GAPositionRunner alloc] initWithLookups:self.lookups
                                          gdef:gdef
                                      settings:settings
                                       metrics:metrics
                                        buffer:buffer] run:[self plan:settings branch:branch]];
}
@end
