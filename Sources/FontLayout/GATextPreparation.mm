#import "GATextPreparation.h"
#include <cctype>
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
Tag scriptTag(NSString *name) {
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
Tag languageTag(NSString *name) {
    if (!name.length)
        return 0;
    std::string language = name.UTF8String ?: "";
    if (language.size() == 4) {
        std::transform(language.begin(), language.end(), language.begin(),
                       [](unsigned char c) { return char(std::toupper(c)); });
        return tag(language);
    }
    // OT language tags that do not follow the language's ISO spelling.
    static const std::map<std::string, std::string> known = {
        {"en", "ENG "},      {"ja", "JAN "},      {"ko", "KOR "},    {"zh", "ZHS "},
        {"zh-Hans", "ZHS "}, {"zh-Hant", "ZHT "}, {"zh-TW", "ZHT "}, {"zh-HK", "ZHH "},
        {"bg", "BGR "},      {"sr", "SRB "},      {"ru", "RUS "},    {"ar", "ARA "},
        {"fa", "FAR "},      {"ur", "URD "},      {"he", "IWR "},    {"tr", "TRK "},
        {"de", "DEU "},      {"fr", "FRA "},      {"el", "ELL "},    {"hi", "HIN "},
        {"th", "THA "},      {"vi", "VIT "},      {"es", "ESP "},    {"it", "ITA "},
        {"pt", "PTG "},      {"pl", "PLK "},      {"nl", "NLD "},    {"ro", "ROM "}};
    auto found = known.find(language);
    return found == known.end() ? 0 : tag(found->second);
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
                                 NSArray<GAGlyphSelectionRun *> *selections) {
    std::vector<TextRun> groups;
    if (!text.length)
        return {};
    int32_t status = 0;
    if (text.length > INT32_MAX)
        throw InvalidTable("text exceeds Unicode index range");
    std::vector<uint16_t> units(text.length);
    [text getCharacters:units.data() range:NSMakeRange(0, text.length)];
    void *bidi = ubidi_openSized(int32_t(text.length), 0, &status);
    if (!bidi)
        throw InvalidTable("Unicode bidi allocation failed");
    ubidi_setPara(bidi, units.data(), int32_t(units.size()), 0xfe, nullptr, &status);
    if (status > 0) {
        ubidi_close(bidi);
        throw InvalidTable("Unicode bidi analysis failed");
    }
    const int32_t ignorableProperty = u_getPropertyEnum("Default_Ignorable_Code_Point");
    uint64_t identity = 1;
    for (NSUInteger start = 0; start < text.length;) {
        NSRange range = [text rangeOfComposedCharacterSequenceAtIndex:start];
        NSString *source = [text substringWithRange:range];
        start = NSMaxRange(range);
        NSString *composed = source.precomposedStringWithCanonicalMapping;
        auto original = scalars(source);
        // Preserve encoded compatibility characters and UVS bases. Canonical
        // composition is useful for combining sequences, but must not erase an
        // explicitly selected glyph that the font can represent.
        if (!original.empty() && cmap.nominal(original.front()) &&
            (original.size() == 1 || (original.size() > 1 && variationSelector(original[1]))))
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
        TextRun group;
        group.source = {uint32_t(range.location), uint32_t(NSMaxRange(range))};
        group.level = ubidi_getLevelAt(bidi, int32_t(range.location));
        for (size_t i = 0; i < values.size(); i++) {
            uint32_t scalar = values[i];
            if (variationSelector(scalar))
                continue;
            Item item;
            item.scalar = scalar;
            item.source = group.source;
            item.glyph = cmap.nominal(scalar);
            item.identity = identity++;
            if (i + 1 < values.size() && variationSelector(values[i + 1])) {
                if (auto variant = cmap.variation(scalar, values[i + 1]))
                    item.glyph = *variant;
                i++;
            }
            item.ignorable = u_getIntPropertyValue(scalar, ignorableProperty) != 0;
            Tag script = scalarScript(scalar);
            if (group.script == 0 && script != tag('D', 'F', 'L', 'T'))
                group.script = script;
            group.glyphs.push_back(item);
        }
        groups.push_back(std::move(group));
    }
    ubidi_close(bidi);
    uint32_t previousEnd = 0;
    for (GAGlyphSelectionRun *selection : selections) {
        NSRange range = selection.range;
        if (!range.length || range.location < previousEnd || range.location > text.length ||
            range.length > text.length - range.location)
            throw InvalidTable("invalid glyph selection range");
        Span span{uint32_t(range.location), uint32_t(NSMaxRange(range))};
        auto first = std::find_if(groups.begin(), groups.end(), [&](const TextRun &group) {
            return group.source.end > span.start;
        });
        auto last = std::find_if(first, groups.end(), [&](const TextRun &group) {
            return group.source.start >= span.end;
        });
        if (first == last || first->source.start != span.start ||
            (last - 1)->source.end != span.end)
            throw InvalidTable("glyph selection splits a grapheme");
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
        auto position = groups.erase(first, last);
        groups.insert(position, std::move(replacement));
        previousEnd = span.end;
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
    for (auto &group : groups) {
        if (runs.empty() || runs.back().script != group.script || runs.back().level != group.level)
            runs.push_back({{}, group.source, group.script, group.level});
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
std::vector<size_t> visualRunOrder(const std::vector<TextRun> &runs) {
    std::vector<size_t> result;
    unsigned highest = 0, lowestOdd = UINT_MAX;
    for (size_t i = 0; i < runs.size(); i++) {
        result.push_back(i);
        highest = std::max(highest, unsigned(runs[i].level));
        if (runs[i].level & 1)
            lowestOdd = std::min(lowestOdd, unsigned(runs[i].level));
    }
    if (lowestOdd == UINT_MAX)
        return result;
    for (unsigned level = highest;; level--) {
        for (size_t start = 0; start < result.size();) {
            while (start < result.size() && runs[result[start]].level < level)
                start++;
            size_t end = start;
            while (end < result.size() && runs[result[end]].level >= level)
                end++;
            std::reverse(result.begin() + start, result.begin() + end);
            start = end;
        }
        if (level == lowestOdd)
            break;
    }
    return result;
}
} // namespace ga::layout
