#ifndef FLOW_PROCESSING_H
#define FLOW_PROCESSING_H
#include <stdint.h>
#if defined(_WIN32)
# if defined(FLOW_PROCESSING_BUILD)
#  define FLOW_DSP_API __declspec(dllexport)
# else
#  define FLOW_DSP_API __declspec(dllimport)
# endif
# define FLOW_DSP_CALL __cdecl
#else
# define FLOW_DSP_API __attribute__((visibility("default")))
# define FLOW_DSP_CALL
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct flow_processing flow_processing;
typedef struct flow_processing_device {
    float x, y; /* normalized room; screen at y=0, listener faces screen */
    float gain; /* relative linear gain [0,1] */
} flow_processing_device;
enum flow_processing_status {
    FLOW_DSP_OK=0, FLOW_DSP_INVALID_ARGUMENT=1, FLOW_DSP_DISCONTINUITY=2,
    FLOW_DSP_QUEUE_FULL=3
};
/* Independent ABI 1. Serialized calls only; no concurrent control/process.
 * Fixed 44100Hz stereo input, N=1..8 device buses; mode 0=sync, 1=cinema.
 * Coordinates/gains (including initial_master_gain) finite [0,1], max_frames
 * 1..65536. Create copies inputs. Production should start master at zero and
 * schedule a >=882-frame ramp; this avoids any initial full-volume sample.
 * Output order for each frame: device0 L,R, device1 L,R, ... .
 * Stereo spatial allocation is not native 5.1 or source separation. */
FLOW_DSP_API uint32_t FLOW_DSP_CALL flow_processing_version(void);
FLOW_DSP_API flow_processing* FLOW_DSP_CALL flow_processing_create(
    uint32_t mode, const flow_processing_device* devices, uint32_t device_count,
    float listener_x, float listener_y, uint32_t max_frames, float initial_master_gain);
/* Schedule at an unprocessed media frame; -1=master, otherwise device index.
 * ramp_frames 882..441000, target [0,1]. At effective_frame ramp's first
 * sample advances 1/ramp_frames; last sample hits target exactly. Queue64;
 * same output/effective frame replaces a queued command. No block allocation. */
FLOW_DSP_API int32_t FLOW_DSP_CALL flow_processing_set_gain(flow_processing*,
    int32_t output_index, float target, uint64_t effective_frame, uint32_t ramp_frames);
/* First frame starts at zero, then continuous. Samples finite [-1,1].
 * sample_count is input float count (must be even, nonzero). Capacity is
 * output float count, not bytes. Input/output must not overlap. Every input
 * and capacity is prevalidated; rejected calls do not advance media or gains.
 * On success writes frames*2*N samples; output remainder stays untouched. */
FLOW_DSP_API int32_t FLOW_DSP_CALL flow_processing_process(flow_processing*,
    uint64_t first_frame, const float* input, uint64_t sample_count,
    float* output, uint64_t output_capacity);
/* Copies N*4 coefficients in device order: LL,LR,RL,RR before gains.
 * Rows have L1 <=1. Useful for inspectable routing and independent validation. */
FLOW_DSP_API int32_t FLOW_DSP_CALL flow_processing_matrix(const flow_processing*,
    float* coefficients, uint32_t capacity);
FLOW_DSP_API const char* FLOW_DSP_CALL flow_processing_last_error(const flow_processing*);
FLOW_DSP_API void FLOW_DSP_CALL flow_processing_destroy(flow_processing*);
#ifdef __cplusplus
}
#endif
#endif
