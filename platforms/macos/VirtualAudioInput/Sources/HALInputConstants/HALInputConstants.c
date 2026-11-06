#include "HALInputConstants.h"
#include <CoreAudio/AudioServerPlugIn.h>

uint32_t flow_input_zero_timestamp_period_selector(void) {
    return kAudioDevicePropertyZeroTimeStampPeriod;
}
