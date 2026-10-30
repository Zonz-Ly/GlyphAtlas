#pragma once
#include "GABinary.h"
#include <map>
namespace ga::layout {
std::vector<double> normalizeCoordinates(View fvar, View avar,
                                         const std::map<Tag, double> &coordinates);
double variationDelta(View store, unsigned outer, unsigned inner,
                      const std::vector<double> &normalized);
/// One entry of a DeltaSetIndexMap (HVAR/VVAR): outer and inner indices into an
/// ItemVariationStore. `valid` is false for an absent/empty map.
struct DeltaSetIndex {
    unsigned outer = 0, inner = 0;
    bool valid = false;
};
DeltaSetIndex deltaSetIndex(View map, unsigned glyph);
double deviceDelta(View device, View store, const std::vector<double> &normalized);
} // namespace ga::layout
