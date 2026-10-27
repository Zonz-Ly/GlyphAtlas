#include "GAOpenType.h"
#include <tuple>

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

std::string featureLabel(const LookupStep &step) {
    auto label = tagName(step.feature);
    if (step.value > 1)
        label += " " + std::to_string(step.value);
    return label;
}

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

// One invocation owns all mutable state. The parsed OpenType program is shared
// read-only across text queries, coordinate changes and worker threads.
class Substitution {
    const std::vector<Lookup> &lookups_;
    const GDEF &gdef_;
    Buffer &buffer_;
    Trace *trace_;
    Decisions *decisions_;
    Budget ownedBudget_;
    Budget &budget_;
    Tag activeFeature_ = 0;
    std::vector<Frame *> frames_;
    std::vector<std::tuple<unsigned, uint64_t, Glyph>> active_;
    uint64_t nextIdentity_ = 1;

    void splice(size_t at, size_t removed, Buffer inserted) {
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
        auto begin = buffer_.begin() + at;
        begin = buffer_.erase(begin, begin + removed);
        buffer_.insert(begin, inserted.begin(), inserted.end());
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
                buffer_[pos].component = int(component);
                buffer_[pos].source = merged;
            }
        }
        // Delete from the right so remaining positions keep their meaning.
        for (size_t i = positions->size(); i > 1; i--)
            splice((*positions)[i - 1], 1, {});
        splice(at, 1, {ligature});
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
            Buffer inserted;
            for (size_t i = 0; i < outputs.size(); i++) {
                Item item = buffer_[at];
                item.glyph = outputs[i];
                if (i)
                    item.identity = nextIdentity_++;
                inserted.push_back(std::move(item));
            }
            size_t next = at + inserted.size();
            splice(at, 1, std::move(inserted));
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
                View d = sub.data;
                size_t p = 6 + d.u16(4) * 2;
                unsigned look = d.u16(p);
                p += 2 + look * 2;
                unsigned count = d.u16(p);
                int ci = sub.coverage.index(buffer_[at].glyph);
                if (ci < 0 || unsigned(ci) >= count)
                    throw InvalidTable("reverse substitute exceeds coverage");
                buffer_[at].glyph = d.u16(p + 2 + ci * 2);
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
        if (index >= lookups_.size() || at >= buffer_.size() || active_.size() >= 64)
            return {};
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
                Buffer before = trace_ ? buffer_ : Buffer{};
                result = subtable(*rule.subtable, lookup, at, step, rule.pattern);
                if (trace_) {
                    trace_->changed(before, buffer_, featureLabel(step));
                }
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
    Substitution(const std::vector<Lookup> &lookups, const GDEF &gdef, Buffer &buffer, Trace *trace,
                 Budget *budget = nullptr, Decisions *decisions = nullptr)
        : lookups_(lookups), gdef_(gdef), buffer_(buffer), trace_(trace), decisions_(decisions),
          ownedBudget_(buffer.size()), budget_(budget ? *budget : ownedBudget_) {
        for (auto &item : buffer_) {
            if (!item.identity)
                item.identity = nextIdentity_++;
            else
                nextIdentity_ = std::max(nextIdentity_, item.identity + 1);
        }
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
        Buffer before = buffer_;
        subtable(*rule.subtable, lookups_[step.lookup], at, step, rule.pattern);
        if (trace_) {
            trace_->changed(before, buffer_, featureLabel(step));
        }
        active_.pop_back();
    }
    void run(const std::vector<LookupStep> &plan) {
        for (const auto &step : plan) {
            activeFeature_ = step.feature;
            const auto &lookup = lookups_[step.lookup];
            Buffer before = trace_ ? buffer_ : Buffer{};
            if (lookup.reverse) {
                for (size_t i = buffer_.size(); i > 0; i--)
                    if (allowed(buffer_[i - 1], step))
                        apply(step.lookup, i - 1, step.value);
            } else
                for (size_t i = 0; i < buffer_.size();) {
                    budget_.step();
                    if (!allowed(buffer_[i], step)) {
                        i++;
                        continue;
                    }
                    auto result = apply(step.lookup, i, step.value);
                    i = result.matched ? result.next : i + 1;
                }
            if (trace_) {
                trace_->changed(before, buffer_, featureLabel(step));
            }
        }
    }
};
// Enumerate nested choices within one matched rule. Each replay finishes
// the entire contextual action list before handing its state to the pipeline.
template <typename Visitor>
void visitRuleOutputs(const std::vector<Lookup> &lookups, const GDEF &gdef,
                      const Buffer &input, const LookupStep &step, size_t at,
                      const Rule &rule, Budget &budget, Visitor &&visit) {
    std::vector<std::vector<size_t>> pending(1);
    while (!pending.empty()) {
        budget.step();
        Decisions decisions{std::move(pending.back()), {}};
        pending.pop_back();
        Buffer output = input;
        Trace found;
        Substitution preview(lookups, gdef, output, &found, &budget, &decisions);
        preview.applyRule(step, at, rule);
        visit(std::move(output), found);
        for (size_t i = decisions.selected.size(); i < decisions.counts.size(); i++)
            for (size_t choice = 1; choice < decisions.counts[i]; choice++) {
                auto path = decisions.selected;
                path.resize(i, 0);
                path.push_back(choice);
                pending.push_back(std::move(path));
            }
    }
}

using Origins = std::map<Span, std::set<std::string>>;
struct CandidateState {
    Buffer items;
    std::optional<Span> focus;
    Origins origins;
};
bool intersects(Span a, Span b) {
    return a.start < b.end && b.start < a.end;
}
std::vector<uint64_t> stateKey(const CandidateState &state) {
    std::vector<uint64_t> key;
    key.push_back(state.focus ? 1 : 0);
    if (state.focus) { key.push_back(state.focus->start); key.push_back(state.focus->end); }
    for (const auto &item : state.items) {
        key.insert(key.end(), {item.glyph, item.source.start, item.source.end,
                              item.scalar, item.form, item.ignorable,
                              uint64_t(item.component + 1), item.components.size()});
        for (Span source : item.components) { key.push_back(source.start); key.push_back(source.end); }
    }
    return key;
}

// Inventory states are peers. Every matched candidate continues at the next
// lookup with its full context and source ownership intact. A focus limits
// subsequent forks to related changes; independent candidate combinations
// are not enumerated as whole-paragraph permutations.
void discover(const std::vector<Lookup> &lookups, const GDEF &gdef, Buffer &buffer,
              const std::vector<LookupStep> &steps, Trace &trace) {
    Budget budget(buffer.size());
    std::vector<CandidateState> states{{buffer, {}, {}}};
    std::set<std::tuple<Span, std::vector<Glyph>, std::string>> recorded;
    auto record = [&](const Trace &found, const Origins &origins) {
        auto add = [&](Change change) {
            if (recorded.emplace(change.source, change.glyphs, change.feature).second)
                trace.changes.push_back(std::move(change));
        };
        for (const auto &change : found.changes) {
            add(change);
            for (const auto &[source, features] : origins)
                if (intersects(source, change.source))
                    for (const auto &feature : features)
                        add({change.source, change.glyphs, feature});
        }
    };
    auto remember = [](CandidateState &state, const Trace &found) {
        for (const auto &change : found.changes)
            state.origins[change.source].insert(change.feature);
    };
    for (const auto &step : steps) {
        std::vector<CandidateState> next;
        std::map<std::vector<uint64_t>, size_t> seen;
        size_t queuedGlyphs = 0;
        auto append = [&](CandidateState state) {
            budget.step();
            auto [at, inserted] = seen.emplace(stateKey(state), next.size());
            if (inserted) {
                if (state.items.size() > budget.maxGlyphs - queuedGlyphs)
                    throw InvalidTable("font discovery state budget exhausted");
                queuedGlyphs += state.items.size();
                next.push_back(std::move(state));
            }
            else for (const auto &[source, features] : state.origins)
                next[at->second].origins[source].insert(features.begin(), features.end());
        };
        for (const auto &state : states) {
            Buffer input = state.items;
            Substitution matcher(lookups, gdef, input, nullptr, &budget);
            for (size_t at : visible(input, gdef, lookups[step.lookup])) {
                for (const auto &rule : matcher.rules(step, at)) {
                    unsigned type = rule.subtable->type;
                    if (type != 4 && type != 5 && type != 6) continue;
                    // A branch can affect a later rule through its backtrack or
                    // lookahead even when that rule changes a different glyph.
                    if (state.focus && !intersects(*state.focus, rule.scope)) continue;
                    visitRuleOutputs(lookups, gdef, input, step, at, rule, budget,
                        [&](Buffer items, const Trace &found) {
                            Trace difference;
                            difference.changed(input, items, tagName(step.feature));
                            std::optional<Span> changed;
                            for (const auto &change : difference.changes)
                                changed = changed ? unite(*changed, change.source) : change.source;
                            record(found, state.origins);
                            if (!changed) return;
                            CandidateState candidate{std::move(items),
                                state.focus ? unite(*state.focus, *changed) : *changed, state.origins};
                            remember(candidate, found);
                            append(std::move(candidate));
                        });
                }
            }
            CandidateState applied = state;
            Trace found;
            Substitution(lookups, gdef, applied.items, &found, &budget).run({step});
            record(found, state.origins);
            remember(applied, found);
            if (!state.focus) buffer = applied.items;
            append(std::move(applied));
        }
        states = std::move(next);
    }
}
} // namespace
void OpenType::substitute(Buffer &buffer, const GDEF &gdef, const Settings &settings, size_t branch,
                          Trace *trace) const {
    if (positioning_)
        throw InvalidTable("positioning program used for substitution");
    substituteLookups(buffer, gdef, plan(settings, branch), trace);
}
void OpenType::substituteLookups(Buffer &buffer, const GDEF &gdef,
                                 const std::vector<LookupStep> &steps, Trace *trace) const {
    if (positioning_)
        throw InvalidTable("positioning program used for substitution");
    for (auto step : steps)
        if (step.lookup >= lookups_.size())
            throw InvalidTable("lookup index outside list");
    if (trace && trace->inventory)
        discover(lookups_, gdef, buffer, steps, *trace);
    else
        Substitution(lookups_, gdef, buffer, trace).run(steps);
}
} // namespace ga::layout
