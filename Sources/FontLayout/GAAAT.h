#pragma once
#include "GAGlyphBuffer.h"
#include <optional>

namespace ga::layout {
// Apple lookup tables are also shared by kerx and legacy class mappings.
std::optional<uint64_t> aatLookup(View table, Glyph glyph);
struct AATSelector {
    unsigned type = 0, setting = 0;
    friend bool operator==(AATSelector a, AATSelector b) {
        return a.type == b.type && a.setting == b.setting;
    }
};
class AATMachine;
class AAT {
    struct Subtable {
        unsigned type;
        uint32_t coverage, flags;
        View data;
        std::shared_ptr<const AATMachine> program;
        size_t index;
    };
    struct Feature {
        AATSelector selector;
        uint32_t enable, disable;
        uint32_t apply(uint32_t flags) const { return (flags & disable) | enable; }
    };
    struct Chain {
        uint32_t defaults;
        std::vector<Feature> features;
        std::vector<Subtable> subtables;
    };
    bool extended_;
    std::vector<Chain> chains_;
    std::vector<AATSelector> selectors_;
    std::vector<const Subtable *> schedule(std::optional<AATSelector> selector, bool vertical,
                                           bool verticalOnly,
                                           const std::vector<AATSelector> &overrides) const;

  public:
    explicit AAT(View table = {}, bool extended = true);
    bool empty() const {
        return chains_.empty();
    }
    const std::vector<AATSelector> &selectors() const {
        return selectors_;
    }
    bool hasVerticalSubstitutions() const;
    void compileMachines(size_t glyphs);
    bool canIndexHorizontalSchedules() const;
    std::vector<size_t> horizontalSchedule(std::optional<AATSelector> selector) const;
    std::vector<AATSelector> outputSelectors() const;
    void collectFeatureOutputs(AATSelector selector, std::vector<bool> &outputs,
                               const Cancellation *cancellation) const;
    std::string featureLabel(std::optional<AATSelector> selector) const;
    std::string name() const {
        return extended_ ? "morx" : "mort";
    }
    void substitute(Buffer &buffer, std::optional<AATSelector> selector = {}, bool rtl = false,
                    bool vertical = false, Trace *trace = nullptr,
                    bool verticalSubstitutionsOnly = false,
                    const std::vector<AATSelector> &overrides = {},
                    const Cancellation *cancellation = nullptr) const;
};
} // namespace ga::layout
