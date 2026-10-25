#pragma once
#include "GABinary.h"
#include <functional>
#include <map>
#include <set>
#include <utility>

namespace ga::layout {
struct Span {
    uint32_t start = 0, end = 0;
    bool empty() const {
        return start >= end;
    }
    friend bool operator==(Span a, Span b) {
        return a.start == b.start && a.end == b.end;
    }
    friend bool operator<(Span a, Span b) {
        return a.start < b.start || (a.start == b.start && a.end < b.end);
    }
};
inline Span unite(Span a, Span b) {
    return {std::min(a.start, b.start), std::max(a.end, b.end)};
}
struct Point {
    double x = 0, y = 0;
};

struct Item {
    Glyph glyph = 0;
    Span source;
    uint32_t scalar = 0;
    Tag form = 0;
    uint64_t identity = 0;
    bool ignorable = false;
    std::vector<Span> components;
    int component = -1;
    double xAdvance = 0, yAdvance = 0, xOffset = 0, yOffset = 0;
};
using Buffer = std::vector<Item>;
struct Cluster {
    Span source;
    std::vector<Glyph> glyphs;
};
std::vector<Cluster> clusters(const Buffer &buffer);
struct Change {
    Span source;
    std::vector<Glyph> glyphs;
    std::string feature;
};
struct Trace {
    std::vector<Change> changes;
    bool inventory = false;
    void changed(const Buffer &before, const Buffer &after, const std::string &feature);
};
struct Budget {
    size_t remaining, maxGlyphs;
    explicit Budget(size_t input)
        : remaining(1000000 + std::min<size_t>(input, 1000000) * 10000),
          maxGlyphs(std::max<size_t>(65536, std::min<size_t>(1000000, input * 64))) {}
    void step() {
        if (!remaining)
            throw InvalidTable("font execution budget exhausted");
        --remaining;
    }
    void growth(size_t size) const {
        if (size > maxGlyphs)
            throw InvalidTable("font output exceeds glyph budget");
    }
};
struct Metrics {
    std::function<double(Glyph)> horizontalAdvance;
    std::function<double(Glyph)> verticalAdvance;
    std::vector<double> normalized;
};
struct GDEF {
    ClassDef glyphClasses, markAttachmentClasses;
    std::vector<Coverage> markSets;
    View variations;
    explicit GDEF(View table = {});
    bool included(Glyph glyph, unsigned flags, unsigned markSet) const;
};
struct LookupFlags {
    unsigned flags = 0, markSet = 0;
};
inline bool accepts(const GDEF &gdef, const LookupFlags &flags, const Item &item) {
    return gdef.included(item.glyph, flags.flags, flags.markSet);
}
inline std::vector<size_t> visible(const Buffer &buffer, const GDEF &gdef, LookupFlags flags) {
    std::vector<size_t> result;
    for (size_t i = 0; i < buffer.size(); i++)
        if (accepts(gdef, flags, buffer[i]))
            result.push_back(i);
    return result;
}
} // namespace ga::layout
