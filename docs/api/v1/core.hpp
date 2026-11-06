#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace flow {

// M0 source-level C++17 contract. Not a stable binary ABI or real-time-safe API.
enum class Error {
    None, InvalidArgument, InvalidState, Unsupported, PrepareFailed,
    WouldBlock, TransportFailed, TimestampDiscontinuity
};
struct Status {
    Error code = Error::None;
    std::string message;
    explicit operator bool() const noexcept { return code == Error::None; }
};
struct AudioFormat {
    std::uint32_t sample_rate = 44100;
    std::uint32_t channels = 2;
};
// Float32 interleaved samples, finite values in [-1,1]; samples.size()/channels frames.
// Vectors own their memory. No references to caller memory may survive submit().
struct AudioBlock {
    AudioFormat format;
    std::uint64_t epoch = 0;
    std::uint64_t first_frame = 0;
    std::vector<float> samples;
};
struct ScheduledBlock {
    AudioBlock audio;
    std::int64_t presentation_time_ns = 0;
};
// Each output channel copies the corresponding zero-based input channel.
// Repeated indices duplicate a channel; M0 has no gain/mixing/resampling.
struct Route {
    std::string output_id;
    std::vector<std::uint32_t> input_channels;
};
struct OutputCapabilities {
    bool scheduled_start = false;
};
class Output {
public:
    virtual ~Output() = default;
    virtual OutputCapabilities capabilities() const noexcept = 0;
    virtual Status prepare(const AudioFormat& format) = 0;
    // On success implementation owns/copies anything required after return.
    // Time is on injected Clock's domain; success means accepted, NOT acoustic playback.
    virtual Status enqueue(const ScheduledBlock& block) = 0;
    // Idempotent; must release partially prepared sessions and queued work.
    virtual void close() noexcept = 0;
};
class Clock {
public:
    virtual ~Clock() = default;
    virtual std::int64_t now_ns() const noexcept = 0;
};
class SteadyClock final : public Clock {
public:
    std::int64_t now_ns() const noexcept override;
};
struct OutputBinding {
    Route route;
    std::shared_ptr<Output> output;
};
enum class EngineState { Idle, Prepared, Running, Faulted };
class PlaybackEngine {
public:
    explicit PlaybackEngine(std::shared_ptr<Clock> clock);
    ~PlaybackEngine();
    PlaybackEngine(const PlaybackEngine&) = delete;
    PlaybackEngine& operator=(const PlaybackEngine&) = delete;

    // Idle only. Validate all routes/capabilities before preparing any output.
    // Duplicate IDs or aliased Output instances are invalid. Failure returns Idle
    // and closes every attempted output, INCLUDING the output failing prepare.
    Status prepare(AudioFormat input_format, std::vector<OutputBinding> outputs);
    // Prepared only; clock >= 0 and lead_ns > 0; origin=now+lead, checked for overflow.
    // epoch may be any integer, first submitted frame must be 0.
    Status start(std::uint64_t epoch, std::int64_t lead_ns);
    // Running only; format, epoch and expected frame must match exactly.
    // Validation errors enqueue nothing and preserve state/expected frame.
    // Any enqueue failure (including WouldBlock) closes ALL outputs and faults
    // the group: earlier outputs may have accepted data, so retry is unsafe.
    Status submit(const AudioBlock& block);
    // Idempotent, closes all retained outputs, returns Idle, resets timeline.
    void stop() noexcept;
    EngineState state() const noexcept;
    std::int64_t origin_ns() const noexcept;
    std::uint64_t next_frame() const noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};
} // namespace flow
