#include "CaptureProcessIdentity.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <string.h>
int capture_process_identity(int32_t pid, uint64_t *seconds, uint64_t *microseconds) {
    if (pid <= 0 || !seconds || !microseconds) return -1;
    struct proc_bsdinfo info;
    memset(&info, 0, sizeof(info));
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (size != sizeof(info) || info.pbi_pid != (uint32_t)pid) return -1;
    *seconds = info.pbi_start_tvsec; *microseconds = info.pbi_start_tvusec;
    return 0;
}
