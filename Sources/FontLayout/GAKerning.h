#pragma once
#include "GAAAT.h"
#include "GAOpenType.h"
namespace ga::layout {
// Legacy pair/class kerning supplements positioning only when GPOS/kerx does
// not own the relevant kern feature. Table offsets include the subtable header.
class Kerning {
    View kern_, kerx_;

  public:
    explicit Kerning(View kern = {}, View kerx = {}) : kern_(kern), kerx_(kerx) {}
    bool empty() const {
        return !kern_ && !kerx_;
    }
    void position(Buffer &buffer, const Settings &settings, const GDEF &gdef) const;
};
} // namespace ga::layout
