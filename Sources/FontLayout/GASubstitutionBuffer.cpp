#include "GASubstitutionBuffer.h"

namespace ga::layout {
namespace {

bool equivalentItem(const Item &a, const Item &b) {
    return a.glyph == b.glyph && a.source == b.source && a.scalar == b.scalar &&
           a.form == b.form && a.ignorable == b.ignorable && a.component == b.component &&
           a.components == b.components;
}

size_t itemHash(const Item &item) {
    size_t hash = item.glyph;
    auto add = [&](size_t value) { hash = hash * 16777619 + value; };
    add(item.source.start);
    add(item.source.end);
    add(item.scalar);
    add(item.form);
    add(item.ignorable);
    add(size_t(item.component));
    for (const auto span : item.components) {
        add(span.start);
        add(span.end);
    }
    return hash;
}

bool sameOutput(const Item &a, const Item &b) {
    return a.glyph == b.glyph && a.source == b.source;
}

} // namespace

void SubstitutionBuffer::Piece::summarize() const {
    if (summarized) return;
    constexpr size_t factor = 1099511628211ULL;
    hash = 0;
    power = 1;
    source = {UINT32_MAX, 0};
    hasEmptySource = false;
    lastIdentity = 0;
    for (const auto &item : items) {
        hash = hash * factor + itemHash(item);
        lastIdentity = std::max(lastIdentity, item.identity);
        power *= factor;
        source = unite(source, item.source);
        hasEmptySource |= item.source.empty();
    }
    summarized = true;
}

SubstitutionBuffer::SubstitutionBuffer(const Buffer &items) : size_(items.size()) {
    pieces_.reserve((items.size() + pieceSize - 1) / pieceSize);
    uint64_t identity = 1;
    for (size_t at = 0; at < size_; at += pieceSize) {
        Buffer piece(items.begin() + at, items.begin() + std::min(size_, at + pieceSize));
        for (auto &item : piece) {
            if (!item.identity) item.identity = identity++;
            else identity = std::max(identity, item.identity + 1);
        }
        pieces_.push_back({at, std::make_shared<Piece>(std::move(piece))});
    }
}

size_t SubstitutionBuffer::slotAt(size_t at) const {
    const auto &current = pieces_[current_];
    if (at >= current.start && at - current.start < current.piece->items.size())
        return current_;
    if (current_ + 1 < pieces_.size()) {
        const auto &next = pieces_[current_ + 1];
        if (at >= next.start && at - next.start < next.piece->items.size())
            return ++current_;
    }
    auto found = std::upper_bound(pieces_.begin(), pieces_.end(), at,
                                 [](size_t position, const Slot &slot) { return position < slot.start; });
    return current_ = size_t(found - pieces_.begin() - 1);
}

const Item &SubstitutionBuffer::operator[](size_t at) const {
    const auto &slot = pieces_[slotAt(at)];
    return slot.piece->items[at - slot.start];
}

Item &SubstitutionBuffer::edit(size_t at) {
    auto &slot = pieces_[slotAt(at)];
    if (slot.piece.use_count() != 1) slot.piece = std::make_shared<Piece>(slot.piece->items);
    slot.piece->summarized = false;
    return slot.piece->items[at - slot.start];
}

void SubstitutionBuffer::replace(size_t at, Buffer inserted) {
    size_t i = slotAt(at);
    edit(at);
    auto &items = pieces_[i].piece->items;
    auto position = items.erase(items.begin() + (at - pieces_[i].start));
    items.insert(position, std::make_move_iterator(inserted.begin()),
                 std::make_move_iterator(inserted.end()));
    size_ = size_ - 1 + inserted.size();
    if (items.empty()) {
        pieces_.erase(pieces_.begin() + i);
    } else if (items.size() > 2 * pieceSize) {
        auto start = pieces_[i].start;
        std::vector<Slot> split;
        for (size_t offset = 0; offset < items.size(); offset += pieceSize) {
            auto first = items.begin() + offset;
            auto end = items.begin() + std::min(items.size(), offset + pieceSize);
            split.push_back({start + offset, std::make_shared<Piece>(Buffer(
                std::make_move_iterator(first), std::make_move_iterator(end)))});
        }
        pieces_.erase(pieces_.begin() + i);
        pieces_.insert(pieces_.begin() + i, std::make_move_iterator(split.begin()),
                       std::make_move_iterator(split.end()));
    }
    size_t start = i ? pieces_[i - 1].start + pieces_[i - 1].piece->items.size() : 0;
    for (; i < pieces_.size(); ++i) {
        pieces_[i].start = start;
        start += pieces_[i].piece->items.size();
    }
    current_ = 0;
}

Buffer SubstitutionBuffer::window(size_t first, size_t end) const {
    Buffer result;
    result.reserve(end - first);
    while (first < end) {
        const auto &slot = pieces_[slotAt(first)];
        size_t offset = first - slot.start;
        size_t length = std::min(end - first, slot.piece->items.size() - offset);
        result.insert(result.end(), slot.piece->items.begin() + offset,
                      slot.piece->items.begin() + offset + length);
        first += length;
    }
    return result;
}

size_t SubstitutionBuffer::hash() const {
    size_t hash = 0;
    for (const auto &slot : pieces_) {
        slot.piece->summarize();
        hash = hash * slot.piece->power + slot.piece->hash;
    }
    return hash;
}

uint64_t SubstitutionBuffer::nextIdentity() const {
    uint64_t next = 1;
    for (const auto &slot : pieces_) {
        slot.piece->summarize();
        next = std::max(next, slot.piece->lastIdentity + 1);
    }
    return next;
}

size_t SubstitutionBuffer::storageBytes(std::unordered_set<const void *> &seen) const {
    size_t bytes = pieces_.capacity() * sizeof(Slot);
    for (const auto &slot : pieces_)
        if (seen.insert(slot.piece.get()).second) {
            bytes += sizeof(Piece) + 32 + slot.piece->items.capacity() * sizeof(Item);
            for (const auto &item : slot.piece->items)
                bytes += item.components.capacity() * sizeof(Span);
        }
    return bytes;
}

bool SubstitutionBuffer::equivalent(const SubstitutionBuffer &other) const {
    if (size_ != other.size_) return false;
    for (size_t at = 0; at < size_;) {
        const auto &a = pieces_[slotAt(at)];
        const auto &b = other.pieces_[other.slotAt(at)];
        size_t offA = at - a.start, offB = at - b.start;
        size_t length = std::min(a.piece->items.size() - offA, b.piece->items.size() - offB);
        if ((a.piece != b.piece || offA != offB) &&
            !std::equal(a.piece->items.begin() + offA, a.piece->items.begin() + offA + length,
                        b.piece->items.begin() + offB, equivalentItem))
            return false;
        at += length;
    }
    return true;
}

bool SubstitutionBuffer::overlapsOutside(size_t first, size_t end, Span scope) const {
    auto overlaps = [&](const Item &item) {
        return item.source.empty() || (item.source.start < scope.end && item.source.end > scope.start);
    };
    for (const auto &slot : pieces_) {
        const auto &piece = *slot.piece;
        size_t limit = slot.start + piece.items.size();
        if (slot.start >= first && limit <= end) continue;
        piece.summarize();
        if (!piece.hasEmptySource && (piece.source.start >= scope.end || piece.source.end <= scope.start))
            continue;
        for (size_t i = slot.start; i < limit; ++i)
            if ((i < first || i >= end) && overlaps(piece.items[i - slot.start]))
                return true;
    }
    return false;
}

void SubstitutionBuffer::recordChanges(const SubstitutionBuffer &after, Trace &trace,
                                       const std::string &feature) const {
    if (trace.provenance) {
        // Replay consumers need the complete before/after sequence.
        trace.changed(materialize(), after.materialize(), feature);
        return;
    }
    size_t first = 0, oldEnd = size_, newEnd = after.size_;
    while (first < std::min(oldEnd, newEnd)) {
        const auto &a = pieces_[slotAt(first)];
        const auto &b = after.pieces_[after.slotAt(first)];
        if (a.start == b.start && a.piece == b.piece) {
            first = a.start + a.piece->items.size();
        } else if (sameOutput(a.piece->items[first - a.start], b.piece->items[first - b.start])) {
            ++first;
        } else {
            break;
        }
    }
    if (first == oldEnd && first == newEnd) {
        for (const auto &slot : pieces_) {
            slot.piece->summarize();
            if (slot.piece->hasEmptySource) {
                trace.changed(materialize(), after.materialize(), feature);
                break;
            }
        }
        return;
    }
    while (oldEnd > first && newEnd > first) {
        const auto &a = pieces_[slotAt(oldEnd - 1)];
        const auto &b = after.pieces_[after.slotAt(newEnd - 1)];
        size_t offA = oldEnd - a.start, offB = newEnd - b.start;
        if (offA == offB && a.piece == b.piece && a.start >= first && b.start >= first) {
            oldEnd = a.start;
            newEnd = b.start;
        } else if (sameOutput(a.piece->items[offA - 1], b.piece->items[offB - 1])) {
            --oldEnd;
            --newEnd;
        } else {
            break;
        }
    }

    Span scope{UINT32_MAX, 0};
    bool positive = true;
    auto include = [&](const Item &item) {
        scope = unite(scope, item.source);
        positive &= !item.source.empty();
    };
    for (size_t i = first; i < oldEnd; ++i) include((*this)[i]);
    for (size_t i = first; i < newEnd; ++i) include(after[i]);
    auto overlaps = [&](const Item &item) {
        return item.source.empty() || (item.source.start < scope.end && item.source.end > scope.start);
    };
    // The untouched ends match in GID and source. Expand to the complete
    // source cluster, and use the original full diff for non-local overlaps.
    for (Span previous; !(previous == scope);) {
        previous = scope;
        while (first && overlaps((*this)[first - 1])) include((*this)[--first]);
        while (oldEnd < size_ && overlaps((*this)[oldEnd])) {
            include((*this)[oldEnd++]);
            ++newEnd;
        }
    }
    if (positive && !overlapsOutside(first, oldEnd, scope))
        trace.changed(window(first, oldEnd), after.window(first, newEnd), feature);
    else
        trace.changed(materialize(), after.materialize(), feature);
}
} // namespace ga::layout
