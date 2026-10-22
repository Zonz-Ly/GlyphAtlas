#import "GATextScanModel.h"

@implementation GATextScanSubitem
- (instancetype)init {
    self = [super init];
    if (self) {
        _content = @"";
        _range = NSMakeRange(0, 0);
        _state = GATextScanSubitemStatePending;
    }
    return self;
}
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
    NSMutableArray<GACharacterGroup *> *_groups;
    NSMutableArray<GATextScanGroup *> *_scanGroups;
    NSMutableDictionary<NSString *, GARawScanResult *> *_cache;
    NSUInteger _nextItemSequence;
    NSUInteger _scanCount;
    BOOL _scanning;
    NSSet<NSString *> *_previousUITextCharacters;
}
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
        _nextItemSequence = 1;
    }
    return self;
}

- (BOOL)isScanning {
    return _scanning;
}

- (NSUInteger)scanCount {
    return _scanCount;
}

- (NSArray<GACharacterGroup *> *)groups {
    return _groups;
}

- (NSArray<GATextScanGroup *> *)scanGroups {
    return _scanGroups;
}

- (BOOL)hasPendingSubitems {
    return [self pendingSubitems].count > 0;
}

- (NSUInteger)pendingCount {
    return [self pendingSubitems].count;
}

- (NSArray<GATextScanSubitem *> *)pendingSubitems {
    NSMutableArray<GATextScanSubitem *> *pending = [NSMutableArray array];
    for (GATextScanGroup *group in _scanGroups) {
        for (GATextScanItem *item in group.items) {
            for (GATextScanSubitem *subitem in item.subitems) {
                if (subitem.state == GATextScanSubitemStatePending) {
                    [pending addObject:subitem];
                }
            }
        }
    }
    return pending;
}

#pragma mark - Text / desired set

- (void)updateText:(NSString *)text {
    [self updateText:text previousUIText:@""];
}

- (void)updateText:(NSString *)text previousUIText:(NSString *)previousUIText {
    NSMutableSet<NSString *> *previousUICharacters = [NSMutableSet set];
    for (NSUInteger index = 0; index < previousUIText.length; ) {
        NSRange range = [previousUIText rangeOfComposedCharacterSequenceAtIndex:index];
        [previousUICharacters addObject:[previousUIText substringWithRange:range]];
        index = NSMaxRange(range);
    }
    _previousUITextCharacters = previousUICharacters;

    NSString *newText = [text copy] ?: @"";
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
            item.sequence = _nextItemSequence++;
            item.length = desiredSubitem.length;
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
            if (oldItem.length < 1 || oldItem.length > newGroups.count) {
                continue;
            }
            [newGroups[oldItem.length - 1].items addObject:oldItem];
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
    _previousUITextCharacters = nil;
    [self notifyUpdate];
    if (![self hasPendingSubitems]) {
        [self.delegate textScanModelDidFinish:self];
    }
}

- (void)rebuildGroupItems {
    // Remove empty groups and items whose subitems were dropped.
    for (GATextScanGroup *group in _scanGroups) {
        NSMutableArray<GATextScanItem *> *kept = [NSMutableArray array];
        for (GATextScanItem *item in group.items) {
            if (item.subitems.count > 0) {
                [kept addObject:item];
            }
        }
        group.items = kept;
    }
}

- (void)rebuildGroups {
    NSMutableArray<GACharacterGroup *> *groups = [NSMutableArray array];
    [_text enumerateSubstringsInRange:NSMakeRange(0, _text.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *substring, NSRange substringRange,
                                        NSRange enclosingRange, BOOL *stop) {
        (void)enclosingRange; (void)stop;
        GACharacterGroup *group = [[GACharacterGroup alloc] init];
        group.text = substring;
        group.textRange = substringRange;
        group.variants = @[];
        [groups addObject:group];
    }];
    _groups = groups;
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
        if ([_previousUITextCharacters containsObject:group.text]) {
            GARawScanResult *cached = _cache[group.text];
            if (cached != nil) {
                [self applySingleCharacterResult:cached content:group.text];
            }
            continue;
        }
        GARawScanResult *cached = _cache[group.text];
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
                GARawScanResult *cached = _cache[subitem.content];
                if (cached != nil) {
                    subitem.result = cached;
                    subitem.state = GATextScanSubitemStateCompleted;
                    [self applySubitem:subitem];
                    [self notifyUpdate];
                    continue;
                }
                subitem.state = GATextScanSubitemStateScanning;
                _scanning = YES;
                _scanCount++;
                return subitem;
            }
        }
    }
    return nil;
}

- (void)completeSubitem:(GATextScanSubitem *)subitem result:(GARawScanResult *)result {
    if (subitem == nil) {
        return;
    }
    _scanning = NO;
    _cache[subitem.content] = result;
    for (GATextScanGroup *group in _scanGroups) {
        for (GATextScanItem *item in group.items) {
            for (GATextScanSubitem *candidate in item.subitems) {
                if (![candidate.content isEqualToString:subitem.content]) {
                    continue;
                }
                candidate.result = result;
                candidate.state = GATextScanSubitemStateCompleted;
                [self applySubitem:candidate];
            }
        }
    }
    if (subitem.length == 1) {
        [self applySingleCharacterResult:result content:subitem.content];
    }
    [self notifyUpdate];
    if (![self hasPendingSubitems]) {
        [self.delegate textScanModelDidFinish:self];
    }
}

- (void)applySingleCharacterResult:(GARawScanResult *)result content:(NSString *)content {
    if (result == nil || content.length == 0) {
        return;
    }
    for (NSUInteger index = 0; index < _groups.count; index++) {
        GACharacterGroup *group = _groups[index];
        if (![group.text isEqualToString:content]) {
            continue;
        }
        GATextScanSubitem *subitem = [[GATextScanSubitem alloc] init];
        subitem.content = content;
        subitem.range = group.textRange;
        subitem.startGroup = index;
        subitem.length = 1;
        subitem.result = result;
        subitem.state = GATextScanSubitemStateCompleted;
        [self applySubitem:subitem];
    }
}

- (void)applySubitem:(GATextScanSubitem *)subitem {
    if (subitem.result == nil) {
        return;
    }
    [self.fontDocument applyRawResult:subitem.result
                         contentRange:subitem.range
                      startGroupIndex:subitem.startGroup
                               groups:_groups];
}

- (void)notifyUpdate {
    [self.delegate textScanModelDidUpdate:self];
}

@end
