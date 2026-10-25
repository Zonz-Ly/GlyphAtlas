#include "GAOpenType.h"
#include <numeric>
#include <tuple>

namespace ga::layout {
namespace {
struct Output {
    unsigned position = 0, value = 1;
    std::vector<Glyph> glyphs;
    bool directFamily = false;
};
// A table catalogue, independent of the current text. Positions identify the
// glyph affected by a nested action, so a rule for W+i contributes W's outputs
// to W and i's outputs to i, rather than placing both on either character.
class Catalogue {
    const std::vector<Lookup> &lookups_;
    const GDEF &gdef_;
    Glyph seed_;
    Budget budget_{1};
    std::map<unsigned, std::vector<Output>> memo_;
    std::set<unsigned> active_;
    const std::vector<Output> empty_;
    void append(std::vector<Output> &outputs, unsigned position, std::vector<Glyph> glyphs,
                unsigned value = 1, bool directFamily = false) {
        auto found = std::find_if(outputs.begin(), outputs.end(), [&](const Output &output) {
            return output.position == position && output.value == value && output.glyphs == glyphs;
        });
        if (found != outputs.end())
            found->directFamily |= directFamily;
        else
            outputs.push_back({position, value, std::move(glyphs), directFamily});
    }
    // SequenceIndex addresses the updated input, including earlier direct
    // multiple substitutions. Preserve each new slot's original owner.
    void updateSlots(std::vector<unsigned> &slots, unsigned at, unsigned lookup,
                     const Pattern &pattern) {
        if (lookup >= lookups_.size() || at >= slots.size())
            return;
        unsigned owner = slots[at];
        if (owner >= pattern.input.size())
            return;
        const auto &predicate = pattern.input[owner];
        Glyph glyph;
        if (predicate.kind == Predicate::Kind::Exact)
            glyph = Glyph(predicate.value);
        else if (predicate.kind == Predicate::Kind::Coverage) {
            auto glyphs = predicate.coverage.glyphs();
            if (glyphs.size() != 1)
                return;
            glyph = glyphs.front();
        } else
            return;
        const auto &program = lookups_[lookup];
        if (!gdef_.included(glyph, program.flags, program.markSet))
            return;
        for (const auto &sub : program.subtables) {
            if (!sub.coverage.contains(glyph))
                continue;
            if (sub.type == 1 || sub.type == 3)
                return;
            if (sub.type != 2)
                return;
            size_t count = substitutionOutputs(sub, glyph).size();
            budget_.growth(slots.size() - 1 + count);
            slots.erase(slots.begin() + at);
            slots.insert(slots.begin() + at, count, owner);
            return;
        }
    }

  public:
    Catalogue(const std::vector<Lookup> &lookups, const GDEF &gdef, Glyph seed)
        : lookups_(lookups), gdef_(gdef), seed_(seed) {}
    const std::vector<Output> &lookup(unsigned index) {
        budget_.step();
        if (index >= lookups_.size() || active_.count(index) || active_.size() >= 64)
            return empty_;
        auto cached = memo_.find(index);
        if (cached != memo_.end())
            return cached->second;
        active_.insert(index);
        std::vector<Output> outputs;
        const auto &program = lookups_[index];
        for (const auto &sub : program.subtables) {
            if (sub.type <= 3) {
                if (!gdef_.included(seed_, program.flags, program.markSet) ||
                    !sub.coverage.contains(seed_))
                    continue;
                auto glyphs = substitutionOutputs(sub, seed_);
                if (sub.type == 3) {
                    for (unsigned i = 0; i < glyphs.size(); i++)
                        append(outputs, 0, {glyphs[i]}, i + 1, true);
                } else
                    append(outputs, 0, std::move(glyphs), 1, sub.type == 1);
            } else if (sub.type == 4) {
                if (!gdef_.included(seed_, program.flags, program.markSet))
                    continue;
                for (const auto &pattern : sub.patterns)
                    for (unsigned i = 0; i < pattern.input.size(); i++) {
                        budget_.step();
                        if (pattern.input[i].matches(seed_))
                            append(outputs, i, pattern.replacement);
                    }
            } else if (sub.type == 8) {
                if (!gdef_.included(seed_, program.flags, program.markSet))
                    continue;
                int ci = sub.coverage.index(seed_);
                if (ci < 0)
                    continue;
                View d = sub.data;
                size_t at = 6 + d.u16(4) * 2;
                at += 2 + d.u16(at) * 2;
                if (unsigned(ci) >= d.u16(at))
                    throw InvalidTable("reverse substitute exceeds coverage");
                append(outputs, 0, {d.u16(at + 2 + ci * 2)});
            } else
                for (const auto &pattern : sub.patterns) {
                    std::vector<unsigned> slots(pattern.input.size());
                    std::iota(slots.begin(), slots.end(), 0);
                    for (auto action : pattern.actions) {
                        budget_.step();
                        if (action.sequence >= slots.size())
                            continue;
                        for (const auto &child : lookup(action.lookup)) {
                            size_t position = size_t(action.sequence) + child.position;
                            unsigned owner =
                                position < slots.size()
                                    ? slots[position]
                                    : unsigned(pattern.input.size() + position - slots.size());
                            if (owner < pattern.input.size()) {
                                if (!pattern.input[owner].matches(seed_))
                                    continue;
                                if (owner == 0 && pattern.firstCoverage &&
                                    !pattern.firstCoverage.contains(seed_))
                                    continue;
                                if (!gdef_.included(seed_, program.flags, program.markSet))
                                    continue;
                            } else if (owner - pattern.input.size() < pattern.lookahead.size() &&
                                       !pattern.lookahead[owner - pattern.input.size()].matches(
                                           seed_))
                                continue;
                            append(outputs, owner, child.glyphs, child.value);
                        }
                        updateSlots(slots, action.sequence, action.lookup, pattern);
                    }
                }
        }
        active_.erase(index);
        return memo_.emplace(index, std::move(outputs)).first->second;
    }
};
} // namespace
std::vector<RelatedSubstitution> OpenType::relatedSubstitutions(Glyph seed,
                                                                const GDEF &gdef) const {
    if (positioning_)
        throw InvalidTable("positioning program used as substitution catalogue");
    Catalogue catalogue(lookups_, gdef, seed);
    std::vector<RelatedSubstitution> result;
    std::map<std::tuple<Tag, unsigned, std::vector<Glyph>>, size_t> seen;
    auto add = [&](const std::vector<Glyph> &glyphs, Tag feature, unsigned value,
                   bool directFamily) {
        if (glyphs == std::vector<Glyph>{seed})
            return;
        auto [found, inserted] =
            seen.emplace(std::make_tuple(feature, value, glyphs), result.size());
        if (inserted)
            result.push_back({glyphs, feature, value, directFamily});
        else
            result[found->second].directFamily |= directFamily;
    };
    for (const auto &branch : branches_)
        for (const auto &feature : branch)
            for (unsigned index : feature.lookups) {
                for (const auto &output : catalogue.lookup(index))
                    add(output.glyphs, feature.name, output.value, output.directFamily);
                if (index >= lookups_.size())
                    continue;
                const auto &lookup = lookups_[index];
                // Reverse the alternate index only at a feature root. This is
                // sibling discovery, not an inverse contextual substitution.
                for (const auto &sub : lookup.subtables) {
                    if (sub.type != 3)
                        continue;
                    auto family = sub.alternateInputs.find(seed);
                    if (family == sub.alternateInputs.end())
                        continue;
                    for (Glyph input : family->second) {
                        if (!gdef.included(input, lookup.flags, lookup.markSet))
                            continue;
                        auto glyphs = substitutionOutputs(sub, input);
                        for (unsigned i = 0; i < glyphs.size(); i++)
                            add({glyphs[i]}, feature.name, i + 1, true);
                    }
                }
            }
    return result;
}
} // namespace ga::layout
