#pragma once
#include <CoreAudio/AudioServerPlugIn.h>

enum {
    kFlowObjectDevice = 2,
    kFlowObjectOutputStream = 3,
    kFlowLatencyFrames = 'hfla',
    kFlowLatencyRevision = 'hflr',
    kFlowZeroTimeStampPeriod = 16384
};
#define FLOW_DEVICE_UID "com.homepodflow.virtual-audio.stereo.v1"
#define FLOW_MODEL_UID "com.homepodflow.virtual-audio.model.v1"
#define FLOW_BUNDLE_ID "com.homepodflow.audio.driver"

/* CFPlugIn factory; no exported app-specific transport or microphone endpoint. */
__attribute__((visibility("default")))
void *FlowVirtualAudioFactory(CFAllocatorRef allocator, CFUUIDRef requestedType);
