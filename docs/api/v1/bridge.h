#ifndef FLOW_BRIDGE_H
#define FLOW_BRIDGE_H
#include <stdint.h>

#if defined(_WIN32)
# if defined(FLOW_BRIDGE_BUILD)
#  define FLOW_API __declspec(dllexport)
# else
#  define FLOW_API __declspec(dllimport)
# endif
# define FLOW_CALL __cdecl
#else
# define FLOW_API __attribute__((visibility("default")))
# define FLOW_CALL
#endif
#ifdef __cplusplus
extern "C" {
#endif

/* ABI v1, serialized calls, callbacks must not re-enter or throw across C. */
typedef struct flow_v1_engine flow_v1_engine;
enum flow_v1_status {
    FLOW_V1_OK = 0, FLOW_V1_INVALID_ARGUMENT = 1, FLOW_V1_INVALID_STATE = 2,
    FLOW_V1_UNSUPPORTED = 3, FLOW_V1_PREPARE_FAILED = 4,
    FLOW_V1_WOULD_BLOCK = 5, FLOW_V1_TRANSPORT_FAILED = 6,
    FLOW_V1_TIMESTAMP_DISCONTINUITY = 7, FLOW_V1_INTERNAL_ERROR = 8
};
typedef int32_t (FLOW_CALL *flow_v1_prepare_fn)(void* user, uint32_t output_id,
    uint32_t sample_rate, uint32_t channels);
typedef int32_t (FLOW_CALL *flow_v1_enqueue_fn)(void* user, uint32_t output_id,
    uint32_t sample_rate, uint32_t channels, uint64_t epoch,
    uint64_t first_frame, int64_t presentation_ns,
    const float* samples, uint64_t sample_count);
typedef void (FLOW_CALL *flow_v1_close_fn)(void* user, uint32_t output_id);

FLOW_API uint32_t FLOW_CALL flow_v1_abi_version(void);
/* Null on invalid callbacks/format/allocation failure; all three required. */
FLOW_API flow_v1_engine* FLOW_CALL flow_v1_create(uint32_t sample_rate,
    uint32_t channels, flow_v1_prepare_fn prepare_fn,
    flow_v1_enqueue_fn enqueue_fn, flow_v1_close_fn close_fn, void* user);
/* Idle only; output_id unique, nonempty channel map copied during call.
 * scheduled_start=1 is an explicit backend declaration, not measured sync. */
FLOW_API int32_t FLOW_CALL flow_v1_add_output(flow_v1_engine* engine,
    uint32_t output_id, const uint32_t* input_channels, uint32_t channels,
    uint32_t scheduled_start);
FLOW_API int32_t FLOW_CALL flow_v1_prepare(flow_v1_engine* engine);
/* Python/host supplies nonnegative monotonic now_ns. Origin returned in THAT
 * domain, not an assumed equivalence with std::chrono steady_clock epoch. */
FLOW_API int32_t FLOW_CALL flow_v1_start(flow_v1_engine* engine, uint64_t epoch,
    int64_t now_ns, int64_t lead_ns, int64_t* origin_ns);
/* Input is copied for call; callback samples valid only until callback returns. */
FLOW_API int32_t FLOW_CALL flow_v1_submit(flow_v1_engine* engine,
    uint64_t epoch, uint64_t first_frame, const float* samples, uint64_t sample_count);
FLOW_API int32_t FLOW_CALL flow_v1_stop(flow_v1_engine* engine);
/* Borrowed UTF-8 diagnostic; valid until next modifying call or destroy.
 * Null engine returns a static diagnostic. Status is authoritative. */
FLOW_API const char* FLOW_CALL flow_v1_last_error(const flow_v1_engine* engine);
/* Null safe; closes prepared/active outputs before callback/user may be freed. */
FLOW_API void FLOW_CALL flow_v1_destroy(flow_v1_engine* engine);

#ifdef __cplusplus
}
#endif
#endif
