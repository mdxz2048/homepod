#include "flow/core.hpp"

#include <cmath>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using namespace flow;
namespace {
void check(bool condition, const char* expression, int line) {
    if (!condition) throw std::runtime_error(std::string(expression) + " at line " + std::to_string(line));
}
#define CHECK(x) check(static_cast<bool>(x), #x, __LINE__)
struct FakeClock : Clock {
    std::int64_t value = 1000000000;
    std::int64_t now_ns() const noexcept override { return value; }
};
struct FakeOutput : Output {
    bool scheduled = true;
    Status prepare_result{};
    Status enqueue_result{};
    int prepares = 0, enqueues = 0, closes = 0;
    bool open = false;
    bool throw_prepare = false, throw_enqueue = false;
    AudioFormat format;
    std::vector<ScheduledBlock> accepted, queued;
    OutputCapabilities capabilities() const noexcept override { return {scheduled}; }
    Status prepare(const AudioFormat& f) override {
        ++prepares; open = true; format = f;
        if (throw_prepare) throw std::runtime_error("prepare exception");
        return prepare_result;
    }
    Status enqueue(const ScheduledBlock& b) override {
        ++enqueues;
        if (throw_enqueue) throw std::runtime_error("enqueue exception");
        if (!enqueue_result) return enqueue_result;
        accepted.push_back(b); queued.push_back(b); return {};
    }
    void close() noexcept override { ++closes; open = false; queued.clear(); }
};
struct Rig {
    std::shared_ptr<FakeClock> clock = std::make_shared<FakeClock>();
    PlaybackEngine engine{clock};
    std::vector<std::shared_ptr<FakeOutput>> sinks;
    std::vector<OutputBinding> bindings;
    explicit Rig(unsigned count = 3) {
        for (unsigned i = 0; i < count; ++i) {
            auto sink = std::make_shared<FakeOutput>();
            sinks.push_back(sink);
            bindings.push_back({{"out-" + std::to_string(i), {i % 3}}, sink});
        }
    }
    void run(AudioFormat format = {48000, 3}) {
        CHECK(engine.prepare(format, bindings));
        CHECK(engine.start(7, 500000000));
    }
};
AudioBlock block(std::uint64_t first = 0) {
    return {{48000, 3}, 7, first, {0.1f, 0.2f, 0.3f, -0.1f, -0.2f, -0.3f}};
}
void untouched(const Rig& rig) {
    for (const auto& sink : rig.sinks) CHECK(sink->prepares == 0 && sink->enqueues == 0);
}
}

int main() {
    std::vector<std::pair<std::string, std::function<void()>>> tests;
    auto test = [&](std::string name, std::function<void()> fn) { tests.emplace_back(std::move(name), std::move(fn)); };
    test("N outputs get distinct channel content on shared media timeline", [] {
        for (unsigned count : {1u, 3u, 5u}) {
            Rig r(count); r.run(); auto b = block();
            CHECK(r.engine.submit(b));
            b.samples[0] = 0.9f;
            CHECK(r.engine.origin_ns() == 1500000000);
            CHECK(r.engine.next_frame() == 2);
            for (unsigned i = 0; i < count; ++i) {
                const auto& got = r.sinks[i]->accepted.at(0);
                float expected = 0.1f * static_cast<float>(i % 3 + 1);
                CHECK(std::fabs(got.audio.samples.at(0) - expected) < 0.000001f);
                CHECK(std::fabs(got.audio.samples.at(1) + expected) < 0.000001f);
                CHECK(got.audio.format.channels == 1 && got.audio.format.sample_rate == 48000);
                CHECK(got.audio.epoch == 7 && got.audio.first_frame == 0);
                CHECK(got.presentation_time_ns == r.engine.origin_ns());
            }
        }
    });
    test("duplicated channels retain interleaved order", [] {
        Rig r(1); r.bindings[0].route.input_channels = {2, 0, 2}; r.run();
        CHECK(r.engine.submit(block()));
        CHECK(r.sinks[0]->accepted[0].audio.samples == std::vector<float>({0.3f,0.1f,0.3f,-0.3f,-0.1f,-0.3f}));
    });
    test("presentation is frame based independent of submission clock", [] {
        Rig r; r.run(); CHECK(r.engine.submit(block()));
        r.clock->value += 12345;
        CHECK(r.engine.submit(block(2)));
        for (const auto& sink : r.sinks) CHECK(sink->accepted[1].presentation_time_ns == 1500000000 + 41666);
    });
    test("invalid source formats rejected before preparing", [] {
        for (AudioFormat f : {AudioFormat{0,3}, AudioFormat{48000,0}}) {
            Rig r; CHECK(r.engine.prepare(f,r.bindings).code == Error::InvalidArgument); untouched(r);
        }
    });
    test("invalid routes and outputs rejected before preparing", [] {
        for (int kind = 0; kind < 6; ++kind) {
            Rig r;
            if (kind == 0) r.bindings.clear();
            if (kind == 1) r.bindings[1].route.input_channels = {3};
            if (kind == 2) r.bindings[1].route.input_channels.clear();
            if (kind == 3) r.bindings[1].output.reset();
            if (kind == 4) r.bindings[1].route.output_id = r.bindings[0].route.output_id;
            if (kind == 5) r.bindings[1].route.output_id.clear();
            CHECK(r.engine.prepare({48000,3},r.bindings).code == Error::InvalidArgument); untouched(r);
        }
    });
    test("unscheduled backend refuses group before any prepare", [] {
        Rig r; r.sinks[2]->scheduled = false;
        CHECK(r.engine.prepare({48000,3},r.bindings).code == Error::Unsupported);
        CHECK(r.engine.state() != EngineState::Running); untouched(r);
    });
    test("partial prepare failure cleans successful and failing output", [] {
        Rig r; r.sinks[1]->prepare_result = {Error::PrepareFailed,"injected"};
        CHECK(!r.engine.prepare({48000,3},r.bindings));
        CHECK(r.sinks[0]->prepares == 1 && r.sinks[0]->closes >= 1 && !r.sinks[0]->open);
        CHECK(r.sinks[1]->prepares == 1 && r.sinks[1]->closes >= 1 && !r.sinks[1]->open);
        CHECK(r.sinks[2]->prepares == 0);
        CHECK(r.engine.state() != EngineState::Running);
        r.engine.stop(); CHECK(r.engine.state() == EngineState::Idle);
    });
    test("zero and negative startup lead refused without losing prepared state", [] {
        Rig r; CHECK(r.engine.prepare({48000,3},r.bindings));
        for (auto lead : {0LL,-1LL}) {
            CHECK(r.engine.start(7,lead).code == Error::InvalidArgument);
            CHECK(r.engine.state() == EngineState::Prepared);
        }
        CHECK(r.engine.start(7,1));
    });
    test("startup clock overflow rejected", [] {
        Rig r; CHECK(r.engine.prepare({48000,3},r.bindings));
        r.clock->value = std::numeric_limits<std::int64_t>::max() - 1;
        CHECK(!r.engine.start(7,2)); CHECK(r.engine.state() == EngineState::Prepared);
    });
    test("invalid blocks preserve running state and allow valid retry", [] {
        for (int kind = 0; kind < 9; ++kind) {
            Rig r; r.run(); auto b = block();
            if (kind == 0) b.format.sample_rate = 44100;
            if (kind == 1) b.format.channels = 2;
            if (kind == 2) b.epoch = 8;
            if (kind == 3) b.first_frame = 1;
            if (kind == 4) b.samples.clear();
            if (kind == 5) b.samples.pop_back();
            if (kind == 6) b.samples[0] = std::numeric_limits<float>::quiet_NaN();
            if (kind == 7) b.samples[0] = std::numeric_limits<float>::infinity();
            if (kind == 8) b.samples[0] = 1.001f;
            CHECK(!r.engine.submit(b));
            CHECK(r.engine.state() == EngineState::Running && r.engine.next_frame() == 0);
            for (const auto& sink : r.sinks) CHECK(sink->enqueues == 0);
            CHECK(r.engine.submit(block()));
        }
    });
    test("duplicate gap and epoch changes rejected after accepted block", [] {
        Rig r; r.run(); CHECK(r.engine.submit(block()));
        for (auto first : {0ULL,1ULL,3ULL}) CHECK(r.engine.submit(block(first)).code == Error::TimestampDiscontinuity);
        auto b = block(2); b.epoch = 8;
        CHECK(r.engine.submit(b).code == Error::TimestampDiscontinuity);
        CHECK(r.engine.next_frame() == 2); CHECK(r.engine.submit(block(2)));
    });
    test("backpressure after partial acceptance faults and clears every output", [] {
        Rig r; r.run(); r.sinks[1]->enqueue_result = {Error::WouldBlock,"queue full"};
        CHECK(r.engine.submit(block()).code == Error::WouldBlock);
        CHECK(r.sinks[0]->accepted.size() == 1 && r.sinks[1]->enqueues == 1 && r.sinks[2]->enqueues == 0);
        CHECK(r.engine.state() == EngineState::Faulted);
        CHECK(!r.engine.submit(block()));
        for (const auto& sink : r.sinks) CHECK(!sink->open && sink->queued.empty() && sink->closes >= 1);
    });
    test("transport failure faults group", [] {
        Rig r; r.run(); r.sinks[0]->enqueue_result = {Error::TransportFailed,"disconnected"};
        CHECK(r.engine.submit(block()).code == Error::TransportFailed);
        CHECK(r.engine.state() == EngineState::Faulted);
        for (const auto& sink : r.sinks) CHECK(!sink->open && sink->closes >= 1);
    });
    test("stop is idempotent and restart uses configured epoch beginning frame zero", [] {
        Rig r; r.run(); CHECK(r.engine.submit(block()));
        r.engine.stop(); r.engine.stop();
        CHECK(r.engine.state() == EngineState::Idle && r.engine.next_frame() == 0);
        for (const auto& sink : r.sinks) CHECK(!sink->open && sink->queued.empty());
        CHECK(r.engine.prepare({48000,3},r.bindings)); CHECK(r.engine.start(8,500));
        auto b = block(); CHECK(!r.engine.submit(b)); b.epoch = 8; CHECK(r.engine.submit(b));
    });
    test("invalid lifecycle calls do not enqueue", [] {
        Rig r; CHECK(!r.engine.start(7,100)); CHECK(!r.engine.submit(block()));
        CHECK(r.engine.prepare({48000,3},r.bindings)); CHECK(!r.engine.prepare({48000,3},r.bindings));
        CHECK(!r.engine.submit(block())); CHECK(r.engine.start(7,100)); CHECK(!r.engine.start(7,100));
        for (const auto& sink : r.sinks) CHECK(sink->enqueues == 0);
    });
    test("destructor releases queued outputs", [] {
        auto sink = std::make_shared<FakeOutput>();
        { PlaybackEngine e(std::make_shared<FakeClock>());
          CHECK(e.prepare({48000,1},{{{"one",{0}},sink}})); CHECK(e.start(1,100));
          CHECK(e.submit({{48000,1},1,0,{0.5f}})); }
        CHECK(!sink->open && sink->queued.empty() && sink->closes >= 1);
    });
    test("same output object cannot own two independent routes", [] {
        Rig r; r.bindings[1].output = r.bindings[0].output;
        CHECK(r.engine.prepare({48000,3},r.bindings).code == Error::InvalidArgument); untouched(r);
    });
    test("null clock rejected before output preparation", [] {
        Rig r; PlaybackEngine engine(nullptr);
        CHECK(engine.prepare({48000,3},r.bindings).code == Error::InvalidArgument); untouched(r);
    });
    test("prepare exception closes partially opened backend", [] {
        Rig r; r.sinks[1]->throw_prepare = true;
        CHECK(r.engine.prepare({48000,3},r.bindings).code == Error::PrepareFailed);
        CHECK(!r.sinks[0]->open && !r.sinks[1]->open && r.sinks[1]->closes >= 1);
        CHECK(r.sinks[2]->prepares == 0);
    });
    test("enqueue exception after acceptance faults whole group", [] {
        Rig r; r.run(); r.sinks[1]->throw_enqueue = true;
        CHECK(r.engine.submit(block()).code == Error::TransportFailed);
        CHECK(r.engine.state() == EngineState::Faulted);
        for (const auto& sink : r.sinks) CHECK(!sink->open && sink->queued.empty());
    });
    test("block end presentation overflow rejects without enqueue or timeline advance", [] {
        Rig r; CHECK(r.engine.prepare({48000,3},r.bindings));
        r.clock->value = std::numeric_limits<std::int64_t>::max() - 100;
        CHECK(r.engine.start(7,1));
        CHECK(r.engine.submit(block()).code == Error::InvalidArgument);
        CHECK(r.engine.state() == EngineState::Running && r.engine.next_frame() == 0);
        for (const auto& sink : r.sinks) CHECK(sink->enqueues == 0);
    });
    int failed = 0;
    for (const auto& entry : tests) {
        try { entry.second(); std::cout << "PASS " << entry.first << '\n'; }
        catch (const std::exception& error) { ++failed; std::cerr << "FAIL " << entry.first << ": " << error.what() << '\n'; }
    }
    std::cout << (tests.size() - failed) << '/' << tests.size() << " offline contract groups passed\n";
    return failed ? 1 : 0;
}
