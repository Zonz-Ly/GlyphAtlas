#import "GASubstitutionEngine.h"
#import "FontLayout/GAAAT.h"
#import "FontLayout/GACmap.h"
#import "FontLayout/GAKerning.h"
#import "FontLayout/GATextPreparation.h"
#import "FontLayout/GAVariation.h"
#include <map>

using namespace ga::layout;
@implementation GASubstitutionMatch
@end

namespace {
View tableBytes(CTFontRef font, Tag name) {
    NSData *data = CFBridgingRelease(CTFontCopyTable(font, name, 0));
    if (!data.length)
        return {};
    const auto *bytes = static_cast<const uint8_t *>(data.bytes);
    return View(std::vector<uint8_t>(bytes, bytes + data.length));
}
struct Domain {
    bool apple = false;
    size_t branch = 0;
    std::optional<AATSelector> selector;
};
struct Resource {
    Cmap cmap;
    GDEF gdef;
    OpenType gsub, gpos{{}, true};
    AAT aat;
    Kerning kerning;
    View fvar, avar;
    unsigned glyphCount = 0;
    double unitsPerEm = 1000;
    std::vector<Domain> domains;
    std::vector<Feature> featureSpecs;
    std::vector<std::string> diagnostics;
    Resource(CTFontRef font) {
        glyphCount = unsigned(CTFontGetGlyphCount(font));
        unitsPerEm = CTFontGetUnitsPerEm(font);
        auto read = [&](Tag name, auto &&assign) {
            try {
                assign(tableBytes(font, name));
            } catch (const InvalidTable &error) {
                diagnostics.push_back(tagName(name) + ": " + error.what());
            }
        };
        read(tag('c', 'm', 'a', 'p'), [&](View data) { cmap = Cmap(data); });
        read(tag('G', 'D', 'E', 'F'), [&](View data) { gdef = GDEF(data); });
        read(tag('G', 'S', 'U', 'B'), [&](View data) { gsub = OpenType(data); });
        read(tag('G', 'P', 'O', 'S'), [&](View data) { gpos = OpenType(data, true); });
        read(tag('m', 'o', 'r', 'x'), [&](View data) { aat = AAT(data, true); });
        if (aat.empty())
            read(tag('m', 'o', 'r', 't'), [&](View data) { aat = AAT(data, false); });
        kerning = Kerning(tableBytes(font, tag('k', 'e', 'r', 'n')),
                          tableBytes(font, tag('k', 'e', 'r', 'x')));
        fvar = tableBytes(font, tag('f', 'v', 'a', 'r'));
        avar = tableBytes(font, tag('a', 'v', 'a', 'r'));
        if (!aat.empty()) {
            domains.push_back({true, 0, {}});
            for (auto selector : aat.selectors())
                domains.push_back({true, 0, selector});
        }
        if (aat.empty() || !gsub.features().empty())
            for (size_t i = 0; i < gsub.branchCount(); i++)
                domains.push_back({false, i, {}});
        featureSpecs = collectFeatures();
    }
    const std::vector<Feature> &specifications() const {
        return featureSpecs;
    }
    std::vector<Feature> collectFeatures() const {
        std::vector<Feature> result;
        for (size_t branch = 0; branch < gsub.branchCount(); branch++)
            for (const auto &f : gsub.features(branch)) {
                auto found = std::find_if(result.begin(), result.end(), [&](const Feature &other) {
                    return other.name == f.name;
                });
                if (found == result.end())
                    result.push_back(f);
                else
                    found->maximum = std::max(found->maximum, f.maximum);
            }
        return result;
    }
    void substitute(Buffer &items, const Domain &domain, const Settings &settings,
                    Trace *trace = nullptr) const {
        if (domain.apple)
            aat.substitute(items, domain.selector, settings.rtl, settings.vertical, trace);
        else
            gsub.substitute(items, gdef, settings, domain.branch, trace);
    }
};
std::string sourceName(const Resource &resource, const Domain &domain) {
    if (!domain.apple)
        return "";
    std::string name = resource.aat.name();
    if (domain.selector)
        name += ":" + std::to_string(domain.selector->type) + ":" +
                std::to_string(domain.selector->setting);
    return name;
}
NSArray<NSNumber *> *glyphArray(const std::vector<Glyph> &glyphs) {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:glyphs.size()];
    for (Glyph glyph : glyphs)
        [array addObject:@(glyph)];
    return array;
}
std::vector<Glyph> glyphVector(NSArray<NSNumber *> *glyphs) {
    std::vector<Glyph> result;
    for (NSNumber *glyph in glyphs)
        result.push_back(glyph.unsignedShortValue);
    return result;
}
NSString *matchKey(Span span, NSArray *glyphs) {
    return [NSString stringWithFormat:@"%u:%u:%@", span.start, span.end, glyphs];
}
void merge(NSMutableDictionary *seen, NSMutableArray<GASubstitutionMatch *> *matches, Span span,
           const std::vector<Glyph> &glyphs, NSString *source, BOOL base) {
    if (span.empty())
        return;
    NSArray *ids = glyphArray(glyphs);
    NSString *key = matchKey(span, ids);
    GASubstitutionMatch *match = seen[key];
    if (!match) {
        match = [[GASubstitutionMatch alloc] init];
        match.glyphIDs = ids;
        match.sourceRange = NSMakeRange(span.start, span.end - span.start);
        match.sources = @[];
        match.base = base;
        seen[key] = match;
        [matches addObject:match];
    }
    match.base |= base;
    if (match.base)
        match.sources = @[];
    else if (source.length && ![match.sources containsObject:source])
        match.sources = [match.sources arrayByAddingObject:source];
}
Buffer literalBuffer(const std::vector<Glyph> &glyphs) {
    Buffer buffer;
    for (size_t i = 0; i < glyphs.size(); i++) {
        Item item;
        item.glyph = glyphs[i];
        item.source = {uint32_t(i), uint32_t(i + 1)};
        item.identity = i + 1;
        buffer.push_back(item);
    }
    return buffer;
}
std::vector<Glyph> identifiers(const Buffer &buffer) {
    std::vector<Glyph> result;
    for (const auto &item : buffer)
        result.push_back(item.glyph);
    return result;
}
std::vector<std::pair<Tag, unsigned>> plans(const Resource &resource, const Domain &domain) {
    std::vector<std::pair<Tag, unsigned>> result{{0, 0}};
    if (!domain.apple)
        for (const auto &feature : resource.specifications())
            for (unsigned value = 1; value <= feature.maximum; value++)
                result.emplace_back(feature.name, value);
    return result;
}
} // namespace

// The resource program owns only immutable table bytes. Coordinate-specific
// fonts and layout state belong to an engine instance, outside the shared cache.
@interface GAFontProgram : NSObject {
  @public
    std::shared_ptr<Resource> resource;
}
@property(nonatomic, strong) NSCache<id, NSDictionary *> *cache;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *errors;
@end
@implementation GAFontProgram
- (instancetype)initWithFont:(CTFontRef)font {
    self = [super init];
    if (self) {
        resource = std::make_shared<Resource>(font);
        _errors = [NSMutableOrderedSet orderedSet];
        for (const auto &message : resource->diagnostics)
            [_errors addObject:@(message.c_str())];
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 2048;
        _cache.totalCostLimit = 32 * 1024 * 1024;
    }
    return self;
}
@end

@interface GASubstitutionEngine ()
@property(nonatomic, strong) GAFontProgram *program;
@property(nonatomic, copy) NSDictionary<NSNumber *, NSNumber *> *coordinates;
- (NSDictionary *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections;
@end
@implementation GASubstitutionEngine {
    CTFontRef _font;
}
- (instancetype)initWithFont:(CTFontRef)font
                 coordinates:(NSDictionary *)coordinates
                     sharing:(GASubstitutionEngine *)source {
    self = [super init];
    if (self) {
        _font = (CTFontRef)CFRetain(font);
        _program = source.program ?: [[GAFontProgram alloc] initWithFont:font];
        _coordinates = [coordinates copy] ?: @{};
    }
    return self;
}
- (void)dealloc {
    if (_font)
        CFRelease(_font);
}
- (NSArray<NSString *> *)diagnostics {
    @synchronized(self.program) {
        return self.program.errors.array;
    }
}
- (void)recordError:(const std::exception &)error {
    @synchronized(self.program) {
        [self.program.errors addObject:@(error.what())];
    }
}
- (BOOL)hasFeatureVariations {
    return self.program->resource->gsub.branchCount() > 1;
}
- (NSArray *)featureSpecifications {
    const auto &r = *self.program->resource;
    NSMutableArray *result = [NSMutableArray array];
    for (const auto &f : r.specifications())
        [result addObject:@{@"tag" : @(tagName(f.name).c_str()), @"max" : @(f.maximum)}];
    for (const auto &domain : r.domains)
        if (domain.apple)
            [result addObject:@{
                @"tag" : @(sourceName(r, domain).c_str()),
                @"max" : @1,
                @"engine" : @(r.aat.name().c_str())
            }];
    return result;
}
- (NSDictionary *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    GAGlyphQueryIdentity *queryKey = GAGlyphQueryKey(text, selections);
    NSDictionary *cached = [self.program.cache objectForKey:queryKey];
    if (cached)
        return cached;
    const auto &r = *self.program->resource;
    auto runs = prepareText(text, r.cmap, selections);
    NSMutableArray *matches = [NSMutableArray array];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSMutableSet *scopes = [NSMutableSet set];
    for (size_t di = 0; di < r.domains.size(); di++) {
        const auto &domain = r.domains[di];
        for (const auto &run : runs) {
            std::vector<Tag> scripts{run.script};
            if (!domain.apple)
                for (GAGlyphSelectionRun *selection : selections)
                    if (NSIntersectionRange(
                            selection.range,
                            NSMakeRange(run.source.start, run.source.end - run.source.start))
                            .length) {
                        for (const auto &script : r.gsub.scripts())
                            if (std::find(scripts.begin(), scripts.end(), script.name) ==
                                scripts.end())
                                scripts.push_back(script.name);
                        break;
                    }
            for (Tag script : scripts) {
                auto languages = domain.apple ? std::vector<Tag>{0} : r.gsub.languages(script);
                for (Tag language : languages)
                    for (auto plan : plans(r, domain)) {
                        Settings settings;
                        settings.script = script;
                        settings.language = language;
                        settings.rtl = run.level & 1;
                        if (plan.first)
                            settings.features[plan.first] = plan.second;
                        Buffer items = run.glyphs;
                        Trace trace;
                        try {
                            r.substitute(items, domain, settings, &trace);
                        } catch (const InvalidTable &error) {
                            [self recordError:error];
                            items = run.glyphs;
                            trace = {};
                        }
                        for (auto &item : items)
                            if (item.glyph >= r.glyphCount)
                                item.glyph = 0;
                        bool base =
                            di == 0 && script == run.script && language == 0 && plan.first == 0;
                        for (auto change : trace.changes) {
                            if (settings.rtl)
                                std::reverse(change.glyphs.begin(), change.glyphs.end());
                            merge(seen, matches, change.source, change.glyphs,
                                  @(change.feature.c_str()), NO);
                        }
                        if (settings.rtl)
                            std::reverse(items.begin(), items.end());
                        std::string label = domain.apple ? sourceName(r, domain)
                                            : plan.first ? tagName(plan.first)
                                                         : "actual";
                        if (plan.second > 1)
                            label += " " + std::to_string(plan.second);
                        for (const auto &cluster : clusters(items))
                            merge(seen, matches, cluster.source, cluster.glyphs, @(label.c_str()),
                                  base);
                        if (items.empty() && !run.source.empty())
                            merge(seen, matches, run.source, {}, @(label.c_str()), base);
                        for (auto scope : trace.windows)
                            [scopes
                                addObject:[NSValue
                                              valueWithRange:NSMakeRange(scope.start,
                                                                         scope.end - scope.start)]];
                    }
            }
        }
    }
    // Direct single/alternate families include unencoded outputs and language
    // alternatives that are not selected by this text's default language system.
    NSArray *bases = [matches copy];
    for (GASubstitutionMatch *base in bases)
        if (base.base && base.glyphIDs.count == 1) {
            Glyph seed = base.glyphIDs.firstObject.unsignedShortValue;
            for (size_t branch = 0; branch < r.gsub.branchCount(); branch++)
                for (const auto &feature : r.gsub.features(branch))
                    for (unsigned li : feature.lookups)
                        for (auto output : r.gsub.family(seed, li, r.gdef)) {
                            if (output.first == seed)
                                continue;
                            std::string label = tagName(feature.name);
                            if (output.second > 1)
                                label += " " + std::to_string(output.second);
                            merge(seen, matches,
                                  {uint32_t(base.sourceRange.location),
                                   uint32_t(NSMaxRange(base.sourceRange))},
                                  {output.first}, @(label.c_str()), NO);
                        }
        }
    // AAT can carry state across any number of glyphs. Merge overlapping scopes
    // before enumerating their grapheme windows; safe boundaries remain cuts.
    if (!r.aat.empty()) {
        std::vector<Span> sorted;
        for (NSValue *value in scopes) {
            NSRange range = value.rangeValue;
            sorted.push_back({uint32_t(range.location), uint32_t(NSMaxRange(range))});
        }
        std::sort(sorted.begin(), sorted.end());
        std::vector<Span> islands;
        for (Span span : sorted) {
            if (!islands.empty() && span.start < islands.back().end)
                islands.back() = unite(islands.back(), span);
            else
                islands.push_back(span);
        }
        for (Span island : islands) {
            if (island.end > text.length)
                continue;
            std::vector<NSRange> groups;
            for (NSUInteger start = island.start; start < island.end;) {
                NSRange group = [text rangeOfComposedCharacterSequenceAtIndex:start];
                groups.push_back(group);
                start = NSMaxRange(group);
            }
            for (size_t a = 0; a < groups.size(); a++)
                for (size_t b = a; b < groups.size(); b++)
                    [scopes addObject:[NSValue valueWithRange:NSMakeRange(groups[a].location,
                                                                          NSMaxRange(groups[b]) -
                                                                              groups[a].location)]];
        }
    }
    NSDictionary *result = @{@"matches" : matches, @"spans" : scopes.allObjects};
    [self.program.cache setObject:result
                           forKey:queryKey
                             cost:text.length * 2 + matches.count * 128];
    return result;
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text {
    return [self discoverText:text selections:@[]];
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text
                                      selections:(NSArray<GAGlyphSelectionRun *> *)selections {
    if (!text.length)
        return @[];
    try {
        NSRange whole = NSMakeRange(0, text.length);
        NSMutableArray *queue = [NSMutableArray arrayWithObject:[NSValue valueWithRange:whole]];
        NSMutableSet *visited = [NSMutableSet setWithArray:queue];
        NSMutableArray *matches = [NSMutableArray array];
        NSMutableDictionary *seen = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < queue.count; i++) {
            NSRange outer = [queue[i] rangeValue];
            NSDictionary *result =
                [self discoverContent:[text substringWithRange:outer]
                           selections:GAGlyphSelectionsInRange(selections, outer)];
            for (GASubstitutionMatch *m in result[@"matches"]) {
                Span span{uint32_t(outer.location + m.sourceRange.location),
                          uint32_t(outer.location + NSMaxRange(m.sourceRange))};
                BOOL base = m.base && NSEqualRanges(outer, whole);
                merge(seen, matches, span, glyphVector(m.glyphIDs),
                      m.sources.firstObject ?: (base ? nil : @"actual"), base);
                GASubstitutionMatch *target = seen[matchKey(span, m.glyphIDs)];
                if (!target.base) {
                    NSMutableOrderedSet *sources =
                        [NSMutableOrderedSet orderedSetWithArray:target.sources];
                    [sources addObjectsFromArray:m.sources];
                    target.sources = sources.array;
                }
            }
            for (NSValue *value in result[@"spans"]) {
                NSRange range = value.rangeValue;
                range.location += outer.location;
                for (GAGlyphSelectionRun *selection in selections)
                    if (NSIntersectionRange(range, selection.range).length)
                        range = NSUnionRange(range, selection.range);
                if (!range.length || NSMaxRange(range) > text.length)
                    continue;
                NSValue *absolute = [NSValue valueWithRange:range];
                if (![visited containsObject:absolute]) {
                    [visited addObject:absolute];
                    [queue addObject:absolute];
                }
            }
        }
        [matches sortUsingComparator:^NSComparisonResult(GASubstitutionMatch *a,
                                                         GASubstitutionMatch *b) {
          if (a.base != b.base)
              return a.base ? NSOrderedAscending : NSOrderedDescending;
          if (!a.base && a.sourceRange.length != b.sourceRange.length)
              return a.sourceRange.length < b.sourceRange.length ? NSOrderedAscending
                                                                 : NSOrderedDescending;
          if (a.sourceRange.location != b.sourceRange.location)
              return a.sourceRange.location < b.sourceRange.location ? NSOrderedAscending
                                                                     : NSOrderedDescending;
          return NSOrderedSame;
        }];
        return matches;
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return @[];
}
- (Metrics)metrics {
    const auto &r = *self.program->resource;
    CTFontRef font = _font;
    double scale = r.unitsPerEm / CTFontGetSize(font);
    Metrics metrics;
    metrics.horizontalAdvance = [font, scale](Glyph glyph) {
        CGSize advance = {};
        CGGlyph g = glyph;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationHorizontal, &g, &advance, 1);
        return advance.width * scale;
    };
    metrics.verticalAdvance = [font, scale](Glyph glyph) {
        CGSize advance = {};
        CGGlyph g = glyph;
        CTFontGetAdvancesForGlyphs(font, kCTFontOrientationVertical, &g, &advance, 1);
        double value = std::max(std::abs(advance.width), std::abs(advance.height));
        return value ? value * scale : (CTFontGetAscent(font) + CTFontGetDescent(font)) * scale;
    };
    std::map<Tag, double> coordinates;
    for (NSNumber *axis in self.coordinates)
        coordinates[axis.unsignedIntValue] = [self.coordinates[axis] doubleValue];
    metrics.normalized = normalizeCoordinates(r.fvar, r.avar, coordinates);
    return metrics;
}
- (void)position:(Buffer &)buffer settings:(const Settings &)settings {
    const auto &r = *self.program->resource;
    Metrics metrics = [self metrics];
    Buffer nominal = buffer;
    bool hasKerning = false;
    try {
        size_t branch = r.gpos.variationBranch(metrics.normalized);
        r.gpos.position(buffer, r.gdef, settings, metrics, branch);
        for (auto step : r.gpos.plan(settings, branch))
            if (step.feature == tag('k', 'e', 'r', 'n'))
                hasKerning = true;
    } catch (const InvalidTable &error) {
        [self recordError:error];
        buffer = std::move(nominal);
        for (auto &item : buffer) {
            item.xAdvance = settings.vertical ? 0 : metrics.horizontalAdvance(item.glyph);
            item.yAdvance = settings.vertical ? -metrics.verticalAdvance(item.glyph) : 0;
            item.xOffset = item.yOffset = 0;
        }
    }
    if (!hasKerning) {
        Buffer before = buffer;
        try {
            r.kerning.position(buffer, settings, r.gdef);
        } catch (const InvalidTable &error) {
            [self recordError:error];
            buffer = std::move(before);
        }
    }
    for (auto &item : buffer)
        if (item.ignorable)
            item.xAdvance = item.yAdvance = 0;
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    return [self positionsForGlyphIDs:glyphIDs content:@""];
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     content:(NSString *)content {
    try {
        const auto &r = *self.program->resource;
        auto runs = prepareText(content, r.cmap);
        Settings settings;
        if (!runs.empty()) {
            settings.script = runs.front().script;
            settings.rtl = runs.front().level & 1;
        }
        Buffer items = literalBuffer(glyphVector(glyphIDs));
        if (settings.rtl)
            std::reverse(items.begin(), items.end());
        [self position:items settings:settings];
        if (settings.rtl)
            std::reverse(items.begin(), items.end());
        double scale = 200.0 / r.unitsPerEm;
        ga::layout::Point pen;
        NSMutableArray *positions = [NSMutableArray array];
        for (const auto &item : items) {
            [positions
                addObject:[NSValue valueWithPoint:NSMakePoint((pen.x + item.xOffset) * scale,
                                                              (pen.y + item.yOffset) * scale)]];
            pen.x += item.xAdvance;
            pen.y += item.yAdvance;
        }
        return positions;
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return @[];
}
- (NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs {
    if (!glyphIDs.count)
        return @[];
    NSArray *key = @[ @"glyphs", [glyphIDs copy] ];
    NSDictionary *cached = [self.program.cache objectForKey:key];
    if (cached)
        return cached[@"matches"];
    try {
        const auto &r = *self.program->resource;
        auto original = glyphVector(glyphIDs);
        Span whole{0, uint32_t(original.size())};
        NSMutableArray *matches = [NSMutableArray array];
        NSMutableDictionary *seen = [NSMutableDictionary dictionary];
        merge(seen, matches, whole, original, nil, YES);
        for (const auto &domain : r.domains) {
            std::vector<Tag> scripts;
            if (domain.apple)
                scripts = {tag('D', 'F', 'L', 'T')};
            else
                for (const auto &script : r.gsub.scripts())
                    scripts.push_back(script.name);
            for (Tag script : scripts)
                for (Tag language : domain.apple ? std::vector<Tag>{0} : r.gsub.languages(script))
                    for (auto plan : plans(r, domain)) {
                        Settings settings;
                        settings.script = script;
                        settings.language = language;
                        if (plan.first)
                            settings.features[plan.first] = plan.second;
                        Buffer items = literalBuffer(original);
                        Trace trace;
                        r.substitute(items, domain, settings, &trace);
                        std::string label = domain.apple ? sourceName(r, domain)
                                            : plan.first ? tagName(plan.first)
                                                         : "actual";
                        if (plan.second > 1)
                            label += " " + std::to_string(plan.second);
                        merge(seen, matches, whole, identifiers(items), @(label.c_str()), NO);
                        for (const auto &change : trace.changes) {
                            if (change.source.end > original.size())
                                continue;
                            auto sequence = original;
                            sequence.erase(sequence.begin() + change.source.start,
                                           sequence.begin() + change.source.end);
                            sequence.insert(sequence.begin() + change.source.start,
                                            change.glyphs.begin(), change.glyphs.end());
                            merge(seen, matches, whole, sequence, @(change.feature.c_str()), NO);
                        }
                    }
        }
        for (size_t component = 0; component < original.size(); component++)
            for (size_t branch = 0; branch < r.gsub.branchCount(); branch++)
                for (const auto &feature : r.gsub.features(branch))
                    for (unsigned li : feature.lookups)
                        for (auto output : r.gsub.family(original[component], li, r.gdef)) {
                            auto sequence = original;
                            sequence[component] = output.first;
                            std::string label = tagName(feature.name);
                            if (output.second > 1)
                                label += " " + std::to_string(output.second);
                            merge(seen, matches, whole, sequence, @(label.c_str()), NO);
                        }
        [self.program.cache setObject:@{@"matches" : matches}
                               forKey:key
                                 cost:glyphIDs.count * 2 + matches.count * 128];
        return matches;
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return @[];
}
- (NSNumber *)verticalGlyph:(uint16_t)glyph {
    try {
        const auto &r = *self.program->resource;
        for (const auto &domain : r.domains) {
            if (domain.apple) {
                if (domain.selector && domain.selector->type != 4)
                    continue;
                Buffer items = literalBuffer({glyph});
                r.aat.substitute(items, domain.selector, false, true, nullptr, true);
                if (items.size() == 1 && items.front().glyph != glyph)
                    return @(items.front().glyph);
            } else
                for (Tag name : {tag('v', 'r', 't', '2'), tag('v', 'e', 'r', 't')})
                    for (const auto &feature : r.gsub.features(domain.branch)) {
                        if (feature.name != name)
                            continue;
                        std::vector<LookupStep> steps;
                        for (unsigned lookup : feature.lookups)
                            steps.push_back({lookup, 1, name, true});
                        Buffer items = literalBuffer({glyph});
                        r.gsub.substituteLookups(items, r.gdef, steps);
                        if (items.size() == 1 && items.front().glyph != glyph)
                            return @(items.front().glyph);
                    }
        }
    } catch (const std::exception &error) {
        [self recordError:error];
    }
    return nil;
}
- (NSDictionary *)shapeText:(NSString *)text
                   features:(NSDictionary *)features
                     script:(NSString *)script
                   language:(NSString *)language
                     branch:(NSUInteger)branch {
    try {
        const auto &r = *self.program->resource;
        auto runs = prepareText(text, r.cmap);
        std::vector<Buffer> output;
        const auto &domain = r.domains[branch < r.domains.size() ? branch : 0];
        for (auto run : runs) {
            Settings settings;
            settings.script = script.length ? scriptTag(script) : run.script;
            settings.language = languageTag(language);
            settings.rtl = run.level & 1;
            for (NSString *name in features)
                settings.features[tag(name.UTF8String ?: "")] = [features[name] unsignedIntValue];
            Buffer items = run.glyphs;
            r.substitute(items, domain, settings);
            [self position:items settings:settings];
            if (settings.rtl)
                std::reverse(items.begin(), items.end());
            output.push_back(std::move(items));
        }
        NSMutableArray *glyphs = [NSMutableArray array], *clusters = [NSMutableArray array],
                       *positions = [NSMutableArray array];
        for (size_t index : visualRunOrder(runs))
            for (const auto &item : output[index]) {
                [glyphs addObject:@(item.glyph)];
                [clusters addObject:@(item.source.start)];
                [positions addObject:@[
                    @(item.xAdvance), @(item.yAdvance), @(item.xOffset), @(item.yOffset)
                ]];
            }
        return
            @{@"ok" : @YES, @"glyphs" : glyphs, @"clusters" : clusters, @"positions" : positions};
    } catch (const std::exception &error) {
        return @{
            @"ok" : @NO,
            @"error" : @(error.what()),
            @"glyphs" : @[],
            @"clusters" : @[],
            @"positions" : @[]
        };
    }
}
@end
