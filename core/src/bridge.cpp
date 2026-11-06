#include "flow/bridge.h"
#include "flow/core.hpp"

#include <cstdio>
#include <limits>
#include <memory>
#include <utility>
#include <vector>

namespace {
static_assert(static_cast<int>(flow::Error::None) == FLOW_V1_OK);
static_assert(static_cast<int>(flow::Error::InvalidArgument) == FLOW_V1_INVALID_ARGUMENT);
static_assert(static_cast<int>(flow::Error::InvalidState) == FLOW_V1_INVALID_STATE);
static_assert(static_cast<int>(flow::Error::Unsupported) == FLOW_V1_UNSUPPORTED);
static_assert(static_cast<int>(flow::Error::PrepareFailed) == FLOW_V1_PREPARE_FAILED);
static_assert(static_cast<int>(flow::Error::WouldBlock) == FLOW_V1_WOULD_BLOCK);
static_assert(static_cast<int>(flow::Error::TransportFailed) == FLOW_V1_TRANSPORT_FAILED);
static_assert(static_cast<int>(flow::Error::TimestampDiscontinuity) == FLOW_V1_TIMESTAMP_DISCONTINUITY);
class HostClock final : public flow::Clock {
public:
    std::int64_t value = 0;
    std::int64_t now_ns() const noexcept override { return value; }
};
struct Callbacks {
    flow_v1_prepare_fn prepare;
    flow_v1_enqueue_fn enqueue;
    flow_v1_close_fn close;
    void* user;
};
flow::Status callback_status(std::int32_t code) {
    if (code < FLOW_V1_OK || code > FLOW_V1_TIMESTAMP_DISCONTINUITY)
        return {flow::Error::TransportFailed, "callback returned unsupported status"};
    return {static_cast<flow::Error>(code), code ? "output callback failed" : ""};
}
class CallbackOutput final : public flow::Output {
public:
    CallbackOutput(Callbacks callbacks, std::uint32_t id, bool scheduled)
        : cb_(callbacks), id_(id), scheduled_(scheduled) {}
    flow::OutputCapabilities capabilities() const noexcept override { return {scheduled_}; }
    flow::Status prepare(const flow::AudioFormat& f) override {
        return callback_status(cb_.prepare(cb_.user, id_, f.sample_rate, f.channels));
    }
    flow::Status enqueue(const flow::ScheduledBlock& b) override {
        return callback_status(cb_.enqueue(cb_.user, id_, b.audio.format.sample_rate,
            b.audio.format.channels, b.audio.epoch, b.audio.first_frame,
            b.presentation_time_ns, b.audio.samples.data(), b.audio.samples.size()));
    }
    void close() noexcept override { cb_.close(cb_.user, id_); }
private:
    Callbacks cb_;
    std::uint32_t id_;
    bool scheduled_;
};
} // namespace

struct flow_v1_engine {
    flow::AudioFormat format;
    Callbacks callbacks;
    std::shared_ptr<HostClock> clock = std::make_shared<HostClock>();
    flow::PlaybackEngine engine{clock};
    std::vector<flow::OutputBinding> bindings;
    char error[512] = {};
    flow_v1_engine(flow::AudioFormat f, Callbacks cb) : format(f), callbacks(cb) {}
};

namespace {
int record(flow_v1_engine* e, int code, const char* message) noexcept {
    if (e) std::snprintf(e->error, sizeof(e->error), "%s", message ? message : "");
    return code;
}
int record(flow_v1_engine* e, const flow::Status& status) noexcept {
    return record(e, static_cast<int>(status.code), status.message.c_str());
}
template<class F> int guarded(flow_v1_engine* e, F&& operation) noexcept {
    if (!e) return FLOW_V1_INVALID_ARGUMENT;
    try { return operation(); }
    catch (...) {
        e->engine.stop();
        return record(e, FLOW_V1_INTERNAL_ERROR, "native exception contained; engine stopped");
    }
}
} // namespace

extern "C" {
std::uint32_t FLOW_CALL flow_v1_abi_version(void) { return 1; }
flow_v1_engine* FLOW_CALL flow_v1_create(std::uint32_t rate, std::uint32_t channels,
    flow_v1_prepare_fn prepare_fn, flow_v1_enqueue_fn enqueue_fn,
    flow_v1_close_fn close_fn, void* user) {
    if (!rate || !channels || !prepare_fn || !enqueue_fn || !close_fn) return nullptr;
    try { return new flow_v1_engine({rate, channels}, {prepare_fn, enqueue_fn, close_fn, user}); }
    catch (...) { return nullptr; }
}
std::int32_t FLOW_CALL flow_v1_add_output(flow_v1_engine* e, std::uint32_t id,
    const std::uint32_t* channels, std::uint32_t count, std::uint32_t scheduled) {
    return guarded(e, [&] {
        if (e->engine.state() != flow::EngineState::Idle)
            return record(e, FLOW_V1_INVALID_STATE, "add_output requires Idle");
        if (!channels || !count || scheduled > 1)
            return record(e, FLOW_V1_INVALID_ARGUMENT, "invalid channel map or capability");
        const auto name = std::to_string(id);
        for (const auto& binding : e->bindings)
            if (binding.route.output_id == name)
                return record(e, FLOW_V1_INVALID_ARGUMENT, "duplicate output id");
        for (std::uint32_t i = 0; i < count; ++i)
            if (channels[i] >= e->format.channels)
                return record(e, FLOW_V1_INVALID_ARGUMENT, "channel out of input range");
        flow::OutputBinding binding;
        binding.route = {name, {channels, channels + count}};
        binding.output = std::make_shared<CallbackOutput>(e->callbacks, id, scheduled != 0);
        e->bindings.push_back(std::move(binding));
        return record(e, FLOW_V1_OK, "");
    });
}
std::int32_t FLOW_CALL flow_v1_prepare(flow_v1_engine* e) {
    return guarded(e, [&] { return record(e, e->engine.prepare(e->format, e->bindings)); });
}
std::int32_t FLOW_CALL flow_v1_start(flow_v1_engine* e, std::uint64_t epoch,
    std::int64_t now, std::int64_t lead, std::int64_t* origin) {
    return guarded(e, [&] {
        if (!origin) return record(e, FLOW_V1_INVALID_ARGUMENT, "origin output required");
        e->clock->value = now;
        auto status = e->engine.start(epoch, lead);
        if (status) *origin = e->engine.origin_ns();
        return record(e, status);
    });
}
std::int32_t FLOW_CALL flow_v1_submit(flow_v1_engine* e, std::uint64_t epoch,
    std::uint64_t first, const float* samples, std::uint64_t count) {
    return guarded(e, [&] {
        if (!samples || !count || count > std::vector<float>().max_size())
            return record(e, FLOW_V1_INVALID_ARGUMENT, "invalid sample buffer");
        flow::AudioBlock block{e->format, epoch, first, {}};
        block.samples.assign(samples, samples + static_cast<std::size_t>(count));
        return record(e, e->engine.submit(block));
    });
}
std::int32_t FLOW_CALL flow_v1_stop(flow_v1_engine* e) {
    return guarded(e, [&] { e->engine.stop(); return record(e, FLOW_V1_OK, ""); });
}
const char* FLOW_CALL flow_v1_last_error(const flow_v1_engine* e) {
    return e ? e->error : "null engine";
}
void FLOW_CALL flow_v1_destroy(flow_v1_engine* e) { delete e; }
} // extern C
