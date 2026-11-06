#include "CaptureRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#define MAX_BUFFERS 32
int capture_zero_output(AudioBufferList *output) {
    if (!output) return 0;
    int result = 0;
    for (uint32_t i = 0; i < output->mNumberBuffers; ++i) {
        AudioBuffer *buffer = &output->mBuffers[i];
        if (!buffer->mDataByteSize) continue;
        if (!buffer->mData) { result = -1; continue; }
        memset(buffer->mData, 0, buffer->mDataByteSize);
    }
    return result;
}
typedef struct {
    CaptureRingMetadata metadata;
    uint32_t lengths[MAX_BUFFERS];
    uint32_t channels[MAX_BUFFERS];
    unsigned char *bytes;
} Slot;
struct CaptureRing {
    uint32_t count, buffers, channels, bytes_per_frame, maximum_bytes;
    Slot *slots;
    unsigned char *storage;
    _Atomic uint32_t write_index;
    _Atomic uint32_t read_index;
    _Atomic uint64_t dropped;
    _Atomic uint32_t fault;
    uint64_t callback_sequence; /* Sole producer; never accessed concurrently. */
};
CaptureRing *capture_ring_create(uint32_t count, uint32_t max_frames,
                                uint32_t buffers, uint32_t channels,
                                uint32_t bytes_per_frame) {
    if (count < 2 || count > 256 || (count & (count - 1)) || !max_frames || max_frames > 16384 ||
        !buffers || buffers > MAX_BUFFERS || !channels || channels > 32 ||
        !bytes_per_frame || bytes_per_frame > 128) return NULL;
    uint64_t required = (uint64_t)count * max_frames * bytes_per_frame * buffers + (uint64_t)count * sizeof(Slot) + sizeof(CaptureRing);
    if (required > 64 * 1024 * 1024) return NULL;
    CaptureRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    ring->count = count; ring->buffers = buffers; ring->channels = channels;
    ring->bytes_per_frame = bytes_per_frame;
    ring->maximum_bytes = max_frames * bytes_per_frame * buffers;
    ring->slots = calloc(count, sizeof(Slot));
    ring->storage = calloc(count, ring->maximum_bytes);
    atomic_init(&ring->write_index, 0); atomic_init(&ring->read_index, 0);
    atomic_init(&ring->dropped, 0); atomic_init(&ring->fault, 0);
    if (!ring->slots || !ring->storage || !atomic_is_lock_free(&ring->write_index) ||
        !atomic_is_lock_free(&ring->read_index) || !atomic_is_lock_free(&ring->dropped) ||
        !atomic_is_lock_free(&ring->fault)) {
        capture_ring_destroy(ring); return NULL;
    }
    for (uint32_t i = 0; i < count; ++i)
        ring->slots[i].bytes = ring->storage + (size_t)i * ring->maximum_bytes;
    size_t total = (size_t)count * ring->maximum_bytes;
    for (size_t i = 0; i < total; i += 4096) ((volatile unsigned char *)ring->storage)[i] = 0;
    ((volatile unsigned char *)ring->storage)[total - 1] = 0;
    return ring;
}
void capture_ring_destroy(CaptureRing *ring) {
    if (!ring) return;
    free(ring->storage); free(ring->slots); free(ring);
}
void capture_ring_set_fault(CaptureRing *ring, uint32_t fault) {
    if (!ring) return;
    uint32_t expected = 0;
    atomic_compare_exchange_strong_explicit(&ring->fault, &expected, fault,
                                           memory_order_relaxed, memory_order_relaxed);
}
void capture_ring_push(CaptureRing *ring, const AudioBufferList *input,
                       const AudioTimeStamp *timestamp, const AudioTimeStamp *now) {
    if (!ring || atomic_load_explicit(&ring->fault, memory_order_relaxed)) return;
    uint64_t sequence = ring->callback_sequence++;
    if (!input || !timestamp || !now || input->mNumberBuffers != ring->buffers) {
        capture_ring_set_fault(ring, 1); return;
    }
    uint32_t bytes_per_buffer = input->mBuffers[0].mDataByteSize;
    if (!bytes_per_buffer) return;
    if (bytes_per_buffer % ring->bytes_per_frame) { capture_ring_set_fault(ring, 1); return; }
    for (uint32_t i = 0; i < ring->buffers; ++i) {
        const AudioBuffer *b = &input->mBuffers[i];
        if (!b->mData || b->mNumberChannels != ring->channels ||
            b->mDataByteSize != bytes_per_buffer ||
            b->mDataByteSize > ring->maximum_bytes / ring->buffers) {
            capture_ring_set_fault(ring, 2); return;
        }
    }
    uint32_t write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    uint32_t read = atomic_load_explicit(&ring->read_index, memory_order_acquire);
    if ((uint32_t)(write - read) >= ring->count) {
        atomic_fetch_add_explicit(&ring->dropped, 1, memory_order_relaxed); return;
    }
    Slot *slot = &ring->slots[write % ring->count];
    slot->metadata = (CaptureRingMetadata){
        .frames = bytes_per_buffer / ring->bytes_per_frame,
        .buffer_count = ring->buffers, .total_bytes = bytes_per_buffer * ring->buffers,
        .timestamp_flags = timestamp->mFlags, .host_time = timestamp->mHostTime,
        .sample_time = timestamp->mSampleTime, .callback_sequence = sequence,
        .dropped_before = atomic_load_explicit(&ring->dropped, memory_order_relaxed),
        .now_timestamp_flags = now->mFlags, .now_host_time = now->mHostTime,
        .now_sample_time = now->mSampleTime
    };
    uint32_t offset = 0;
    for (uint32_t i = 0; i < ring->buffers; ++i) {
        const AudioBuffer *b = &input->mBuffers[i];
        slot->lengths[i] = b->mDataByteSize; slot->channels[i] = b->mNumberChannels;
        memcpy(slot->bytes + offset, b->mData, b->mDataByteSize);
        offset += b->mDataByteSize;
    }
    atomic_store_explicit(&ring->write_index, write + 1, memory_order_release);
}
int capture_ring_pop(CaptureRing *ring, void *bytes, size_t capacity,
                     CaptureRingMetadata *metadata, uint32_t *lengths, uint32_t *channels) {
    if (!ring || !bytes || !metadata || !lengths || !channels) return -1;
    uint32_t read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    uint32_t write = atomic_load_explicit(&ring->write_index, memory_order_acquire);
    if (read == write) return 0;
    Slot *slot = &ring->slots[read % ring->count];
    if (slot->metadata.total_bytes > capacity) return -1;
    *metadata = slot->metadata;
    memcpy(bytes, slot->bytes, metadata->total_bytes);
    memcpy(lengths, slot->lengths, metadata->buffer_count * sizeof(uint32_t));
    memcpy(channels, slot->channels, metadata->buffer_count * sizeof(uint32_t));
    atomic_store_explicit(&ring->read_index, read + 1, memory_order_release);
    return 1;
}
uint64_t capture_ring_dropped(const CaptureRing *ring) {
    return ring ? atomic_load_explicit(&ring->dropped, memory_order_relaxed) : 0;
}
uint32_t capture_ring_fault(const CaptureRing *ring) {
    return ring ? atomic_load_explicit(&ring->fault, memory_order_relaxed) : 0;
}
