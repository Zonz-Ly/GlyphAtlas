#include "GAOpenType.h"
#include <tuple>

namespace ga::layout {
namespace {
using PredicateTest = std::function<bool(Glyph)>;
using Filter = std::shared_ptr<const PredicateTest>;
struct Slot {
    Filter filter;
    size_t state = 0;
    // Re-emitting an already possible output does not create another state.
    std::shared_ptr<const std::set<Glyph>> produced;
};
struct Effect {
    size_t offset, consumed;
    std::vector<Glyph> glyphs;
    bool operator<(const Effect &other) const {
        return std::tie(offset, consumed, glyphs) <
               std::tie(other.offset, other.consumed, other.glyphs);
    }
};
using Effects = std::set<Effect>;

class FeatureOutputs {
    const std::vector<Lookup> &lookups_;
    const GDEF &gdef_;
    std::vector<bool> &outputs_;
    Budget budget_;
    size_t nextSlotState_ = 1;
    std::set<std::pair<unsigned, size_t>> active_;

    void emit(Effects *effects, size_t consumed, std::vector<Glyph> glyphs, bool changed = true) {
        if (changed)
            for (Glyph glyph : glyphs)
                if (glyph && glyph != 0xffff && glyph < outputs_.size())
                    outputs_[glyph] = true;
        if (effects && changed)
            effects->insert({0, consumed, std::move(glyphs)});
    }

    bool possible(const Predicate &predicate, const PredicateTest &allowed) {
        if (predicate.kind == Predicate::Kind::Exact)
            return allowed(Glyph(predicate.value));
        if (predicate.kind == Predicate::Kind::Coverage) {
            for (Glyph glyph : predicate.coverage.glyphs()) {
                budget_.step();
                if (allowed(glyph)) return true;
            }
        } else {
            for (size_t i = 0; i < outputs_.size(); ++i) {
                budget_.step();
                if (allowed(Glyph(i))) return true;
            }
        }
        return false;
    }

    // Carry the possible GIDs at each sequence index across ordered actions.
    // Keep the unchanged path for rules whose conditions might not match.
    void update(std::vector<Slot> &slots, size_t at, const Effects &effects) {
        if (effects.empty()) return;
        std::vector<std::set<Glyph>> generated;
        std::vector<std::set<size_t>> moved;
        for (const auto &effect : effects) {
            const size_t position = at + effect.offset;
            if (position >= slots.size()) continue;
            const size_t removed = std::min(effect.consumed, slots.size() - position);
            const size_t end = slots.size() - removed + effect.glyphs.size();
            budget_.growth(end);
            const size_t required = std::max(end, generated.size());
            generated.resize(required);
            moved.resize(required);
            for (size_t i = 0; i < effect.glyphs.size(); ++i)
                generated[position + i].insert(effect.glyphs[i]);
            for (size_t i = position + removed; i < slots.size(); ++i) {
                budget_.step();
                size_t destination = i - removed + effect.glyphs.size();
                if (i != destination)
                    moved[destination].insert(i);
            }
        }
        auto original = slots;
        slots.resize(std::max(slots.size(), generated.size()));
        for (size_t i = at; i < generated.size(); ++i) {
            if (generated[i].empty() && moved[i].empty()) continue;
            Slot prior = i < original.size() ? original[i] : Slot{};
            if (moved[i].empty() && prior.filter) {
                if (!prior.produced ||
                    !std::includes(prior.produced->begin(), prior.produced->end(),
                                   generated[i].begin(), generated[i].end())) {
                    auto produced = std::make_shared<std::set<Glyph>>(generated[i]);
                    if (prior.produced)
                        produced->insert(prior.produced->begin(), prior.produced->end());
                    prior.produced = std::move(produced);
                    prior.state = nextSlotState_++;
                } else if (std::all_of(generated[i].begin(), generated[i].end(),
                                       [&](Glyph g) { return (*prior.filter)(g); })) {
                    continue;
                }
            } else {
                // Merging different source slots creates a new symbolic slot.
                prior.state = nextSlotState_++;
                prior.produced.reset();
            }
            std::vector<Filter> filters;
            if (i < original.size()) filters.push_back(original[i].filter);
            for (size_t source : moved[i]) filters.push_back(original[source].filter);
            slots[i] = {
                std::make_shared<PredicateTest>(
                    [glyphs = std::move(generated[i]), filters = std::move(filters)](Glyph g) {
                        if (glyphs.count(g)) return true;
                        return std::any_of(filters.begin(), filters.end(),
                                           [&](const Filter &f) { return f && (*f)(g); });
                    }),
                prior.state, std::move(prior.produced)
            };
        }
    }

  public:
    FeatureOutputs(const std::vector<Lookup> &lookups, const GDEF &gdef,
                   std::vector<bool> &outputs, const Cancellation *cancellation)
        : lookups_(lookups), gdef_(gdef), outputs_(outputs),
          budget_(std::min<size_t>(outputs.size(), 1000), cancellation) {}

    void collect(unsigned index, const std::vector<Slot> &scope = {}, size_t anchor = 0,
                 Effects *effects = nullptr, const LookupFlags *scopeFlags = nullptr) {
        budget_.step();
        if (index >= lookups_.size())
            throw InvalidTable("feature lookup outside list");
        const size_t anchorState = anchor < scope.size() ? scope[anchor].state : 0;
        // Narrowing a predicate preserves the slot state. A different slot or
        // an earlier substitution can legitimately re-enter the same lookup.
        const auto key = std::make_pair(index, anchorState);
        if (active_.size() >= 64 || !active_.insert(key).second)
            return;
        const auto &lookup = lookups_[index];
        // An action always addresses the same anchor. Following visible slots
        // align only when both lookups use the same glyph filtering.
        const bool aligned = scopeFlags && lookup.flags == scopeFlags->flags &&
                             lookup.markSet == scopeFlags->markSet;
        auto inherited = [&](std::ptrdiff_t offset) -> const Slot * {
            if (offset && !aligned) return nullptr;
            const auto at = std::ptrdiff_t(anchor) + offset;
            return at >= 0 && size_t(at) < scope.size() ? &scope[size_t(at)] : nullptr;
        };
        auto accepted = [&](size_t at, Glyph g) {
            const auto *slot = inherited(std::ptrdiff_t(at));
            return g < outputs_.size() && (!slot || !slot->filter || (*slot->filter)(g)) &&
                   gdef_.included(g, lookup.flags, lookup.markSet);
        };
        auto contextFits = [&](const Pattern &pattern) {
            auto fits = [&](const Predicate &predicate, std::ptrdiff_t offset) {
                const auto *slot = inherited(offset);
                return !slot || !slot->filter || possible(predicate, [&](Glyph g) {
                    return (*slot->filter)(g) && predicate.matches(g);
                });
            };
            for (size_t i = 0; i < pattern.backtrack.size(); ++i)
                if (!fits(pattern.backtrack[i], -std::ptrdiff_t(i + 1))) return false;
            for (size_t i = 0; i < pattern.lookahead.size(); ++i)
                if (!fits(pattern.lookahead[i], std::ptrdiff_t(pattern.input.size() + i)))
                    return false;
            return true;
        };
        for (const auto &sub : lookup.subtables) {
            if (sub.type <= 3 || sub.type == 8) {
                if (sub.type == 8 && !contextFits(sub.patterns.front())) continue;
                for (Glyph glyph : sub.coverage.glyphs()) {
                    budget_.step();
                    if (!accepted(0, glyph)) continue;
                    auto replacements = sub.type == 8
                        ? std::vector<Glyph>{reverseSubstitutionOutput(sub, sub.coverage.index(glyph))}
                        : substitutionOutputs(sub, glyph);
                    if (sub.type == 3) {
                        for (Glyph alternate : replacements)
                            emit(effects, 1, {alternate}, alternate != glyph);
                    } else {
                        bool changed = replacements.size() != 1 || replacements.front() != glyph;
                        emit(effects, 1, std::move(replacements), changed);
                    }
                }
                continue;
            }
            for (const auto &pattern : sub.patterns) {
                budget_.step();
                if (!contextFits(pattern)) continue;
                std::vector<Slot> slots;
                for (size_t i = 0; i < pattern.input.size(); ++i) {
                    PredicateTest filter = [&, i](Glyph g) {
                        return accepted(i, g) && pattern.input[i].matches(g) &&
                               (i || !pattern.firstCoverage || pattern.firstCoverage.contains(g));
                    };
                    if (!possible(pattern.input[i], filter)) break;
                    const auto *prior = inherited(std::ptrdiff_t(i));
                    const size_t state = i == 0 ? anchorState : prior ? prior->state : nextSlotState_++;
                    slots.push_back({std::make_shared<PredicateTest>(std::move(filter)), state,
                                     prior ? prior->produced : nullptr});
                }
                if (slots.empty() || slots.size() != pattern.input.size()) continue;
                if (sub.type == 4) {
                    emit(effects, slots.size(), pattern.replacement);
                    continue;
                }
                for (const auto &action : pattern.actions) {
                    budget_.step();
                    if (action.sequence >= slots.size()) continue;
                    Effects next;
                    collect(action.lookup, slots, action.sequence, &next, &lookup);
                    if (effects)
                        for (const auto &effect : next)
                            effects->insert({action.sequence + effect.offset, effect.consumed,
                                             effect.glyphs});
                    update(slots, action.sequence, next);
                }
            }
        }
        active_.erase(key);
    }
};
} // namespace

void OpenType::collectFeatureOutputs(Tag feature, size_t branch, const GDEF &gdef,
                                     std::vector<bool> &outputs,
                                     const Cancellation *cancellation) const {
    FeatureOutputs collector(lookups_, gdef, outputs, cancellation);
    std::set<unsigned> visited;
    for (const auto &entry : features(branch))
        if (entry.name == feature)
            for (unsigned index : entry.lookups)
                if (visited.insert(index).second)
                    collector.collect(index);
}
} // namespace ga::layout
