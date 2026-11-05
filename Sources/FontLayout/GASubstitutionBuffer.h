#pragma once
#include "GAGlyphBuffer.h"
#include <memory>
#include <unordered_set>

namespace ga::layout {

// GSUB discovery states share unchanged pieces. Positions are local to each
// sequence, so deletion in one piece never copies the glyphs in its suffix.
class SubstitutionBuffer {
    static constexpr size_t pieceSize = 96;

    struct Piece {
        Buffer items;
        mutable bool summarized = false;
        mutable size_t hash = 0, power = 1;
        mutable uint64_t lastIdentity = 0;
        mutable Span source;
        mutable bool hasEmptySource = false;

        explicit Piece(Buffer glyphs) : items(std::move(glyphs)) {}
        void summarize() const;
    };
    struct Slot {
        size_t start;
        std::shared_ptr<Piece> piece;
    };

    std::vector<Slot> pieces_;
    size_t size_ = 0;
    mutable size_t current_ = 0;

    size_t slotAt(size_t at) const;
    Buffer window(size_t first, size_t end) const;
    bool overlapsOutside(size_t first, size_t end, Span scope) const;

  public:
    SubstitutionBuffer() = default;
    explicit SubstitutionBuffer(const Buffer &items);
    size_t size() const { return size_; }
    const Item &operator[](size_t at) const;
    Item &edit(size_t at);
    void replace(size_t at, Buffer inserted);
    Buffer materialize() const { return window(0, size_); }
    size_t hash() const;
    bool equivalent(const SubstitutionBuffer &other) const;
    uint64_t nextIdentity() const;
    size_t storageBytes(std::unordered_set<const void *> &seen) const;
    void recordChanges(const SubstitutionBuffer &after, Trace &trace, const std::string &feature) const;
};

} // namespace ga::layout
