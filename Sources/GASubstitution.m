#import "GAOpenType.h"
typedef struct {
    BOOL matched;
    NSUInteger next;
} GAApplied;
NS_INLINE GAApplied GANoMatch(void) { return (GAApplied){NO, 0}; }
NS_INLINE GAApplied GAWasApplied(NSUInteger next) { return (GAApplied){YES, next}; }

/// Mutable state belongs to one execution; shared table programs remain
/// read-only.
@interface GASubstitutionRunner : NSObject {
    NSArray<GAOTLookup *> *_lookups;
    GAGDEF *_gdef;
    NSMutableArray<GALayoutItem *> *_buffer;
    GALayoutTrace *_trace;
    GALayoutBudget *_budget;
    GATag _activeFeature;
    NSMutableArray<NSMutableArray<NSNumber *> *> *_frames;
    NSMutableArray<NSArray<NSNumber *> *> *_active;
    uint64_t _nextIdentity;
}
- (instancetype)initWithLookups:(NSArray<GAOTLookup *> *)lookups
                           gdef:(GAGDEF *)gdef
                         buffer:(NSMutableArray<GALayoutItem *> *)buffer
                          trace:(GALayoutTrace *)trace
                         budget:(GALayoutBudget *)budget;
- (void)run:(NSArray<GAOTLookupStep *> *)plan;
@end
@implementation GASubstitutionRunner
- (instancetype)initWithLookups:(NSArray<GAOTLookup *> *)lookups
                           gdef:(GAGDEF *)gdef
                         buffer:(NSMutableArray<GALayoutItem *> *)buffer
                          trace:(GALayoutTrace *)trace
                         budget:(GALayoutBudget *)budget {
    if (!(self = [super init]))
        return nil;
    _lookups = lookups;
    _gdef = gdef;
    _buffer = buffer;
    _trace = trace;
    _budget = budget ?: [[GALayoutBudget alloc] initWithInput:buffer.count];
    _frames = [NSMutableArray array];
    _active = [NSMutableArray array];
    _nextIdentity = 1;
    for (GALayoutItem *item in buffer) {
        if (!item.identity)
            item.identity = _nextIdentity++;
        else
            _nextIdentity = MAX(_nextIdentity, item.identity + 1);
    }
    return self;
}
- (void)splice:(NSUInteger)at
       removed:(NSUInteger)removed
      inserted:(NSArray<GALayoutItem *> *)inserted {
    if (at > _buffer.count || removed > _buffer.count - at)
        GAInvalidTable(@"substitution range outside buffer");
    [_budget growth:_buffer.count - removed + inserted.count];
    for (NSMutableArray<NSNumber *> *frame in _frames) {
        NSMutableArray *adjusted = [NSMutableArray array];
        BOOL replaced = NO;
        for (NSNumber *number in frame) {
            NSUInteger pos = number.unsignedIntegerValue;
            if (pos < at)
                [adjusted addObject:number];
            else if (pos >= at + removed)
                [adjusted addObject:@(pos - removed + inserted.count)];
            else if (!replaced) {
                for (NSUInteger j = 0; j < inserted.count; j++)
                    [adjusted addObject:@(at + j)];
                replaced = YES;
            }
        }
        [frame setArray:adjusted];
    }
    [_buffer replaceObjectsInRange:NSMakeRange(at, removed) withObjectsFromArray:inserted];
}
- (BOOL)allowed:(GALayoutItem *)item step:(GAOTLookupStep *)step {
    if (step.explicitValue)
        return YES;
    BOOL form = step.feature == GATagMake('i', 's', 'o', 'l') ||
                step.feature == GATagMake('i', 'n', 'i', 't') ||
                step.feature == GATagMake('m', 'e', 'd', 'i') ||
                step.feature == GATagMake('f', 'i', 'n', 'a');
    return !form || item.form == step.feature;
}
- (GAApplied)contextual:(GAOTPattern *)pattern
                 lookup:(GAOTLookup *)lookup
                     at:(NSUInteger)at
                   step:(GAOTLookupStep *)step {
    NSArray *input =
        GAMatchPattern(pattern, _buffer, at, _gdef, lookup.flags, lookup.markSet, NULL);
    if (!input)
        return GANoMatch();
    NSMutableArray<NSNumber *> *frame = [input mutableCopy];
    [_frames addObject:frame];
    for (GAOTAction *action in pattern.actions)
        if (action.sequence < frame.count)
            [self apply:action.lookup
                     at:frame[action.sequence].unsignedIntegerValue
                  value:step.value];
    NSUInteger next = frame.count ? frame.lastObject.unsignedIntegerValue + 1 : at;
    [_frames removeLastObject];
    return GAWasApplied(next);
}
- (GAApplied)ligate:(GAOTPattern *)pattern lookup:(GAOTLookup *)lookup at:(NSUInteger)at {
    NSArray<NSNumber *> *positions =
        GAMatchPattern(pattern, _buffer, at, _gdef, lookup.flags, lookup.markSet, NULL);
    if (!positions)
        return GANoMatch();
    GALayoutItem *ligature = [_buffer[at] copy];
    ligature.glyph = pattern.replacement.firstObject.unsignedShortValue;
    NSMutableArray<NSValue *> *components = [NSMutableArray array];
    for (NSNumber *number in positions) {
        GALayoutItem *item = _buffer[number.unsignedIntegerValue];
        if (item.components.count)
            [components addObjectsFromArray:item.components];
        else
            [components addObject:GASpanValue(item.source)];
    }
    ligature.components = components;
    GASpan merged = _buffer[positions.firstObject.unsignedIntegerValue].source;
    for (NSNumber *number in positions)
        merged = GAUnite(merged, _buffer[number.unsignedIntegerValue].source);
    ligature.source = merged;
    for (NSUInteger pos = positions.firstObject.unsignedIntegerValue;
         pos <= positions.lastObject.unsignedIntegerValue; pos++)
        if (![positions containsObject:@(pos)]) {
            GASpan original = _buffer[pos].source;
            unsigned component = 0;
            for (unsigned i = 0; i < components.count; i++)
                if (GASpanFromValue(components[i]).start <= original.start)
                    component = i;
            _buffer[pos].component = component;
            _buffer[pos].source = merged;
        }
    for (NSUInteger i = positions.count; i > 1; i--)
        [self splice:positions[i - 1].unsignedIntegerValue removed:1 inserted:@[]];
    [self splice:at removed:1 inserted:@[ ligature ]];
    return GAWasApplied(at + 1);
}
- (void)collect:(GAOTLookupStep *)step onlyAt:(NSNumber *)onlyAt {
    if (!_trace.inventory || _active.count >= 64)
        return;
    GAOTLookup *lookup = _lookups[step.lookup];
    NSArray<NSNumber *> *indices =
        onlyAt ? @[ onlyAt ] : GAVisible(_buffer, _gdef, lookup.flags, lookup.markSet);
    NSString *label = GATagName(step.feature);
    if (step.value > 1)
        label = [label stringByAppendingFormat:@" %u", step.value];
    for (GAOTSubtable *sub in lookup.subtables)
        for (NSNumber *number in indices) {
            NSUInteger start = number.unsignedIntegerValue;
            if (![self allowed:_buffer[start] step:step])
                continue;
            for (NSNumber *candidateIndex in sub.starts[@(_buffer[start].glyph)]) {
                [_budget step];
                GAOTPattern *pattern = sub.patterns[candidateIndex.unsignedIntegerValue];
                if (!GAMatchPattern(pattern, _buffer, start, _gdef, lookup.flags, lookup.markSet,
                                    NULL))
                    continue;
                NSMutableArray *candidate = GACopyBuffer(_buffer);
                GALayoutTrace *alternatives = [GALayoutTrace new];
                alternatives.inventory = YES;
                GASubstitutionRunner *preview =
                    [[GASubstitutionRunner alloc] initWithLookups:_lookups
                                                             gdef:_gdef
                                                           buffer:candidate
                                                            trace:alternatives
                                                           budget:_budget];
                preview->_active = [_active mutableCopy];
                preview->_activeFeature = step.feature;
                NSArray *key =
                    @[ @(step.lookup), @(_buffer[start].identity), @(_buffer[start].glyph) ];
                if (![preview->_active containsObject:key])
                    [preview->_active addObject:key];
                GAApplied result = GANoMatch();
                if (sub.type == 4)
                    result = [preview ligate:pattern lookup:lookup at:start];
                else if (sub.type == 5 || sub.type == 6)
                    result = [preview contextual:pattern lookup:lookup at:start step:step];
                if (result.matched) {
                    [_trace changed:_buffer after:candidate feature:label];
                    [_trace.changes addObjectsFromArray:alternatives.changes];
                }
            }
        }
}
- (GAApplied)subtable:(GAOTSubtable *)sub
               lookup:(GAOTLookup *)lookup
                   at:(NSUInteger)at
                 step:(GAOTLookupStep *)step {
    [_budget step];
    if (at >= _buffer.count)
        return GANoMatch();
    if (sub.type <= 3) {
        if ([sub.coverage index:_buffer[at].glyph] < 0)
            return GANoMatch();
        NSArray<NSNumber *> *outputs = GASubstitutionOutputs(sub, _buffer[at].glyph);
        if (sub.type == 3) {
            if (!step.value || step.value > outputs.count)
                return GANoMatch();
            outputs = @[ outputs[step.value - 1] ];
        }
        if (sub.type == 1 && !outputs.count)
            GAInvalidTable(@"invalid single substitution");
        NSMutableArray *inserted = [NSMutableArray array];
        for (NSUInteger i = 0; i < outputs.count; i++) {
            GALayoutItem *item = [_buffer[at] copy];
            item.glyph = outputs[i].unsignedShortValue;
            if (i)
                item.identity = _nextIdentity++;
            [inserted addObject:item];
        }
        NSUInteger next = at + inserted.count;
        [self splice:at removed:1 inserted:inserted];
        return GAWasApplied(next);
    }
    for (NSNumber *number in sub.starts[@(_buffer[at].glyph)]) {
        [_budget step];
        GAOTPattern *pattern = sub.patterns[number.unsignedIntegerValue];
        if (sub.type == 4) {
            GAApplied result = [self ligate:pattern lookup:lookup at:at];
            if (result.matched)
                return result;
        } else if (sub.type == 5 || sub.type == 6) {
            GAApplied result = [self contextual:pattern lookup:lookup at:at step:step];
            if (result.matched)
                return result;
        } else if (sub.type == 8) {
            if (!GAMatchPattern(pattern, _buffer, at, _gdef, lookup.flags, lookup.markSet, NULL))
                continue;
            GATableView *data = sub.data;
            NSUInteger p = 6 + [data u16:4] * 2;
            unsigned look = [data u16:p];
            p += 2 + look * 2;
            unsigned count = [data u16:p];
            NSInteger ci = [sub.coverage index:_buffer[at].glyph];
            if (ci < 0 || (NSUInteger)ci >= count)
                GAInvalidTable(@"reverse substitute exceeds coverage");
            _buffer[at].glyph = [data u16:p + 2 + ci * 2];
            return GAWasApplied(at + 1);
        }
    }
    return GANoMatch();
}
- (GAApplied)apply:(unsigned)index at:(NSUInteger)at value:(unsigned)value {
    if (index >= _lookups.count || at >= _buffer.count || _active.count >= 64)
        return GANoMatch();
    GAOTLookup *lookup = _lookups[index];
    if (![_gdef includes:_buffer[at].glyph flags:lookup.flags markSet:lookup.markSet])
        return GANoMatch();
    NSArray *key = @[ @(index), @(_buffer[at].identity), @(_buffer[at].glyph) ];
    if ([_active containsObject:key])
        return GANoMatch();
    [_active addObject:key];
    GAOTLookupStep *step = [GAOTLookupStep new];
    step.lookup = index;
    step.value = value;
    step.feature = _activeFeature;
    step.explicitValue = YES;
    [self collect:step onlyAt:@(at)];
    GAApplied result = GANoMatch();
    for (GAOTSubtable *sub in lookup.subtables) {
        result = [self subtable:sub lookup:lookup at:at step:step];
        if (result.matched)
            break;
    }
    [_active removeLastObject];
    return result;
}
- (void)run:(NSArray<GAOTLookupStep *> *)plan {
    for (GAOTLookupStep *step in plan) {
        _activeFeature = step.feature;
        GAOTLookup *lookup = _lookups[step.lookup];
        [self collect:step onlyAt:nil];
        NSArray *before = _trace ? GACopyBuffer(_buffer) : @[];
        if (lookup.reverse) {
            for (NSUInteger i = _buffer.count; i > 0; i--)
                if ([self allowed:_buffer[i - 1] step:step])
                    [self apply:step.lookup at:i - 1 value:step.value];
        } else
            for (NSUInteger i = 0; i < _buffer.count;) {
                [_budget step];
                if (![self allowed:_buffer[i] step:step]) {
                    i++;
                    continue;
                }
                GAApplied result = [self apply:step.lookup at:i value:step.value];
                i = result.matched ? result.next : i + 1;
            }
        if (_trace) {
            NSString *label = GATagName(step.feature);
            if (step.value > 1)
                label = [label stringByAppendingFormat:@" %u", step.value];
            [_trace changed:before after:_buffer feature:label];
        }
    }
}
@end
@implementation GAOpenType (Substitution)
- (void)substituteBuffer:(NSMutableArray<GALayoutItem *> *)buffer
                    gdef:(GAGDEF *)gdef
                settings:(GALayoutSettings *)settings
                  branch:(NSUInteger)branch
                   trace:(GALayoutTrace *)trace {
    [self substituteLookups:buffer gdef:gdef steps:[self plan:settings branch:branch] trace:trace];
}
- (void)substituteLookups:(NSMutableArray<GALayoutItem *> *)buffer
                     gdef:(GAGDEF *)gdef
                    steps:(NSArray<GAOTLookupStep *> *)steps
                    trace:(GALayoutTrace *)trace {
    if (self.positioning)
        GAInvalidTable(@"positioning program used for substitution");
    for (GAOTLookupStep *step in steps)
        if (step.lookup >= self.lookups.count)
            GAInvalidTable(@"lookup index outside list");
    [[[GASubstitutionRunner alloc] initWithLookups:self.lookups
                                              gdef:gdef
                                            buffer:buffer
                                             trace:trace
                                            budget:nil] run:steps];
}
@end
