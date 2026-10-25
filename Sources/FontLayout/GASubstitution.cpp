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

// One invocation owns all mutable state. The parsed OpenType program is shared
// read-only across text queries, coordinate changes and worker threads.
class Substitution {
    const std::vector<Lookup> &lookups_;
    const GDEF &gdef_;
    Buffer &buffer_;
    Trace *trace_;
    Budget budget_;
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
    void window(Span scope) {
        if (trace_ && !scope.empty())
            trace_->windows.insert(scope);
    }
    void collect(const Lookup &lookup) {
        if (!trace_)
            return;
        auto indices = visible(buffer_, gdef_, lookup);
        for (const auto &sub : lookup.subtables)
            for (size_t start : indices) {
                if (sub.type <= 3) {
                    if (sub.coverage.contains(buffer_[start].glyph))
                        window(buffer_[start].source);
                    continue;
                }
                auto candidates = sub.starts.find(buffer_[start].glyph);
                if (candidates == sub.starts.end())
                    continue;
                for (unsigned pi : candidates->second) {
                    budget_.step();
                    Span scope;
                    if (match(sub.patterns[pi], buffer_, start, gdef_, lookup, &scope))
                        window(scope);
                }
            }
    }
    Applied contextual(const Pattern &pattern, const Lookup &lookup, size_t at,
                       const LookupStep &step) {
        Span scope;
        auto input = match(pattern, buffer_, at, gdef_, lookup, &scope);
        if (!input)
            return {};
        window(scope);
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
        Span scope;
        auto positions = match(pattern, buffer_, at, gdef_, lookup, &scope);
        if (!positions)
            return {};
        window(scope);
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
    Applied subtable(const Subtable &sub, const Lookup &lookup, size_t at, const LookupStep &step) {
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
            window(buffer_[at].source);
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
                Span scope;
                if (!match(pattern, buffer_, at, gdef_, lookup, &scope))
                    continue;
                window(scope);
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
        LookupStep step{index, value, 0, true};
        Applied result;
        for (const auto &sub : lookup.subtables) {
            result = subtable(sub, lookup, at, step);
            if (result.matched)
                break;
        }
        active_.pop_back();
        return result;
    }

  public:
    Substitution(const std::vector<Lookup> &lookups, const GDEF &gdef, Buffer &buffer, Trace *trace)
        : lookups_(lookups), gdef_(gdef), buffer_(buffer), trace_(trace), budget_(buffer.size()) {
        for (auto &item : buffer_) {
            if (!item.identity)
                item.identity = nextIdentity_++;
            else
                nextIdentity_ = std::max(nextIdentity_, item.identity + 1);
        }
    }
    void run(const std::vector<LookupStep> &plan) {
        for (const auto &step : plan) {
            const auto &lookup = lookups_[step.lookup];
            collect(lookup);
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
                auto label = tagName(step.feature);
                if (step.value > 1)
                    label += " " + std::to_string(step.value);
                trace_->changed(before, buffer_, label);
            }
        }
    }
};
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
    Substitution(lookups_, gdef, buffer, trace).run(steps);
}
} // namespace ga::layout
