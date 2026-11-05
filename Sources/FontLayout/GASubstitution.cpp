#include "GAOpenType.h"
#include "GASubstitutionBuffer.h"
#include <tuple>
#include <array>

namespace ga::layout {
namespace {
struct Frame {
    std::vector<size_t> input;
};
struct Applied {
    bool matched = false;
    size_t next = 0;
};

struct Rule {
    const Subtable *subtable;
    std::optional<unsigned> pattern;
    Span scope;
};

// Replaying a contextual rule with another nested choice preserves all later
// actions and their updated SequenceIndex mappings, rather than saving a GID
// snapshot halfway through that rule.
struct Decisions {
    std::vector<size_t> selected, counts;
    size_t choose(size_t count) {
        size_t at = counts.size();
        counts.push_back(count);
        size_t choice = at < selected.size() ? selected[at] : 0;
        if (choice >= count) throw InvalidTable("invalid discovery decision");
        return choice;
    }
};

// The discovery traversal still visits positions in order. Share the cheap
// first-glyph rejection across states of the same lookup.
class LookupCoverage {
    const Lookup &lookup_;
    std::array<uint8_t, 65536> flags_{};

  public:
    static constexpr uint8_t known = 1, canApply = 2, canBranch = 4;

    explicit LookupCoverage(const Lookup &lookup) : lookup_(lookup) {}
    uint8_t operator[](Glyph glyph) {
        auto &flag = flags_[glyph];
        if (flag) return flag;
        flag = known;
        for (const auto &sub : lookup_.subtables) {
            if (!(sub.type <= 3 ? sub.coverage.contains(glyph) : sub.starts.count(glyph)))
                continue;
            flag |= canApply;
            if (sub.type >= 4 && sub.type <= 6) flag |= canBranch;
        }
        return flag;
    }
};

// One invocation owns all mutable state. The parsed OpenType program is shared
// read-only across text queries, coordinate changes and worker threads.
class Substitution {
    const std::vector<Lookup> &lookups_;
    const GDEF &gdef_;
    SubstitutionBuffer &buffer_;
    Trace *trace_;
    Decisions *decisions_;
    Budget ownedBudget_;
    Budget &budget_;
    Tag activeFeature_ = 0;
    std::vector<Frame *> frames_;
    std::vector<std::tuple<unsigned, uint64_t, Glyph>> active_;
    uint64_t nextIdentity_ = 1;

    void splice(size_t at, Buffer inserted) {
        constexpr size_t removed = 1;
        if (at > buffer_.size() || removed > buffer_.size() - at)
            throw InvalidTable("substitution range outside buffer");
        budget_.growth(buffer_.size() - removed + inserted.size());
        for (auto *frame : frames_) {
            std::vector<size_t> adjusted;
            bool replaced = false;
            for (size_t pos : frame->input) {
                if (pos < at)
                    adjusted.push_back(pos);
                else if (pos >= at + removed)
                    adjusted.push_back(pos - removed + inserted.size());
                else if (!replaced) {
                    for (size_t j = 0; j < inserted.size(); j++)
                        adjusted.push_back(at + j);
                    replaced = true;
                }
            }
            frame->input = std::move(adjusted);
        }
        buffer_.replace(at, std::move(inserted));
    }
    Applied contextual(const Pattern &pattern, const Lookup &lookup, size_t at,
                       const LookupStep &step) {
        auto input = match(pattern, buffer_, at, gdef_, lookup);
        if (!input)
            return {};
        Frame frame{*input};
        frames_.push_back(&frame);
        for (auto action : pattern.actions)
            if (action.sequence < frame.input.size())
                apply(action.lookup, frame.input[action.sequence], step.value);
        size_t next = frame.input.empty() ? at : frame.input.back() + 1;
        frames_.pop_back();
        return {true, next};
    }
    Applied ligate(const Pattern &pattern, const Lookup &lookup, size_t at) {
        auto positions = match(pattern, buffer_, at, gdef_, lookup);
        if (!positions)
            return {};
        Item ligature = buffer_[at];
        ligature.glyph = pattern.replacement.front();
        ligature.components.clear();
        for (size_t pos : *positions) {
            const auto &component = buffer_[pos];
            if (component.components.empty())
                ligature.components.push_back(component.source);
            else
                ligature.components.insert(ligature.components.end(), component.components.begin(),
                                           component.components.end());
        }
        Span merged = buffer_[positions->front()].source;
        for (size_t pos : *positions)
            merged = unite(merged, buffer_[pos].source);
        ligature.source = merged;
        for (size_t pos = positions->front(); pos <= positions->back(); pos++) {
            if (std::find(positions->begin(), positions->end(), pos) == positions->end()) {
                auto original = buffer_[pos].source;
                unsigned component = 0;
                for (unsigned i = 0; i < ligature.components.size(); i++)
                    if (ligature.components[i].start <= original.start)
                        component = i;
                auto &item = buffer_.edit(pos);
                item.component = int(component);
                item.source = merged;
            }
        }
        // Delete from the right so remaining positions keep their meaning.
        for (size_t i = positions->size(); i > 1; i--)
            splice((*positions)[i - 1], {});
        splice(at, {ligature});
        return {true, at + 1};
    }
    Applied subtable(const Subtable &sub, const Lookup &lookup, size_t at, const LookupStep &step,
                     std::optional<unsigned> onlyPattern = {}) {
        budget_.step();
        if (at >= buffer_.size())
            return {};
        if (sub.type <= 3) {
            if (sub.coverage.index(buffer_[at].glyph) < 0)
                return {};
            auto outputs = substitutionOutputs(sub, buffer_[at].glyph);
            if (sub.type == 3) {
                if (!step.value || step.value > outputs.size())
                    return {};
                outputs = {outputs[step.value - 1]};
            }
            if (sub.type == 1 && outputs.empty())
                throw InvalidTable("invalid single substitution");
            if (outputs.size() == 1) {
                budget_.growth(buffer_.size());
                if (buffer_[at].glyph != outputs.front())
                    buffer_.edit(at).glyph = outputs.front();
                return {true, at + 1};
            }
            Buffer inserted;
            for (size_t i = 0; i < outputs.size(); i++) {
                Item item = buffer_[at];
                item.glyph = outputs[i];
                if (i)
                    item.identity = nextIdentity_++;
                inserted.push_back(std::move(item));
            }
            size_t next = at + inserted.size();
            splice(at, std::move(inserted));
            return {true, next};
        }
        auto candidates = sub.starts.find(buffer_[at].glyph);
        if (candidates == sub.starts.end())
            return {};
        for (unsigned pi : candidates->second) {
            if (onlyPattern && pi != *onlyPattern) continue;
            budget_.step();
            const auto &pattern = sub.patterns[pi];
            if (sub.type == 4) {
                auto result = ligate(pattern, lookup, at);
                if (result.matched)
                    return result;
            } else if (sub.type == 5 || sub.type == 6) {
                auto result = contextual(pattern, lookup, at, step);
                if (result.matched)
                    return result;
            } else if (sub.type == 8) {
                if (!match(pattern, buffer_, at, gdef_, lookup))
                    continue;
                int ci = sub.coverage.index(buffer_[at].glyph);
                if (ci < 0)
                    throw InvalidTable("reverse substitute exceeds coverage");
                const Glyph glyph = reverseSubstitutionOutput(sub, unsigned(ci));
                if (buffer_[at].glyph != glyph) buffer_.edit(at).glyph = glyph;
                return {true, at + 1};
            }
        }
        return {};
    }
    bool allowed(const Item &item, const LookupStep &step) const {
        if (step.explicitValue)
            return true;
        bool form =
            step.feature == tag('i', 's', 'o', 'l') || step.feature == tag('i', 'n', 'i', 't') ||
            step.feature == tag('m', 'e', 'd', 'i') || step.feature == tag('f', 'i', 'n', 'a');
        return !form || item.form == step.feature;
    }
    Applied apply(unsigned index, size_t at, unsigned value) {
        if (index >= lookups_.size() || at >= buffer_.size()) return {};
        if (active_.size() >= 64) {
            if (budget_.discovery) throw DiscoveryLimit{};
            return {};
        }
        const auto &lookup = lookups_[index];
        if (!accepts(gdef_, lookup, buffer_[at]))
            return {};
        auto key = std::make_tuple(index, buffer_[at].identity, buffer_[at].glyph);
        if (std::find(active_.begin(), active_.end(), key) != active_.end())
            return {};
        active_.push_back(key);
        LookupStep step{index, value, activeFeature_, true};
        Applied result;
        if (decisions_) {
            auto choices = rules(step, at);
            if (!choices.empty()) {
                const auto &rule = choices[decisions_->choose(choices.size())];
                SubstitutionBuffer before = trace_ ? buffer_ : SubstitutionBuffer{};
                result = subtable(*rule.subtable, lookup, at, step, rule.pattern);
                if (trace_) {
                    before.recordChanges(buffer_, *trace_, featureLabel(step.feature, step.value));
                }
            }
        } else if (trace_ && trace_->provenance) {
            auto choices = rules(step, at);
            if (!choices.empty()) {
                const auto &rule = choices.front();
                bool nested = rule.subtable->type == 5 || rule.subtable->type == 6;
                SubstitutionBuffer before = nested ? SubstitutionBuffer{} : buffer_;
                result = subtable(*rule.subtable, lookup, at, step, rule.pattern);
                // Nested actions record their own actual input/output.
                if (!nested) before.recordChanges(buffer_, *trace_, featureLabel(step.feature, step.value));
            }
        } else {
            for (const auto &sub : lookup.subtables) {
                result = subtable(sub, lookup, at, step);
                if (result.matched) break;
            }
        }
        active_.pop_back();
        return result;
    }

  public:
    Substitution(const std::vector<Lookup> &lookups, const GDEF &gdef, SubstitutionBuffer &buffer, Trace *trace,
                 Budget *budget = nullptr, Decisions *decisions = nullptr)
        : lookups_(lookups), gdef_(gdef), buffer_(buffer), trace_(trace), decisions_(decisions),
          ownedBudget_(buffer.size()), budget_(budget ? *budget : ownedBudget_) {
        nextIdentity_ = buffer_.nextIdentity();
    }
    std::vector<Rule> rules(const LookupStep &step, size_t at) {
        std::vector<Rule> result;
        const auto &lookup = lookups_[step.lookup];
        if (at >= buffer_.size() || !allowed(buffer_[at], step) ||
            !accepts(gdef_, lookup, buffer_[at])) return result;
        for (const auto &sub : lookup.subtables) {
            if (sub.type <= 3) {
                if (!sub.coverage.contains(buffer_[at].glyph)) continue;
                if (sub.type == 3 && (!step.value ||
                    step.value > substitutionOutputs(sub, buffer_[at].glyph).size())) continue;
                result.push_back({&sub, {}, buffer_[at].source});
                continue;
            }
            auto candidates = sub.starts.find(buffer_[at].glyph);
            if (candidates == sub.starts.end()) continue;
            for (unsigned pi : candidates->second) {
                budget_.step();
                Span scope;
                if (match(sub.patterns[pi], buffer_, at, gdef_, lookup, &scope))
                    result.push_back({&sub, pi, scope});
            }
        }
        return result;
    }
    void applyRule(const LookupStep &step, size_t at, const Rule &rule) {
        activeFeature_ = step.feature;
        active_.push_back({step.lookup, buffer_[at].identity, buffer_[at].glyph});
        SubstitutionBuffer before = buffer_;
        subtable(*rule.subtable, lookups_[step.lookup], at, step, rule.pattern);
        if (trace_) {
            before.recordChanges(buffer_, *trace_, featureLabel(step.feature, step.value));
        }
        active_.pop_back();
    }
    void runStep(const LookupStep &step, LookupCoverage *coverage = nullptr) {
        activeFeature_ = step.feature;
        const auto &lookup = lookups_[step.lookup];
        SubstitutionBuffer before = trace_ && !trace_->provenance ? buffer_ : SubstitutionBuffer{};
        if (lookup.reverse) {
            for (size_t i = buffer_.size(); i > 0; i--) {
                if (budget_.cancellation)
                    budget_.poll();
                const auto &item = buffer_[i - 1];
                if ((!coverage || ((*coverage)[item.glyph] & LookupCoverage::canApply)) && allowed(item, step))
                    apply(step.lookup, i - 1, step.value);
            }
        } else
            for (size_t i = 0; i < buffer_.size();) {
                budget_.step();
                const auto &item = buffer_[i];
                if ((coverage && !((*coverage)[item.glyph] & LookupCoverage::canApply)) || !allowed(item, step)) {
                    i++;
                    continue;
                }
                auto result = apply(step.lookup, i, step.value);
                i = result.matched ? result.next : i + 1;
            }
        if (trace_ && !trace_->provenance) {
            before.recordChanges(buffer_, *trace_, featureLabel(step.feature, step.value));
        }
    }
    void run(const std::vector<LookupStep> &plan) {
        for (const auto &step : plan) runStep(step);
    }
};
// Enumerate nested choices within one matched rule. Each replay finishes
// the entire contextual action list before handing its state to the pipeline.
template <typename Visitor>
void visitRuleOutputs(const std::vector<Lookup> &lookups, const GDEF &gdef,
                      const SubstitutionBuffer &input, const LookupStep &step, size_t at,
                      const Rule &rule, Budget &budget, Visitor &&visit) {
    std::vector<std::vector<size_t>> pending(1);
    size_t pendingBytes = sizeof(pending.front());
    constexpr size_t pendingLimit = 16 * 1024 * 1024;
    while (!pending.empty()) {
        budget.step();
        pendingBytes -= sizeof(pending.back()) + pending.back().capacity() * sizeof(size_t);
        Decisions decisions{std::move(pending.back()), {}};
        pending.pop_back();
        SubstitutionBuffer output = input;
        Trace found;
        Substitution preview(lookups, gdef, output, &found, &budget, &decisions);
        preview.applyRule(step, at, rule);
        visit(std::move(output), found);
        for (size_t i = decisions.selected.size(); i < decisions.counts.size(); i++)
            for (size_t choice = 1; choice < decisions.counts[i]; choice++) {
                auto path = decisions.selected;
                path.resize(i, 0);
                path.push_back(choice);
                budget.step();
                pendingBytes += sizeof(path) + path.capacity() * sizeof(size_t);
                if (pendingBytes > pendingLimit) throw DiscoveryLimit{};
                pending.push_back(std::move(path));
            }
    }
}

class Origins {
    static constexpr uint32_t bucketWidth = 128;
    using Entries = std::map<Span, std::set<std::string>>;
    std::map<uint32_t, std::shared_ptr<Entries>> buckets_;
    uint32_t maxWidth_ = 0;

  public:
    void add(Span source, const std::string &feature) {
        auto &bucket = buckets_[source.start / bucketWidth];
        if (!bucket) {
            bucket = std::make_shared<Entries>();
        } else {
            auto prior = bucket->find(source);
            if (prior != bucket->end() && prior->second.count(feature)) return;
            if (bucket.use_count() != 1) bucket = std::make_shared<Entries>(*bucket);
        }
        (*bucket)[source].insert(feature);
        if (!source.empty()) maxWidth_ = std::max(maxWidth_, source.end - source.start);
    }
    template <typename Visitor>
    void overlapping(Span source, Visitor visit) const {
        // Each entry starts no earlier than this and still reaches source.start.
        uint32_t first = source.start >= maxWidth_ ? source.start - maxWidth_ : 0;
        for (auto bucket = buckets_.lower_bound(first / bucketWidth); bucket != buckets_.end() &&
             bucket->first * bucketWidth < source.end; ++bucket)
            for (auto it = bucket->second->lower_bound({first, 0}); it != bucket->second->end() &&
                 it->first.start < source.end; ++it)
                if (source.start < it->first.end)
                    for (const auto &feature : it->second)
                        visit(feature);
    }
    void merge(const Origins &other) {
        for (const auto &[index, incoming] : other.buckets_) {
            auto [slot, inserted] = buckets_.try_emplace(index, incoming);
            if (inserted || slot->second == incoming) continue;
            for (const auto &[source, features] : *incoming)
                for (const auto &feature : features)
                    add(source, feature);
        }
        maxWidth_ = std::max(maxWidth_, other.maxWidth_);
    }
};

struct CandidateState {
    SubstitutionBuffer items;
    std::optional<Span> focus;
    Origins origins;
};
bool intersects(Span a, Span b) {
    return a.start < b.end && b.start < a.end;
}
size_t stateHash(const CandidateState &state) {
    size_t hash = state.items.hash();
    if (state.focus)
        hash = (hash * 16777619 + state.focus->start) * 16777619 + state.focus->end;
    return hash;
}

// Inventory states are peers. Every matched candidate continues at the next
// lookup with its full context and source ownership intact. A focus limits
// subsequent forks to related changes; independent candidate combinations
// are not enumerated as whole-paragraph permutations.
void discover(const std::vector<Lookup> &lookups, const GDEF &gdef, Buffer &buffer,
              const std::vector<LookupStep> &steps, Trace &trace, const Cancellation *cancellation) {
    if (steps.empty()) return;
    Budget budget(buffer.size(), cancellation, true);
    SubstitutionBuffer appliedBuffer(buffer);
    std::vector<CandidateState> states{{appliedBuffer, {}, {}}};
    std::map<std::tuple<Span, std::vector<Glyph>, std::vector<uint64_t>>, std::set<std::string>> recorded;
    auto record = [&](const Trace &found, const Origins &origins) {
        for (const auto &change : found.changes) {
            if (cancellation) budget.poll();
            auto &labels = recorded[{change.source, change.glyphs, change.inputKey()}];
            if (labels.insert(change.feature).second)
                trace.changes.push_back(change);
            origins.overlapping(change.source, [&](const std::string &feature) {
                if (!labels.insert(feature).second) return;
                Change inherited = change;
                inherited.feature = feature;
                inherited.inherited = true;
                trace.changes.push_back(std::move(inherited));
            });
        }
    };
    auto remember = [](CandidateState &state, const Trace &found) {
        for (const auto &change : found.changes)
            state.origins.add(change.source, change.feature);
    };
    for (const auto &step : steps) {
        checkCancellation(cancellation);
        const bool lastStep = &step == &steps.back();
        std::vector<CandidateState> next;
        std::unordered_multimap<size_t, size_t> seen;
        std::unordered_set<const void *> storage;
        size_t bytes = 0;
        constexpr size_t frontierLimit = 128 * 1024 * 1024;
        auto append = [&](CandidateState state) {
            budget.step();
            const size_t hash = stateHash(state);
            auto entries = seen.equal_range(hash);
            for (auto entry = entries.first; entry != entries.second; ++entry) {
                auto &prior = next[entry->second];
                if (!(state.focus == prior.focus) || !state.items.equivalent(prior.items)) continue;
                prior.origins.merge(state.origins);
                return;
            }
            bytes += sizeof(CandidateState) + 64 + state.items.storageBytes(storage);
            if (bytes > frontierLimit) throw DiscoveryLimit{};
            seen.emplace(hash, next.size());
            next.push_back(std::move(state));
        };
        const auto &lookup = lookups[step.lookup];
        LookupCoverage coverage(lookup);
        const bool branches = std::any_of(lookup.subtables.begin(), lookup.subtables.end(),
            [](const Subtable &sub) { return sub.type >= 4 && sub.type <= 6; });
        for (const auto &state : states) {
            auto input = state.items;
            Substitution matcher(lookups, gdef, input, nullptr, &budget);
            for (size_t at = 0; branches && at < input.size(); ++at) {
                if (cancellation)
                    budget.poll();
                if (!(coverage[input[at].glyph] & LookupCoverage::canBranch)) continue;
                for (const auto &rule : matcher.rules(step, at)) {
                    unsigned type = rule.subtable->type;
                    if (type != 4 && type != 5 && type != 6) continue;
                    // A branch can affect a later rule through its backtrack or
                    // lookahead even when that rule changes a different glyph.
                    if (state.focus && !intersects(*state.focus, rule.scope)) continue;
                    visitRuleOutputs(lookups, gdef, input, step, at, rule, budget,
                        [&](SubstitutionBuffer items, const Trace &found) {
                            record(found, state.origins);
                            if (lastStep) return;
                            Trace difference;
                            input.recordChanges(items, difference, tagName(step.feature));
                            std::optional<Span> changed;
                            for (const auto &change : difference.changes)
                                changed = changed ? unite(*changed, change.source) : change.source;
                            if (!changed) return;
                            CandidateState candidate{std::move(items),
                                state.focus ? unite(*state.focus, *changed) : *changed, state.origins};
                            remember(candidate, found);
                            append(std::move(candidate));
                        });
                }
            }
            auto applied = state.items;
            Trace found;
            Substitution(lookups, gdef, applied, &found, &budget).runStep(step, &coverage);
            record(found, state.origins);
            if (!state.focus) appliedBuffer = applied;
            if (!lastStep) {
                CandidateState candidate{std::move(applied), state.focus, state.origins};
                remember(candidate, found);
                append(std::move(candidate));
            }
        }
        states = std::move(next);
    }
    buffer = appliedBuffer.materialize();
}
} // namespace
void OpenType::substitute(Buffer &buffer, const GDEF &gdef, const Settings &settings, size_t branch,
                          Trace *trace, const Cancellation *cancellation) const {
    if (positioning_)
        throw InvalidTable("positioning program used for substitution");
    substituteLookups(buffer, gdef, plan(settings, branch), trace, cancellation);
}
void OpenType::substituteLookups(Buffer &buffer, const GDEF &gdef,
                                 const std::vector<LookupStep> &steps, Trace *trace, const Cancellation *cancellation) const {
    if (positioning_)
        throw InvalidTable("positioning program used for substitution");
    checkCancellation(cancellation);
    for (auto step : steps)
        if (step.lookup >= lookups_.size())
            throw InvalidTable("lookup index outside list");
    if (trace && trace->inventory) {
        try {
            discover(lookups_, gdef, buffer, steps, *trace, cancellation);
        } catch (const DiscoveryLimit &) {
            trace->incomplete = true;
        }
    } else {
        SubstitutionBuffer shared(buffer);
        Budget budget(buffer.size(), cancellation);
        Substitution(lookups_, gdef, shared, trace, &budget).run(steps);
        buffer = shared.materialize();
    }
}
} // namespace ga::layout
