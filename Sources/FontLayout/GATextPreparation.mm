#import "GATextPreparation.h"
#import "Font/GAGlyphSelection.h"
#include "GACmap.h"
#include <cctype>
#include <deque>
#include <memory>
extern "C" {
int32_t uscript_getScript(int32_t, int32_t *);
const char *uscript_getShortName(int32_t);
int32_t u_getPropertyEnum(const char *);
int32_t u_getPropertyValueEnum(int32_t, const char *);
int32_t u_getIntPropertyValue(int32_t, int32_t);
void *ubidi_openSized(int32_t, int32_t, int32_t *);
void ubidi_setPara(void *, const uint16_t *, int32_t, uint8_t, const uint8_t *, int32_t *);
uint8_t ubidi_getLevelAt(const void *, int32_t);
void ubidi_close(void *);
}
namespace ga::layout {
static Tag scriptTag(NSString *name) {
    std::string s = name.UTF8String ?: "";
    if (s.size() != 4)
        return tag('D', 'F', 'L', 'T');
    for (auto &c : s)
        c = char(std::tolower(uint8_t(c)));
    static const std::map<std::string, std::string> exceptions = {
        {"hira", "kana"}, {"laoo", "lao "}, {"yiii", "yi  "}, {"nkoo", "nko "}, {"vaii", "vai "}};
    auto found = exceptions.find(s);
    if (found != exceptions.end())
        return tag(found->second);
    if (s == "zyyy" || s == "zinh" || s == "zzzz" || s == "dflt")
        return tag('D', 'F', 'L', 'T');
    return tag(s);
}
static std::vector<uint32_t> scalars(NSString *text) {
    std::vector<uint32_t> result;
    for (NSUInteger i = 0; i < text.length; i++) {
        uint32_t scalar = [text characterAtIndex:i];
        if (CFStringIsSurrogateHighCharacter(scalar) && i + 1 < text.length &&
            CFStringIsSurrogateLowCharacter([text characterAtIndex:i + 1])) {
            scalar = CFStringGetLongCharacterForSurrogatePair(scalar, [text characterAtIndex:++i]);
        }
        result.push_back(scalar);
    }
    return result;
}
// Canonical normalization may compose several original scalars into one
// nominal glyph, or decompose one scalar into several. Match their canonical
// decompositions to retain the actual UTF-16 source of each prepared scalar.
// Overlapping sources remain atomic (for example, an unencoded precomposed
// character decomposed for this font); they must never be split for activation.
static std::vector<Span> scalarSources(NSString *source, NSRange range,
                                       const std::vector<uint32_t> &values) {
    if (values.size() == 1)
        return {{uint32_t(range.location), uint32_t(NSMaxRange(range))}};
    std::map<uint32_t, std::deque<Span>> origins;
    for (NSUInteger i = 0; i < source.length;) {
        NSUInteger length = CFStringIsSurrogateHighCharacter([source characterAtIndex:i]) &&
                                    i + 1 < source.length &&
                                    CFStringIsSurrogateLowCharacter([source characterAtIndex:i + 1])
                                ? 2 : 1;
        NSString *part = [source substringWithRange:NSMakeRange(i, length)];
        Span span{uint32_t(range.location + i), uint32_t(range.location + i + length)};
        for (uint32_t scalar : scalars(part.decomposedStringWithCanonicalMapping))
            origins[scalar].push_back(span);
        i += length;
    }
    std::vector<Span> result;
    for (uint32_t value : values) {
        unichar units[2] = {unichar(value), 0};
        NSUInteger length = 1;
        if (value > 0xffff) {
            units[0] = unichar(0xd800 + ((value - 0x10000) >> 10));
            units[1] = unichar(0xdc00 + ((value - 0x10000) & 0x3ff));
            length = 2;
        }
        NSString *part = [NSString stringWithCharacters:units length:length];
        Span span{uint32_t(NSMaxRange(range)), uint32_t(range.location)};
        for (uint32_t scalar : scalars(part.decomposedStringWithCanonicalMapping)) {
            auto &queue = origins[scalar];
            if (queue.empty()) throw InvalidTable("canonical source mapping failed");
            span = unite(span, queue.front());
            queue.pop_front();
        }
        result.push_back(span);
    }
    return result;
}
static bool variationSelector(uint32_t scalar) {
    return (scalar >= 0xfe00 && scalar <= 0xfe0f) || (scalar >= 0xe0100 && scalar <= 0xe01ef);
}
static Tag scalarScript(uint32_t scalar) {
    int32_t error = 0;
    int32_t script = uscript_getScript(scalar, &error);
    const char *shortName = error > 0 ? nullptr : uscript_getShortName(script);
    return shortName ? scriptTag(@(shortName)) : tag('D', 'F', 'L', 'T');
}
std::vector<TextRun> prepareText(NSString *text, const Cmap &cmap,
                                 NSArray<GAGlyphSelectionRun *> *selections, int baseDirection) {
    std::vector<TextRun> groups;
    if (!text.length)
        return {};
    int32_t status = 0;
    if (text.length > INT32_MAX)
        throw InvalidTable("text exceeds Unicode index range");
    std::vector<NSUInteger> seedBoundaries;
    NSUInteger previousEnd = 0;
    for (GAGlyphSelectionRun *selection : selections) {
        NSRange range = selection.range;
        if (!range.length || range.location < previousEnd || range.location > text.length ||
            range.length > text.length - range.location)
            throw InvalidTable("invalid glyph selection range");
        for (NSUInteger boundary : {range.location, NSMaxRange(range)}) {
            if (boundary > 0 && boundary < text.length &&
                CFStringIsSurrogateHighCharacter([text characterAtIndex:boundary - 1]) &&
                CFStringIsSurrogateLowCharacter([text characterAtIndex:boundary]))
                throw InvalidTable("glyph selection splits a surrogate pair");
            seedBoundaries.push_back(boundary);
        }
        previousEnd = NSMaxRange(range);
    }
    std::vector<uint16_t> units(text.length);
    [text getCharacters:units.data() range:NSMakeRange(0, text.length)];
    std::unique_ptr<void, decltype(&ubidi_close)> bidi(
        ubidi_openSized(int32_t(text.length), 0, &status), ubidi_close);
    if (!bidi)
        throw InvalidTable("Unicode bidi allocation failed");
    ubidi_setPara(bidi.get(), units.data(), int32_t(units.size()),
        baseDirection < 0 ? 0xfe : uint8_t(baseDirection), nullptr, &status);
    if (status > 0) {
        throw InvalidTable("Unicode bidi analysis failed");
    }
    const int32_t ignorableProperty = u_getPropertyEnum("Default_Ignorable_Code_Point");
    uint64_t identity = 1;
    for (NSUInteger start = 0; start < text.length;) {
        NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:start];
        start = NSMaxRange(range);
        TextRun group;
        group.source = {uint32_t(range.location), uint32_t(NSMaxRange(range))};
        group.level = ubidi_getLevelAt(bidi.get(), int32_t(range.location));
        // Normalize on either side of a literal selection independently, so
        // a newly typed accent cannot compose away its selected base glyph.
        auto boundary = std::upper_bound(seedBoundaries.begin(), seedBoundaries.end(), range.location);
        for (NSUInteger partStart = range.location; partStart < NSMaxRange(range);) {
            NSUInteger partEnd = boundary != seedBoundaries.end() && *boundary < NSMaxRange(range)
                                   ? *boundary : NSMaxRange(range);
            NSRange partRange = NSMakeRange(partStart, partEnd - partStart);
            NSString *source = [text substringWithRange:partRange];
            NSString *composed = source.precomposedStringWithCanonicalMapping;
            auto original = scalars(source);
            // Preserve encoded compatibility characters and UVS bases. Canonical
            // composition is useful for combining sequences, but must not erase an
            // explicitly selected glyph that the font can represent.
            if (!original.empty() && cmap.nominal(original.front()) &&
                (original.size() == 1 || variationSelector(original[1])))
                composed = source;
            auto values = scalars(composed);
            bool supported = true;
            for (uint32_t scalar : values)
                if (!variationSelector(scalar) && !u_getIntPropertyValue(scalar, ignorableProperty) &&
                    !cmap.nominal(scalar)) {
                    supported = false;
                    break;
                }
            if (!supported)
                values = scalars(source.decomposedStringWithCanonicalMapping);
            auto sources = scalarSources(source, partRange, values);
            for (size_t i = 0; i < values.size(); i++) {
                uint32_t scalar = values[i];
                if (variationSelector(scalar))
                    continue;
                Item item;
                item.scalar = scalar;
                item.source = sources[i];
                item.glyph = cmap.nominal(scalar);
                item.identity = identity++;
                if (i + 1 < values.size() && variationSelector(values[i + 1])) {
                    if (auto variant = cmap.variation(scalar, values[i + 1]))
                        item.glyph = *variant;
                    item.source = unite(item.source, sources[++i]);
                }
                item.ignorable = u_getIntPropertyValue(scalar, ignorableProperty) != 0;
                Tag script = scalarScript(scalar);
                if (group.script == 0 && script != tag('D', 'F', 'L', 'T'))
                    group.script = script;
                group.glyphs.push_back(item);
            }
            partStart = partEnd;
            while (boundary != seedBoundaries.end() && *boundary <= partStart) ++boundary;
        }
        groups.push_back(std::move(group));
    }
    bidi.reset();
    for (GAGlyphSelectionRun *selection : selections) {
        NSRange range = selection.range;
        Span span{uint32_t(range.location), uint32_t(NSMaxRange(range))};
        auto first = std::find_if(groups.begin(), groups.end(), [&](const TextRun &group) {
            return group.source.end > span.start;
        });
        auto last = std::find_if(first, groups.end(), [&](const TextRun &group) {
            return group.source.start >= span.end;
        });
        if (first == last)
            throw InvalidTable("glyph selection has no source");
        TextRun prefix{{}, {}, first->script, first->level};
        TextRun suffix{{}, {}, (last - 1)->script, (last - 1)->level};
        Span covered{span.end, span.start};
        for (auto group = first; group != last; ++group)
            for (const auto &item : group->glyphs) {
                if (item.source.end <= span.start)
                    prefix.glyphs.push_back(item);
                else if (item.source.start >= span.end)
                    suffix.glyphs.push_back(item);
                else {
                    if (item.source.start < span.start || item.source.end > span.end)
                        throw InvalidTable("glyph selection splits a nominal component");
                    covered = unite(covered, item.source);
                }
            }
        if (!(covered == span))
            throw InvalidTable("glyph selection does not cover nominal components");
        TextRun replacement;
        replacement.source = span;
        replacement.level = first->level;
        replacement.script = first->script;
        for (NSNumber *identifier in selection.selection.glyphIDs) {
            Item item;
            item.glyph = identifier.unsignedShortValue;
            item.source = span;
            item.identity = identity++;
            replacement.glyphs.push_back(item);
        }
        std::vector<TextRun> pieces;
        if (!prefix.glyphs.empty()) {
            prefix.source = {first->source.start, span.start};
            pieces.push_back(std::move(prefix));
        }
        pieces.push_back(std::move(replacement));
        if (!suffix.glyphs.empty()) {
            suffix.source = {span.end, (last - 1)->source.end};
            pieces.push_back(std::move(suffix));
        }
        auto position = groups.erase(first, last);
        groups.insert(position, pieces.begin(), pieces.end());
    }
    // Resolve common/inherited groups at grapheme boundaries, so splitting a run
    // can never leave a surrogate pair or combining sequence half processed.
    Tag previous = 0;
    for (size_t i = 0; i < groups.size(); i++) {
        if (!groups[i].script) {
            groups[i].script = previous;
            if (!groups[i].script)
                for (size_t j = i + 1; j < groups.size(); j++)
                    if (groups[j].script) {
                        groups[i].script = groups[j].script;
                        break;
                    }
        }
        if (!groups[i].script)
            groups[i].script = tag('D', 'F', 'L', 'T');
        previous = groups[i].script;
    }
    std::vector<TextRun> runs;
    bool paragraphStart = true;
    for (auto &group : groups) {
        bool newline = false;
        for (const auto &item : group.glyphs)
            newline |= (item.scalar >= '\n' && item.scalar <= '\r') || item.scalar == 0x0085 ||
                       item.scalar == 0x2028 || item.scalar == 0x2029;
        if (newline) {
            paragraphStart = true;
            continue;
        }
        if (paragraphStart || runs.back().script != group.script ||
            runs.back().level != group.level)
            runs.push_back({{}, group.source, group.script, group.level});
        paragraphStart = false;
        auto &run = runs.back();
        run.source = unite(run.source, group.source);
        run.glyphs.insert(run.glyphs.end(), group.glyphs.begin(), group.glyphs.end());
    }
    // Joining forms are feature masks on nominal glyphs, not substitutions made
    // with presentation-form Unicode characters. Transparent marks do not break joins.
    int32_t joining = u_getPropertyEnum("Joining_Type"),
            dual = u_getPropertyValueEnum(joining, "D"),
            right = u_getPropertyValueEnum(joining, "R"),
            left = u_getPropertyValueEnum(joining, "L"),
            causing = u_getPropertyValueEnum(joining, "C"),
            transparent = u_getPropertyValueEnum(joining, "T");
    for (auto &run : runs) {
        auto &items = run.glyphs;
        for (size_t i = 0; i < items.size(); i++) {
            int value = u_getIntPropertyValue(items[i].scalar, joining);
            if (value == transparent)
                continue;
            auto connectsBefore = [&](int type) {
                return type == dual || type == right || type == causing;
            };
            auto connectsAfter = [&](int type) {
                return type == dual || type == left || type == causing;
            };
            bool before = false, after = false;
            for (size_t p = i; p > 0;) {
                int jt = u_getIntPropertyValue(items[--p].scalar, joining);
                if (jt == transparent)
                    continue;
                before = connectsBefore(value) && connectsAfter(jt);
                break;
            }
            for (size_t p = i + 1; p < items.size(); p++) {
                int jt = u_getIntPropertyValue(items[p].scalar, joining);
                if (jt == transparent)
                    continue;
                after = connectsAfter(value) && connectsBefore(jt);
                break;
            }
            if (connectsBefore(value) || connectsAfter(value))
                items[i].form = before
                                    ? (after ? tag('m', 'e', 'd', 'i') : tag('f', 'i', 'n', 'a'))
                                    : (after ? tag('i', 'n', 'i', 't') : tag('i', 's', 'o', 'l'));
        }
    }
    return runs;
}
} // namespace ga::layout
