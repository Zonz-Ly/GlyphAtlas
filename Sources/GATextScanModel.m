#import "GATextScanModel.h"

@implementation GATextScanSubitem
@end

@implementation GATextScanItem
- (instancetype)init {
    self = [super init];
    if (self) {
        _subitems = [NSMutableArray array];
    }
    return self;
}
@end

@implementation GATextScanGroup
- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [NSMutableArray array];
    }
    return self;
}
@end

@interface GATextScanModel () {
    GAFontDocument *_fontDocument;
    NSMutableArray<GACharacterGroup *> *_groups;
    NSMutableArray<GATextScanGroup *> *_scanGroups;
    NSMutableDictionary<NSString *, GARawScanResult *> *_cache;
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *_singleGroupIndicesByContent;
}
- (BOOL)hasPendingSubitems;
@end

@implementation GATextScanModel

- (instancetype)initWithFontDocument:(GAFontDocument *)fontDocument {
    self = [super init];
    if (self) {
        _fontDocument = fontDocument;
        _text = @"";
        _groups = [NSMutableArray array];
        _scanGroups = [NSMutableArray array];
        _cache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (GARawScanResult *)cachedResultForContent:(NSString *)content {
    GARawScanResult *raw = _cache[content];
    if (raw == nil) return nil;
    GARawScanResult *rebound = [_fontDocument rebindResult:raw content:content];
    _cache[content] = rebound;
    return rebound;
}

- (void)updateFontDocument:(GAFontDocument *)document {
    _fontDocument = document;
    // Discoveries cover all conditional branches. Coordinates only rebind the
    // literal GIDs and metrics; the content queue and cache remain resource-wide.
    for (GACharacterGroup *group in _groups) {
        NSMutableArray *variants = [NSMutableArray arrayWithCapacity:group.variants.count];
        for (GAGlyphVariant *variant in group.variants) {
            NSString *content = group.text;
            NSRange range = variant.sourceTextRange;
            if (variant.isLigature && range.location != NSNotFound && NSMaxRange(range) <= _text.length) content = [_text substringWithRange:range];
            [variants addObject:[document rebindVariant:variant content:content]];
        }
        group.variants = variants;
    }
    for (GATextScanGroup *group in _scanGroups) for (GATextScanItem *item in group.items) for (GATextScanSubitem *subitem in item.subitems) {
        if (subitem.state == GATextScanSubitemStateScanning) subitem.state = GATextScanSubitemStatePending;
    }
    [self notifyUpdate];
}

- (NSArray<GACharacterGroup *> *)groups {
    return _groups;
}

- (NSArray<GATextScanGroup *> *)scanGroups {
    return _scanGroups;
}

- (BOOL)hasPendingSubitems {
    for (GATextScanGroup *group in _scanGroups) {
        for (GATextScanItem *item in group.items) {
            for (GATextScanSubitem *subitem in item.subitems) {
                if (subitem.state == GATextScanSubitemStatePending) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

#pragma mark - Text / desired set

- (void)updateText:(NSString *)text {
    NSString *newText = [text copy];
    _text = newText;
    [self rebuildGroups];
    NSArray<GATextScanSubitem *> *desired = [self desiredSubitems];

    // Old unfinished work, keyed by content. A still-valid subitem keeps its
    // old item and is rebound to the new range/start below.
    NSMutableDictionary<NSString *, NSMutableArray<GATextScanSubitem *> *> *oldByContent =
        [NSMutableDictionary dictionary];
    for (GATextScanGroup *group in _scanGroups) {
        for (GATextScanItem *item in group.items) {
            for (GATextScanSubitem *subitem in item.subitems) {
                if (subitem.state == GATextScanSubitemStateCompleted) {
                    continue;
                }
                NSMutableArray<GATextScanSubitem *> *list = oldByContent[subitem.content];
                if (list == nil) {
                    list = [NSMutableArray array];
                    oldByContent[subitem.content] = list;
                }
                [list addObject:subitem];
            }
        }
    }

    NSUInteger maxLength = 0;
    for (GATextScanSubitem *subitem in desired) {
        maxLength = MAX(maxLength, subitem.length);
    }
    NSMutableArray<GATextScanGroup *> *newGroups =
        [NSMutableArray arrayWithCapacity:maxLength];
    for (NSUInteger length = 1; length <= maxLength; length++) {
        GATextScanGroup *group = [[GATextScanGroup alloc] init];
        group.length = length;
        [newGroups addObject:group];
    }

    NSMutableSet<GATextScanSubitem *> *reused = [NSMutableSet set];
    NSMutableDictionary<NSNumber *, GATextScanItem *> *missingItemByLength =
        [NSMutableDictionary dictionary];
    for (__strong GATextScanSubitem *desiredSubitem in desired) {
        NSMutableArray<GATextScanSubitem *> *list = oldByContent[desiredSubitem.content];
        GATextScanSubitem *old = list.firstObject;
        if (old != nil) {
            [list removeObjectAtIndex:0];
            old.range = desiredSubitem.range;
            old.startGroup = desiredSubitem.startGroup;
            old.length = desiredSubitem.length;
            [reused addObject:old];
            continue;
        }
        desiredSubitem.state = GATextScanSubitemStatePending;
        NSNumber *key = @(desiredSubitem.length);
        GATextScanItem *item = missingItemByLength[key];
        if (item == nil) {
            item = [[GATextScanItem alloc] init];
            missingItemByLength[key] = item;
        }
        [item.subitems addObject:desiredSubitem];
    }

    // Keep only the reused subitems in their old items; old items with none
    // left disappear. The old items stay ahead of this change's new items.
    for (GATextScanGroup *oldGroup in _scanGroups) {
        for (GATextScanItem *oldItem in oldGroup.items) {
            NSMutableArray<GATextScanSubitem *> *kept = [NSMutableArray array];
            for (GATextScanSubitem *subitem in oldItem.subitems) {
                if ([reused containsObject:subitem]) {
                    [kept addObject:subitem];
                }
            }
            if (kept.count == 0) {
                continue;
            }
            oldItem.subitems = kept;
            NSUInteger length = oldGroup.length;
            if (length < 1 || length > newGroups.count) {
                continue;
            }
            [newGroups[length - 1].items addObject:oldItem];
        }
    }
    for (NSNumber *key in missingItemByLength) {
        NSUInteger length = key.unsignedIntegerValue;
        if (length < 1 || length > newGroups.count) {
            continue;
        }
        [newGroups[length - 1].items addObject:missingItemByLength[key]];
    }

    _scanGroups = newGroups;
    [self notifyUpdate];
    if (![self hasPendingSubitems]) {
        [self.delegate textScanModelDidFinish:self];
    }
}

- (void)rebuildGroups {
    _groups = [GAGroupsForText(_text) mutableCopy];
    NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *indicesByContent =
        [NSMutableDictionary dictionary];
    for (NSUInteger index = 0; index < _groups.count; index++) {
        NSString *content = _groups[index].text;
        NSMutableArray<NSNumber *> *indices = indicesByContent[content];
        if (indices == nil) {
            indices = [NSMutableArray array];
            indicesByContent[content] = indices;
        }
        [indices addObject:@(index)];
    }
    _singleGroupIndicesByContent = indicesByContent;
}

- (BOOL)groupIsLineBreak:(GACharacterGroup *)group {
    return [group.text isEqualToString:@"\n"] || [group.text isEqualToString:@"\r"];
}

- (NSArray<GATextScanSubitem *> *)desiredSubitems {
    NSMutableArray<GATextScanSubitem *> *result = [NSMutableArray array];
    NSMutableSet<NSString *> *seenSingleCharacters = [NSMutableSet set];
    NSUInteger count = _groups.count;
    for (NSUInteger index = 0; index < count; index++) {
        GACharacterGroup *group = _groups[index];
        if ([seenSingleCharacters containsObject:group.text]) {
            continue;
        }
        [seenSingleCharacters addObject:group.text];
        GARawScanResult *cached = [self cachedResultForContent:group.text];
        if (cached != nil) {
            [self applySingleCharacterResult:cached content:group.text];
            continue;
        }
        GATextScanSubitem *subitem = [[GATextScanSubitem alloc] init];
        subitem.content = group.text;
        subitem.range = group.textRange;
        subitem.startGroup = index;
        subitem.length = 1;
        [result addObject:subitem];
    }
    for (NSUInteger length = 2; length <= count; length++) {
        for (NSUInteger start = 0; start + length <= count; start++) {
            BOOL hasBreak = NO;
            for (NSUInteger index = start; index < start + length; index++) {
                if ([self groupIsLineBreak:_groups[index]]) {
                    hasBreak = YES;
                    break;
                }
            }
            if (hasBreak) {
                continue;
            }
            NSRange first = _groups[start].textRange;
            NSRange last = _groups[start + length - 1].textRange;
            GATextScanSubitem *subitem = [[GATextScanSubitem alloc] init];
            subitem.content = [_text substringWithRange:
                NSMakeRange(first.location, NSMaxRange(last) - first.location)];
            subitem.range = NSMakeRange(first.location, NSMaxRange(last) - first.location);
            subitem.startGroup = start;
            subitem.length = length;
            [result addObject:subitem];
        }
    }
    return result;
}

#pragma mark - Scanning

- (GATextScanSubitem *)startNextSubitem {
    return [self startNextSubitemWithMaximumLength:NSUIntegerMax];
}

- (GATextScanSubitem *)startNextSubitemWithMaximumLength:(NSUInteger)maxLength {
    for (GATextScanGroup *group in _scanGroups) {
        for (GATextScanItem *item in group.items) {
            for (GATextScanSubitem *subitem in item.subitems) {
                if (subitem.length > maxLength) {
                    continue;
                }
                if (subitem.state != GATextScanSubitemStatePending) {
                    continue;
                }
                GARawScanResult *cached = [self cachedResultForContent:subitem.content];
                if (cached != nil) {
                    subitem.result = cached;
                    subitem.state = GATextScanSubitemStateCompleted;
                    if (subitem.length == 1) {
                        [self applySingleCharacterResult:cached content:subitem.content];
                    } else {
                        [self applySubitem:subitem];
                    }
                    [self notifyUpdate];
                    continue;
                }
                subitem.state = GATextScanSubitemStateScanning;
                return subitem;
            }
        }
    }
    return nil;
}

- (void)completeSubitem:(GATextScanSubitem *)subitem result:(GARawScanResult *)result {
    _cache[subitem.content] = result;
    BOOL single = (subitem.length == 1);
    for (GATextScanGroup *group in _scanGroups) {
        for (GATextScanItem *item in group.items) {
            for (GATextScanSubitem *candidate in item.subitems) {
                if (![candidate.content isEqualToString:subitem.content]) {
                    continue;
                }
                candidate.result = result;
                candidate.state = GATextScanSubitemStateCompleted;
                if (!single) {
                    [self applySubitem:candidate];
                }
            }
        }
    }
    if (single) {
        [self applySingleCharacterResult:result content:subitem.content];
    }
    [self notifyUpdate];
    if (![self hasPendingSubitems]) {
        [self.delegate textScanModelDidFinish:self];
    }
}

- (void)applySingleCharacterResult:(GARawScanResult *)result content:(NSString *)content {
    NSArray<NSNumber *> *indices = _singleGroupIndicesByContent[content];
    for (NSNumber *number in indices) {
        NSUInteger index = number.unsignedIntegerValue;
        GACharacterGroup *group = _groups[index];
        [_fontDocument applyRawResult:result
                         contentRange:group.textRange
                      startGroupIndex:index
                               groups:_groups];
    }
}

- (void)applySubitem:(GATextScanSubitem *)subitem {
    [_fontDocument applyRawResult:subitem.result
                     contentRange:subitem.range
                  startGroupIndex:subitem.startGroup
                           groups:_groups];
}

- (void)notifyUpdate {
    [self.delegate textScanModelDidUpdate:self];
}

@end
