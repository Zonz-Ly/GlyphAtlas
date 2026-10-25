#pragma once
#include "GABinary.h"
#include <optional>
namespace ga::layout {
class Cmap {
    struct Subtable {
        View data;
        bool symbol = false, macRoman = false;
        unsigned rank = 0;
    };
    std::vector<Subtable> subtables_;
    View variation_;

  public:
    explicit Cmap(View table = {});
    Glyph nominal(uint32_t scalar) const;
    std::optional<Glyph> variation(uint32_t scalar, uint32_t selector) const;
};
} // namespace ga::layout
