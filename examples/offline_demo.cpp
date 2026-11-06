#include "flow/core.hpp"

#include <iostream>
#include <memory>
#include <utility>
#include <vector>

// This executable sends nothing, opens no device, and produces no sound.
class FixedClock final : public flow::Clock {
public:
    std::int64_t now_ns() const noexcept override { return 1000000000; }
};
class RecordingOutput final : public flow::Output {
public:
    flow::OutputCapabilities capabilities() const noexcept override { return {true}; }
    flow::Status prepare(const flow::AudioFormat&) override {
        blocks.clear(); open = true; return {};
    }
    flow::Status enqueue(const flow::ScheduledBlock& block) override {
        if (!open) return {flow::Error::TransportFailed, "closed"};
        if (blocks.size() >= capacity) return {flow::Error::WouldBlock, "bounded queue full"};
        blocks.push_back(block);
        return {};
    }
    void close() noexcept override { open = false; blocks.clear(); }
    static constexpr std::size_t capacity = 2;
    bool open = false;
    std::vector<flow::ScheduledBlock> blocks;
};

int main() {
    flow::PlaybackEngine engine(std::make_shared<FixedClock>());
    auto front = std::make_shared<RecordingOutput>();
    auto left = std::make_shared<RecordingOutput>();
    auto right = std::make_shared<RecordingOutput>();
    auto require = [](flow::Status status) {
        if (!status) std::cerr << status.message << '\n';
        return static_cast<bool>(status);
    };
    if (!require(engine.prepare({48000, 3}, {
            {{"front", {0, 0}}, front},
            {{"left", {1, 1}}, left},
            {{"right", {2, 2}}, right}}))
        || !require(engine.start(7, 500000000))) return 1;
    flow::AudioBlock block;
    block.format = {48000, 3}; block.epoch = 7;
    block.samples = {0.1F, 0.2F, 0.3F, 0.4F, 0.5F, 0.6F};
    if (!require(engine.submit(block))) return 1;
    std::cout << "Offline simulation only; timestamps are not acoustic evidence.\n";
    const std::vector<std::pair<const char*, std::shared_ptr<RecordingOutput>>> outputs = {
        {"front", front}, {"left", left}, {"right", right}};
    for (const auto& output : outputs) {
        const auto& recorded = output.second->blocks.front();
        std::cout << output.first << " epoch=" << recorded.audio.epoch
                  << " frame=" << recorded.audio.first_frame
                  << " presentation_ns=" << recorded.presentation_time_ns
                  << " samples=";
        for (auto sample : recorded.audio.samples) std::cout << sample << ' ';
        std::cout << '\n';
    }
    block.first_frame = 2;
    if (!require(engine.submit(block))) return 1;
    block.first_frame = 4;
    const auto full = engine.submit(block);
    if (full.code != flow::Error::WouldBlock || engine.state() != flow::EngineState::Faulted)
        return 2;
    std::cout << "Bounded queue full: WouldBlock; entire group closed and Faulted.\n";
    engine.stop();
    return engine.state() == flow::EngineState::Idle ? 0 : 3;
}
