#include "GAOpenType.h"
#include <numeric>
#include <tuple>

namespace ga::layout {

// Related substitutions for a single glyph.
namespace {
struct Output {
    unsigned position, value;
    std::vector<Glyph> glyphs;
};
// A table catalogue, independent of the current text. Positions identify the
// glyph affected by a nested action, so a rule for W+i contributes W's outputs
// to W and i's outputs to i, rather than placing both on either character.
class Catalogue {
    const std::vector<Lookup> &lookups_;
    const GDEF &gdef_;
    Glyph seed_;
    Budget budget_;
    std::map<unsigned, std::vector<Output>> memo_;
    std::set<unsigned> active_;
    const std::vector<Output> empty_;
    void append(std::vector<Output> &outputs, unsigned position, std::vector<Glyph> glyphs,
                unsigned value = 1) {
        auto found = std::find_if(outputs.begin(), outputs.end(), [&](const Output &output) {
            return output.position == position && output.value == value && output.glyphs == glyphs;
        });
        if (found == outputs.end())
            outputs.push_back({position, value, std::move(glyphs)});
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
    Catalogue(const std::vector<Lookup> &lookups, const GDEF &gdef, Glyph seed,
              const Cancellation *cancellation)
        : lookups_(lookups), gdef_(gdef), seed_(seed), budget_(1, cancellation) {}
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
                        append(outputs, 0, {glyphs[i]}, i + 1);
                } else
                    append(outputs, 0, std::move(glyphs));
            } else if (sub.type == 4) {
                // Ligatures require their complete input sequence. This also
                // excludes type 4 called by a contextual lookup; the actual
                // executor discovers those combinations with source ranges.
                continue;
            } else if (sub.type == 8) {
                if (!gdef_.included(seed_, program.flags, program.markSet))
                    continue;
                int ci = sub.coverage.index(seed_);
                if (ci < 0)
                    continue;
                append(outputs, 0, {reverseSubstitutionOutput(sub, unsigned(ci))});
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
                                                                const GDEF &gdef,
                                                                const Cancellation *cancellation) const {
    if (positioning_)
        throw InvalidTable("positioning program used as substitution catalogue");
    Catalogue catalogue(lookups_, gdef, seed, cancellation);
    std::vector<RelatedSubstitution> result;
    std::set<std::tuple<Tag, unsigned, std::vector<Glyph>>> seen;
    auto add = [&](const std::vector<Glyph> &glyphs, Tag feature, unsigned value) {
        if (glyphs == std::vector<Glyph>{seed})
            return;
        if (seen.emplace(feature, value, glyphs).second)
            result.push_back({glyphs, feature, value});
    };
    for (const auto &branch : branches_)
        for (const auto &feature : branch)
            for (unsigned index : feature.lookups) {
                for (const auto &output : catalogue.lookup(index))
                    add(output.glyphs, feature.name, output.value);
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
                            add({glyphs[i]}, feature.name, i + 1);
                    }
                }
            }
    return result;
}

// Glyph outputs for an active feature branch.
namespace {
using Mask = std::vector<uint64_t>;
using Filter = const Mask *;
struct FilterPairHash {
    size_t operator()(const std::pair<Filter, Filter> &key) const {
        return (std::hash<Filter>{}(key.first) << 1) ^ std::hash<Filter>{}(key.second);
    }
};
bool contains(const Mask &set, Glyph glyph) {
    return (glyph / 64 < set.size()) && (set[glyph / 64] & (uint64_t(1) << (glyph % 64)));
}
void add(Mask &set, Glyph glyph) {
    if (glyph / 64 < set.size()) set[glyph / 64] |= uint64_t(1) << (glyph % 64);
}
struct Slot {
    Filter filter = nullptr;
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
    // Canonical sets make repeated intersections reusable across rule invocations.
    std::map<std::tuple<Predicate::Kind, size_t, unsigned>, Filter> predicates_;
    std::map<std::pair<unsigned, unsigned>, Filter> flags_;
    std::set<Mask> masks_;
    std::unordered_map<std::pair<Filter, Filter>, Filter, FilterPairHash> intersections_;
    Filter empty_;
    // Single, multiple and alternate substitutions only inspect their anchor.
    std::unordered_map<const Subtable *, std::unordered_map<Filter, Effects>> direct_;
    size_t cachedEffectBytes_ = 0;
    size_t words() const { return (outputs_.size() + 63) / 64; }

    Filter intern(Mask mask) {
        auto [entry, inserted] = masks_.insert(std::move(mask));
        constexpr size_t maskBudget = 16 * 1024 * 1024;
        const size_t bytesPerMask = sizeof(Mask) + 4 * sizeof(void *) + words() * sizeof(uint64_t);
        if (inserted && masks_.size() > maskBudget / bytesPerMask)
            throw InvalidTable("feature filter exceeds mask budget");
        return &*entry;
    }

    Filter intersect(Filter a, Filter b) {
        if (!a || a == b) return b;
        if (!b) return a;
        if (a == empty_ || b == empty_) return empty_;
        if (std::less<Filter>{}(b, a)) std::swap(a, b);
        auto key = std::make_pair(a, b);
        auto found = intersections_.find(key);
        if (found != intersections_.end()) return found->second;
        Mask mask(words());
        for (size_t i = 0; i < mask.size(); ++i) {
            budget_.step();
            mask[i] = (*a)[i] & (*b)[i];
        }
        Filter result = intern(std::move(mask));
        if (intersections_.size() < 65536) intersections_.emplace(key, result);
        return result;
    }

    Filter covered(const Coverage &coverage) {
        auto key = std::make_tuple(Predicate::Kind::Coverage, coverage.tableOffset(), 0u);
        auto [entry, inserted] = predicates_.try_emplace(key);
        if (inserted) {
            Mask mask(words());
            for (Glyph glyph : coverage.glyphs()) {
                budget_.step();
                if (glyph < outputs_.size()) add(mask, glyph);
            }
            entry->second = intern(std::move(mask));
        }
        return entry->second;
    }
    Filter matching(const Predicate &predicate) {
        if (predicate.kind == Predicate::Kind::Coverage) return covered(predicate.coverage);
        auto key = std::make_tuple(predicate.kind, predicate.classes.tableOffset(), predicate.value);
        auto [entry, inserted] = predicates_.try_emplace(key);
        if (inserted) {
            Mask mask(words());
            if (predicate.kind == Predicate::Kind::Exact) {
                if (predicate.value < outputs_.size()) add(mask, Glyph(predicate.value));
            } else {
                for (size_t i = 0; i < outputs_.size(); ++i) {
                    budget_.step();
                    if (predicate.matches(Glyph(i))) add(mask, Glyph(i));
                }
            }
            entry->second = intern(std::move(mask));
        }
        return entry->second;
    }
    Filter included(const Lookup &lookup) {
        auto [entry, inserted] = flags_.try_emplace(std::make_pair(lookup.flags, lookup.markSet));
        if (inserted) {
            Mask mask(words());
            for (size_t i = 0; i < outputs_.size(); ++i) {
                budget_.step();
                if (gdef_.included(Glyph(i), lookup.flags, lookup.markSet)) add(mask, Glyph(i));
            }
            entry->second = intern(std::move(mask));
        }
        return entry->second;
    }
    std::set<std::pair<unsigned, size_t>> active_;

    void emit(Effects *effects, size_t consumed, std::vector<Glyph> glyphs, bool changed = true) {
        if (changed)
            for (Glyph glyph : glyphs)
                if (glyph && glyph != 0xffff && glyph < outputs_.size())
                    outputs_[glyph] = true;
        if (effects && changed)
            effects->insert({0, consumed, std::move(glyphs)});
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
                                       [&](Glyph g) { return contains(*prior.filter, g); })) {
                    continue;
                }
            } else {
                // Merging different source slots creates a new symbolic slot.
                prior.state = nextSlotState_++;
                prior.produced.reset();
            }
            Mask mask(words());
            auto merge = [&](const Slot &slot) {
                if (!slot.filter) return;
                for (size_t j = 0; j < words(); ++j) {
                    budget_.step();
                    mask[j] |= (*slot.filter)[j];
                }
            };
            if (i < original.size()) merge(original[i]);
            for (size_t source : moved[i]) merge(original[source]);
            for (Glyph glyph : generated[i]) add(mask, glyph);
            slots[i] = {intern(std::move(mask)), prior.state, std::move(prior.produced)};
        }
    }

  public:
    FeatureOutputs(const std::vector<Lookup> &lookups, const GDEF &gdef,
                   std::vector<bool> &outputs, const Cancellation *cancellation)
        : lookups_(lookups), gdef_(gdef), outputs_(outputs),
          budget_(std::min<size_t>(outputs.size(), 1000), cancellation) {
        // A cold feature query can traverse hundreds of thousands of actions.
        // Keep its limit separate from text shaping and AAT.
        budget_.remaining *= 2;
        empty_ = intern(Mask(words()));
    }

    void collect(unsigned index, const std::vector<Slot> &scope = {}, size_t anchor = 0,
                 Effects *effects = nullptr, const LookupFlags *scopeFlags = nullptr) {
        budget_.step();
        if (index >= lookups_.size())
            return;
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
            return g < outputs_.size() && (!slot || !slot->filter || contains(*slot->filter, g)) &&
                   gdef_.included(g, lookup.flags, lookup.markSet);
        };
        auto contextFits = [&](const Pattern &pattern) {
            auto fits = [&](const Predicate &predicate, std::ptrdiff_t offset) {
                const auto *slot = inherited(offset);
                if (!slot || !slot->filter) return true;
                return intersect(matching(predicate), slot->filter) != empty_;
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
                constexpr size_t effectCacheBudget = 2 * 1024 * 1024;
                Effects *target = effects;
                Effects computed;
                const auto *slot = inherited(0);
                Filter mask = slot ? slot->filter : nullptr;
                auto *saved = sub.type <= 3 && mask ? &direct_[&sub] : nullptr;
                if (saved) {
                    auto hit = saved->find(mask);
                    if (hit != saved->end()) {
                        if (effects) effects->insert(hit->second.begin(), hit->second.end());
                        continue;
                    }
                    if (effects && cachedEffectBytes_ < effectCacheBudget) target = &computed;
                }
                for (Glyph glyph : sub.coverage.glyphs()) {
                    budget_.step();
                    if (!accepted(0, glyph)) continue;
                    auto replacements = sub.type == 8
                        ? std::vector<Glyph>{reverseSubstitutionOutput(sub, sub.coverage.index(glyph))}
                        : substitutionOutputs(sub, glyph);
                    if (sub.type == 3) {
                        for (Glyph alternate : replacements)
                            emit(target, 1, {alternate}, alternate != glyph);
                    } else {
                        bool changed = replacements.size() != 1 || replacements.front() != glyph;
                        emit(target, 1, std::move(replacements), changed);
                    }
                }
                if (target == &computed) {
                    effects->insert(computed.begin(), computed.end());
                    size_t cost = 128; // Map entry and set bookkeeping.
                    for (const auto &effect : computed)
                        cost += sizeof(Effect) + 4 * sizeof(void *) + effect.glyphs.capacity() * sizeof(Glyph);
                    if (cost <= effectCacheBudget - cachedEffectBytes_) {
                        cachedEffectBytes_ += cost;
                        saved->emplace(mask, std::move(computed));
                    }
                }
                continue;
            }
            for (const auto &pattern : sub.patterns) {
                budget_.step();
                if (!contextFits(pattern)) continue;
                std::vector<Slot> slots;
                for (size_t i = 0; i < pattern.input.size(); ++i) {
                    Filter mask = intersect(matching(pattern.input[i]), included(lookup));
                    const auto *prior = inherited(std::ptrdiff_t(i));
                    if (prior) mask = intersect(mask, prior->filter);
                    if (i == 0 && pattern.firstCoverage)
                        mask = intersect(mask, covered(pattern.firstCoverage));
                    if (mask == empty_) break;
                    const size_t state = i == 0 ? anchorState : prior ? prior->state : nextSlotState_++;
                    slots.push_back({mask, state, prior ? prior->produced : nullptr});
                }
                if (slots.empty() || slots.size() != pattern.input.size()) continue;
                if (sub.type == 4) {
                    emit(effects, slots.size(), pattern.replacement);
                    continue;
                }
                for (size_t i = 0; i < pattern.actions.size(); ++i) {
                    const auto &action = pattern.actions[i];
                    const bool last = i + 1 == pattern.actions.size();
                    budget_.step();
                    if (action.sequence >= slots.size()) continue;
                    Effects next;
                    collect(action.lookup, slots, action.sequence, (!last || effects) ? &next : nullptr, &lookup);
                    if (effects)
                        for (const auto &effect : next)
                            effects->insert({action.sequence + effect.offset, effect.consumed,
                                             effect.glyphs});
                    if (!last) update(slots, action.sequence, next);
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
