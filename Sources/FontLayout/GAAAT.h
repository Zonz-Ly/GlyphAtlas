#pragma once
#include "GAGlyphBuffer.h"
#include <optional>

namespace ga::layout {
// Apple lookup tables are also shared by kerx and legacy class mappings.
std::optional<uint64_t> aatLookup(View table, Glyph glyph, unsigned valueSize = 2);
struct AATSelector {
    unsigned type = 0, setting = 0;
    friend bool operator==(AATSelector a, AATSelector b) {
        return a.type == b.type && a.setting == b.setting;
    }
};
class AAT {
    struct Subtable {
        unsigned type;
        uint32_t coverage, flags;
        View data;
    };
    struct Feature {
        AATSelector selector;
        uint32_t enable, disable;
    };
    struct Chain {
        uint32_t defaults;
        std::vector<Feature> features;
        std::vector<Subtable> subtables;
    };
    bool extended_;
    std::vector<Chain> chains_;
    std::vector<AATSelector> selectors_;

  public:
    explicit AAT(View table = {}, bool extended = true);
    bool empty() const {
        return chains_.empty();
    }
    const std::vector<AATSelector> &selectors() const {
        return selectors_;
    }
    bool hasVerticalSubstitutions() const;
    std::string name() const {
        return extended_ ? "morx" : "mort";
    }
    void substitute(Buffer &buffer, std::optional<AATSelector> selector = {}, bool rtl = false,
                    bool vertical = false, Trace *trace = nullptr,
                    bool verticalSubstitutionsOnly = false) const;
};
} // namespace ga::layout
