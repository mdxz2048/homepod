#include "HFLatencyControlSupport.h"
#include <CoreAudio/AudioServerPlugIn.h>

uint32_t hfl_zero_timestamp_period_selector(void) {
    return kAudioDevicePropertyZeroTimeStampPeriod;
}
