#pragma once
#include "GABinary.h"
#include <map>
namespace ga::layout {
std::vector<double> normalizeCoordinates(View fvar, View avar,
                                         const std::map<Tag, double> &coordinates);
double variationDelta(View store, unsigned outer, unsigned inner,
                      const std::vector<double> &normalized);
double deviceDelta(View device, View store, const std::vector<double> &normalized);
} // namespace ga::layout
