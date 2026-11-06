#ifndef FLOW_CAPTURE_PROCESS_IDENTITY_H
#define FLOW_CAPTURE_PROCESS_IDENTITY_H
#include <stdint.h>
/* Non-RT only. Identifies a live process by PID and kernel start timestamp. */
int capture_process_identity(int32_t pid, uint64_t *seconds, uint64_t *microseconds);
#endif
