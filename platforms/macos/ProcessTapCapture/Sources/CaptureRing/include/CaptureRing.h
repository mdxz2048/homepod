#ifndef FLOW_CAPTURE_RING_H
#define FLOW_CAPTURE_RING_H
#include <CoreAudio/CoreAudio.h>
#include <stdint.h>
#include <stddef.h>
#include "CaptureProcessIdentity.h"
typedef struct CaptureRing CaptureRing;
typedef struct {
    uint32_t frames;
    uint32_t buffer_count;
    uint32_t total_bytes;
    uint32_t timestamp_flags;
    uint64_t host_time;
    double sample_time;
    uint64_t callback_sequence;
    uint64_t dropped_before;
    uint32_t now_timestamp_flags;
    uint64_t now_host_time;
    double now_sample_time;
} CaptureRingMetadata;
CaptureRing *capture_ring_create(uint32_t slots, uint32_t max_frames,
                                uint32_t buffer_count, uint32_t channels_per_buffer,
                                uint32_t bytes_per_frame);
void capture_ring_destroy(CaptureRing *ring);
/* SPSC: sole HAL producer. No allocation, locks, file I/O or logging. */
void capture_ring_push(CaptureRing *ring, const AudioBufferList *input,
                       const AudioTimeStamp *timestamp, const AudioTimeStamp *now);
/* Sole non-RT consumer. Copies into caller-owned memory before releasing slot. */
int capture_ring_pop(CaptureRing *ring, void *bytes, size_t capacity,
                     CaptureRingMetadata *metadata, uint32_t *lengths,
                     uint32_t *channels);
uint64_t capture_ring_dropped(const CaptureRing *ring);
uint32_t capture_ring_fault(const CaptureRing *ring);
void capture_ring_set_fault(CaptureRing *ring, uint32_t fault);
/* HAL-owned preallocated output memory only. Never copies captured PCM out. */
int capture_zero_output(AudioBufferList *output);
#endif
