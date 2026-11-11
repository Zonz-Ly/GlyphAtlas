#import "GASubstitutionEngine.h"
#import "Font/GAGlyphSelection.h"
#import "GAAAT.h"
#import "GACmap.h"
#import "GAOpenType.h"
#import "GATextPreparation.h"
#import "GAVariation.h"
#include <cmath>
#include <map>
#include <deque>
#include <unordered_map>
#include <mutex>

using namespace ga::layout;
@implementation GASubstitutionMatch
@end
@implementation GASubstitutionOrigin
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
    bool apple;
    size_t branch;
    std::optional<AATSelector> selector;
    size_t sharedSchedule = 0;
    bool lastUseOfSchedule = false;
};
struct Resource {
    Cmap cmap;
    GDEF gdef;
    OpenType gsub, gpos{{}, true};
    AAT aat;
    Kerning kerning;
    View fvar, avar;
    View os2, variationStore, head;
    struct VariationIndex {
        bool present = false;
        unsigned outer = 0, inner = 0;
    } ascenderVariation, descenderVariation;
    bool verticalAAT;
    double unitsPerEm;
    std::vector<Domain> domains;
    std::vector<std::pair<Tag, unsigned>> featureSpecs;
    std::map<std::string, AATSelector, std::less<>> outputSelectors;
    Resource(CTFontRef font)
        : unitsPerEm(CTFontGetUnitsPerEm(font)) {
        auto read = [&](Tag name, auto &&assign) {
            try {
                assign(tableBytes(font, name));
            } catch (const InvalidTable &) {
                // Keep the default program when a table is invalid.
            }
        };
        read(tag('c', 'm', 'a', 'p'), [&](View data) { cmap = Cmap(data); });
        read(tag('G', 'D', 'E', 'F'), [&](View data) { gdef = GDEF(data); });
        read(tag('G', 'S', 'U', 'B'), [&](View data) { gsub = OpenType(data); });
        read(tag('G', 'P', 'O', 'S'), [&](View data) { gpos = OpenType(data, true); });
        read(tag('m', 'o', 'r', 'x'), [&](View data) { aat = AAT(data); });
        if (aat.empty())
            read(tag('m', 'o', 'r', 't'), [&](View data) { aat = AAT(data, false); });
        kerning = Kerning(tableBytes(font, tag('k', 'e', 'r', 'n')),
                          tableBytes(font, tag('k', 'e', 'r', 'x')));
        fvar = tableBytes(font, tag('f', 'v', 'a', 'r'));
        avar = tableBytes(font, tag('a', 'v', 'a', 'r'));
        os2 = tableBytes(font, tag('O', 'S', '/', '2'));
        head = tableBytes(font, tag('h', 'e', 'a', 'd'));
        read(tag('M', 'V', 'A', 'R'), [&](View data) { readVariationMetrics(data); });
        if (!aat.empty()) {
            aat.compileMachines(CTFontGetGlyphCount(font));
            domains.push_back({true, 0, {}});
            for (auto selector : aat.selectors())
                domains.push_back({true, 0, selector});
            if (aat.canIndexHorizontalSchedules()) {
                std::map<std::vector<size_t>, std::vector<size_t>> schedules;
                for (size_t i = 0; i < domains.size(); ++i)
                    schedules[aat.horizontalSchedule(domains[i].selector)].push_back(i);
                for (const auto &entry : schedules) {
                    const auto &indices = entry.second;
                    if (indices.size() < 2)
                        continue;
                    for (size_t index : indices)
                        domains[index].sharedSchedule = indices.front() + 1;
                    domains[indices.back()].lastUseOfSchedule = true;
                }
            }
        }
        if (aat.empty() || !gsub.features().empty())
            for (size_t i = 0; i < gsub.branchCount(); i++)
                domains.push_back({false, i, {}});
        featureSpecs = collectFeatures();
        for (auto selector : aat.outputSelectors())
            outputSelectors.emplace(aat.featureLabel(selector), selector);
        verticalAAT = aat.hasVerticalSubstitutions();
    }
    void readVariationMetrics(View mvar) {
        if (!mvar)
            return;
        if (mvar.u16(0) != 1)
            throw InvalidTable("unknown MVAR version");
        unsigned size = mvar.u16(6), count = mvar.u16(8);
        if (size < 8)
            throw InvalidTable("short MVAR value record");
        mvar.array(12, count, size);
        VariationIndex ascender, descender;
        for (unsigned i = 0; i < count; i++) {
            size_t at = 12 + size_t(i) * size;
            Tag name = mvar.u32(at);
            if (name == tag('h', 'a', 's', 'c')) {
                ascender.present = true;
                ascender.outer = mvar.u16(at + 4);
                ascender.inner = mvar.u16(at + 6);
            } else if (name == tag('h', 'd', 's', 'c')) {
                descender.present = true;
                descender.outer = mvar.u16(at + 4);
                descender.inner = mvar.u16(at + 6);
            }
        }
        // The store is shared by both records; keep it only when one applies.
        if (!ascender.present && !descender.present)
            return;
        View store = mvar.offset16(10);
        if (!store)
            return;
        variationStore = store;
        ascenderVariation = ascender;
        descenderVariation = descender;
    }
    Tag verticalFeature(size_t branch) const {
        // Select by feature presence, never by whether this glyph is covered.
        for (const auto &feature : gsub.features(branch))
            if (feature.name == tag('v', 'r', 't', '2'))
                return feature.name;
        return tag('v', 'e', 'r', 't');
    }
    std::vector<std::pair<Tag, unsigned>> collectFeatures() const {
        std::vector<std::pair<Tag, unsigned>> result;
        for (size_t branch = 0; branch < gsub.branchCount(); branch++)
            for (const auto &f : gsub.features(branch)) {
                auto found = std::find_if(result.begin(), result.end(), [&](const auto &other) {
                    return other.first == f.name;
                });
                if (found == result.end())
                    result.emplace_back(f.name, f.maximum);
                else
                    found->second = std::max(found->second, f.maximum);
            }
        return result;
    }
    void substitute(Buffer &items, const Domain &domain, const Settings &settings,
                    Trace *trace = nullptr, const Cancellation *cancellation = nullptr) const {
        if (domain.apple)
            aat.substitute(items, domain.selector, settings.rtl, settings.vertical, trace,
                           false, {}, cancellation);
        else
            gsub.substitute(items, gdef, settings, domain.branch, trace, cancellation);
    }
};
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
std::vector<Glyph> replacingGlyph(const std::vector<Glyph> &glyphs, size_t index,
                                 NSDictionary *output) {
    auto sequence = glyphs;
    auto replacement = glyphVector(output[@"glyphs"]);
    sequence.erase(sequence.begin() + index);
    sequence.insert(sequence.begin() + index, replacement.begin(), replacement.end());
    return sequence;
}
struct MatchKey {
    Span source;
    std::vector<Glyph> glyphs;
    bool operator==(const MatchKey &other) const {
        return source == other.source && glyphs == other.glyphs;
    }
};

struct MatchKeyHash {
    size_t operator()(const MatchKey &key) const {
        size_t hash = size_t(key.source.start) * 1000003 + key.source.end;
        for (Glyph glyph : key.glyphs)
            hash = hash * 1000003 + glyph;
        return hash;
    }
};

using MatchIndex = std::unordered_map<MatchKey, GASubstitutionMatch *, MatchKeyHash>;

bool merge(MatchIndex &seen, NSMutableArray<GASubstitutionMatch *> *matches, Span span,
           const std::vector<Glyph> &glyphs, NSString *source, BOOL base) {
    if (span.empty())
        return false;
    auto [entry, inserted] = seen.try_emplace(MatchKey{span, glyphs}, nil);
    if (inserted) {
        GASubstitutionMatch *candidate = [[GASubstitutionMatch alloc] init];
        candidate.glyphIDs = glyphArray(glyphs);
        candidate.sourceRange = NSMakeRange(span.start, span.end - span.start);
        candidate.sources = @[];
        entry->second = candidate;
        [matches addObject:candidate];
    }
    GASubstitutionMatch *match = entry->second;
    match.base |= base;
    if (source.length && ![match.sources containsObject:source]) {
        match.sources = [match.sources arrayByAddingObject:source];
        return true;
    }
    return inserted;
}

using ParagraphKey = std::vector<uint32_t>;
struct ParagraphMatch {
    Span source;
    std::vector<Glyph> glyphs;
    NSString *label;
};
struct ParagraphOutput {
    std::map<size_t, std::vector<ParagraphMatch>> domains;
    size_t cost = 0;
};
using ParagraphCache = std::map<ParagraphKey, std::shared_ptr<const ParagraphOutput>>;
constexpr size_t paragraphCacheBudget = 4 * 1024 * 1024;

struct QueryParagraph {
    Span source;
    size_t firstRun, endRun;
    ParagraphKey key;
    std::shared_ptr<const ParagraphOutput> reused;
    std::shared_ptr<ParagraphOutput> output;

    void remember(size_t domain, Span span, const std::vector<Glyph> &glyphs, NSString *label,
                  size_t &remaining) {
        if (!output) return;
        // Count backing storage as well as the record, with room for vector growth.
        const size_t cost = 2 * sizeof(ParagraphMatch) + 2 * glyphs.size() * sizeof(Glyph) +
                            2 * label.length + 64;
        if (cost > remaining || span.start < source.start || span.end > source.end) {
            output.reset();
            return;
        }
        remaining -= cost;
        output->cost += cost;
        output->domains[domain].push_back(
            {{span.start - source.start, span.end - source.start}, glyphs, label});
    }
};

std::vector<QueryParagraph> queryParagraphs(NSString *text, const std::vector<TextRun> &runs,
                                            const Cancellation *cancellation) {
    if (runs.size() < 2) return {};
    constexpr size_t maxCachedParagraphs = 4096;
    std::vector<QueryParagraph> paragraphs;
    size_t firstRun = 0;
    for (NSUInteger at = 0; firstRun < runs.size();) {
        checkCancellation(cancellation);
        NSUInteger end, contentsEnd;
        [text getLineStart:nullptr end:&end contentsEnd:&contentsEnd forRange:NSMakeRange(at, 0)];
        size_t endRun = firstRun;
        while (endRun < runs.size() && runs[endRun].source.start < end) {
            // A literal seed can cover a newline. Keep the full-query path
            // when an existing search run cannot be contained in one line.
            if (runs[endRun].source.start < at || runs[endRun].source.end > contentsEnd)
                return {};
            ++endRun;
        }
        if (endRun != firstRun) {
            if (paragraphs.size() == maxCachedParagraphs) return {};
            paragraphs.push_back({{uint32_t(at), uint32_t(contentsEnd)}, firstRun, endRun, {}, {}, {}});
        }
        firstRun = endRun;
        at = end;
        if (at >= text.length && firstRun < runs.size()) return {};
    }
    if (paragraphs.size() < 2) return {};
    return paragraphs;
}

void prepareParagraphCache(std::vector<QueryParagraph> &paragraphs, const std::vector<TextRun> &runs,
                           const std::vector<bool> &selectedRuns,
                           const ParagraphCache *previous, size_t &remaining,
                           const Cancellation *cancellation) {
    for (auto &paragraph : paragraphs) {
        checkCancellation(cancellation);
        constexpr size_t overhead = 128;
        size_t words = 1;
        for (size_t i = paragraph.firstRun; i < paragraph.endRun; ++i)
            words += 6 + 6 * runs[i].glyphs.size();
        size_t cost = overhead + words * sizeof(uint32_t);
        if (cost > remaining) continue;
        const uint32_t base = paragraph.source.start;
        auto &key = paragraph.key;
        key.reserve(words);
        key.push_back(paragraph.source.end - base);
        for (size_t i = paragraph.firstRun; i < paragraph.endRun; ++i) {
            const auto &run = runs[i];
            key.insert(key.end(), {run.source.start - base, run.source.end - base,
                                   run.script, run.level, uint32_t(selectedRuns[i]),
                                   uint32_t(run.glyphs.size())});
            // Prepared identities are unique within the run. Only their
            // correspondence to slots matters, so absolute IDs are omitted.
            for (const auto &item : run.glyphs)
                key.insert(key.end(), {item.glyph, item.source.start - base, item.source.end - base,
                                       item.scalar, item.form, uint32_t(item.ignorable)});
        }
        if (previous) {
            auto hit = previous->find(key);
            if (hit != previous->end() && hit->second->cost <= remaining) {
                paragraph.reused = hit->second;
                remaining -= paragraph.reused->cost;
                continue;
            }
        }
        paragraph.output = std::make_shared<ParagraphOutput>();
        paragraph.output->cost = cost;
        remaining -= cost;
    }
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
std::optional<std::vector<Glyph>> sequenceAt(const Buffer &buffer, Span span, bool rtl) {
    std::vector<Glyph> result;
    Span covered{span.end, span.start};
    for (const auto &item : buffer) {
        if (item.source.start >= span.end || item.source.end <= span.start)
            continue;
        if (item.source.start < span.start || item.source.end > span.end)
            return {};
        covered = unite(covered, item.source);
        if (item.glyph != 0xffff)
            result.push_back(item.glyph);
    }
    if (!(covered == span))
        return {};
    if (rtl)
        std::reverse(result.begin(), result.end());
    return result;
}
bool verticalSource(const std::string &source) {
    auto feature = source.substr(0, source.find(' '));
    return feature == "vert" || feature == "vrt2" ||
           source.rfind("morx:4:", 0) == 0 || source.rfind("mort:4:", 0) == 0;
}
struct OriginEdge {
    std::vector<Glyph> glyphs;
    std::string feature;
    bool vertical;
};
GASubstitutionOrigin *origin(NSUInteger index, const std::vector<std::string> &features) {
    GASubstitutionOrigin *result = [[GASubstitutionOrigin alloc] init];
    result.sourceIndex = index;
    NSMutableArray *labels = [NSMutableArray array];
    for (const auto &feature : features) {
        NSString *label = @(feature.c_str());
        if (label.length && ![labels containsObject:label])
            [labels addObject:label];
    }
    result.sources = labels;
    return result;
}
bool primaryChange(const Change &change, const std::vector<Cluster> &roots) {
    auto first = std::lower_bound(roots.begin(), roots.end(), change.source.start,
        [](const Cluster &input, uint32_t start) { return input.source.end <= start; });
    auto last = first;
    while (last != roots.end() && last->source.start < change.source.end) ++last;
    if (size_t(last - first) == change.inputs.size() &&
        std::equal(first, last, change.inputs.begin(),
                   [](const Cluster &a, const Cluster &b) {
                       return a.source == b.source && a.glyphs == b.glyphs;
                   }))
        return true;
    // A ligature can be formed from already localized/joined input glyphs.
    return change.inputs.size() > 1;
}
std::vector<std::pair<Tag, unsigned>> plans(const Resource &resource, const Domain &domain) {
    std::vector<std::pair<Tag, unsigned>> result{{0, 0}};
    if (!domain.apple)
        for (const auto &[feature, maximum] : resource.featureSpecs)
            for (unsigned value = 1; value <= maximum; value++)
                result.emplace_back(feature, value);
    return result;
}
} // namespace

// The resource program owns only immutable table bytes. Coordinate-specific
// fonts and layout state belong to an engine instance, outside the shared cache.
@interface GAFontProgram : NSObject {
  @public
    std::shared_ptr<Resource> resource;
}
@property(nonatomic, strong, readonly) NSCache<id, NSArray<GASubstitutionMatch *> *> *cache;
@property(nonatomic, strong, readonly) NSCache<NSArray *, NSIndexSet *> *glyphOutputCache;
@property(nonatomic, strong, readonly) NSCache<NSNumber *, NSArray<NSDictionary *> *> *relatedCache;
@property(nonatomic, strong, readonly) NSCache<NSString *, NSArray<NSNumber *> *> *positioningContexts;
@end
@implementation GAFontProgram
- (instancetype)initWithFont:(CTFontRef)font {
    self = [super init];
    if (self) {
        resource = std::make_shared<Resource>(font);
        _cache = [[NSCache alloc] init];
        _glyphOutputCache = [[NSCache alloc] init];
        _glyphOutputCache.countLimit = 24;
        _relatedCache = [[NSCache alloc] init];
        _relatedCache.countLimit = 2048;
        _relatedCache.totalCostLimit = 16 * 1024 * 1024;
        _positioningContexts = [[NSCache alloc] init];
        _positioningContexts.countLimit = 1024;
        _positioningContexts.totalCostLimit = 1024 * 1024;
        _cache.countLimit = 2048;
        _cache.totalCostLimit = 32 * 1024 * 1024;
    }
    return self;
}
@end

@interface GASubstitutionEngine ()
@property(nonatomic, strong, readonly) GAFontProgram *program;
- (NSArray<NSDictionary *> *)relatedOutputs:(Glyph)glyph cancellation:(const Cancellation *)cancellation;
- (NSArray<GASubstitutionMatch *> *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections
                     cancellation:(const Cancellation *)cancellation
                   nextParagraphs:(std::optional<ParagraphCache> &)nextParagraphs
                       incomplete:(BOOL &)incomplete;
@end
@implementation GASubstitutionEngine {
    CTFontRef _font;
    std::optional<std::vector<double>> _normalizedCoordinates;
    std::shared_ptr<const ParagraphCache> _paragraphCache;
    std::unordered_map<uint32_t, double> _deviceDeltas;
    std::mutex _deviceDeltasMutex;
}
- (instancetype)initWithFont:(CTFontRef)font
                 coordinates:(NSDictionary *)coordinates
                     sharing:(GASubstitutionEngine *)source {
    self = [super init];
    if (self) {
        _font = (CTFontRef)CFRetain(font);
        _program = source.program ?: [[GAFontProgram alloc] initWithFont:font];
        if (source) {
            // Discovery is coordinate-independent, including its completed
            // paragraph results; positioning remains local to this instance.
            @synchronized (source) { _paragraphCache = source->_paragraphCache; }
        }
        const auto &resource = *_program->resource;
        std::map<Tag, double> values;
        for (NSNumber *axis in coordinates)
            values[axis.unsignedIntValue] = [coordinates[axis] doubleValue];
        try {
            _normalizedCoordinates = normalizeCoordinates(resource.fvar, resource.avar, values);
        } catch (const InvalidTable &) {
            // Static layout remains usable when the variation coordinates are unknown.
        }
    }
    return self;
}
- (void)dealloc {
    if (_font)
        CFRelease(_font);
}
- (NSArray<NSDictionary *> *)relatedOutputs:(Glyph)glyph cancellation:(const Cancellation *)cancellation {
    NSArray *cached = [self.program.relatedCache objectForKey:@(glyph)];
    if (cached)
        return cached;
    NSMutableArray *outputs = [NSMutableArray array];
    try {
        const auto &r = *self.program->resource;
        for (const auto &output : r.gsub.relatedSubstitutions(glyph, r.gdef, cancellation)) {
            std::string label = featureLabel(output.feature, output.value);
            [outputs addObject:@{
                @"glyphs" : glyphArray(output.glyphs),
                @"source" : @(label.c_str())
            }];
        }
        if (r.verticalAAT)
            for (const auto &domain : r.domains) {
                if (!domain.apple || (domain.selector && domain.selector->type != 4)) continue;
                Buffer input = literalBuffer({glyph});
                r.aat.substitute(input, domain.selector, false, true, nullptr, true, {}, cancellation);
                auto ids = identifiers(input);
                if (ids == std::vector<Glyph>{glyph}) continue;
                std::string source = r.aat.featureLabel(domain.selector);
                [outputs addObject:@{@"glyphs":glyphArray(ids),@"source":@(source.c_str()),@"vertical":@YES}];
            }
    } catch (const InvalidTable &) {
        // Keep any catalogue entries already collected.
    }
    checkCancellation(cancellation);
    [self.program.relatedCache setObject:outputs forKey:@(glyph) cost:outputs.count * 128];
    return outputs;
}
- (NSArray<GASubstitutionMatch *> *)discoverContent:(NSString *)text
                       selections:(NSArray<GAGlyphSelectionRun *> *)selections
                     cancellation:(const Cancellation *)cancellation
                   nextParagraphs:(std::optional<ParagraphCache> &)nextParagraphs
                       incomplete:(BOOL &)incomplete {
    checkCancellation(cancellation);
    GAGlyphQueryIdentity *queryKey = GAGlyphQueryKey(text, selections);
    NSArray<GASubstitutionMatch *> *cached = [self.program.cache objectForKey:queryKey];
    if (cached)
        return cached;
    const auto &r = *self.program->resource;
    std::vector<Span> unpairedSelectors;
    const auto runs = prepareText(text, r.cmap, selections, -1, &unpairedSelectors);
    std::vector<bool> selectedRuns(runs.size());
    NSUInteger selectionIndex = 0;
    for (size_t i = 0; i < runs.size(); ++i) {
        const Span span = runs[i].source;
        while (selectionIndex < selections.count &&
               NSMaxRange(selections[selectionIndex].range) <= span.start)
            ++selectionIndex;
        selectedRuns[i] = selectionIndex < selections.count &&
                          selections[selectionIndex].range.location < span.end;
    }
    auto paragraphs = queryParagraphs(text, runs, cancellation);
    size_t remaining = paragraphCacheBudget;
    if (!paragraphs.empty()) {
        std::shared_ptr<const ParagraphCache> previous;
        @synchronized (self) { previous = _paragraphCache; }
        prepareParagraphCache(paragraphs, runs, selectedRuns, previous.get(), remaining, cancellation);
    }
    std::vector<std::vector<Cluster>> runRoots;
    runRoots.reserve(runs.size());
    for (const auto &run : runs) {
        checkCancellation(cancellation);
        runRoots.push_back(clusters(run.glyphs));
    }
    NSMutableArray *matches = [NSMutableArray array];
    MatchIndex seen;
    std::set<Span> inputSpans;
    // The root is the prepared cmap/UVS input (or the user's literal seed).
    // Shaping results are discoveries, never replacements for this row.
    for (const auto &roots : runRoots)
        for (const auto &cluster : roots) {
            checkCancellation(cancellation);
            merge(seen, matches, cluster.source, cluster.glyphs, nil, YES);
            inputSpans.insert(cluster.source);
        }
    // Catalogue order comes first; text matches below merge into these rows.
    // Preserve other GIDs belonging to the same atomic input cluster.
    for (const auto &roots : runRoots)
        for (const auto &cluster : roots)
            for (size_t i = 0; i < cluster.glyphs.size(); i++)
                for (NSDictionary *output in [self relatedOutputs:cluster.glyphs[i] cancellation:cancellation]) {
                    checkCancellation(cancellation);
                    auto sequence = replacingGlyph(cluster.glyphs, i, output);
                    merge(seen, matches, cluster.source, sequence, output[@"source"], NO);
                }
    std::vector<std::map<size_t, Trace>> appleResults(runs.size());
    for (size_t domainIndex = 0; domainIndex < r.domains.size(); ++domainIndex) {
        const auto &domain = r.domains[domainIndex];
        size_t paragraphIndex = 0;
        for (size_t runIndex = 0; runIndex < runs.size(); ++runIndex) {
            QueryParagraph *paragraph = nullptr;
            if (!paragraphs.empty()) {
                if (runIndex == paragraphs[paragraphIndex].endRun)
                    ++paragraphIndex;
                paragraph = &paragraphs[paragraphIndex];
                if (paragraph->reused) {
                    if (runIndex == paragraph->firstRun) {
                        checkCancellation(cancellation);
                        auto cachedDomain = paragraph->reused->domains.find(domainIndex);
                        if (cachedDomain != paragraph->reused->domains.end())
                            for (const auto &match : cachedDomain->second) {
                                checkCancellation(cancellation);
                                const uint32_t base = paragraph->source.start;
                                merge(seen, matches, {match.source.start + base, match.source.end + base},
                                      match.glyphs, match.label, NO);
                            }
                    }
                    continue;
                }
            }
            const auto &run = runs[runIndex];
            const auto &roots = runRoots[runIndex];
            std::vector<Tag> scripts{run.script};
            if (!domain.apple && selectedRuns[runIndex])
                for (const auto &script : r.gsub.scripts())
                    if (std::find(scripts.begin(), scripts.end(), script.name) == scripts.end())
                        scripts.push_back(script.name);
            using StepKey = std::tuple<unsigned, unsigned, Tag, bool>;
            std::set<std::vector<StepKey>> executed;
            for (Tag script : scripts) {
                auto languages = domain.apple ? std::vector<Tag>{0} : r.gsub.languages(script);
                for (Tag language : languages)
                    for (auto plan : plans(r, domain)) {
                        checkCancellation(cancellation);
                        Settings settings;
                        settings.script = script;
                        settings.language = language;
                        settings.rtl = run.level & 1;
                        if (plan.first)
                            settings.features[plan.first] = plan.second;
                        Trace found;
                        const Trace *trace = &found;
                        auto &shared = appleResults[runIndex];
                        auto previous = shared.find(domain.sharedSchedule);
                        if (previous != shared.end()) {
                            trace = &previous->second;
                        } else {
                            Buffer items = run.glyphs;
                            found.inventory = true;
                            try {
                                if (domain.apple) {
                                    r.substitute(items, domain, settings, &found, cancellation);
                                } else {
                                    const auto steps = r.gsub.plan(settings, domain.branch);
                                    std::vector<StepKey> key;
                                    for (const auto &step : steps)
                                        key.emplace_back(step.lookup, step.value, step.feature,
                                                         step.explicitValue);
                                    if (!executed.insert(std::move(key)).second)
                                        continue;
                                    r.gsub.substituteLookups(items, r.gdef, steps, &found, cancellation);
                                }
                            } catch (const InvalidTable &) {
                                found = {};
                                if (paragraph) paragraph->output.reset();
                            }
                        }
                        if (trace->incomplete) {
                            incomplete = YES;
                            if (paragraph) paragraph->output.reset();
                        }
                        const auto appleLabel = domain.apple
                            ? r.aat.featureLabel(domain.selector) : std::string{};
                        for (const auto &change : trace->changes) {
                            checkCancellation(cancellation);
                            // Keep direct changes of the original input and
                            // newly formed combinations. Later changes of a
                            // variant are resolved lazily when clicked.
                            if (!primaryChange(change, roots))
                                continue;
                            auto glyphs = change.glyphs;
                            if (settings.rtl)
                                std::reverse(glyphs.begin(), glyphs.end());
                            const auto &label = domain.apple ? appleLabel : change.feature;
                            NSString *source = @(label.c_str());
                            if (merge(seen, matches, change.source, glyphs, source, NO) && paragraph)
                                paragraph->remember(domainIndex, change.source, glyphs, source, remaining);
                        }
                        if (domain.lastUseOfSchedule) {
                            if (previous != shared.end())
                                shared.erase(previous);
                        } else if (domain.sharedSchedule && previous == shared.end())
                            shared.emplace(domain.sharedSchedule, std::move(found));
                    }
            }
        }
    }
    // A first-formed composition is a browsing root in its own right.
    // List its direct catalogue outputs, without closing over their outputs.
    NSArray *firstLevel = [matches copy];
    std::set<Span> compositionRoots;
    for (GASubstitutionMatch *match in firstLevel) {
        checkCancellation(cancellation);
        Span span{uint32_t(match.sourceRange.location), uint32_t(NSMaxRange(match.sourceRange))};
        if (inputSpans.count(span) || !compositionRoots.insert(span).second)
            continue;
        auto original = glyphVector(match.glyphIDs);
        for (size_t i = 0; i < original.size(); i++)
            for (NSDictionary *output in [self relatedOutputs:original[i] cancellation:cancellation])
                merge(seen, matches,
                      {uint32_t(match.sourceRange.location), uint32_t(NSMaxRange(match.sourceRange))},
                      replacingGlyph(original, i, output), output[@"source"], NO);
    }
    // Report these code points as missing without adding them to the shaping input.
    for (Span span : unpairedSelectors) {
        checkCancellation(cancellation);
        auto next = inputSpans.lower_bound({span.start, 0});
        if ((next != inputSpans.end() && next->start < span.end) ||
            (next != inputSpans.begin() && std::prev(next)->end > span.start))
            continue;
        merge(seen, matches, span, {0}, nil, YES);
    }
    checkCancellation(cancellation);
    nextParagraphs.emplace();
    for (auto &paragraph : paragraphs) {
        auto result = paragraph.reused ? paragraph.reused : std::move(paragraph.output);
        if (result)
            nextParagraphs->try_emplace(std::move(paragraph.key), std::move(result));
    }
    if (!incomplete)
        [self.program.cache setObject:matches
                               forKey:queryKey
                                 cost:text.length * 2 + matches.count * 128];
    return matches;
}
- (NSArray<GASubstitutionMatch *> *)discoverText:(NSString *)text
                                      selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                      incomplete:(BOOL *)incomplete
                                       cancelled:(BOOL (^)(void))cancelled {
    if (incomplete) *incomplete = NO;
    if (cancelled && cancelled())
        return nil;
    if (!text.length)
        return @[];
    Cancellation cancellation{[cancelled] { return cancelled() != NO; }};
    const Cancellation *check = cancelled ? &cancellation : nullptr;
    try {
        std::optional<ParagraphCache> nextParagraphs;
        BOOL didExhaust = NO;
        NSMutableArray *matches = [[self discoverContent:text selections:selections cancellation:check
                                           nextParagraphs:nextParagraphs incomplete:didExhaust] mutableCopy];
        [matches sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(GASubstitutionMatch *a,
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
        checkCancellation(check);
        if (nextParagraphs) {
            @synchronized (self) {
                checkCancellation(check);
                _paragraphCache = nextParagraphs->empty() ? nullptr
                    : std::make_shared<const ParagraphCache>(std::move(*nextParagraphs));
            }
        }
        if (incomplete) *incomplete = didExhaust;
        return matches;
    } catch (const QueryCancelled &) {
        return nil;
    } catch (const std::exception &) {
        // Failed discovery yields no candidates.
    }
    return @[];
}
- (NSArray<NSString *> *)languageTags {
    const auto &r = *self.program->resource;
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (Tag language : r.gsub.languageTags())
        [result addObject:@(tagName(language).c_str())];
    return result;
}

- (NSArray<NSString *> *)glyphFeatureTags {
    const auto &r = *self.program->resource;
    NSMutableOrderedSet<NSString *> *tags = [NSMutableOrderedSet orderedSet];
    try {
        const auto branch = [self gsubBranch];
        for (const auto &feature : r.gsub.features(branch)) {
            if (feature.lookups.empty()) continue;
            NSString *label = @(tagName(feature.name).c_str());
            if (label.length == 4)
                [tags addObject:label];
        }
    } catch (const InvalidTable &) {
        // AAT labels are still available if GSUB variation data is invalid.
    }
    for (const auto &entry : r.outputSelectors)
        [tags addObject:@(entry.first.c_str())];
    return tags.array;
}

- (NSIndexSet *)glyphOutputsForFeatureTag:(NSString *)label cancelled:(BOOL (^)(void))cancelled {
    const auto &r = *self.program->resource;
    Cancellation cancellation{[cancelled] { return cancelled && cancelled(); }};
    try {
        cancellation.check();
        const bool openType = label.length == 4;
        const auto branch = openType || !label.length ? [self gsubBranch] : 0;
        NSArray *key = @[label, @(branch)];
        if (NSIndexSet *cached = [self.program.glyphOutputCache objectForKey:key])
            return cached;
        if (!label.length) {
            NSMutableIndexSet *unfeatured = [NSMutableIndexSet indexSetWithIndexesInRange:
                NSMakeRange(0, CTFontGetGlyphCount(_font))];
            for (NSString *feature in self.glyphFeatureTags) {
                NSIndexSet *outputs = [self glyphOutputsForFeatureTag:feature cancelled:cancelled];
                if (!outputs) return nil;
                [unfeatured removeIndexes:outputs];
            }
            cancellation.check();
            NSIndexSet *result = [unfeatured copy];
            [self.program.glyphOutputCache setObject:result forKey:key];
            return result;
        }
        const char *name = label.UTF8String;
        if (!name)
            return [NSIndexSet indexSet];
        std::vector<bool> outputs(std::min<size_t>(CTFontGetGlyphCount(_font), 65536));
        if (openType) {
            r.gsub.collectFeatureOutputs(tag(name), branch, r.gdef, outputs, &cancellation);
        } else {
            auto entry = r.outputSelectors.find(name);
            if (entry != r.outputSelectors.end())
                r.aat.collectFeatureOutputs(entry->second, outputs, &cancellation);
        }
        NSMutableIndexSet *glyphs = [NSMutableIndexSet indexSet];
        for (size_t i = 0; i < outputs.size(); ++i)
            if (outputs[i])
                [glyphs addIndex:i];
        cancellation.check();
        NSIndexSet *result = [glyphs copy];
        [self.program.glyphOutputCache setObject:result forKey:key];
        return result;
    } catch (const QueryCancelled &) {
        return nil;
    } catch (const InvalidTable &) {
        return nil;
    }
}

- (GASubstitutionOrigin *)originForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                sourceRange:(NSRange)sourceRange
                                       text:(NSString *)text
                                 selections:(NSArray<GAGlyphSelectionRun *> *)selections
                                 candidates:(NSArray<NSArray<NSNumber *> *> *)candidates
                                   vertical:(BOOL)vertical
                       featureSettings:(NSArray<NSDictionary *> *)featureSettings
                   baseWritingDirection:(NSInteger)direction
                            languageTag:(NSString *)languageTag
                                  cancelled:(BOOL (^)(void))cancelled {
    if (!sourceRange.length || NSMaxRange(sourceRange) > text.length || !candidates.count)
        return nil;
    const auto &r = *self.program->resource;
    Span span{uint32_t(sourceRange.location), uint32_t(NSMaxRange(sourceRange))};
    auto target = glyphVector(glyphIDs);
    std::vector<std::vector<Glyph>> sources;
    for (NSArray *candidate in candidates)
        sources.push_back(glyphVector(candidate));
    try {
        size_t branch = [self gsubBranch];
        // This is our executor's replay, not a trace of TextKit internals.
        // Accept it only when its final sequence and complete source agree.
        for (const auto &run : prepareText(text, r.cmap, selections, int(direction))) {
            if (cancelled()) return nil;
            if (run.source.start > span.start || run.source.end < span.end) continue;
            Settings settings;
            settings.script = run.script;
            settings.language = tag(languageTag.UTF8String ?: "");
            settings.rtl = run.level & 1;
            settings.vertical = vertical;
            if (vertical) settings.features[r.verticalFeature(branch)] = 1;
            for (NSDictionary *feature in featureSettings) {
                NSString *name = feature[(__bridge NSString *)kCTFontOpenTypeFeatureTag];
                if (name.length == 4)
                    settings.features[tag(name.UTF8String)] =
                        [feature[(__bridge NSString *)kCTFontOpenTypeFeatureValue] unsignedIntValue];
            }
            Buffer items = run.glyphs;
            Trace trace;
            trace.provenance = true;
            if (!r.aat.empty()) {
                std::vector<AATSelector> overrides;
                for (NSDictionary *feature in featureSettings) {
                    NSNumber *type = feature[(__bridge NSString *)kCTFontFeatureTypeIdentifierKey];
                    NSNumber *selector = feature[(__bridge NSString *)kCTFontFeatureSelectorIdentifierKey];
                    if (type && selector) overrides.push_back({type.unsignedIntValue, selector.unsignedIntValue});
                }
                r.aat.substitute(items, {}, settings.rtl, vertical, &trace, false, overrides);
            } else
                r.gsub.substitute(items, r.gdef, settings, branch, &trace);
            auto final = sequenceAt(items, span, settings.rtl);
            if (!final || *final != target) continue;
            auto current = target;
            std::vector<std::string> labels;
            for (auto step = trace.steps.rbegin(); step != trace.steps.rend(); ++step) {
                auto after = sequenceAt(step->after, span, settings.rtl);
                auto before = sequenceAt(step->before, span, settings.rtl);
                if (!after || *after != current || !before) break;
                if (*before == current) continue;
                labels.insert(labels.begin(), step->feature);
                for (size_t i = 0; i < sources.size(); i++)
                    if (*before == sources[i]) return origin(i, labels);
                current = std::move(*before);
            }
        }
    } catch (const InvalidTable &) {
        // An unavailable replay proceeds to independent source discovery.
    }

    // Multi-source breadth-first traversal. Two visits per sequence retain
    // paths with/without a vertical feature separately. Mode preference wins
    // over distance; BFS then resolves shortest path and sidebar order.
    struct State {
        std::vector<Glyph> glyphs;
        size_t source;
        bool vertical;
        std::vector<std::string> labels;
    };
    std::deque<State> pending;
    std::set<std::pair<std::vector<Glyph>, bool>> visited;
    std::map<std::vector<Glyph>, std::vector<OriginEdge>> edges;
    GASubstitutionOrigin *otherMode = nil;
    Budget budget(text.length);
    size_t queuedGlyphs = 0;
    try {
        for (size_t i = 0; i < sources.size(); i++)
            if (visited.emplace(sources[i], false).second) {
                pending.push_back({sources[i], i, false, {}});
                queuedGlyphs += sources[i].size();
            }
        while (!pending.empty()) {
            if (cancelled()) return nil;
            budget.step();
            State state = std::move(pending.front());
            pending.pop_front();
            queuedGlyphs -= state.glyphs.size();
            if (state.glyphs == target) {
                if (state.vertical == bool(vertical)) return origin(state.source, state.labels);
                if (!otherMode) otherMode = origin(state.source, state.labels);
                continue;
            }
            if (otherMode && !vertical && state.vertical) continue;
            auto [entry, inserted] = edges.emplace(state.glyphs, std::vector<OriginEdge>{});
            auto &outputs = entry->second;
            if (inserted) {
                // Static single-GID catalogue plus actual full-context matches
                // cover contextual and multi-GID/composition sources alike.
                for (size_t i = 0; i < state.glyphs.size(); i++)
                    for (NSDictionary *output in [self relatedOutputs:state.glyphs[i] cancellation:nullptr]) {
                        std::string label = [output[@"source"] UTF8String];
                        outputs.push_back({replacingGlyph(state.glyphs, i, output), label,
                                           verticalSource(label) || [output[@"vertical"] boolValue]});
                    }
                NSMutableArray *seedRuns = [NSMutableArray array];
                for (GAGlyphSelectionRun *selection in selections)
                    if (!NSIntersectionRange(selection.range, sourceRange).length)
                        [seedRuns addObject:selection];
                GAGlyphSelectionRun *seed = [[GAGlyphSelectionRun alloc] init];
                seed.range = sourceRange;
                seed.selection = [[GAGlyphSelection alloc]
                    initWithSourceText:[text substringWithRange:sourceRange]
                    glyphIDs:glyphArray(state.glyphs) featureSources:@[] ligature:NO];
                [seedRuns addObject:seed];
                [seedRuns sortUsingComparator:^NSComparisonResult(GAGlyphSelectionRun *a,
                                                                   GAGlyphSelectionRun *b) {
                    return a.range.location < b.range.location ? NSOrderedAscending
                         : a.range.location > b.range.location ? NSOrderedDescending : NSOrderedSame;
                }];
                for (const auto &run : prepareText(text, r.cmap, seedRuns, int(direction))) {
                    if (run.source.start > span.start || run.source.end < span.end) continue;
                    for (const auto &domain : r.domains)
                        for (Tag language : domain.apple ? std::vector<Tag>{0}
                                                       : r.gsub.languages(run.script))
                            for (auto plan : plans(r, domain))
                                for (bool orientation : domain.apple && r.verticalAAT
                                                            ? std::vector<bool>{false, true}
                                                            : std::vector<bool>{false}) {
                                    if (cancelled()) return nil;
                                    budget.step();
                                    Settings settings;
                                    settings.script = run.script;
                                    settings.language = language;
                                    settings.rtl = run.level & 1;
                                    settings.vertical = orientation;
                                    if (plan.first) settings.features[plan.first] = plan.second;
                                    Buffer items = run.glyphs;
                                    Trace found;
                                    found.inventory = true;
                                    try {
                                        r.substitute(items, domain, settings, &found);
                                    } catch (const InvalidTable &) {
                                        continue;
                                    }
                                    for (const auto &change : found.changes) {
                                        if (!(change.source == span) || change.inherited) continue;
                                        std::vector<Glyph> input;
                                        for (const auto &cluster : change.inputs)
                                            input.insert(input.end(), cluster.glyphs.begin(), cluster.glyphs.end());
                                        auto output = change.glyphs;
                                        if (settings.rtl) {
                                            std::reverse(input.begin(), input.end());
                                            std::reverse(output.begin(), output.end());
                                        }
                                        if (input == state.glyphs)
                                            outputs.push_back({std::move(output), change.feature,
                                                verticalSource(change.feature) || change.vertical});
                                    }
                                }
                }
            }
            for (const auto &output : outputs) {
                budget.step();
                bool containsVertical = state.vertical || output.vertical;
                if (output.glyphs.empty() || output.glyphs == state.glyphs ||
                    !visited.emplace(output.glyphs, containsVertical).second) continue;
                budget.growth(queuedGlyphs + output.glyphs.size());
                queuedGlyphs += output.glyphs.size();
                State next{output.glyphs, state.source, containsVertical, state.labels};
                next.labels.push_back(output.feature);
                pending.push_back(std::move(next));
            }
        }
    } catch (const InvalidTable &) {
        // Cycles, malformed data and excessive discovery cannot stall a click.
    }
    return otherMode;
}
- (size_t)gsubBranch {
    return _normalizedCoordinates
        ? self.program->resource->gsub.variationBranch(*_normalizedCoordinates) : 0;
}
- (BOOL)typoMetricsAscender:(CGFloat *)ascender descender:(CGFloat *)descender {
    const auto &r = *self.program->resource;
    // OS/2 typographic values are design units and need the head table's em
    // scale. Bitmap-only fonts (no head) can store pixel metrics there; use
    // CoreText's ascent/descent fallback instead.
    if (r.head.size() < 54 || r.head.u16(18) == 0 || r.os2.size() < 72)
        return NO;
    double top = r.os2.s16(68);
    double bottom = r.os2.s16(70);
    try {
        if (r.variationStore && _normalizedCoordinates) {
            const auto &normalized = *_normalizedCoordinates;
            if (r.ascenderVariation.present)
                top += variationDelta(r.variationStore, r.ascenderVariation.outer,
                                      r.ascenderVariation.inner, normalized);
            if (r.descenderVariation.present)
                bottom += variationDelta(r.variationStore, r.descenderVariation.outer,
                                         r.descenderVariation.inner, normalized);
        }
    } catch (const InvalidTable &) {
        // Malformed variation data leaves the static OS/2 values in place.
        top = r.os2.s16(68);
        bottom = r.os2.s16(70);
    }
    if (!std::isfinite(top) || !std::isfinite(bottom))
        return NO;
    top = std::round(top);
    bottom = std::round(bottom);
    if (top + std::fabs(bottom) <= 0)
        return NO;
    *ascender = top;
    *descender = bottom;
    return YES;
}
- (double)cachedDeviceDelta:(const View &)device {
    if (device.u16(4) != 0x8000) return 0;
    uint32_t key = (uint32_t(device.u16(0)) << 16) | device.u16(2);
    {
        std::lock_guard<std::mutex> lock(_deviceDeltasMutex);
        auto found = _deviceDeltas.find(key);
        if (found != _deviceDeltas.end()) return found->second;
    }
    // Decode on demand and keep failures uncached: unused malformed records
    // must not affect other lookups or change the existing GPOS fallback.
    double value = variationDelta(self.program->resource->gdef.variations,
                                  key >> 16, key & 0xffff, *_normalizedCoordinates);
    {
        std::lock_guard<std::mutex> lock(_deviceDeltasMutex);
        if (_deviceDeltas.size() < 2048) _deviceDeltas.emplace(key, value);
    }
    return value;
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
    if (_normalizedCoordinates)
        metrics.normalized = *_normalizedCoordinates;
    else
        metrics.variationCoordinatesValid = false;
    if (_normalizedCoordinates && r.gdef.variations)
        metrics.deviceDelta = [self](const View &device) {
            return [self cachedDeviceDelta:device];
        };
    return metrics;
}
- (void)position:(Buffer &)buffer settings:(const Settings &)settings {
    const auto &r = *self.program->resource;
    Metrics metrics = [self metrics];
    Buffer nominal = buffer;
    bool hasKerning = false;
    try {
        size_t branch = metrics.variationCoordinatesValid ? r.gpos.variationBranch(metrics.normalized) : 0;
        hasKerning = r.gpos.position(buffer, r.gdef, settings, metrics, branch);
    } catch (const InvalidTable &) {
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
        } catch (const InvalidTable &) {
            buffer = std::move(before);
        }
    }
    for (auto &item : buffer)
        if (item.ignorable)
            item.xAdvance = item.yAdvance = 0;
}
- (NSArray<NSValue *> *)positionsForGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                                     content:(NSString *)content {
    try {
        const auto &r = *self.program->resource;
        Settings settings;
        if (content.length) {
            NSArray<NSNumber *> *context = [self.program.positioningContexts objectForKey:content];
            if (context) {
                settings.script = context[0].unsignedIntValue;
                settings.rtl = context[1].boolValue;
            } else {
                auto runs = prepareText(content, r.cmap);
                if (!runs.empty()) {
                    settings.script = runs.front().script;
                    settings.rtl = runs.front().level & 1;
                }
                // Cmap and Unicode preparation belong to the shared resource;
                // advances, GPOS and variation coordinates remain instance-local.
                if (content.length <= 32768)
                    [self.program.positioningContexts
                        setObject:@[@(settings.script), @(settings.rtl)]
                           forKey:[content copy] cost:content.length * 2 + 128];
            }
        }
        // Pair and attachment lookups need a second glyph. With no single
        // positioning coverage, the only origin is zero regardless of advance.
        if (glyphIDs.count == 1 && r.unitsPerEm > 0 &&
            !r.gpos.mayPositionSingleGlyph(glyphIDs.firstObject.unsignedShortValue)) {
            static NSArray<NSValue *> *zeroOrigin;
            static dispatch_once_t once;
            dispatch_once(&once, ^{ zeroOrigin = @[[NSValue valueWithPoint:NSZeroPoint]]; });
            return zeroOrigin;
        }
        Buffer items = literalBuffer(glyphVector(glyphIDs));
        if (settings.rtl)
            std::reverse(items.begin(), items.end());
        [self position:items settings:settings];
        if (settings.rtl)
            std::reverse(items.begin(), items.end());
        double scale = CTFontGetSize(_font) / r.unitsPerEm;
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
    } catch (const std::exception &) {
        // Failed positioning yields no explicit origins.
    }
    return @[];
}
- (NSArray<GASubstitutionMatch *> *)discoverGlyphIDs:(NSArray<NSNumber *> *)glyphIDs
                               cancelled:(BOOL (^)(void))cancelled {
    if (cancelled && cancelled())
        return nil;
    if (!glyphIDs.count)
        return @[];
    NSArray *key = @[ @"glyphs", [glyphIDs copy] ];
    NSArray<GASubstitutionMatch *> *cached = [self.program.cache objectForKey:key];
    if (cached)
        return cached;
    Cancellation cancellation{[cancelled] { return cancelled() != NO; }};
    const Cancellation *check = cancelled ? &cancellation : nullptr;
    try {
        const auto &r = *self.program->resource;
        auto original = glyphVector(glyphIDs);
        const auto roots = clusters(literalBuffer(original));
        Span whole{0, uint32_t(original.size())};
        NSMutableArray *matches = [NSMutableArray array];
        MatchIndex seen;
        bool complete = true;
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
                        trace.inventory = true;
                        r.substitute(items, domain, settings, &trace, check);
                        complete &= !trace.incomplete;
                        for (const auto &change : trace.changes) {
                            checkCancellation(check);
                            if (!primaryChange(change, roots) ||
                                change.source.end > original.size())
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
        for (size_t i = 0; i < original.size(); i++)
            for (NSDictionary *output in [self relatedOutputs:original[i] cancellation:check]) {
                checkCancellation(check);
                auto sequence = replacingGlyph(original, i, output);
                merge(seen, matches, whole, sequence, output[@"source"], NO);
            }
        checkCancellation(check);
        if (complete)
            [self.program.cache setObject:matches
                                   forKey:key
                                     cost:glyphIDs.count * 2 + matches.count * 128];
        return matches;
    } catch (const QueryCancelled &) {
        return nil;
    } catch (const std::exception &) {
        // Failed discovery yields no candidates.
    }
    return @[];
}
- (NSNumber *)verticalGlyph:(uint16_t)glyph {
    try {
        const auto &r = *self.program->resource;
        for (const auto &domain : r.domains) {
            if (!domain.apple || (domain.selector && domain.selector->type != 4))
                continue;
            Buffer items = literalBuffer({glyph});
            r.aat.substitute(items, domain.selector, false, true, nullptr, true);
            if (items.size() == 1 && items.front().glyph != glyph)
                return @(items.front().glyph);
        }
        size_t branch = [self gsubBranch];
        Tag name = r.verticalFeature(branch);
        for (const auto &feature : r.gsub.features(branch)) {
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
    } catch (const std::exception &) {
        // A failed lookup has no vertical substitute.
    }
    return nil;
}
@end
