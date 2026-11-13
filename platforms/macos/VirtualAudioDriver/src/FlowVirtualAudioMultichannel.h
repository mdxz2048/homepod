#pragma once
#include <CoreAudio/AudioServerPlugIn.h>
#include "FlowMultichannelMap.h"

/*
 * Fixed-layout device family aligned with MULTICHANNEL_CONTRACT.md v1.
 *
 * Default build is the safe staging identity (distinct .dev. UIDs and bundle
 * ID) so it cannot collide with the installed production stereo driver.
 * Build with -DMC_PRODUCTION_IDENTITY=1 to emit the contract's production
 * UID/model UID identity for review, still without installing.
 *
 * Height layouts (5_1_2 / 7_1_2 / 7_1_4) are RES: names and channel order are
 * frozen in FlowMultichannelMap but they are not enumerated here.
 */

#ifndef MC_PRODUCTION_IDENTITY
#define MC_PRODUCTION_IDENTITY 0
#endif

#ifndef MC_SINGLE_DEVICE
#define MC_SINGLE_DEVICE 0
#endif

#if MC_PRODUCTION_IDENTITY
#define MC_BUNDLE_ID "com.homepodflow.audio.driver"

#define MC_DEVICE_UID_STEREO "com.homepodflow.virtual-audio.stereo.v1"
#define MC_DEVICE_UID_MONO "com.homepodflow.virtual-audio.mono.v1"
#define MC_DEVICE_UID_30 "com.homepodflow.virtual-audio.surround30.v1"
#define MC_DEVICE_UID_40 "com.homepodflow.virtual-audio.quad40.v1"
#define MC_DEVICE_UID_51S "com.homepodflow.virtual-audio.surround51s.v1"
#define MC_DEVICE_UID_51B "com.homepodflow.virtual-audio.surround51b.v1"
#define MC_DEVICE_UID_71 "com.homepodflow.virtual-audio.surround71.v1"

#define MC_MODEL_UID_STEREO "com.homepodflow.virtual-audio.model.v1"
#define MC_MODEL_UID_MONO "com.homepodflow.virtual-audio.model.mono.v1"
#define MC_MODEL_UID_30 "com.homepodflow.virtual-audio.model.surround30.v1"
#define MC_MODEL_UID_40 "com.homepodflow.virtual-audio.model.quad40.v1"
#define MC_MODEL_UID_51S "com.homepodflow.virtual-audio.model.surround51s.v1"
#define MC_MODEL_UID_51B "com.homepodflow.virtual-audio.model.surround51b.v1"
#define MC_MODEL_UID_71 "com.homepodflow.virtual-audio.model.surround71.v1"

#define MC_DEVICE_NAME_STEREO "HomePod Flow Audio"
#define MC_DEVICE_NAME_MONO "HomePod Flow Audio Mono"
#define MC_DEVICE_NAME_30 "HomePod Flow Audio 3.0"
#define MC_DEVICE_NAME_40 "HomePod Flow Audio 4.0"
#define MC_DEVICE_NAME_51S "HomePod Flow Audio 5.1 Side"
#define MC_DEVICE_NAME_51B "HomePod Flow Audio 5.1 Back"
#define MC_DEVICE_NAME_71 "HomePod Flow Audio 7.1"

#define MC_STREAM_NAME_STEREO "HomePod Flow Stereo Output"
#define MC_STREAM_NAME_MONO "HomePod Flow Mono Output"
#define MC_STREAM_NAME_30 "HomePod Flow 3.0 Output"
#define MC_STREAM_NAME_40 "HomePod Flow 4.0 Output"
#define MC_STREAM_NAME_51S "HomePod Flow 5.1 Side Output"
#define MC_STREAM_NAME_51B "HomePod Flow 5.1 Back Output"
#define MC_STREAM_NAME_71 "HomePod Flow 7.1 Output"
#define MC_PLUGIN_NAME "HomePod Flow Audio Plug-in"
#else
#define MC_BUNDLE_ID "com.homepodflow.audio.driver.family.dev"

#define MC_DEVICE_UID_STEREO "com.homepodflow.virtual-audio.dev.stereo.v1"
#define MC_DEVICE_UID_MONO "com.homepodflow.virtual-audio.dev.mono.v1"
#define MC_DEVICE_UID_30 "com.homepodflow.virtual-audio.dev.surround30.v1"
#define MC_DEVICE_UID_40 "com.homepodflow.virtual-audio.dev.quad40.v1"
#define MC_DEVICE_UID_51S "com.homepodflow.virtual-audio.dev.surround51s.v1"
#define MC_DEVICE_UID_51B "com.homepodflow.virtual-audio.dev.surround51b.v1"
#define MC_DEVICE_UID_71 "com.homepodflow.virtual-audio.dev.surround71.v1"

#define MC_MODEL_UID_STEREO "com.homepodflow.virtual-audio.model.dev.stereo.v1"
#define MC_MODEL_UID_MONO "com.homepodflow.virtual-audio.model.dev.mono.v1"
#define MC_MODEL_UID_30 "com.homepodflow.virtual-audio.model.dev.surround30.v1"
#define MC_MODEL_UID_40 "com.homepodflow.virtual-audio.model.dev.quad40.v1"
#define MC_MODEL_UID_51S "com.homepodflow.virtual-audio.model.dev.surround51s.v1"
#define MC_MODEL_UID_51B "com.homepodflow.virtual-audio.model.dev.surround51b.v1"
#define MC_MODEL_UID_71 "com.homepodflow.virtual-audio.model.dev.surround71.v1"

#define MC_DEVICE_NAME_STEREO "HomePod Flow Audio Stereo (Dev)"
#define MC_DEVICE_NAME_MONO "HomePod Flow Audio Mono (Dev)"
#define MC_DEVICE_NAME_30 "HomePod Flow Audio 3.0 (Dev)"
#define MC_DEVICE_NAME_40 "HomePod Flow Audio 4.0 (Dev)"
#define MC_DEVICE_NAME_51S "HomePod Flow Audio 5.1 Side (Dev)"
#define MC_DEVICE_NAME_51B "HomePod Flow Audio 5.1 Back (Dev)"
#define MC_DEVICE_NAME_71 "HomePod Flow Audio 7.1 (Dev)"

#define MC_STREAM_NAME_STEREO "HomePod Flow Stereo Output (Dev)"
#define MC_STREAM_NAME_MONO "HomePod Flow Mono Output (Dev)"
#define MC_STREAM_NAME_30 "HomePod Flow 3.0 Output (Dev)"
#define MC_STREAM_NAME_40 "HomePod Flow 4.0 Output (Dev)"
#define MC_STREAM_NAME_51S "HomePod Flow 5.1 Side Output (Dev)"
#define MC_STREAM_NAME_51B "HomePod Flow 5.1 Back Output (Dev)"
#define MC_STREAM_NAME_71 "HomePod Flow 7.1 Output (Dev)"
#define MC_PLUGIN_NAME "HomePod Flow Multichannel Family (Dev) Plug-in"
#endif

#if MC_SINGLE_DEVICE
#undef MC_DEVICE_NAME_71
#define MC_DEVICE_NAME_71 "HomePod Flow Audio"
#endif

enum {
    kMCObjectDeviceStereo = 2,
    kMCObjectStreamStereo = 3,
    kMCObjectDeviceMono = 4,
    kMCObjectStreamMono = 5,
    kMCObjectDevice30 = 6,
    kMCObjectStream30 = 7,
    kMCObjectDevice40 = 8,
    kMCObjectStream40 = 9,
    kMCObjectDevice51S = 10,
    kMCObjectStream51S = 11,
    kMCObjectDevice51B = 12,
    kMCObjectStream51B = 13,
    kMCObjectDevice71 = 14,
    kMCObjectStream71 = 15,
    kMCObjectControlVolumeBase = 400,
    kMCObjectControlMuteBase = 401,
    kMCLatencyFrames = 'hfla',
    kMCLatencyRevision = 'hflr',
    kMCLatencyStatus = 'hfls',
    kMCZeroTimeStampPeriod = 16384
};

#if MC_SINGLE_DEVICE
#define MC_DEVICE_COUNT 1
#else
#define MC_DEVICE_COUNT 7
#endif

/* Fixed process-local handles.  Never persist these across launches. */
__attribute__((visibility("default")))
void *FlowVirtualAudioMultichannelFactory(CFAllocatorRef allocator, CFUUIDRef requestedType);
