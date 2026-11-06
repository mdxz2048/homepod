/* Native C consumer of ABI v1; no network or audio-device access. */
#include "flow/bridge.h"
#include <stdio.h>
#include <math.h>
#include <stdint.h>
#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c); return 1; } } while (0)
typedef struct {
    int prepared, enqueued, closed, fail_prepare, fail_enqueue;
    int64_t presentation[3];
    float first[3];
} record;
static int32_t FLOW_CALL prepare(void* user, uint32_t id, uint32_t rate, uint32_t channels) {
    record* r = user; ++r->prepared;
    if (rate != 44100 || channels != 2) return FLOW_V1_INVALID_ARGUMENT;
    return r->fail_prepare && id == 1 ? FLOW_V1_PREPARE_FAILED : FLOW_V1_OK;
}
static int32_t FLOW_CALL enqueue(void* user, uint32_t id, uint32_t rate, uint32_t channels,
    uint64_t epoch, uint64_t frame, int64_t presentation, const float* samples, uint64_t count) {
    record* r = user; ++r->enqueued;
    if (rate != 44100 || channels != 2 || epoch != 7 || frame != 0 || count != 4)
        return FLOW_V1_INVALID_ARGUMENT;
    r->presentation[id] = presentation; r->first[id] = samples[0];
    return r->fail_enqueue && id == 1 ? FLOW_V1_WOULD_BLOCK : FLOW_V1_OK;
}
static void FLOW_CALL close_output(void* user, uint32_t id) {
    record* r = user; (void)id; ++r->closed;
}
static flow_v1_engine* make_engine(record* r) {
    flow_v1_engine* e = flow_v1_create(44100,3,prepare,enqueue,close_output,r);
    uint32_t id;
    for (id = 0; e && id < 3; ++id) {
        uint32_t map[2] = {id,id};
        if (flow_v1_add_output(e,id,map,2,1) != FLOW_V1_OK) { flow_v1_destroy(e); return NULL; }
        map[0] = 999; /* ABI must copy route memory during add_output. */
    }
    return e;
}
int main(void) {
    const float samples[6] = {0.1f,0.2f,0.3f,-0.1f,-0.2f,-0.3f};
    int64_t origin = 0;
    record r = {0}; flow_v1_engine* e;
    CHECK(flow_v1_abi_version() == 1);
    CHECK(flow_v1_create(44100,3,NULL,enqueue,close_output,&r) == NULL);
    CHECK(flow_v1_prepare(NULL) == FLOW_V1_INVALID_ARGUMENT);
    CHECK(flow_v1_submit(NULL,7,0,samples,6) == FLOW_V1_INVALID_ARGUMENT);
    CHECK(flow_v1_last_error(NULL) != NULL);
    flow_v1_destroy(NULL);
    e = make_engine(&r); CHECK(e != NULL);
    CHECK(flow_v1_prepare(e) == FLOW_V1_OK && r.prepared == 3);
    CHECK(flow_v1_start(e,7,1000000000,3000000000,&origin) == FLOW_V1_OK);
    CHECK(origin == 4000000000LL);
    CHECK(flow_v1_submit(e,8,0,samples,6) == FLOW_V1_TIMESTAMP_DISCONTINUITY);
    CHECK(r.enqueued == 0);
    CHECK(flow_v1_submit(e,7,0,samples,6) == FLOW_V1_OK && r.enqueued == 3);
    CHECK(fabsf(r.first[0] - 0.1f) < 0.000001f && fabsf(r.first[1] - 0.2f) < 0.000001f);
    CHECK(fabsf(r.first[2] - 0.3f) < 0.000001f);
    CHECK(r.presentation[0] == origin && r.presentation[1] == origin && r.presentation[2] == origin);
    CHECK(flow_v1_stop(e) == FLOW_V1_OK && r.closed == 3);
    CHECK(flow_v1_stop(e) == FLOW_V1_OK && r.closed == 3);
    flow_v1_destroy(e);
    { record partial = {0}; partial.fail_prepare = 1; e = make_engine(&partial); CHECK(e != NULL);
      CHECK(flow_v1_prepare(e) == FLOW_V1_PREPARE_FAILED);
      CHECK(partial.prepared == 2 && partial.closed == 2); flow_v1_destroy(e); }
    { record pressure = {0}; pressure.fail_enqueue = 1; e = make_engine(&pressure); CHECK(e != NULL);
      CHECK(flow_v1_prepare(e) == FLOW_V1_OK);
      CHECK(flow_v1_start(e,7,1000000000,3000000000,&origin) == FLOW_V1_OK);
      CHECK(flow_v1_submit(e,7,0,samples,6) == FLOW_V1_WOULD_BLOCK);
      CHECK(pressure.enqueued == 2 && pressure.closed == 3);
      CHECK(flow_v1_submit(e,7,0,samples,6) == FLOW_V1_INVALID_STATE); flow_v1_destroy(e); }
    puts("PASS native C ABI version/null/ownership/routing/timeline/epoch/stop/partial-prepare/backpressure");
    return 0;
}
