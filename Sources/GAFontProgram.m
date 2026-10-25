#import "GAFontProgram.h"
@implementation GAQueryDomain
@end
static GATableView *GAFontTable(CTFontRef font, GATag name) {
    NSData *bytes = CFBridgingRelease(CTFontCopyTable(font, name, 0));
    return [GATableView data:bytes];
}
@implementation GAFontProgram
- (void)read:(NSString *)name font:(CTFontRef)font assign:(void (^)(GATableView *))assign {
    @try {
        assign(GAFontTable(font, GATagFromString(name)));
    } @catch (NSException *error) {
        if (![error.name isEqual:@"GAInvalidFontTable"])
            @throw;
        [_errors addObject:[NSString stringWithFormat:@"%@: %@", name, error.reason]];
    }
}
- (instancetype)initWithFont:(CTFontRef)font {
    if (!(self = [super init]))
        return nil;
    _glyphCount = (unsigned)CTFontGetGlyphCount(font);
    _unitsPerEm = CTFontGetUnitsPerEm(font);
    _errors = [NSMutableOrderedSet orderedSet];
    GATableView *empty = [GATableView data:nil];
    _cmap = [[GACmap alloc] initWithView:empty];
    _gdef = [[GAGDEF alloc] initWithView:empty];
    _gsub = [[GAOpenType alloc] initWithView:empty positioning:NO];
    _gpos = [[GAOpenType alloc] initWithView:empty positioning:YES];
    _aat = [[GAAAT alloc] initWithView:empty extended:YES];
    [self read:@"cmap"
          font:font
        assign:^(GATableView *v) {
            self->_cmap = [[GACmap alloc] initWithView:v];
        }];
    [self read:@"GDEF"
          font:font
        assign:^(GATableView *v) {
            self->_gdef = [[GAGDEF alloc] initWithView:v];
        }];
    [self read:@"GSUB"
          font:font
        assign:^(GATableView *v) {
            self->_gsub = [[GAOpenType alloc] initWithView:v positioning:NO];
        }];
    [self read:@"GPOS"
          font:font
        assign:^(GATableView *v) {
            self->_gpos = [[GAOpenType alloc] initWithView:v positioning:YES];
        }];
    [self read:@"morx"
          font:font
        assign:^(GATableView *v) {
            self->_aat = [[GAAAT alloc] initWithView:v extended:YES];
        }];
    if (_aat.empty)
        [self read:@"mort"
              font:font
            assign:^(GATableView *v) {
                self->_aat = [[GAAAT alloc] initWithView:v extended:NO];
            }];
    _kerning = [[GAKerning alloc] initWithKern:GAFontTable(font, GATagMake('k', 'e', 'r', 'n'))
                                          kerx:GAFontTable(font, GATagMake('k', 'e', 'r', 'x'))];
    _fvar = GAFontTable(font, GATagMake('f', 'v', 'a', 'r'));
    _avar = GAFontTable(font, GATagMake('a', 'v', 'a', 'r'));
    NSMutableArray *domains = [NSMutableArray array];
    if (!_aat.empty) {
        GAQueryDomain *domain = [GAQueryDomain new];
        domain.apple = YES;
        [domains addObject:domain];
        for (GAAATSelector *selector in _aat.selectors) {
            domain = [GAQueryDomain new];
            domain.apple = YES;
            domain.selector = selector;
            [domains addObject:domain];
        }
    }
    if (_aat.empty || [_gsub features:0].count)
        for (NSUInteger i = 0; i < _gsub.branchCount; i++) {
            GAQueryDomain *domain = [GAQueryDomain new];
            domain.branch = i;
            [domains addObject:domain];
        }
    _domains = domains;
    NSMutableArray<GAOTFeature *> *specifications = [NSMutableArray array];
    NSMutableDictionary<NSNumber *, GAOTFeature *> *byName = [NSMutableDictionary dictionary];
    for (NSUInteger branch = 0; branch < _gsub.branchCount; branch++)
        for (GAOTFeature *feature in [_gsub features:branch]) {
            GAOTFeature *found = byName[@(feature.name)];
            if (found)
                found.maximum = MAX(found.maximum, feature.maximum);
            else {
                found = [feature copy];
                byName[@(feature.name)] = found;
                [specifications addObject:found];
            }
        }
    _specifications = specifications;
    _verticalAAT = _aat.hasVerticalSubstitutions;
    _cache = [NSCache new];
    _cache.countLimit = 2048;
    _cache.totalCostLimit = 32 * 1024 * 1024;
    _relatedCache = [NSCache new];
    _relatedCache.countLimit = 2048;
    _relatedCache.totalCostLimit = 16 * 1024 * 1024;
    return self;
}
- (void)substitute:(NSMutableArray<GALayoutItem *> *)items
            domain:(GAQueryDomain *)domain
          settings:(GALayoutSettings *)settings
             trace:(GALayoutTrace *)trace {
    if (domain.apple)
        [_aat substituteBuffer:items
                      selector:domain.selector
                           rtl:settings.rtl
                      vertical:settings.vertical
                         trace:trace
                  verticalOnly:NO];
    else
        [_gsub substituteBuffer:items
                           gdef:_gdef
                       settings:settings
                         branch:domain.branch
                          trace:trace];
}
@end
