#include "flow/core.hpp"

#include <chrono>
#include <cmath>
#include <exception>
#include <limits>
#include <unordered_set>
#include <utility>

namespace flow {
namespace {
Status fail(Error code, const char* message) { return {code, message}; }
constexpr std::uint64_t billion = 1000000000ULL;

bool frame_time(std::int64_t origin, std::uint64_t frame,
                std::uint32_t rate, std::int64_t& result) {
    const auto seconds = frame / rate;
    const auto fraction = ((frame % rate) * billion) / rate;
    const auto available = static_cast<std::uint64_t>(
        std::numeric_limits<std::int64_t>::max() - origin);
    if (seconds > available / billion) return false;
    const auto whole = seconds * billion;
    if (fraction > available - whole) return false;
    result = origin + static_cast<std::int64_t>(whole + fraction);
    return true;
}
} // namespace

struct PlaybackEngine::Impl {
    std::shared_ptr<Clock> clock;
    AudioFormat format;
    std::vector<OutputBinding> outputs;
    EngineState state = EngineState::Idle;
    std::int64_t origin = 0;
    std::uint64_t epoch = 0;
    std::uint64_t next = 0;

    void close_outputs() noexcept {
        for (auto& binding : outputs) binding.output->close();
        outputs.clear();
    }
};

std::int64_t SteadyClock::now_ns() const noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

PlaybackEngine::PlaybackEngine(std::shared_ptr<Clock> clock)
    : impl_(std::make_unique<Impl>()) { impl_->clock = std::move(clock); }
PlaybackEngine::~PlaybackEngine() { stop(); }

Status PlaybackEngine::prepare(AudioFormat format, std::vector<OutputBinding> outputs) {
    if (impl_->state != EngineState::Idle)
        return fail(Error::InvalidState, "prepare requires Idle");
    if (!impl_->clock || format.sample_rate == 0 || format.channels == 0 || outputs.empty())
        return fail(Error::InvalidArgument, "clock, input format and outputs are required");
    std::unordered_set<std::string> ids;
    std::unordered_set<const Output*> instances;
    for (const auto& binding : outputs) {
        if (!binding.output || binding.route.output_id.empty() || binding.route.input_channels.empty()
            || binding.route.input_channels.size() > std::numeric_limits<std::uint32_t>::max())
            return fail(Error::InvalidArgument, "output and nonempty route are required");
        if (!ids.insert(binding.route.output_id).second || !instances.insert(binding.output.get()).second)
            return fail(Error::InvalidArgument, "output ids and output instances must be unique");
        for (auto channel : binding.route.input_channels)
            if (channel >= format.channels)
                return fail(Error::InvalidArgument, "route channel exceeds input format");
        if (!binding.output->capabilities().scheduled_start)
            return fail(Error::Unsupported, "output cannot accept common scheduled time");
    }
    std::size_t attempted = 0;
    Status status;
    try {
        for (auto& binding : outputs) {
            ++attempted; // close even an output that fails partway through prepare
            status = binding.output->prepare({format.sample_rate,
                static_cast<std::uint32_t>(binding.route.input_channels.size())});
            if (!status) break;
        }
    } catch (...) {
        status = fail(Error::PrepareFailed, "output threw while preparing");
    }
    if (!status) {
        for (std::size_t i = 0; i < attempted; ++i) outputs[i].output->close();
        return status;
    }
    impl_->format = format;
    impl_->outputs = std::move(outputs);
    impl_->state = EngineState::Prepared;
    return {};
}

Status PlaybackEngine::start(std::uint64_t epoch, std::int64_t lead_ns) {
    if (impl_->state != EngineState::Prepared)
        return fail(Error::InvalidState, "start requires Prepared");
    const auto now = impl_->clock->now_ns();
    if (now < 0 || lead_ns <= 0 || now > std::numeric_limits<std::int64_t>::max() - lead_ns)
        return fail(Error::InvalidArgument, "invalid clock or lead time overflow");
    impl_->origin = now + lead_ns;
    impl_->epoch = epoch;
    impl_->next = 0;
    impl_->state = EngineState::Running;
    return {};
}

Status PlaybackEngine::submit(const AudioBlock& block) {
    if (impl_->state != EngineState::Running)
        return fail(Error::InvalidState, "submit requires Running");
    if (block.format.sample_rate != impl_->format.sample_rate || block.format.channels != impl_->format.channels
        || block.samples.empty() || block.samples.size() % block.format.channels != 0)
        return fail(Error::InvalidArgument, "invalid audio format or sample count");
    if (block.epoch != impl_->epoch || block.first_frame != impl_->next)
        return fail(Error::TimestampDiscontinuity, "epoch or contiguous frame sequence differs");
    for (auto sample : block.samples)
        if (!std::isfinite(sample) || sample < -1.0F || sample > 1.0F)
            return fail(Error::InvalidArgument, "samples must be finite and normalized");
    const auto frames = block.samples.size() / block.format.channels;
    if (frames > std::numeric_limits<std::uint64_t>::max() - impl_->next)
        return fail(Error::InvalidArgument, "frame sequence overflow");
    std::int64_t presentation = 0;
    std::int64_t end_time = 0;
    if (!frame_time(impl_->origin, block.first_frame, block.format.sample_rate, presentation)
        || !frame_time(impl_->origin, impl_->next + frames, block.format.sample_rate, end_time))
        return fail(Error::InvalidArgument, "presentation time overflow");

    // Construct and validate the entire fanout before invoking any backend.
    std::vector<ScheduledBlock> routed;
    routed.reserve(impl_->outputs.size());
    for (const auto& binding : impl_->outputs) {
        const auto channels = binding.route.input_channels.size();
        ScheduledBlock output;
        output.presentation_time_ns = presentation;
        output.audio.format = {block.format.sample_rate, static_cast<std::uint32_t>(channels)};
        output.audio.epoch = block.epoch;
        output.audio.first_frame = block.first_frame;
        if (frames > output.audio.samples.max_size() / channels)
            return fail(Error::InvalidArgument, "routed block too large");
        output.audio.samples.reserve(frames * channels);
        for (std::size_t frame = 0; frame < frames; ++frame)
            for (auto channel : binding.route.input_channels)
                output.audio.samples.push_back(block.samples[frame * block.format.channels + channel]);
        routed.push_back(std::move(output));
    }
    Status status;
    try {
        for (std::size_t i = 0; i < routed.size(); ++i) {
            status = impl_->outputs[i].output->enqueue(routed[i]);
            if (!status) break;
        }
    } catch (...) {
        status = fail(Error::TransportFailed, "output threw while enqueueing");
    }
    if (!status) {
        impl_->close_outputs();
        impl_->state = EngineState::Faulted;
        return status;
    }
    impl_->next += frames;
    return {};
}

void PlaybackEngine::stop() noexcept {
    impl_->close_outputs();
    impl_->state = EngineState::Idle;
    impl_->origin = 0;
    impl_->epoch = 0;
    impl_->next = 0;
}
EngineState PlaybackEngine::state() const noexcept { return impl_->state; }
std::int64_t PlaybackEngine::origin_ns() const noexcept { return impl_->origin; }
std::uint64_t PlaybackEngine::next_frame() const noexcept { return impl_->next; }
} // namespace flow
