#import "GAAAT.h"
static uint64_t GAUnsignedValue(GATableView *data, NSUInteger at, unsigned size) {
    if (size != 1 && size != 2 && size != 4 && size != 8)
        GAInvalidTable(@"unsupported Apple lookup value size");
    [data require:at count:size];
    uint64_t result = 0;
    for (unsigned i = 0; i < size; i++)
        result = (result << 8) | [data u8:at + i];
    return result;
}
NSNumber *GAAATLookup(GATableView *table, GAGlyph glyph, unsigned valueSize) {
    if (!table.present || glyph == 0xffff)
        return nil;
    unsigned format = [table u16:0];
    if (format == 0) {
        NSUInteger at = 2 + (NSUInteger)glyph * valueSize;
        if (at > table.length || valueSize > table.length - at)
            return nil;
        return @(GAUnsignedValue(table, at, valueSize));
    }
    if (format == 8 || format == 10) {
        unsigned size = format == 8 ? 2 : [table u16:2];
        NSUInteger firstAt = format == 8 ? 2 : 4;
        unsigned first = [table u16:firstAt], count = [table u16:firstAt + 2];
        if (glyph < first || (unsigned)glyph - first >= count)
            return nil;
        return @(GAUnsignedValue(table, firstAt + 4 + (NSUInteger)(glyph - first) * size, size));
    }
    if (format != 2 && format != 4 && format != 6)
        GAInvalidTable(@"unknown Apple lookup format");
    unsigned stride = [table u16:2], count = [table u16:4],
             required = format == 6   ? 2 + valueSize
                        : format == 4 ? 6
                                      : 4 + valueSize;
    if (stride < required)
        GAInvalidTable(@"short Apple lookup record");
    [table array:12 count:count stride:stride];
    NSUInteger lo = 0, hi = count;
    while (lo < hi) {
        NSUInteger mid = (lo + hi) / 2, p = 12 + mid * stride;
        unsigned last = [table u16:p], first = format == 6 ? last : [table u16:p + 2];
        if (glyph < first)
            hi = mid;
        else if (glyph > last)
            lo = mid + 1;
        else if (format == 4)
            return @(GAUnsignedValue(
                table, [table u16:p + 4] + (NSUInteger)(glyph - first) * valueSize, valueSize));
        else
            return @(GAUnsignedValue(table, p + (format == 6 ? 2 : 4), valueSize));
    }
    return nil;
}
@implementation GAAATSelector
+ (instancetype)type:(unsigned)type setting:(unsigned)setting {
    GAAATSelector *selector = [self new];
    selector.type = type;
    selector.setting = setting;
    return selector;
}
- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:GAAATSelector.class] && _type == [(GAAATSelector *)object type] &&
           _setting == [(GAAATSelector *)object setting];
}
- (NSUInteger)hash {
    return ((NSUInteger)_type << 16) ^ _setting;
}
@end
@interface GAAATSubtable : NSObject
@property(nonatomic) unsigned type;
@property(nonatomic) uint32_t coverage, flags;
@property(nonatomic, strong) GATableView *data;
@end
@implementation GAAATSubtable
@end
@interface GAAATFeature : NSObject
@property(nonatomic, strong) GAAATSelector *selector;
@property(nonatomic) uint32_t enable, disable;
@end
@implementation GAAATFeature
@end
@interface GAAATChain : NSObject
@property(nonatomic) uint32_t defaults;
@property(nonatomic, copy) NSArray<GAAATFeature *> *features;
@property(nonatomic, copy) NSArray<GAAATSubtable *> *subtables;
@end
@implementation GAAATChain
@end
typedef struct {
    unsigned state, flags, first, second;
} GAAATEntry;
@interface GAAATMachine : NSObject {
    GATableView *_data;
    BOOL _extended;
    unsigned _type, _classes;
    NSUInteger _classOffset, _stateOffset, _entryOffset;
}
- (instancetype)initWithView:(GATableView *)data extended:(BOOL)extended type:(unsigned)type;
- (unsigned)glyphClass:(GAGlyph)glyph;
- (GAAATEntry)entry:(unsigned)state class:(unsigned)cls;
- (BOOL)actionable:(GAAATEntry)entry;
- (NSNumber *)contextual:(unsigned)index glyph:(GAGlyph)glyph;
- (uint32_t)ligatureAction:(NSUInteger)index;
- (unsigned)component:(int64_t)glyphPlusOffset;
- (GAGlyph)ligature:(NSUInteger)index;
- (NSArray<NSNumber *> *)insertion:(unsigned)index count:(unsigned)count;
@end
@implementation GAAATMachine
- (unsigned)word:(unsigned)field {
    return _extended ? [_data u32:field * 4] : [_data u16:field * 2];
}
- (instancetype)initWithView:(GATableView *)data extended:(BOOL)extended type:(unsigned)type {
    if (!(self = [super init]))
        return nil;
    _data = data;
    _extended = extended;
    _type = type;
    _classes = [self word:0];
    _classOffset = [self word:1];
    _stateOffset = [self word:2];
    _entryOffset = [self word:3];
    if (_classes < 4)
        GAInvalidTable(@"state machine omits predefined classes");
    [data require:_classOffset count:extended ? 2 : 4];
    [data require:_stateOffset count:0];
    [data require:_entryOffset count:0];
    return self;
}
- (unsigned)glyphClass:(GAGlyph)glyph {
    if (glyph == 0xffff)
        return 2;
    unsigned result = 1;
    if (_extended) {
        NSNumber *value = GAAATLookup([_data at:_classOffset], glyph, 2);
        if (value)
            result = value.unsignedIntValue;
    } else {
        unsigned first = [_data u16:_classOffset], count = [_data u16:_classOffset + 2];
        if (glyph >= first && glyph - first < count)
            result = [_data u8:_classOffset + 4 + glyph - first];
    }
    return result < _classes ? result : 1;
}
- (GAAATEntry)entry:(unsigned)state class:(unsigned)cls {
    NSUInteger index = (NSUInteger)state * _classes + cls,
               at = _stateOffset + index * (_extended ? 2 : 1);
    unsigned ei = _extended ? [_data u16:at] : [_data u8:at], stride = _type == 0 ? 4
                                                                       : _type == 2
                                                                           ? (_extended ? 6 : 4)
                                                                           : 8;
    GATableView *record = [_data slice:_entryOffset + (NSUInteger)ei * stride length:stride];
    unsigned raw = [record u16:0];
    GAAATEntry entry = {0, [record u16:2], 0xffff, 0xffff};
    if (_extended)
        entry.state = raw;
    else {
        if (raw < _stateOffset || (raw - _stateOffset) % _classes)
            GAInvalidTable(@"unaligned legacy state row");
        entry.state = (unsigned)((raw - _stateOffset) / _classes);
    }
    if (stride >= 6)
        entry.first = [record u16:4];
    if (stride >= 8)
        entry.second = [record u16:6];
    return entry;
}
- (BOOL)actionable:(GAAATEntry)entry {
    if (_type == 0)
        return (entry.flags & 15) != 0;
    if (_type == 1)
        return _extended ? (entry.first != 0xffff || entry.second != 0xffff)
                         : (entry.first != 0 || entry.second != 0);
    if (_type == 2)
        return (_extended ? (entry.flags & 0x2000) : (entry.flags & 0x3fff)) != 0;
    return (entry.flags & 0x3ff) != 0;
}
- (NSNumber *)contextual:(unsigned)index glyph:(GAGlyph)glyph {
    if (_extended) {
        if (index == 0xffff)
            return nil;
        GATableView *list = [_data at:[self word:4]];
        NSNumber *value = GAAATLookup([list offset32:(NSUInteger)index * 4], glyph, 2);
        return value ? @((GAGlyph)value.unsignedLongLongValue) : nil;
    }
    if (!index)
        return nil;
    int64_t at = 2 * ((int64_t)(int16_t)index + glyph);
    if (at < 0)
        GAInvalidTable(@"negative legacy substitution offset");
    GAGlyph g = [_data u16:(NSUInteger)at];
    return g ? @(g) : nil;
}
- (uint32_t)ligatureAction:(NSUInteger)index {
    return [_data u32:_extended ? [self word:4] + index * 4 : index];
}
- (unsigned)component:(int64_t)glyphPlusOffset {
    int64_t at = _extended ? (int64_t)[self word:5] + 2 * glyphPlusOffset : 2 * glyphPlusOffset;
    if (at < 0)
        GAInvalidTable(@"negative ligature component offset");
    return [_data u16:(NSUInteger)at];
}
- (GAGlyph)ligature:(NSUInteger)index {
    return [_data u16:_extended ? [self word:6] + index * 2 : index];
}
- (NSArray<NSNumber *> *)insertion:(unsigned)index count:(unsigned)count {
    if (!count || (_extended ? index == 0xffff : index == 0))
        return @[];
    NSUInteger at = _extended ? [self word:4] + (NSUInteger)index * 2 : index;
    [_data array:at count:count stride:2];
    NSMutableArray *result = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++)
        [result addObject:@([_data u16:at + i * 2])];
    return result;
}
@end
static void GAReverseBuffer(NSMutableArray *buffer) {
    [buffer setArray:buffer.reverseObjectEnumerator.allObjects];
}
@interface GAAATRunner : NSObject {
    NSMutableArray<GALayoutItem *> *_buffer;
    GALayoutTrace *_trace;
    GALayoutBudget *_budget;
    uint64_t _nextIdentity;
    NSUInteger _mark, _first, _last;
    BOOL _marked;
    NSMutableArray<NSNumber *> *_stack;
}
- (instancetype)initWithBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                         trace:(GALayoutTrace *)trace
                        budget:(GALayoutBudget *)budget;
- (void)run:(GATableView *)data type:(unsigned)type extended:(BOOL)extended;
- (void)discover:(GATableView *)data
            type:(unsigned)type
        extended:(BOOL)extended
           label:(NSString *)label;
@end
@implementation GAAATRunner
- (instancetype)initWithBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                         trace:(GALayoutTrace *)trace
                        budget:(GALayoutBudget *)budget {
    if ((self = [super init])) {
        _buffer = buffer;
        _trace = trace;
        _budget = budget ?: [[GALayoutBudget alloc] initWithInput:buffer.count];
        _nextIdentity = 1;
        _stack = [NSMutableArray array];
        for (GALayoutItem *item in buffer) {
            if (!item.identity)
                item.identity = _nextIdentity++;
            else
                _nextIdentity = MAX(_nextIdentity, item.identity + 1);
        }
    }
    return self;
}
- (NSUInteger)locate:(uint64_t)identity {
    for (NSUInteger i = 0; i < _buffer.count; i++)
        if (_buffer[i].identity == identity)
            return i;
    return _buffer.count;
}
- (void)merge:(NSUInteger)first last:(NSUInteger)last {
    if (first >= last || last > _buffer.count)
        return;
    GASpan span = _buffer[first].source;
    for (NSUInteger i = first + 1; i < last; i++)
        span = GAUnite(span, _buffer[i].source);
    for (NSUInteger i = first; i < last; i++)
        _buffer[i].source = span;
}
- (void)rearrange:(unsigned)verb {
    if (_first >= _last || _last > _buffer.count)
        return;
    static const unsigned heads[] = {0, 1, 0, 1, 2, 2, 0, 0, 1, 1, 2, 2, 2, 2, 2, 2},
                          tails[] = {0, 0, 1, 1, 0, 0, 2, 2, 2, 2, 1, 1, 2, 2, 2, 2};
    unsigned h = heads[verb], t = tails[verb];
    if (_last - _first < h + t)
        return;
    [self merge:_first last:_last];
    NSMutableArray *head = [[_buffer subarrayWithRange:NSMakeRange(_first, h)] mutableCopy],
                   *tail = [[_buffer subarrayWithRange:NSMakeRange(_last - t, t)] mutableCopy];
    if (verb == 5 || verb == 11 || verb == 13 || verb == 15)
        GAReverseBuffer(head);
    if (verb == 7 || verb == 9 || verb == 14 || verb == 15)
        GAReverseBuffer(tail);
    NSMutableArray *result = [tail mutableCopy];
    [result addObjectsFromArray:[_buffer subarrayWithRange:NSMakeRange(_first + h,
                                                                       _last - t - _first - h)]];
    [result addObjectsFromArray:head];
    [_buffer replaceObjectsInRange:NSMakeRange(_first, _last - _first) withObjectsFromArray:result];
}
- (void)contextual:(GAAATMachine *)machine entry:(GAAATEntry)entry cursor:(NSUInteger)cursor {
    if (!_buffer.count || (cursor == _buffer.count && !_marked))
        return;
    if (_marked && _mark < _buffer.count) {
        NSNumber *g = [machine contextual:entry.first glyph:_buffer[_mark].glyph];
        if (g)
            _buffer[_mark].glyph = g.unsignedShortValue;
    }
    if (cursor < _buffer.count) {
        NSNumber *g = [machine contextual:entry.second glyph:_buffer[cursor].glyph];
        if (g)
            _buffer[cursor].glyph = g.unsignedShortValue;
    }
    if (entry.flags & 0x8000) {
        _mark = cursor;
        _marked = YES;
    }
}
- (void)ligate:(GAAATMachine *)machine
         entry:(GAAATEntry)entry
        cursor:(NSUInteger)cursor
      extended:(BOOL)extended {
    if ((entry.flags & 0x8000) && cursor < _buffer.count) {
        NSNumber *identity = @(_buffer[cursor].identity);
        if (![_stack.lastObject isEqual:identity])
            [_stack addObject:identity];
    }
    if (!(extended ? (entry.flags & 0x2000) : (entry.flags & 0x3fff)))
        return;
    NSUInteger actionAt = extended ? entry.first : (entry.flags & 0x3fff);
    unsigned accumulated = 0;
    NSMutableArray<NSNumber *> *pending = [NSMutableArray array];
    while (_stack.count) {
        [_budget step];
        NSUInteger pos = [self locate:_stack.lastObject.unsignedLongLongValue];
        [_stack removeLastObject];
        if (pos >= _buffer.count)
            continue;
        uint32_t value = [machine ligatureAction:actionAt];
        actionAt += extended ? 1 : 4;
        int32_t offset = (int32_t)(value & 0x3fffffff);
        if (offset & 0x20000000)
            offset |= (int32_t)0xc0000000;
        accumulated += [machine component:(int64_t)_buffer[pos].glyph + offset];
        [pending addObject:@(pos)];
        if (value & 0xc0000000) {
            GAGlyph glyph = [machine ligature:accumulated];
            GASpan source = _buffer[pos].source;
            NSUInteger low = pos, high = pos;
            for (NSNumber *number in pending) {
                NSUInteger p = number.unsignedIntegerValue;
                source = GAUnite(source, _buffer[p].source);
                low = MIN(low, p);
                high = MAX(high, p);
                if (p != pos)
                    _buffer[p].glyph = 0xffff;
            }
            NSMutableArray *components = [NSMutableArray array];
            for (NSNumber *number in pending.reverseObjectEnumerator) {
                GALayoutItem *item = _buffer[number.unsignedIntegerValue];
                if (item.components.count)
                    [components addObjectsFromArray:item.components];
                else
                    [components addObject:GASpanValue(item.source)];
            }
            _buffer[pos].glyph = glyph;
            _buffer[pos].source = source;
            _buffer[pos].components = components;
            for (NSUInteger p = low; p <= high; p++)
                _buffer[p].source = source;
            [pending setArray:@[ @(pos) ]];
        }
        if (value & 0x80000000) {
            if (pending.count)
                [_stack addObject:@(_buffer[pending.lastObject.unsignedIntegerValue].identity)];
            break;
        }
    }
}
- (NSUInteger)insert:(GAAATMachine *)machine
               index:(unsigned)index
               count:(unsigned)count
            position:(NSUInteger)position
              before:(BOOL)before
               owner:(GASpan)owner {
    if (position >= _buffer.count)
        return 0;
    NSArray<NSNumber *> *glyphs = [machine insertion:index count:count];
    if (!glyphs.count)
        return 0;
    GALayoutItem *basis = [_buffer[position] copy];
    basis.source = owner;
    NSMutableArray *added = [NSMutableArray array];
    for (NSNumber *glyph in glyphs) {
        GALayoutItem *item = [basis copy];
        item.glyph = glyph.unsignedShortValue;
        item.identity = _nextIdentity++;
        [added addObject:item];
    }
    [_budget growth:_buffer.count + added.count];
    NSUInteger at = position + (before ? 0 : 1);
    [_buffer replaceObjectsInRange:NSMakeRange(at, 0) withObjectsFromArray:added];
    if (_mark >= at)
        _mark += added.count;
    return added.count;
}
- (NSUInteger)insertion:(GAAATMachine *)machine entry:(GAAATEntry)entry cursor:(NSUInteger)cursor {
    if (cursor >= _buffer.count) {
        if (_marked && _mark < _buffer.count)
            [self insert:machine
                   index:entry.second
                   count:entry.flags & 31
                position:_mark
                  before:(entry.flags & 0x400) != 0
                   owner:_buffer[_mark].source];
        return _buffer.count;
    }
    uint64_t currentIdentity = _buffer[cursor].identity;
    GASpan currentSource = _buffer[cursor].source;
    NSUInteger originalMark = _mark;
    BOOL setMark = (entry.flags & 0x8000) != 0;
    unsigned markedCount = entry.flags & 31, currentCount = (entry.flags >> 5) & 31;
    if (markedCount && originalMark < _buffer.count) {
        GASpan source = (entry.flags & 0x1000) ? _buffer[originalMark].source : currentSource;
        [self insert:machine
               index:entry.second
               count:markedCount
            position:originalMark
              before:(entry.flags & 0x400) != 0
               owner:source];
    }
    cursor = [self locate:currentIdentity];
    if (cursor >= _buffer.count)
        return cursor;
    if (setMark) {
        _mark = cursor;
        _marked = YES;
    }
    if (currentCount) {
        GASpan source = currentSource;
        if (!(entry.flags & 0x2000) && _marked && _mark < _buffer.count)
            source = _buffer[_mark].source;
        BOOL before = (entry.flags & 0x800) != 0;
        NSUInteger count = [self insert:machine
                                  index:entry.first
                                  count:currentCount
                               position:cursor
                                 before:before
                                  owner:source];
        if (count) {
            NSUInteger now = [self locate:currentIdentity];
            return (entry.flags & 0x4000) ? (before ? cursor : now + 1)
                                          : (before ? now : now + count);
        }
    }
    return [self locate:currentIdentity];
}
- (void)action:(GAAATMachine *)machine
         entry:(GAAATEntry)entry
        cursor:(NSUInteger *)cursor
          type:(unsigned)type
      extended:(BOOL)extended {
    if (type == 0) {
        if (entry.flags & 0x8000)
            _first = *cursor;
        if (entry.flags & 0x2000)
            _last = MIN(*cursor + 1, _buffer.count);
        if (entry.flags & 15)
            [self rearrange:entry.flags & 15];
    } else if (type == 1)
        [self contextual:machine entry:entry cursor:*cursor];
    else if (type == 2)
        [self ligate:machine entry:entry cursor:*cursor extended:extended];
    else if (type == 5)
        *cursor = [self insertion:machine entry:entry cursor:*cursor];
}
- (void)terminal:(GAAATMachine *)machine
           state:(unsigned)state
          cursor:(NSUInteger)cursor
            type:(unsigned)type
        extended:(BOOL)extended
           label:(NSString *)label {
    if (!cursor || cursor >= _buffer.count ||
        _buffer[cursor - 1].source.end > _buffer[cursor].source.start)
        return;
    GAAATEntry ending = [machine entry:state class:0];
    if (![machine actionable:ending])
        return;
    [_budget step];
    NSMutableArray *prefix = GACopyBuffer([_buffer subarrayWithRange:NSMakeRange(0, cursor)]);
    NSArray *before = GACopyBuffer(prefix);
    GAAATRunner *trial = [[GAAATRunner alloc] initWithBuffer:prefix trace:nil budget:_budget];
    trial->_mark = _mark;
    trial->_first = _first;
    trial->_last = _last;
    trial->_marked = _marked;
    trial->_stack = [_stack mutableCopy];
    trial->_nextIdentity = _nextIdentity;
    [trial action:machine entry:ending cursor:&cursor type:type extended:extended];
    [_trace changed:before after:prefix feature:label];
}
- (void)runMachine:(GAAATMachine *)machine
              type:(unsigned)type
          extended:(BOOL)extended
             start:(NSUInteger)start
             label:(NSString *)label {
    unsigned state = 0;
    NSUInteger cursor = start;
    _mark = _first = _last = start;
    _marked = NO;
    [_stack removeAllObjects];
    while (cursor <= _buffer.count) {
        [_budget step];
        BOOL end = cursor == _buffer.count;
        if (label && !end)
            [self terminal:machine
                     state:state
                    cursor:cursor
                      type:type
                  extended:extended
                     label:label];
        unsigned cls = end ? 0 : [machine glyphClass:_buffer[cursor].glyph];
        GAAATEntry entry = [machine entry:state class:cls];
        NSArray *before = label && [machine actionable:entry] ? GACopyBuffer(_buffer) : @[];
        [self action:machine entry:entry cursor:&cursor type:type extended:extended];
        if (before.count)
            [_trace changed:before after:_buffer feature:label];
        state = entry.state;
        if (end)
            break;
        if (!(entry.flags & 0x4000))
            cursor++;
    }
}
- (void)run:(GATableView *)data type:(unsigned)type extended:(BOOL)extended {
    if (type == 4) {
        for (GALayoutItem *item in _buffer) {
            NSNumber *value = GAAATLookup(data, item.glyph, 2);
            if (value)
                item.glyph = value.unsignedShortValue;
        }
    } else
        [self runMachine:[[GAAATMachine alloc] initWithView:data extended:extended type:type]
                    type:type
                extended:extended
                   start:0
                   label:nil];
}
- (void)discover:(GATableView *)data
            type:(unsigned)type
        extended:(BOOL)extended
           label:(NSString *)label {
    if (type == 4)
        return;
    GAAATMachine *machine = [[GAAATMachine alloc] initWithView:data extended:extended type:type];
    for (NSUInteger start = 0; start < _buffer.count; start++) {
        [_budget step];
        GAAATEntry root = [machine entry:0 class:[machine glyphClass:_buffer[start].glyph]];
        if (!root.state && ![machine actionable:root] && !root.flags)
            continue;
        NSMutableArray *candidate = GACopyBuffer(_buffer);
        GAAATRunner *matcher = [[GAAATRunner alloc] initWithBuffer:candidate
                                                             trace:_trace
                                                            budget:_budget];
        [matcher runMachine:machine type:type extended:extended start:start label:label];
    }
}
@end
@implementation GAAAT {
    BOOL _extended;
    NSArray<GAAATChain *> *_chains;
}
- (instancetype)initWithView:(GATableView *)table extended:(BOOL)extended {
    if (!(self = [super init]))
        return nil;
    _extended = extended;
    _chains = @[];
    _selectors = @[];
    if (!table.present)
        return self;
    unsigned version = [table u32:0] >> 16;
    if ((extended && version != 2 && version != 3) || (!extended && version != 1))
        GAInvalidTable(@"unknown metamorphosis version");
    NSUInteger at = 8;
    unsigned count = [table u32:4];
    NSMutableArray *chains = [NSMutableArray array], *selectors = [NSMutableArray array];
    for (unsigned ci = 0; ci < count; ci++) {
        GATableView *tail = [table at:at];
        unsigned header = extended ? 16 : 12, length = [tail u32:4];
        if (length < header)
            GAInvalidTable(@"short metamorphosis chain");
        GATableView *body = [tail slice:0 length:length];
        GAAATChain *chain = [GAAATChain new];
        chain.defaults = [body u32:0];
        unsigned featureCount = extended ? [body u32:8] : [body u16:8],
                 subtableCount = extended ? [body u32:12] : [body u16:10];
        [body array:header count:featureCount stride:12];
        NSUInteger pos = header;
        NSMutableArray *features = [NSMutableArray array], *subtables = [NSMutableArray array];
        for (unsigned fi = 0; fi < featureCount; fi++, pos += 12) {
            GAAATFeature *f = [GAAATFeature new];
            f.selector = [GAAATSelector type:[body u16:pos] setting:[body u16:pos + 2]];
            f.enable = [body u32:pos + 4];
            f.disable = [body u32:pos + 8];
            [features addObject:f];
            if (![selectors containsObject:f.selector])
                [selectors addObject:f.selector];
        }
        for (unsigned si = 0; si < subtableCount; si++) {
            unsigned sh = extended ? 12 : 8;
            [body require:pos count:sh];
            unsigned size = extended ? [body u32:pos] : [body u16:pos];
            if (size < sh)
                GAInvalidTable(@"short metamorphosis subtable");
            GATableView *sub = [body slice:pos length:size];
            uint32_t coverage = extended ? [sub u32:4] : (uint32_t)[sub u16:2] << 16;
            unsigned type = extended ? (coverage & 255) : ([sub u16:2] & 7);
            coverage &= 0xffff0000;
            if (type != 0 && type != 1 && type != 2 && type != 4 && type != 5)
                GAInvalidTable(@"unknown metamorphosis subtable type");
            GAAATSubtable *s = [GAAATSubtable new];
            s.type = type;
            s.coverage = coverage;
            s.flags = [sub u32:extended ? 8 : 4];
            s.data = [sub at:sh];
            [subtables addObject:s];
            pos += size;
        }
        chain.features = features;
        chain.subtables = subtables;
        [chains addObject:chain];
        at += length;
    }
    _chains = chains;
    _selectors = selectors;
    return self;
}
- (BOOL)empty {
    return !_chains.count;
}
- (NSString *)name {
    return _extended ? @"morx" : @"mort";
}
- (BOOL)hasVerticalSubstitutions {
    for (GAAATChain *chain in _chains) {
        for (GAAATFeature *feature in chain.features)
            if (feature.selector.type == 4)
                return YES;
        for (GAAATSubtable *sub in chain.subtables)
            if (!(sub.coverage & 0x20000000) && (sub.coverage & 0x80000000))
                return YES;
    }
    return NO;
}
- (void)substituteBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                selector:(GAAATSelector *)selector
                     rtl:(BOOL)rtl
                vertical:(BOOL)vertical
                   trace:(GALayoutTrace *)trace
            verticalOnly:(BOOL)verticalOnly {
    [self applyFeatures:selector ? @[ selector ] : @[]
                 buffer:buffer
                    rtl:rtl
               vertical:vertical
                  trace:trace
           verticalOnly:verticalOnly];
}
- (void)applyFeatures:(NSArray<GAAATSelector *> *)selectors
               buffer:(NSMutableArray<GALayoutItem *> *)buffer
                  rtl:(BOOL)rtl
             vertical:(BOOL)vertical
                trace:(GALayoutTrace *)trace
         verticalOnly:(BOOL)verticalOnly {
    NSString *label = self.name;
    for (GAAATSelector *selector in selectors)
        label = [label stringByAppendingFormat:@":%u:%u", selector.type, selector.setting];
    NSArray *original = trace.inventory ? GACopyBuffer(buffer) : @[];
    NSArray<GALayoutCluster *> *originalClusters = GAClusters(original);
    GALayoutBudget *discoveryBudget = [[GALayoutBudget alloc] initWithInput:buffer.count];
    NSMutableSet<NSArray *> *recorded = [NSMutableSet set];
    for (GAAATChain *chain in _chains) {
        uint32_t flags = chain.defaults;
        for (GAAATFeature *feature in chain.features)
            if ([selectors containsObject:feature.selector])
                flags = (flags & feature.disable) | feature.enable;
        for (GAAATSubtable *sub in chain.subtables) {
            if (!(sub.flags & flags))
                continue;
            if (verticalOnly) {
                BOOL directional = !(sub.coverage & 0x20000000) && (sub.coverage & 0x80000000);
                BOOL selected = NO;
                for (GAAATSelector *selector in selectors)
                    if (selector.type == 4)
                        selected = YES;
                selected = selected && (sub.flags & flags & ~chain.defaults);
                if (!directional && !selected)
                    continue;
            }
            if (!(sub.coverage & 0x20000000) && ((sub.coverage & 0x80000000) != 0) != vertical)
                continue;
            BOOL reverse =
                ((sub.coverage & 0x40000000) != 0) ^ ((sub.coverage & 0x10000000) ? NO : rtl);
            NSArray *before = trace ? GACopyBuffer(buffer) : @[];
            if (reverse)
                GAReverseBuffer(buffer);
            @try {
                if (trace.inventory) {
                    NSUInteger prior = trace.changes.count;
                    void (^append)(GALayoutChange *) = ^(GALayoutChange *change) {
                        NSArray *key = @[ GASpanKey(change.source), change.glyphs, change.feature ];
                        if (![recorded containsObject:key]) {
                            [recorded addObject:key];
                            [trace.changes addObject:change];
                        }
                    };
                    void (^mapped)(GASpan, NSArray<NSNumber *> *) =
                        ^(GASpan source, NSArray<NSNumber *> *glyphs) {
                            NSMutableArray *output = [glyphs mutableCopy];
                            for (NSUInteger i = 0; i < output.count; i++) {
                                NSNumber *value =
                                    GAAATLookup(sub.data, [output[i] unsignedShortValue], 2);
                                if (value)
                                    output[i] = @((GAGlyph)value.unsignedLongLongValue);
                            }
                            if (![output isEqual:glyphs]) {
                                GALayoutChange *change = [GALayoutChange new];
                                change.source = source;
                                change.glyphs = output;
                                change.feature = label;
                                append(change);
                            }
                        };
                    void (^explore)(NSMutableArray<GALayoutItem *> *) = ^(
                        NSMutableArray<GALayoutItem *> *candidate) {
                        NSArray *input = GACopyBuffer(candidate);
                        GALayoutTrace *found = [GALayoutTrace new];
                        GAAATRunner *matcher = [[GAAATRunner alloc] initWithBuffer:candidate
                                                                             trace:found
                                                                            budget:discoveryBudget];
                        [matcher discover:sub.data
                                     type:sub.type
                                 extended:self->_extended
                                    label:label];
                        GAAATRunner *runner = [[GAAATRunner alloc] initWithBuffer:candidate
                                                                            trace:nil
                                                                           budget:discoveryBudget];
                        [runner run:sub.data type:sub.type extended:self->_extended];
                        [found changed:input after:candidate feature:label];
                        for (GALayoutChange *change in found.changes) {
                            if (reverse)
                                change.glyphs = change.glyphs.reverseObjectEnumerator.allObjects;
                            append(change);
                        }
                    };
                    if (sub.type == 4) {
                        for (GALayoutCluster *cluster in originalClusters)
                            mapped(cluster.source, cluster.glyphs);
                        for (GALayoutCluster *cluster in GAClusters(buffer))
                            mapped(cluster.source,
                                   reverse ? cluster.glyphs.reverseObjectEnumerator.allObjects
                                           : cluster.glyphs);
                    } else
                        explore(GACopyBuffer(buffer));
                    NSMutableArray<GALayoutItem *> *input = GACopyBuffer(original);
                    if (reverse)
                        GAReverseBuffer(input);
                    BOOL same = input.count == buffer.count;
                    if (same)
                        for (NSUInteger i = 0; i < input.count; i++)
                            if (input[i].glyph != buffer[i].glyph ||
                                !GASpanEqual(input[i].source, buffer[i].source)) {
                                same = NO;
                                break;
                            }
                    if (!same && sub.type != 4)
                        explore(input);
                    NSMutableSet *visited = [NSMutableSet set];
                    for (NSUInteger i = 0; i < prior; i++) {
                        GALayoutChange *previous = trace.changes[i];
                        NSArray *key = @[ GASpanKey(previous.source), previous.glyphs ];
                        if (!previous.glyphs.count || [visited containsObject:key])
                            continue;
                        [visited addObject:key];
                        if (sub.type == 4) {
                            mapped(previous.source, previous.glyphs);
                            continue;
                        }
                        NSMutableArray *candidate = [NSMutableArray array];
                        for (NSNumber *glyph in previous.glyphs) {
                            GALayoutItem *item = [GALayoutItem new];
                            item.glyph = glyph.unsignedShortValue;
                            item.source = previous.source;
                            [candidate addObject:item];
                        }
                        if (reverse)
                            GAReverseBuffer(candidate);
                        explore(candidate);
                    }
                }
                [[[GAAATRunner alloc] initWithBuffer:buffer trace:trace budget:nil] run:sub.data
                                                                                   type:sub.type
                                                                               extended:_extended];
            } @catch (NSException *error) {
                if (![error.name isEqual:@"GAInvalidFontTable"])
                    @throw;
                GAInvalidTable([NSString
                    stringWithFormat:@"%@ type %u: %@", self.name, sub.type, error.reason]);
            }
            if (reverse)
                GAReverseBuffer(buffer);
            if (trace)
                [trace changed:before after:buffer feature:label];
        }
    }
    NSIndexSet *deleted = [buffer
        indexesOfObjectsPassingTest:^BOOL(GALayoutItem *item, NSUInteger index, BOOL *stop) {
            (void)index;
            (void)stop;
            return item.glyph == 0xffff;
        }];
    [buffer removeObjectsAtIndexes:deleted];
}
@end
