/*
 * GlyphAtlas review reproductions, commit
 * 22174e5e4cd509db1613efb125a9dd4670e5f73c.
 *
 * Standalone tests of source excerpts, NOT a full macOS application build.
 * The script selection and legacy-kern adjustment functions are copied verbatim.
 * The ligature test runs the original type-4 parsing block against synthetic bytes;
 * only the supporting model types are reduced to the fields that block uses.
 * No complete font file, operating-system font loader, or GUI is exercised.
 * Upstream excerpts are licensed under GlyphAtlas's GPL-3.0 license.
 */
#include <algorithm>
#include <cassert>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

using Glyph = uint16_t;
using Tag = uint32_t;
constexpr Tag tag(char a, char b, char c, char d) {
    return (uint32_t(uint8_t(a)) << 24) | (uint32_t(uint8_t(b)) << 16) |
           (uint32_t(uint8_t(c)) << 8) | uint8_t(d);
}
std::string tagName(Tag value) {
    return {char(value >> 24), char(value >> 16), char(value >> 8), char(value)};
}

// GATextPreparation.mm: scriptTag (unchanged).
static Tag scriptTag(const char *name) {
    if (std::strlen(name) != 4) return tag('D', 'F', 'L', 'T');
    Tag value = 0;
    for (unsigned i = 0; i < 4; ++i)
        value = (value << 8) | uint8_t(std::tolower(uint8_t(name[i])));
    switch (value) {
        case tag('h','i','r','a'): return tag('k','a','n','a');
        case tag('l','a','o','o'): return tag('l','a','o',' ');
        case tag('y','i','i','i'): return tag('y','i',' ',' ');
        case tag('n','k','o','o'): return tag('n','k','o',' ');
        case tag('v','a','i','i'): return tag('v','a','i',' ');
        case tag('z','y','y','y'): case tag('z','i','n','h'):
        case tag('z','z','z','z'): case tag('d','f','l','t'):
            return tag('D','F','L','T');
        default: return value;
    }
}
// Minimal Script model: selectScript uses only its name field.
struct Script { Tag name; };
// GAOpenType.cpp: selectScript (unchanged).
static const Script *selectScript(const std::vector<Script> &scripts, Tag wanted) {
    for (Tag name : {wanted, tag('D', 'F', 'L', 'T'), tag('l', 'a', 't', 'n')})
        for (const auto &s : scripts)
            if (s.name == name)
                return &s;
    return nullptr;
}

struct Item {
    double xAdvance = 0, yAdvance = 0, xOffset = 0, yOffset = 0;
};
using Buffer = std::vector<Item>;
// GAPositioning.cpp: adjust (unchanged).
void adjust(Buffer &buffer, size_t first, size_t second, double value, bool vertical, bool cross,
            bool overrideValue) {
    auto &a = buffer[first];
    auto &b = buffer[second];
    double &target =
        cross ? (vertical ? b.xOffset : b.yOffset) : (vertical ? a.yAdvance : a.xAdvance);
    if (cross && value == -32768) {
        target = 0;
        return;
    }
    if (vertical && !cross)
        value = -value;
    if (overrideValue)
        target = value;
    else
        target += value;
}

class InvalidTable final : public std::runtime_error {
public:
    explicit InvalidTable(const std::string &message) : std::runtime_error(message) {}
};
// GABinary.h View methods used by the following excerpt (unchanged).
class View {
    std::shared_ptr<const std::vector<uint8_t>> owner_;
    size_t begin_ = 0, length_ = 0;
public:
    View() = default;
    explicit View(std::vector<uint8_t> bytes)
        : owner_(std::make_shared<const std::vector<uint8_t>>(std::move(bytes))),
          length_(owner_->size()) {}
    explicit operator bool() const { return length_ != 0; }
    bool contains(size_t at, size_t count) const {
        return at <= length_ && count <= length_ - at;
    }
    void require(size_t at, size_t count) const {
        if (!contains(at, count))
            throw InvalidTable("offset " + std::to_string(at) + " + " + std::to_string(count) +
                               " outside table size " + std::to_string(length_));
    }
    uint8_t u8(size_t at) const {
        require(at, 1);
        return (*owner_)[begin_ + at];
    }
    uint16_t u16(size_t at) const {
        require(at, 2);
        return uint16_t((u8(at) << 8) | u8(at + 1));
    }
    View at(size_t offset) const {
        require(offset, 0);
        View v = *this;
        v.begin_ += offset;
        v.length_ -= offset;
        return v;
    }
    View offset16(size_t field) const {
        auto n = u16(field);
        return n ? at(n) : View{};
    }
    void array(size_t at, size_t count, size_t stride) const {
        if (!stride || at > length_ || count > (length_ - at) / stride)
            throw InvalidTable("array outside font table");
    }
};
// Relevant original Coverage implementation.
class Coverage {
    View data_;
public:
    explicit Coverage(View data) : data_(data) {
        if (!data_) return;
        auto format = data_.u16(0), count = data_.u16(2);
        if (format != 1 && format != 2)
            throw InvalidTable("unknown coverage format");
        data_.array(4, count, format == 1 ? 2 : 6);
        unsigned previous, index = 0;
        for (unsigned i = 0; i < count; i++) {
            size_t p = 4 + size_t(i) * (format == 1 ? 2 : 6);
            unsigned first = data_.u16(p), last = format == 1 ? first : data_.u16(p + 2);
            if (first > last || (i && first <= previous))
                throw InvalidTable("unordered coverage ranges");
            if (format == 2 && data_.u16(p + 4) != index)
                throw InvalidTable("noncontiguous coverage indices");
            previous = last;
            index += last - first + 1;
        }
    }
    std::vector<Glyph> glyphs() const {
        std::vector<Glyph> result;
        if (!data_) return result;
        auto format = data_.u16(0);
        for (unsigned i = 0, n = data_.u16(2); i < n; i++) {
            if (format == 1)
                result.push_back(data_.u16(4 + i * 2));
            else {
                size_t p = 4 + i * 6;
                unsigned first = data_.u16(p), last = data_.u16(p + 2);
                for (unsigned g = first; g <= last; g++)
                    result.push_back(Glyph(g));
            }
        }
        return result;
    }
};
// Only fields used in the GSUB type-4 parsing block are needed in this harness.
struct Predicate {
    unsigned value = 0;
    static Predicate exact(Glyph g) { Predicate p; p.value = g; return p; }
};
struct Pattern { std::vector<Predicate> input; std::vector<Glyph> replacement; };
struct Subtable {
    Coverage coverage;
    std::vector<Pattern> patterns;
    explicit Subtable(View data) : coverage(data.offset16(2)) {}
};
// predicates' format-1 branch, the only branch reachable for ligatures.
static void predicates(std::vector<Predicate> &result, View table, size_t at, unsigned count,
                       unsigned format) {
    assert(format == 1);
    table.array(at, count, 2);
    for (unsigned i = 0; i < count; i++)
        result.push_back(Predicate::exact(table.u16(at + i * 2)));
}
static Subtable parseLigature(View data) {
    Subtable s(data);
    // Original readSubtable type == 4 body, unchanged.
    {
        if (data.u16(0) != 1)
            throw InvalidTable("unknown ligature format");
        auto glyphs = s.coverage.glyphs();
        unsigned count = data.u16(4);
        data.array(6, count, 2);
        if (count > glyphs.size())
            throw InvalidTable("ligature set exceeds coverage");
        for (unsigned i = 0; i < count; i++) {
            View set = data.offset16(6 + i * 2);
            if (!set)
                continue;
            unsigned n = set.u16(0);
            set.array(2, n, 2);
            for (unsigned j = 0; j < n; j++) {
                View lig = set.offset16(2 + j * 2);
                Pattern p;
                p.input.push_back(Predicate::exact(glyphs[i]));
                unsigned length = lig.u16(2);
                if (!length)
                    throw InvalidTable("empty ligature");
                predicates(p.input, lig, 4, length - 1, 1);
                p.replacement = {lig.u16(0)};
                s.patterns.push_back(std::move(p));
            }
        }
    }
    return s;
}

// Controlled, small fixture. All parent offsets share one LigatureSet, and all
// LigatureSet offsets share one Ligature record. Never writes a complete font.
std::vector<uint8_t> repeatedLigatures(unsigned count) {
    if (count == 0 || count > 500)
        throw std::invalid_argument("fixture count must be 1..500");
    size_t coverage = 6 + 2 * count;
    size_t set = coverage + 10;
    size_t ligature = set + 2 + 2 * count;
    std::vector<uint8_t> bytes(ligature + 6);
    auto put = [&](size_t at, unsigned value) {
        assert(value <= 65535 && at + 1 < bytes.size());
        bytes[at] = uint8_t(value >> 8);
        bytes[at + 1] = uint8_t(value);
    };
    put(0, 1); put(2, coverage); put(4, count);
    for (unsigned i = 0; i < count; ++i) put(6 + i * 2, set);
    put(coverage, 2); put(coverage + 2, 1);
    put(coverage + 4, 1); put(coverage + 6, count); put(coverage + 8, 0);
    put(set, count);
    for (unsigned i = 0; i < count; ++i) put(set + 2 + i * 2, ligature - set);
    put(ligature, 1000); put(ligature + 2, 2); put(ligature + 4, 1001);
    return bytes;
}
int main() {
    std::cout << "GlyphAtlas source-excerpt checks, commit 22174e5\n";
    for (auto pair : {std::pair{"Deva", "dev2"}, {"Beng", "bng2"}, {"Mymr", "mym2"}}) {
        Tag modern = tag(pair.second[0], pair.second[1], pair.second[2], pair.second[3]);
        std::vector<Script> scripts{{modern}};
        Tag requested = scriptTag(pair.first);
        assert(selectScript(scripts, modern));
        assert(selectScript(scripts, requested) == nullptr);
        std::cout << "SCRIPT " << pair.first << " -> " << tagName(requested)
                  << "; available " << pair.second << "; selected: none (expected available script)\n";
    }
    Buffer b(2); b[0].xAdvance = 600; b[1].xAdvance = 600;
    adjust(b, 0, 1, -50, false, false, true);
    assert(b[0].xAdvance == -50);
    std::cout << "KERN single override: actual advance=" << b[0].xAdvance
              << ", expected=550 (nominal 600, kerning -50)\n";
    b[0].xAdvance = 600;
    adjust(b, 0, 1, -20, false, false, false);
    adjust(b, 0, 1, -50, false, false, true);
    assert(b[0].xAdvance == -50);
    std::cout << "KERN additive then override: actual advance=" << b[0].xAdvance
              << ", expected=550 (override prior -20 kerning only)\n";
    // The following is the arithmetic of Positioning::resolve for a mark on
    // the first base, followed by the actual legacy-kern adjust function.
    // It models the ordering in GASubstitutionEngine::position, not a GUI test.
    Buffer marked(3);
    marked[0].xAdvance = 600;
    marked[1].xAdvance = 0;
    marked[2].xAdvance = 600;
    const double markDelta = 300;
    const double parentPen = 0;
    const double oldMarkPen = marked[0].xAdvance;
    marked[1].xOffset = parentPen + marked[0].xOffset + markDelta - oldMarkPen;
    adjust(marked, 0, 2, -50, false, false, false);
    const double finalMarkOrigin = marked[0].xAdvance + marked[1].xOffset;
    assert(finalMarkOrigin == 250);
    std::cout << "KERN after mark attachment: actual mark origin=" << finalMarkOrigin
              << ", expected=300 (attachment to unchanged base)\n";
    for (unsigned n : {100u, 300u}) {
        auto bytes = repeatedLigatures(n);
        auto parsed = parseLigature(View(bytes));
        assert(parsed.patterns.size() == size_t(n) * n);
        std::cout << "GSUB alias expansion: " << bytes.size() << " bytes, " << n
                  << " x " << n << " offsets -> " << parsed.patterns.size()
                  << " materialized patterns\n";
    }
    std::cout << "All source-behavior assertions passed; these checks reproduce defects, not fixes.\n";
}
