/*
 * Experimental output-only N-channel AudioServerPlugIn family.
 *
 * This is a separate development bundle.  It does not modify, replace, or
 * share state with the production stereo driver in FlowVirtualAudio.c.
 *
 * The data plane is still a sink: WriteMix is consumed, not stored, mixed,
 * upmixed, downmixed, or forwarded.  Source layout is a capture/App concern.
 * No allocation, lock, log, file, or network access occurs in the realtime
 * callbacks (ZeroTimeStamp, WillIO, BeginIO, DoIO).
 */
#include "FlowVirtualAudioMultichannel.h"

#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreAudio/AudioHardware.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    AudioObjectID deviceID;
    AudioObjectID streamID;
    const char *uid;
    const char *modelUID;
    const char *name;
    const char *streamName;
    CFStringRef uidString;
    CFStringRef modelString;
    CFStringRef nameString;
    CFStringRef streamString;
    MCLayout layout;
    bool systemDefaultEligible;
    bool hidden;
} MCDeviceInfo;

/*
 * Device policy lives in this table.  The core property/format/clock code is
 * layout-driven, so the architect may later choose one configurable device,
 * separate devices, or a different subset without rewriting the HAL logic.
 */
static const MCDeviceInfo gDevices[MC_DEVICE_COUNT] = {
#if !MC_SINGLE_DEVICE
    {kMCObjectDeviceStereo, kMCObjectStreamStereo,
     MC_DEVICE_UID_STEREO, MC_MODEL_UID_STEREO,
     MC_DEVICE_NAME_STEREO, MC_STREAM_NAME_STEREO,
     CFSTR(MC_DEVICE_UID_STEREO), CFSTR(MC_MODEL_UID_STEREO),
     CFSTR(MC_DEVICE_NAME_STEREO), CFSTR(MC_STREAM_NAME_STEREO),
     MC_LAYOUT_STEREO, true, false},
    {kMCObjectDeviceMono, kMCObjectStreamMono,
     MC_DEVICE_UID_MONO, MC_MODEL_UID_MONO,
     MC_DEVICE_NAME_MONO, MC_STREAM_NAME_MONO,
     CFSTR(MC_DEVICE_UID_MONO), CFSTR(MC_MODEL_UID_MONO),
     CFSTR(MC_DEVICE_NAME_MONO), CFSTR(MC_STREAM_NAME_MONO),
     MC_LAYOUT_MONO, false, true},
    {kMCObjectDevice30, kMCObjectStream30,
     MC_DEVICE_UID_30, MC_MODEL_UID_30,
     MC_DEVICE_NAME_30, MC_STREAM_NAME_30,
     CFSTR(MC_DEVICE_UID_30), CFSTR(MC_MODEL_UID_30),
     CFSTR(MC_DEVICE_NAME_30), CFSTR(MC_STREAM_NAME_30),
     MC_LAYOUT_3_0, false, true},
    {kMCObjectDevice40, kMCObjectStream40,
     MC_DEVICE_UID_40, MC_MODEL_UID_40,
     MC_DEVICE_NAME_40, MC_STREAM_NAME_40,
     CFSTR(MC_DEVICE_UID_40), CFSTR(MC_MODEL_UID_40),
     CFSTR(MC_DEVICE_NAME_40), CFSTR(MC_STREAM_NAME_40),
     MC_LAYOUT_4_0, false, true},
    {kMCObjectDevice51S, kMCObjectStream51S,
     MC_DEVICE_UID_51S, MC_MODEL_UID_51S,
     MC_DEVICE_NAME_51S, MC_STREAM_NAME_51S,
     CFSTR(MC_DEVICE_UID_51S), CFSTR(MC_MODEL_UID_51S),
     CFSTR(MC_DEVICE_NAME_51S), CFSTR(MC_STREAM_NAME_51S),
     MC_LAYOUT_5_1_SIDE, false, false},
    {kMCObjectDevice51B, kMCObjectStream51B,
     MC_DEVICE_UID_51B, MC_MODEL_UID_51B,
     MC_DEVICE_NAME_51B, MC_STREAM_NAME_51B,
     CFSTR(MC_DEVICE_UID_51B), CFSTR(MC_MODEL_UID_51B),
     CFSTR(MC_DEVICE_NAME_51B), CFSTR(MC_STREAM_NAME_51B),
     MC_LAYOUT_5_1_BACK, false, true},
#endif
    {kMCObjectDevice71, kMCObjectStream71,
     MC_DEVICE_UID_71, MC_MODEL_UID_71,
     MC_DEVICE_NAME_71, MC_STREAM_NAME_71,
     CFSTR(MC_DEVICE_UID_71), CFSTR(MC_MODEL_UID_71),
     CFSTR(MC_DEVICE_NAME_71), CFSTR(MC_STREAM_NAME_71),
     MC_LAYOUT_7_1, false, false},
};

_Static_assert(sizeof(gDevices) / sizeof(gDevices[0]) == MC_DEVICE_COUNT,
               "device table and MC_DEVICE_COUNT disagree");

typedef enum {
    MCPendingNone = 0,
    MCPendingRate = 1,
    MCPendingLatency = 2
} MCPendingKind;

enum {
    MCLatencyStatusIdle = 0,
    MCLatencyStatusPending = 1,
    MCLatencyStatusBusy = 2,
    MCLatencyStatusRejected = 3
};

typedef struct {
    _Atomic UInt32 running;
    _Atomic UInt32 rate;
    _Atomic UInt32 latency;
    _Atomic float volume;
    _Atomic UInt32 mute;
    _Atomic UInt64 revision;
    _Atomic UInt64 clockSequence;
    _Atomic UInt64 anchor;
    _Atomic UInt64 seed;
    UInt32 latencyBudgetFrames;
    UInt32 latencyBudgetRate;
    /* Single per-device pending transaction slot, shared by rate and latency. */
    UInt32 pendingKind;
    Float64 pendingRate;
    UInt32 pendingLatency;
    UInt64 pendingAction;
    UInt64 nextAction;
    Boolean lastHostRejected;
    UInt32 runningClients[64];
    Boolean clientSlotUsed[64];
} MCDeviceState;

static AudioServerPlugInHostRef gHost;
static pthread_mutex_t gControl = PTHREAD_MUTEX_INITIALIZER;
static _Atomic UInt32 gReferences = 1;
static _Atomic UInt32 gPropertyErrorLogs;
static _Atomic UInt32 gConfigEventLogs;
static _Atomic Boolean gStateInitialized;
static mach_timebase_info_data_t gTimebase;
static MCDeviceState gState[MC_DEVICE_COUNT];

static HRESULT QueryInterface(void *, REFIID, LPVOID *);
static ULONG AddRef(void *);
static ULONG Release(void *);
static OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef,
                             const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus Client(AudioServerPlugInDriverRef, AudioObjectID,
                       const AudioServerPlugInClientInfo *);
static OSStatus PerformChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus AbortChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                           const AudioObjectPropertyAddress *);
static OSStatus IsSettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                           const AudioObjectPropertyAddress *, Boolean *);
static OSStatus DataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                         const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus GetData(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                        const AudioObjectPropertyAddress *, UInt32, const void *, UInt32,
                        UInt32 *, void *);
static OSStatus SetData(AudioServerPlugInDriverRef, AudioObjectID, pid_t,
                        const AudioObjectPropertyAddress *, UInt32, const void *, UInt32,
                        const void *);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus ZeroTime(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *,
                         UInt64 *, UInt64 *);
static OSStatus WillIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                       Boolean *, Boolean *);
static OSStatus BeginIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32,
                        UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus DoIO(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32,
                     UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice,
    Client, Client, PerformChange, AbortChange, HasProperty, IsSettable, DataSize,
    GetData, SetData, StartIO, StopIO, ZeroTime, WillIO, BeginIO, DoIO, BeginIO};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;

static AudioServerPlugInDriverRef Driver(void) { return &gInterfacePointer; }
static Boolean ValidDriver(AudioServerPlugInDriverRef driver) { return driver == Driver(); }

static int DeviceIndex(AudioObjectID object) {
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        if (gDevices[i].deviceID == object) return (int)i;
    }
    return -1;
}

static int StreamIndex(AudioObjectID object) {
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        if (gDevices[i].streamID == object) return (int)i;
    }
    return -1;
}

static int ControlIndex(AudioObjectID object, Boolean *isVolume) {
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        if (object == (AudioObjectID)(kMCObjectControlVolumeBase + 2 * i)) {
            if (isVolume) *isVolume = true;
            return (int)i;
        }
        if (object == (AudioObjectID)(kMCObjectControlMuteBase + 2 * i)) {
            if (isVolume) *isVolume = false;
            return (int)i;
        }
    }
    return -1;
}

/* The master controls expose a linear scalar in 0...1 backed by a -96...0 dB
 * curve. The driver deliberately performs no DSP: the app forwards the value
 * to the AirPlay group, so macOS volume keys have exactly one authority. */
static const Float32 kMCVolumeMinDecibels = -96.0f;

static Float32 MCVolumeToDecibels(Float32 scalar) {
    if (!(scalar > 0.000001f)) return kMCVolumeMinDecibels;
    Float32 decibels = 20.0f * log10f(scalar);
    return decibels < kMCVolumeMinDecibels ? kMCVolumeMinDecibels : decibels;
}

static Float32 MCDecibelsToVolume(Float32 decibels) {
    if (!(decibels > kMCVolumeMinDecibels)) return 0.0f;
    Float32 scalar = powf(10.0f, decibels / 20.0f);
    return scalar > 1.0f ? 1.0f : scalar;
}

static Boolean ValidObject(AudioObjectID object) {
    return object == kAudioObjectPlugInObject || DeviceIndex(object) >= 0 ||
           StreamIndex(object) >= 0 || ControlIndex(object, NULL) >= 0;
}

static UInt32 DeviceChannels(const MCDeviceInfo *info) {
    return MCLayoutChannelCount(info->layout);
}

static AudioObjectPropertyAddress Global(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
}

/* Control-plane diagnostics only.  Never called by a realtime callback. */
static void PropertyReadFailure(AudioObjectID object,
                                const AudioObjectPropertyAddress *address,
                                OSStatus status) {
    if (!address) return;
    UInt32 count = atomic_load(&gPropertyErrorLogs);
    while (count < 64 &&
           !atomic_compare_exchange_weak(&gPropertyErrorLogs, &count, count + 1)) {
    }
    if (count >= 64) return;
    os_log_error(OS_LOG_DEFAULT,
                 "HomePodFlowAudioFamily property read rejected object=%{public}u "
                 "selector=%{public}u scope=%{public}u element=%{public}u status=%{public}d",
                 object, address->mSelector, address->mScope, address->mElement,
                 (int)status);
}

static void Notify(AudioObjectID object, UInt32 count,
                   const AudioObjectPropertyAddress *addresses) {
    if (gHost) gHost->PropertiesChanged(gHost, object, count, addresses);
}

static CFStringRef DeviceUIDString(const MCDeviceInfo *info) { return info->uidString; }
static CFStringRef DeviceModelUIDString(const MCDeviceInfo *info) { return info->modelString; }
static CFStringRef DeviceNameString(const MCDeviceInfo *info) { return info->nameString; }
static CFStringRef StreamNameString(const MCDeviceInfo *info) { return info->streamString; }

static CFStringRef LabelString(MCLabel label) {
    switch (label) {
        case MC_LABEL_M: return CFSTR("M");
        case MC_LABEL_FL: return CFSTR("FL");
        case MC_LABEL_FR: return CFSTR("FR");
        case MC_LABEL_FC: return CFSTR("FC");
        case MC_LABEL_LFE: return CFSTR("LFE");
        case MC_LABEL_SL: return CFSTR("SL");
        case MC_LABEL_SR: return CFSTR("SR");
        case MC_LABEL_BL: return CFSTR("BL");
        case MC_LABEL_BR: return CFSTR("BR");
        case MC_LABEL_TFL: return CFSTR("TFL");
        case MC_LABEL_TFR: return CFSTR("TFR");
        case MC_LABEL_TRL: return CFSTR("TRL");
        case MC_LABEL_TRR: return CFSTR("TRR");
        case MC_LABEL_NONE:
        default: return CFSTR("NONE");
    }
}

static AudioChannelLabel CoreAudioLabel(MCLabel label) {
    switch (label) {
        case MC_LABEL_M: return kAudioChannelLabel_Mono;
        case MC_LABEL_FL: return kAudioChannelLabel_Left;
        case MC_LABEL_FR: return kAudioChannelLabel_Right;
        case MC_LABEL_FC: return kAudioChannelLabel_Center;
        case MC_LABEL_LFE: return kAudioChannelLabel_LFEScreen;
        /* Side and back are deliberately different CoreAudio labels. */
        case MC_LABEL_SL: return kAudioChannelLabel_LeftSurroundDirect;
        case MC_LABEL_SR: return kAudioChannelLabel_RightSurroundDirect;
        case MC_LABEL_BL: return kAudioChannelLabel_LeftSurround;
        case MC_LABEL_BR: return kAudioChannelLabel_RightSurround;
        case MC_LABEL_TFL: return kAudioChannelLabel_LeftTopFront;
        case MC_LABEL_TFR: return kAudioChannelLabel_RightTopFront;
        case MC_LABEL_TRL: return kAudioChannelLabel_TopBackLeft;
        case MC_LABEL_TRR: return kAudioChannelLabel_TopBackRight;
        case MC_LABEL_NONE:
        default: return kAudioChannelLabel_Unknown;
    }
}

/* Azimuth: 0 front, positive right, negative left, degrees. */
static Float32 CoreAudioAzimuth(MCLabel label) {
    switch (label) {
        case MC_LABEL_M: return 0.0f;
        case MC_LABEL_FL: return -30.0f;
        case MC_LABEL_FR: return 30.0f;
        case MC_LABEL_FC: return 0.0f;
        case MC_LABEL_LFE: return 0.0f;
        case MC_LABEL_SL: return -90.0f;
        case MC_LABEL_SR: return 90.0f;
        case MC_LABEL_BL: return -135.0f;
        case MC_LABEL_BR: return 135.0f;
        case MC_LABEL_TFL: return -30.0f;
        case MC_LABEL_TFR: return 30.0f;
        case MC_LABEL_TRL: return -135.0f;
        case MC_LABEL_TRR: return 135.0f;
        case MC_LABEL_NONE:
        default: return 0.0f;
    }
}

static Float32 CoreAudioElevation(MCLabel label) {
    switch (label) {
        case MC_LABEL_TFL:
        case MC_LABEL_TFR:
        case MC_LABEL_TRL:
        case MC_LABEL_TRR:
            return 45.0f;
        default:
            return 0.0f;
    }
}

/* Local layout storage with enough room for MC_MAX_CHANNELS descriptions. */
typedef struct {
    AudioChannelLayoutTag mChannelLayoutTag;
    AudioChannelBitmap mChannelBitmap;
    UInt32 mNumberChannelDescriptions;
    AudioChannelDescription mChannelDescriptions[MC_MAX_CHANNELS];
} MCLayoutStorage;

static UInt32 PreferredLayoutSize(UInt32 channels) {
    return (UInt32)(offsetof(MCLayoutStorage, mChannelDescriptions) +
                    channels * sizeof(AudioChannelDescription));
}

static void FillPreferredLayout(const MCDeviceInfo *info, MCLayoutStorage *storage) {
    MCLabel labels[MC_MAX_CHANNELS];
    UInt32 count = 0;
    MCLayoutLabels(info->layout, labels, &count);
    memset(storage, 0, sizeof(*storage));
    storage->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    storage->mChannelBitmap = 0;
    storage->mNumberChannelDescriptions = count;
    for (UInt32 i = 0; i < count; ++i) {
        AudioChannelDescription *description = &storage->mChannelDescriptions[i];
        description->mChannelLabel = CoreAudioLabel(labels[i]);
        description->mChannelFlags = kAudioChannelFlags_SphericalCoordinates;
        description->mCoordinates[0] = CoreAudioAzimuth(labels[i]);
        description->mCoordinates[1] = CoreAudioElevation(labels[i]);
        description->mCoordinates[2] = 1.0f;
    }
}

static AudioStreamBasicDescription Format(UInt32 rate, UInt32 channels) {
    UInt32 bytesPerFrame = 4 * channels;
    return (AudioStreamBasicDescription){
        rate,
        kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        bytesPerFrame,
        1,
        bytesPerFrame,
        channels,
        32,
        0};
}

static Boolean ValidFormatForDevice(const MCDeviceInfo *info,
                                    const AudioStreamBasicDescription *format) {
    if (!format) return false;
    if (format->mSampleRate != 44100 && format->mSampleRate != 48000) return false;
    AudioStreamBasicDescription wanted = Format((UInt32)format->mSampleRate,
                                                DeviceChannels(info));
    return format->mFormatID == wanted.mFormatID &&
           format->mFormatFlags == wanted.mFormatFlags &&
           format->mBytesPerPacket == wanted.mBytesPerPacket &&
           format->mFramesPerPacket == wanted.mFramesPerPacket &&
           format->mBytesPerFrame == wanted.mBytesPerFrame &&
           format->mChannelsPerFrame == wanted.mChannelsPerFrame &&
           format->mBitsPerChannel == wanted.mBitsPerChannel;
}

static void ResetClock(int index) {
    MCDeviceState *state = &gState[index];
    atomic_fetch_add_explicit(&state->clockSequence, 1, memory_order_acq_rel);
    atomic_store_explicit(&state->anchor, mach_absolute_time(), memory_order_relaxed);
    atomic_fetch_add_explicit(&state->seed, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&state->clockSequence, 1, memory_order_release);
}

static void InitializeState(void) {
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        MCDeviceState *state = &gState[i];
        atomic_store(&state->running, 0);
        atomic_store(&state->rate, 48000);
        atomic_store(&state->latency, 0);
        atomic_store(&state->volume, 1.0f);
        atomic_store(&state->mute, 0);
        atomic_store(&state->revision, 1);
        atomic_store(&state->clockSequence, 0);
        atomic_store(&state->anchor, 0);
        atomic_store(&state->seed, 1);
        state->latencyBudgetFrames = 0;
        state->latencyBudgetRate = 48000;
        state->pendingKind = MCPendingNone;
        state->pendingRate = 48000;
        state->pendingLatency = 0;
        state->pendingAction = 0;
        state->nextAction = 0;
        state->lastHostRejected = false;
        for (UInt32 client = 0; client < 64; ++client) {
            state->runningClients[client] = 0;
            state->clientSlotUsed[client] = false;
        }
    }
}

void *FlowVirtualAudioMultichannelFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    (void)allocator;
    return type && CFEqual(type, kAudioServerPlugInTypeUUID) ? Driver() : NULL;
}

static HRESULT QueryInterface(void *driver, REFIID iid, LPVOID *result) {
    if (!result) return E_POINTER;
    *result = NULL;
    if (!ValidDriver(driver)) return E_NOINTERFACE;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean supported = uuid &&
        (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID));
    if (uuid) CFRelease(uuid);
    if (!supported) return E_NOINTERFACE;
    AddRef(driver);
    *result = Driver();
    return S_OK;
}

static ULONG AddRef(void *driver) {
    if (!ValidDriver(driver)) return 0;
    return atomic_fetch_add(&gReferences, 1) + 1;
}

static ULONG Release(void *driver) {
    if (!ValidDriver(driver)) return 0;
    UInt32 old = atomic_load(&gReferences);
    while (old > 1 && !atomic_compare_exchange_weak(&gReferences, &old, old - 1)) {
    }
    return old > 1 ? old - 1 : 1;
}

static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (!ValidDriver(driver) || !host) return kAudioHardwareBadObjectError;
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        if (!atomic_is_lock_free(&gState[i].anchor) ||
            !atomic_is_lock_free(&gState[i].clockSequence) ||
            !atomic_is_lock_free(&gState[i].rate)) {
            return kAudioHardwareUnsupportedOperationError;
        }
    }
    if (mach_timebase_info(&gTimebase) != KERN_SUCCESS || !gTimebase.numer ||
        !gTimebase.denom) {
        return kAudioHardwareUnspecifiedError;
    }
    if (!atomic_exchange(&gStateInitialized, true)) InitializeState();
    gHost = host;
    UInt64 now = mach_absolute_time();
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        atomic_store(&gState[i].anchor, now);
    }
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef properties,
                             const AudioServerPlugInClientInfo *client,
                             AudioObjectID *object) {
    (void)driver;
    (void)properties;
    (void)client;
    if (object) *object = kAudioObjectUnknown;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID object) {
    (void)driver;
    (void)object;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus Client(AudioServerPlugInDriverRef driver, AudioObjectID object,
                       const AudioServerPlugInClientInfo *client) {
    return ValidDriver(driver) && DeviceIndex(object) >= 0 && client
               ? noErr
               : kAudioHardwareBadObjectError;
}

static UInt32 PendingStatus(int index) {
    MCDeviceState *state = &gState[index];
    pthread_mutex_lock(&gControl);
    UInt32 pending = state->pendingKind;
    Boolean rejected = state->lastHostRejected;
    Boolean running = atomic_load(&state->running) > 0;
    pthread_mutex_unlock(&gControl);
    if (pending != MCPendingNone) return MCLatencyStatusPending;
    if (running) return MCLatencyStatusBusy;
    if (rejected) return MCLatencyStatusRejected;
    return MCLatencyStatusIdle;
}

/* Control-plane diagnostics only.  Never called by a realtime callback. */
static void LogConfigEvent(AudioObjectID object, int index, const char *phase,
                           UInt32 kind, UInt64 action, OSStatus status) {
    UInt32 count = atomic_load(&gConfigEventLogs);
    while (count < 64 &&
           !atomic_compare_exchange_weak(&gConfigEventLogs, &count, count + 1)) {
    }
    if (count >= 64) return;
    os_log_info(OS_LOG_DEFAULT,
                "HomePodFlowAudioFamily config object=%{public}u device=%{public}d "
                "phase=%{public}s kind=%{public}u action=%{public}llu status=%{public}d",
                object, index, phase, kind, action, (int)status);
}

/*
 * Reserve the single per-device pending slot, then enqueue the host request
 * off the caller.  Apple's NullAudio sample dispatches every
 * RequestDeviceConfigurationChange out of the property-set thread for both
 * rate and latency setters; the host may otherwise run its transaction
 * synchronously inside SetData and re-enter the driver.  The pending kind,
 * target values, and unique action stay reserved in the per-device slot until
 * the host's matching PerformChange commits them; refusal or AbortChange
 * clears the reservation.  A missing host is a terminal failure and is
 * refused synchronously because there is no request to enqueue.
 */
typedef void (*MCHostRequestFunction)(void *context);
typedef void (*MCHostRequestSubmitter)(MCHostRequestFunction function,
                                       void *context);

static MCHostRequestSubmitter gHostRequestSubmitter;

typedef struct {
    AudioObjectID deviceObject;
    UInt32 index;
    UInt32 kind;
    Float64 rate;
    UInt32 latency;
    UInt64 action;
} MCHostRequest;

static void MCHostRequestRun(void *context) {
    MCHostRequest *request = (MCHostRequest *)context;
    MCDeviceState *state = &gState[request->index];

    pthread_mutex_lock(&gControl);
    Boolean current = state->pendingKind != MCPendingNone &&
                      state->pendingAction == request->action;
    pthread_mutex_unlock(&gControl);
    if (!current) {
        LogConfigEvent(request->deviceObject, request->index, "stale-request",
                       request->kind, request->action,
                       kAudioHardwareIllegalOperationError);
        free(request);
        return;
    }
    if (!gHost) {
        AbortChange(Driver(), request->deviceObject, request->action, NULL);
        LogConfigEvent(request->deviceObject, request->index, "request-no-host",
                       request->kind, request->action,
                       kAudioHardwareNotReadyError);
        free(request);
        return;
    }
    OSStatus status = gHost->RequestDeviceConfigurationChange(
        gHost, request->deviceObject, request->action, NULL);
    LogConfigEvent(request->deviceObject, request->index, "request",
                   request->kind, request->action, status);
    if (status) {
        AbortChange(Driver(), request->deviceObject, request->action, NULL);
    }
    free(request);
}

static OSStatus RequestConfigurationChange(AudioObjectID deviceObject, int index,
                                           UInt32 kind, Float64 rate,
                                           UInt32 latency) {
    MCDeviceState *state = &gState[index];
    pthread_mutex_lock(&gControl);
    if (atomic_load(&state->running) || state->pendingKind != MCPendingNone) {
        pthread_mutex_unlock(&gControl);
        return kAudioHardwareIllegalOperationError;
    }
    if (kind == MCPendingRate && rate == atomic_load(&state->rate)) {
        state->lastHostRejected = false;
        pthread_mutex_unlock(&gControl);
        return noErr;
    }
    if (kind == MCPendingLatency && latency == atomic_load(&state->latency)) {
        state->lastHostRejected = false;
        pthread_mutex_unlock(&gControl);
        return noErr;
    }
    state->pendingKind = kind;
    if (kind == MCPendingRate) {
        state->pendingRate = rate;
    } else {
        state->pendingLatency = latency;
    }
    state->lastHostRejected = false;
    UInt64 action = ++state->nextAction;
    if (action == 0) {
        state->nextAction = 1;
        action = 1;
    }
    state->pendingAction = action;
    pthread_mutex_unlock(&gControl);

    if (!gHost) {
        AbortChange(Driver(), deviceObject, action, NULL);
        LogConfigEvent(deviceObject, index, "request-no-host", kind, action,
                       kAudioHardwareNotReadyError);
        return kAudioHardwareNotReadyError;
    }
    MCHostRequest *request = (MCHostRequest *)malloc(sizeof(MCHostRequest));
    if (!request) {
        AbortChange(Driver(), deviceObject, action, NULL);
        LogConfigEvent(deviceObject, index, "request-no-memory", kind, action,
                       kAudioHardwareUnspecifiedError);
        return kAudioHardwareUnspecifiedError;
    }
    request->deviceObject = deviceObject;
    request->index = index;
    request->kind = kind;
    request->rate = rate;
    request->latency = latency;
    request->action = action;
    if (gHostRequestSubmitter) {
        gHostRequestSubmitter(MCHostRequestRun, request);
    } else {
        dispatch_async_f(
            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
            request, MCHostRequestRun);
    }
    return noErr;
}

/* Both commit helpers run with gControl held. */
static void CommitRateChange(int index) {
    MCDeviceState *state = &gState[index];
    UInt32 rate = (UInt32)state->pendingRate;
    UInt32 latency = (UInt32)(((UInt64)state->latencyBudgetFrames * rate +
                               state->latencyBudgetRate / 2) /
                              state->latencyBudgetRate);
    atomic_fetch_add(&state->clockSequence, 1);
    atomic_store(&state->rate, rate);
    atomic_store(&state->latency, latency);
    atomic_store(&state->anchor, mach_absolute_time());
    atomic_fetch_add(&state->seed, 1);
    atomic_fetch_add(&state->clockSequence, 1);
    atomic_fetch_add(&state->revision, 1);
}

static void CommitLatencyChange(int index) {
    MCDeviceState *state = &gState[index];
    UInt32 frames = state->pendingLatency;
    atomic_store(&state->latency, frames);
    state->latencyBudgetFrames = frames;
    state->latencyBudgetRate = atomic_load(&state->rate);
    atomic_fetch_add(&state->revision, 1);
}

static OSStatus PerformChange(AudioServerPlugInDriverRef driver, AudioObjectID object,
                              UInt64 action, void *info) {
    (void)info;
    int index = DeviceIndex(object);
    if (!ValidDriver(driver) || index < 0) return kAudioHardwareBadObjectError;
    MCDeviceState *state = &gState[index];
    pthread_mutex_lock(&gControl);
    if (state->pendingKind == MCPendingNone || action != state->pendingAction ||
        atomic_load(&state->running)) {
        pthread_mutex_unlock(&gControl);
        return kAudioHardwareIllegalOperationError;
    }
    UInt32 kind = state->pendingKind;
    if (kind == MCPendingRate) {
        CommitRateChange(index);
    } else {
        CommitLatencyChange(index);
    }
    state->pendingKind = MCPendingNone;
    state->lastHostRejected = false;
    pthread_mutex_unlock(&gControl);
    LogConfigEvent(object, index, "commit", kind, action, noErr);

    const MCDeviceInfo *device = &gDevices[index];
    AudioObjectPropertyAddress deviceAddresses[4];
    AudioObjectPropertyAddress streamAddresses[4];
    UInt32 deviceCount = 0;
    UInt32 streamCount = 0;
    if (kind == MCPendingRate) {
        deviceAddresses[deviceCount++] = Global(kAudioDevicePropertyNominalSampleRate);
        streamAddresses[streamCount++] = Global(kAudioStreamPropertyVirtualFormat);
        streamAddresses[streamCount++] = Global(kAudioStreamPropertyPhysicalFormat);
    }
    deviceAddresses[deviceCount++] = Global(kMCLatencyFrames);
    deviceAddresses[deviceCount++] = Global(kMCLatencyRevision);
    deviceAddresses[deviceCount++] = Global(kMCLatencyStatus);
    streamAddresses[streamCount++] = Global(kAudioStreamPropertyLatency);
    streamAddresses[streamCount++] =
        (AudioObjectPropertyAddress){kAudioStreamPropertyLatency,
                                     kAudioObjectPropertyScopeOutput,
                                     kAudioObjectPropertyElementMain};
    Notify(device->deviceID, deviceCount, deviceAddresses);
    Notify(device->streamID, streamCount, streamAddresses);
    return noErr;
}

static OSStatus AbortChange(AudioServerPlugInDriverRef driver, AudioObjectID object,
                            UInt64 action, void *info) {
    (void)info;
    int index = DeviceIndex(object);
    if (!ValidDriver(driver) || index < 0) return kAudioHardwareBadObjectError;
    MCDeviceState *state = &gState[index];
    pthread_mutex_lock(&gControl);
    UInt32 kind = state->pendingKind;
    Boolean matched = kind != MCPendingNone && action == state->pendingAction;
    if (matched) {
        state->pendingKind = MCPendingNone;
        state->lastHostRejected = true;
    }
    pthread_mutex_unlock(&gControl);
    if (matched) LogConfigEvent(object, index, "abort", kind, action, noErr);
    return noErr;
}

/* The property table is the single source of truth for HasProperty and sizes. */
static OSStatus PropertyDataSize(AudioObjectID object,
                                 const AudioObjectPropertyAddress *address,
                                 UInt32 *size) {
    if (!address || !size || !ValidObject(object)) return kAudioHardwareBadObjectError;
    int deviceIndex = DeviceIndex(object);
    int streamIndex = StreamIndex(object);
    Boolean controlIsVolume = false;
    int controlIndex = ControlIndex(object, &controlIsVolume);
    Boolean global = address->mScope == kAudioObjectPropertyScopeGlobal;
    Boolean output = address->mScope == kAudioObjectPropertyScopeOutput;
    Boolean input = address->mScope == kAudioObjectPropertyScopeInput;

    if (controlIndex >= 0) {
        if (!global || address->mElement != kAudioObjectPropertyElementMain) {
            return kAudioHardwareUnknownPropertyError;
        }
        switch (address->mSelector) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioControlPropertyVariant:
                *size = sizeof(UInt32);
                return noErr;
            case kAudioObjectPropertyName:
                *size = sizeof(CFStringRef);
                return noErr;
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                if (controlIsVolume) {
                    *size = sizeof(Float32);
                    return noErr;
                }
                break;
            case kAudioLevelControlPropertyDecibelRange:
                if (controlIsVolume) {
                    *size = sizeof(AudioValueRange);
                    return noErr;
                }
                break;
            case kAudioBooleanControlPropertyValue:
                if (!controlIsVolume) {
                    *size = sizeof(UInt32);
                    return noErr;
                }
                break;
            case kAudioObjectPropertyControlList:
            case kAudioObjectPropertyOwnedObjects:
                *size = 0;
                return noErr;
            default:
                break;
        }
        return kAudioHardwareUnknownPropertyError;
    }

    if (deviceIndex >= 0 && address->mSelector == kAudioObjectPropertyElementName) {
        UInt32 channels = DeviceChannels(&gDevices[deviceIndex]);
        if ((global && address->mElement == kAudioObjectPropertyElementMain) ||
            (output && address->mElement <= channels)) {
            *size = sizeof(CFStringRef);
            return noErr;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    if (address->mElement != kAudioObjectPropertyElementMain) {
        return kAudioHardwareUnknownPropertyError;
    }
    if (!global && !output && !input) return kAudioHardwareUnknownPropertyError;

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            if (global) {
                *size = sizeof(UInt32);
                return noErr;
            }
            break;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            if (global) {
                *size = sizeof(CFStringRef);
                return noErr;
            }
            break;
        case kAudioObjectPropertyOwnedObjects:
            if (object == kAudioObjectPlugInObject && global) {
                *size = MC_DEVICE_COUNT * sizeof(AudioObjectID);
                return noErr;
            }
            if (deviceIndex >= 0 && (global || output || input)) {
                *size = input ? 0 : sizeof(AudioObjectID);
                return noErr;
            }
            if (streamIndex >= 0 && global) {
                *size = 0;
                return noErr;
            }
            break;
    }

    if (object == kAudioObjectPlugInObject && global) {
        switch (address->mSelector) {
            case kAudioPlugInPropertyBundleID:
            case kAudioPlugInPropertyResourceBundle:
                *size = sizeof(CFStringRef);
                return noErr;
            case kAudioPlugInPropertyBoxList:
                *size = 0;
                return noErr;
            case kAudioPlugInPropertyDeviceList:
                *size = MC_DEVICE_COUNT * sizeof(AudioObjectID);
                return noErr;
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyTranslateUIDToBox:
                *size = sizeof(AudioObjectID);
                return noErr;
            default:
                break;
        }
    }

    if (deviceIndex >= 0) {
        UInt32 channels = DeviceChannels(&gDevices[deviceIndex]);
        switch (address->mSelector) {
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                if (global) {
                    *size = sizeof(CFStringRef);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyRelatedDevices:
                if (global) {
                    *size = sizeof(AudioObjectID);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyStreams:
                if (global || output || input) {
                    *size = input ? 0 : sizeof(AudioObjectID);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyStreamConfiguration:
                if (output) {
                    *size = sizeof(AudioBufferList);
                    return noErr;
                }
                if (input) {
                    *size = 0;
                    return noErr;
                }
                break;
            case kAudioDevicePropertyVolumeScalar:
                if (output) {
                    *size = sizeof(Float32);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyMute:
                if (output) {
                    *size = sizeof(UInt32);
                    return noErr;
                }
                break;
            case kAudioObjectPropertyControlList:
                if (global) {
                    *size = 2 * sizeof(AudioObjectID);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyNominalSampleRate:
                if (global) {
                    *size = sizeof(Float64);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                if (global) {
                    *size = 2 * sizeof(AudioValueRange);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyBufferFrameSizeRange:
                if (global) {
                    *size = sizeof(AudioValueRange);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                if (output) {
                    *size = 2 * sizeof(UInt32);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyPreferredChannelLayout:
                if (output) {
                    *size = PreferredLayoutSize(channels);
                    return noErr;
                }
                break;
            case kAudioObjectPropertyCustomPropertyInfoList:
                if (global) {
                    *size = 3 * sizeof(AudioServerPlugInCustomPropertyInfo);
                    return noErr;
                }
                break;
            case kMCLatencyFrames:
            case kMCLatencyRevision:
            case kMCLatencyStatus:
                if (global) {
                    *size = sizeof(CFNumberRef);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceIsRunningSomewhere:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyBufferFrameSize:
                if (global) {
                    *size = sizeof(UInt32);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (output || input) {
                    *size = sizeof(UInt32);
                    return noErr;
                }
                break;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                if (output || input) {
                    *size = sizeof(UInt32);
                    return noErr;
                }
                break;
            default:
                break;
        }
    }

    if (streamIndex >= 0) {
        if (output && address->mSelector == kAudioStreamPropertyLatency) {
            *size = sizeof(UInt32);
            return noErr;
        }
        if (global) {
            switch (address->mSelector) {
                case kAudioStreamPropertyIsActive:
                case kAudioStreamPropertyDirection:
                case kAudioStreamPropertyTerminalType:
                case kAudioStreamPropertyStartingChannel:
                case kAudioStreamPropertyLatency:
                    *size = sizeof(UInt32);
                    return noErr;
                case kAudioStreamPropertyVirtualFormat:
                case kAudioStreamPropertyPhysicalFormat:
                    *size = sizeof(AudioStreamBasicDescription);
                    return noErr;
                case kAudioStreamPropertyAvailableVirtualFormats:
                case kAudioStreamPropertyAvailablePhysicalFormats:
                    *size = 2 * sizeof(AudioStreamRangedDescription);
                    return noErr;
                default:
                    break;
            }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object,
                           pid_t pid, const AudioObjectPropertyAddress *address) {
    (void)pid;
    UInt32 size;
    return ValidDriver(driver) && PropertyDataSize(object, address, &size) == noErr;
}

static OSStatus IsSettable(AudioServerPlugInDriverRef driver, AudioObjectID object,
                           pid_t pid, const AudioObjectPropertyAddress *address,
                           Boolean *settable) {
    (void)pid;
    UInt32 size;
    if (!ValidDriver(driver) || !settable) return kAudioHardwareBadObjectError;
    OSStatus status = PropertyDataSize(object, address, &size);
    if (status) return status;
    *settable = false;
    Boolean controlIsVolume = false;
    int controlIndex = ControlIndex(object, &controlIsVolume);
    if (controlIndex >= 0) {
        if (controlIsVolume) {
            *settable = address->mSelector == kAudioLevelControlPropertyScalarValue ||
                        address->mSelector == kAudioLevelControlPropertyDecibelValue;
        } else {
            *settable = address->mSelector == kAudioBooleanControlPropertyValue;
        }
    } else if (DeviceIndex(object) >= 0) {
        switch (address->mSelector) {
            case kAudioDevicePropertyVolumeScalar:
            case kAudioDevicePropertyMute:
                *settable = address->mScope == kAudioObjectPropertyScopeOutput;
                break;
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyBufferFrameSize:
            case kMCLatencyFrames:
                *settable = true;
                break;
            default:
                break;
        }
    } else if (StreamIndex(object) >= 0) {
        if (address->mSelector == kAudioStreamPropertyVirtualFormat ||
            address->mSelector == kAudioStreamPropertyPhysicalFormat) {
            *settable = true;
        }
    }
    return noErr;
}

static OSStatus DataSize(AudioServerPlugInDriverRef driver, AudioObjectID object,
                         pid_t pid, const AudioObjectPropertyAddress *address,
                         UInt32 qualifierSize, const void *qualifier, UInt32 *size) {
    (void)pid;
    (void)qualifierSize;
    (void)qualifier;
    if (!ValidDriver(driver)) return kAudioHardwareBadObjectError;
    OSStatus status = PropertyDataSize(object, address, size);
    if (status) PropertyReadFailure(object, address, status);
    return status;
}

static OSStatus GetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                        const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                        const void *qualifier, UInt32 capacity, UInt32 *written,
                        void *data) {
    (void)pid;
    if (!ValidDriver(driver) || !written) return kAudioHardwareBadObjectError;
    *written = 0;
    UInt32 size = 0;
    OSStatus status = PropertyDataSize(object, address, &size);
    if (status) {
        PropertyReadFailure(object, address, status);
        return status;
    }
    if (capacity < size || (size && !data)) return kAudioHardwareBadPropertySizeError;
    if (!size) return noErr;

    int deviceIndex = DeviceIndex(object);
    int streamIndex = StreamIndex(object);
    Boolean controlIsVolume = false;
    int controlIndex = ControlIndex(object, &controlIsVolume);
    UInt32 value = 0;
    CFStringRef string = NULL;

    /* kAudioStreamPropertyLatency and kAudioDevicePropertyLatency share the
     * same 'ltnc' selector; a single switch cannot contain both cases. Resolve
     * by object type: stream latency is the configured budget, device latency
     * remains zero. */
    if (address->mSelector == kAudioStreamPropertyLatency) {
        value = streamIndex >= 0 ? atomic_load(&gState[streamIndex].latency) : 0;
        memcpy(data, &value, size);
        *written = size;
        return noErr;
    }

    if (controlIndex >= 0) {
        MCDeviceState *controlState = &gState[controlIndex];
        Float32 scalar = atomic_load(&controlState->volume);
        switch (address->mSelector) {
            case kAudioObjectPropertyBaseClass:
                value = controlIsVolume ? kAudioLevelControlClassID
                                        : kAudioBooleanControlClassID;
                break;
            case kAudioObjectPropertyClass:
                value = controlIsVolume ? kAudioVolumeControlClassID
                                        : kAudioMuteControlClassID;
                break;
            case kAudioObjectPropertyOwner:
                value = gDevices[controlIndex].deviceID;
                break;
            case kAudioObjectPropertyName: {
                CFStringRef name = controlIsVolume ? CFSTR("Volume") : CFSTR("Mute");
                CFRetain(name);
                memcpy(data, &name, sizeof(name));
                *written = sizeof(name);
                return noErr;
            }
            case kAudioControlPropertyScope:
                value = kAudioObjectPropertyScopeOutput;
                break;
            case kAudioControlPropertyElement:
                value = kAudioObjectPropertyElementMain;
                break;
            case kAudioControlPropertyVariant:
                value = 0;
                break;
            case kAudioLevelControlPropertyScalarValue:
                memcpy(data, &scalar, sizeof(scalar));
                *written = sizeof(scalar);
                return noErr;
            case kAudioLevelControlPropertyDecibelValue: {
                Float32 decibels = MCVolumeToDecibels(scalar);
                memcpy(data, &decibels, sizeof(decibels));
                *written = sizeof(decibels);
                return noErr;
            }
            case kAudioLevelControlPropertyDecibelRange: {
                AudioValueRange range = {kMCVolumeMinDecibels, 0.0f};
                memcpy(data, &range, sizeof(range));
                *written = sizeof(range);
                return noErr;
            }
            case kAudioLevelControlPropertyConvertScalarToDecibels: {
                Float32 input = 0;
                memcpy(&input, data, sizeof(input));
                Float32 decibels = MCVolumeToDecibels(input);
                memcpy(data, &decibels, sizeof(decibels));
                *written = sizeof(decibels);
                return noErr;
            }
            case kAudioLevelControlPropertyConvertDecibelsToScalar: {
                Float32 input = 0;
                memcpy(&input, data, sizeof(input));
                Float32 result = MCDecibelsToVolume(input);
                memcpy(data, &result, sizeof(result));
                *written = sizeof(result);
                return noErr;
            }
            case kAudioBooleanControlPropertyValue:
                value = atomic_load(&controlState->mute);
                break;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
        memcpy(data, &value, size);
        *written = size;
        return noErr;
    }

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            value = kAudioObjectClassID;
            break;
        case kAudioObjectPropertyClass:
            value = object == kAudioObjectPlugInObject
                        ? kAudioPlugInClassID
                        : deviceIndex >= 0 ? kAudioDeviceClassID : kAudioStreamClassID;
            break;
        case kAudioObjectPropertyOwner:
            value = object == kAudioObjectPlugInObject
                        ? kAudioObjectUnknown
                        : deviceIndex >= 0 ? kAudioObjectPlugInObject
                                           : gDevices[streamIndex].deviceID;
            break;
        case kAudioObjectPropertyName:
            if (object == kAudioObjectPlugInObject) {
                string = CFSTR(MC_PLUGIN_NAME);
            } else if (deviceIndex >= 0) {
                string = DeviceNameString(&gDevices[deviceIndex]);
            } else {
                string = StreamNameString(&gDevices[streamIndex]);
            }
            break;
        case kAudioObjectPropertyManufacturer:
            string = CFSTR("HomePod Flow");
            break;
        case kAudioObjectPropertyElementName:
            if (address->mElement == kAudioObjectPropertyElementMain) {
                string = CFSTR("Main");
            } else {
                MCLabel labels[MC_MAX_CHANNELS];
                MCLayoutLabels(gDevices[deviceIndex].layout, labels, NULL);
                string = LabelString(labels[address->mElement - 1]);
            }
            break;
        case kAudioObjectPropertyOwnedObjects:
            if (object == kAudioObjectPlugInObject) {
                AudioObjectID ids[MC_DEVICE_COUNT];
                for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
                    ids[i] = gDevices[i].deviceID;
                }
                memcpy(data, ids, size);
                *written = size;
                return noErr;
            }
            value = gDevices[deviceIndex].streamID;
            break;
        case kAudioPlugInPropertyBundleID:
            string = CFSTR(MC_BUNDLE_ID);
            break;
        case kAudioPlugInPropertyResourceBundle:
            string = CFSTR("");
            break;
        case kAudioPlugInPropertyDeviceList: {
            AudioObjectID ids[MC_DEVICE_COUNT];
            for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
                ids[i] = gDevices[i].deviceID;
            }
            memcpy(data, ids, size);
            *written = size;
            return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToBox:
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) {
                return kAudioHardwareBadPropertySizeError;
            }
            value = kAudioObjectUnknown;
            break;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) {
                return kAudioHardwareBadPropertySizeError;
            }
            CFStringRef requested = *(CFStringRef const *)qualifier;
            value = kAudioObjectUnknown;
            if (requested) {
                for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
                    if (CFEqual(requested, DeviceUIDString(&gDevices[i]))) {
                        value = gDevices[i].deviceID;
                        break;
                    }
                }
            }
            break;
        }
        case kAudioDevicePropertyDeviceUID:
            string = DeviceUIDString(&gDevices[deviceIndex]);
            break;
        case kAudioDevicePropertyModelUID:
            string = DeviceModelUIDString(&gDevices[deviceIndex]);
            break;
        case kAudioDevicePropertyRelatedDevices:
            value = gDevices[deviceIndex].deviceID;
            break;
        case kAudioDevicePropertyStreams:
            value = gDevices[deviceIndex].streamID;
            break;
        case kAudioDevicePropertyStreamConfiguration: {
            AudioBufferList list;
            memset(&list, 0, sizeof(list));
            list.mNumberBuffers = 1;
            list.mBuffers[0].mNumberChannels =
                DeviceChannels(&gDevices[deviceIndex]);
            list.mBuffers[0].mDataByteSize = 0;
            list.mBuffers[0].mData = NULL;
            memcpy(data, &list, size);
            *written = size;
            return noErr;
        }
        case kAudioDevicePropertyTransportType:
            value = kAudioDeviceTransportTypeVirtual;
            break;
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioStreamPropertyIsActive:
            value = 1;
            break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            value = address->mScope == kAudioObjectPropertyScopeOutput;
            break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            value = address->mScope == kAudioObjectPropertyScopeOutput &&
                    gDevices[deviceIndex].systemDefaultEligible;
            break;
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceIsRunningSomewhere:
            value = atomic_load(&gState[deviceIndex].running) > 0;
            break;
        case kAudioObjectPropertyControlList: {
            AudioObjectID controls[2] = {
                (AudioObjectID)(kMCObjectControlVolumeBase + 2 * deviceIndex),
                (AudioObjectID)(kMCObjectControlMuteBase + 2 * deviceIndex)};
            memcpy(data, controls, sizeof(controls));
            *written = sizeof(controls);
            return noErr;
        }
        case kAudioDevicePropertyVolumeScalar: {
            Float32 volume = atomic_load(&gState[deviceIndex].volume);
            memcpy(data, &volume, sizeof(volume));
            *written = sizeof(volume);
            return noErr;
        }
        case kAudioDevicePropertyMute:
            value = atomic_load(&gState[deviceIndex].mute);
            break;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            value = kMCZeroTimeStampPeriod;
            break;
        case kAudioDevicePropertyBufferFrameSize:
            value = 512;
            break;
        case kAudioStreamPropertyDirection:
            value = 0;
            break;
        case kAudioStreamPropertyTerminalType:
            value = kAudioStreamTerminalTypeSpeaker;
            break;
        case kAudioStreamPropertyStartingChannel:
            value = 1;
            break;
        case kMCLatencyFrames: {
            UInt32 frames = atomic_load(&gState[deviceIndex].latency);
            CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type,
                                                &frames);
            if (!number) return kAudioHardwareUnspecifiedError;
            memcpy(data, &number, sizeof(number));
            *written = sizeof(number);
            return noErr;
        }
        case kMCLatencyRevision: {
            SInt64 revision = (SInt64)atomic_load(&gState[deviceIndex].revision);
            CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type,
                                                &revision);
            if (!number) return kAudioHardwareUnspecifiedError;
            memcpy(data, &number, sizeof(number));
            *written = sizeof(number);
            return noErr;
        }
        case kMCLatencyStatus: {
            SInt32 status = (SInt32)PendingStatus(deviceIndex);
            CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type,
                                                &status);
            if (!number) return kAudioHardwareUnspecifiedError;
            memcpy(data, &number, sizeof(number));
            *written = sizeof(number);
            return noErr;
        }
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertySafetyOffset:
            value = 0;
            break;
        case kAudioDevicePropertyIsHidden:
            value = gDevices[deviceIndex].hidden;
            break;
        case kAudioDevicePropertyNominalSampleRate: {
            Float64 rate = atomic_load(&gState[deviceIndex].rate);
            memcpy(data, &rate, sizeof(rate));
            *written = sizeof(rate);
            return noErr;
        }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange ranges[] = {{44100, 44100}, {48000, 48000}};
            memcpy(data, ranges, sizeof(ranges));
            *written = sizeof(ranges);
            return noErr;
        }
        case kAudioDevicePropertyBufferFrameSizeRange: {
            AudioValueRange range = {15, 4096};
            memcpy(data, &range, sizeof(range));
            *written = sizeof(range);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            UInt32 channels[] = {1, gDevices[deviceIndex].layout == MC_LAYOUT_MONO ? 1 : 2};
            memcpy(data, channels, sizeof(channels));
            *written = sizeof(channels);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            MCLayoutStorage storage;
            FillPreferredLayout(&gDevices[deviceIndex], &storage);
            memcpy(data, &storage, size);
            *written = size;
            return noErr;
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo properties[] = {
                {kMCLatencyFrames, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                 kAudioServerPlugInCustomPropertyDataTypeNone},
                {kMCLatencyRevision, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                 kAudioServerPlugInCustomPropertyDataTypeNone},
                {kMCLatencyStatus, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                 kAudioServerPlugInCustomPropertyDataTypeNone}};
            memcpy(data, properties, sizeof(properties));
            *written = sizeof(properties);
            return noErr;
        }
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription format =
                Format(atomic_load(&gState[streamIndex].rate),
                       DeviceChannels(&gDevices[streamIndex]));
            memcpy(data, &format, sizeof(format));
            *written = sizeof(format);
            return noErr;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 channels = DeviceChannels(&gDevices[streamIndex]);
            AudioStreamRangedDescription formats[] = {
                {Format(44100, channels), {44100, 44100}},
                {Format(48000, channels), {48000, 48000}}};
            memcpy(data, formats, sizeof(formats));
            *written = sizeof(formats);
            return noErr;
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }

    if (string) {
        CFRetain(string);
        memcpy(data, &string, size);
    } else {
        memcpy(data, &value, size);
    }
    *written = size;
    return noErr;
}

static OSStatus SetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid,
                        const AudioObjectPropertyAddress *address, UInt32 qualifierSize,
                        const void *qualifier, UInt32 size, const void *data) {
    (void)qualifierSize;
    (void)qualifier;
    Boolean settable = false;
    OSStatus status = IsSettable(driver, object, pid, address, &settable);
    if (status) return status;
    if (!settable) return kAudioHardwareUnknownPropertyError;
    if (!data) return kAudioHardwareBadPropertySizeError;

    int deviceIndex = DeviceIndex(object);
    int streamIndex = StreamIndex(object);
    Boolean controlIsVolume = false;
    int controlIndex = ControlIndex(object, &controlIsVolume);

    if (controlIndex >= 0) {
        MCDeviceState *state = &gState[controlIndex];
        AudioObjectPropertyAddress deviceChange;
        if (controlIsVolume) {
            if (size != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            Float32 volume = 0;
            memcpy(&volume, data, sizeof(volume));
            if (address->mSelector == kAudioLevelControlPropertyDecibelValue) {
                if (!(volume >= kMCVolumeMinDecibels && volume <= 0.0f)) {
                    return kAudioHardwareIllegalOperationError;
                }
                volume = MCDecibelsToVolume(volume);
            } else if (address->mSelector != kAudioLevelControlPropertyScalarValue) {
                return kAudioHardwareUnknownPropertyError;
            }
            if (!(volume >= 0.0f && volume <= 1.0f)) {
                return kAudioHardwareIllegalOperationError;
            }
            /* Idempotent writes must not notify: the app mirrors the control
             * value back into the driver, and a notification per echo would
             * spin the listener loop. */
            if (fabsf(atomic_load(&state->volume) - volume) < 0.000001f) return noErr;
            atomic_store(&state->volume, volume);
            AudioObjectPropertyAddress changes[2] = {
                {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal,
                 kAudioObjectPropertyElementMain},
                {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal,
                 kAudioObjectPropertyElementMain}};
            Notify(object, 2, changes);
            deviceChange = (AudioObjectPropertyAddress){
                kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
                kAudioObjectPropertyElementMain};
        } else {
            if (address->mSelector != kAudioBooleanControlPropertyValue) {
                return kAudioHardwareUnknownPropertyError;
            }
            if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 mute = 0;
            memcpy(&mute, data, sizeof(mute));
            if (mute > 1) return kAudioHardwareIllegalOperationError;
            if (atomic_load(&state->mute) == mute) return noErr;
            atomic_store(&state->mute, mute);
            AudioObjectPropertyAddress change = {
                kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain};
            Notify(object, 1, &change);
            deviceChange = (AudioObjectPropertyAddress){
                kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
                kAudioObjectPropertyElementMain};
        }
        Notify(gDevices[controlIndex].deviceID, 1, &deviceChange);
        return noErr;
    }

    if (address->mSelector == kAudioDevicePropertyBufferFrameSize) {
        if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        UInt32 frames = 0;
        memcpy(&frames, data, sizeof(frames));
        return (frames >= 15 && frames <= 4096) ? noErr
                                                : kAudioHardwareIllegalOperationError;
    }

    if (address->mSelector == kAudioDevicePropertyVolumeScalar) {
        if (size != sizeof(Float32) || deviceIndex < 0) {
            return kAudioHardwareBadPropertySizeError;
        }
        Float32 volume = 0;
        memcpy(&volume, data, sizeof(volume));
        if (!(volume >= 0.0f && volume <= 1.0f)) {
            return kAudioHardwareIllegalOperationError;
        }
        if (fabsf(atomic_load(&gState[deviceIndex].volume) - volume) < 0.000001f) {
            return noErr;
        }
        atomic_store(&gState[deviceIndex].volume, volume);
        AudioObjectPropertyAddress changed = {
            kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain};
        Notify(object, 1, &changed);
        AudioObjectID volumeControl =
            (AudioObjectID)(kMCObjectControlVolumeBase + 2 * deviceIndex);
        AudioObjectPropertyAddress controlChanges[2] = {
            {kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal,
             kAudioObjectPropertyElementMain},
            {kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal,
             kAudioObjectPropertyElementMain}};
        Notify(volumeControl, 2, controlChanges);
        return noErr;
    }

    if (address->mSelector == kAudioDevicePropertyMute) {
        if (size != sizeof(UInt32) || deviceIndex < 0) {
            return kAudioHardwareBadPropertySizeError;
        }
        UInt32 mute = 0;
        memcpy(&mute, data, sizeof(mute));
        if (mute > 1) return kAudioHardwareIllegalOperationError;
        if (atomic_load(&gState[deviceIndex].mute) == mute) return noErr;
        atomic_store(&gState[deviceIndex].mute, mute);
        AudioObjectPropertyAddress changed = {
            kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain};
        Notify(object, 1, &changed);
        AudioObjectID muteControl =
            (AudioObjectID)(kMCObjectControlMuteBase + 2 * deviceIndex);
        AudioObjectPropertyAddress controlChange = {
            kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        Notify(muteControl, 1, &controlChange);
        return noErr;
    }

    if (address->mSelector == kMCLatencyFrames) {
        CFPropertyListRef property = NULL;
        if (size != sizeof(property)) return kAudioHardwareBadPropertySizeError;
        memcpy(&property, data, sizeof(property));
        if (!property || CFGetTypeID(property) != CFNumberGetTypeID()) {
            return kAudioHardwareBadPropertySizeError;
        }
        SInt64 raw = 0;
        if (!CFNumberGetValue((CFNumberRef)property, kCFNumberSInt64Type, &raw) ||
            raw < 0 || raw > UINT32_MAX) {
            return kAudioHardwareIllegalOperationError;
        }
        UInt32 frames = (UInt32)raw;
        MCDeviceState *state = &gState[deviceIndex];
        if (frames > 10 * atomic_load(&state->rate)) {
            return kAudioHardwareIllegalOperationError;
        }
        /* Defer the commit: the host owns the configuration transaction and
         * the value must not be published until PerformChange runs. */
        return RequestConfigurationChange(
            gDevices[deviceIndex].deviceID, deviceIndex, MCPendingLatency, 0, frames);
    }

    Float64 rate = 0;
    if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(rate)) return kAudioHardwareBadPropertySizeError;
        memcpy(&rate, data, sizeof(rate));
    } else if (streamIndex >= 0 &&
               (address->mSelector == kAudioStreamPropertyVirtualFormat ||
                address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription)) {
            return kAudioHardwareBadPropertySizeError;
        }
        AudioStreamBasicDescription format;
        memcpy(&format, data, sizeof(format));
        if (!ValidFormatForDevice(&gDevices[streamIndex], &format)) {
            /* A 2ch ASBD on a 6ch/8ch stream is rejected here; it is never
             * accepted and then described as a wider native source. */
            return kAudioDeviceUnsupportedFormatError;
        }
        rate = format.mSampleRate;
    } else {
        return kAudioHardwareUnknownPropertyError;
    }
    int index = deviceIndex >= 0 ? deviceIndex : streamIndex;
    return RequestConfigurationChange(gDevices[index].deviceID, index,
                                      MCPendingRate, rate, 0);
}

static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client) {
    int index = DeviceIndex(object);
    if (!ValidDriver(driver) || index < 0) return kAudioHardwareBadObjectError;
    MCDeviceState *state = &gState[index];
    pthread_mutex_lock(&gControl);
    int freeSlot = -1;
    for (int i = 0; i < 64; ++i) {
        if (state->clientSlotUsed[i] && state->runningClients[i] == client) {
            pthread_mutex_unlock(&gControl);
            return kAudioHardwareIllegalOperationError;
        }
        if (!state->clientSlotUsed[i]) freeSlot = i;
    }
    if (state->pendingKind != MCPendingNone || freeSlot < 0) {
        pthread_mutex_unlock(&gControl);
        return kAudioHardwareIllegalOperationError;
    }
    if (!atomic_load(&state->running)) ResetClock(index);
    state->clientSlotUsed[freeSlot] = true;
    state->runningClients[freeSlot] = client;
    atomic_fetch_add(&state->running, 1);
    pthread_mutex_unlock(&gControl);
    AudioObjectPropertyAddress address = Global(kAudioDevicePropertyDeviceIsRunning);
    Notify(object, 1, &address);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client) {
    int index = DeviceIndex(object);
    if (!ValidDriver(driver) || index < 0) return kAudioHardwareBadObjectError;
    MCDeviceState *state = &gState[index];
    pthread_mutex_lock(&gControl);
    int slot = -1;
    for (int i = 0; i < 64; ++i) {
        if (state->clientSlotUsed[i] && state->runningClients[i] == client) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        pthread_mutex_unlock(&gControl);
        return kAudioHardwareIllegalOperationError;
    }
    state->clientSlotUsed[slot] = false;
    atomic_fetch_sub(&state->running, 1);
    pthread_mutex_unlock(&gControl);
    AudioObjectPropertyAddress address = Global(kAudioDevicePropertyDeviceIsRunning);
    Notify(object, 1, &address);
    return noErr;
}

static OSStatus ZeroTime(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client,
                         Float64 *sample, UInt64 *host, UInt64 *seed) {
    (void)client;
    int index = DeviceIndex(object);
    if (!ValidDriver(driver) || index < 0 || !sample || !host || !seed) {
        return kAudioHardwareBadObjectError;
    }
    MCDeviceState *state = &gState[index];
    for (int attempt = 0; attempt < 8; ++attempt) {
        UInt64 sequence = atomic_load_explicit(&state->clockSequence, memory_order_acquire);
        if (sequence & 1) continue;
        UInt64 anchor = atomic_load_explicit(&state->anchor, memory_order_relaxed);
        UInt64 epoch = atomic_load_explicit(&state->seed, memory_order_relaxed);
        UInt32 rate = atomic_load_explicit(&state->rate, memory_order_relaxed);
        UInt64 now = mach_absolute_time();
        if (sequence != atomic_load_explicit(&state->clockSequence, memory_order_acquire)) {
            continue;
        }
        if (!gTimebase.numer || !gTimebase.denom || now < anchor) {
            return kAudioHardwareNotReadyError;
        }
        __uint128_t elapsed = (__uint128_t)(now - anchor) * gTimebase.numer * rate;
        __uint128_t periodWide =
            elapsed /
            ((__uint128_t)gTimebase.denom * 1000000000ULL * kMCZeroTimeStampPeriod);
        if (periodWide > UINT64_MAX / kMCZeroTimeStampPeriod) {
            return kAudioHardwareIllegalOperationError;
        }
        UInt64 period = (UInt64)periodWide;
        UInt64 frames = period * kMCZeroTimeStampPeriod;
        __uint128_t ticksWide =
            (__uint128_t)frames * 1000000000ULL * gTimebase.denom /
            ((__uint128_t)rate * gTimebase.numer);
        if (ticksWide > UINT64_MAX - anchor) {
            return kAudioHardwareIllegalOperationError;
        }
        UInt64 ticks = (UInt64)ticksWide;
        *sample = (Float64)frames;
        *host = anchor + ticks;
        *seed = epoch;
        return noErr;
    }
    return kAudioHardwareNotReadyError;
}

static OSStatus WillIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client,
                       UInt32 operation, Boolean *will, Boolean *inPlace) {
    (void)client;
    int deviceIndex = DeviceIndex(object);
    if (!ValidDriver(driver) || deviceIndex < 0 || !will || !inPlace) {
        return kAudioHardwareBadObjectError;
    }
    *will = operation == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = *will;
    return noErr;
}

static OSStatus BeginIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client,
                        UInt32 operation, UInt32 frames,
                        const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client;
    (void)operation;
    (void)frames;
    (void)cycle;
    return ValidDriver(driver) && DeviceIndex(object) >= 0
               ? noErr
               : kAudioHardwareBadObjectError;
}

static OSStatus DoIO(AudioServerPlugInDriverRef driver, AudioObjectID object,
                     AudioObjectID stream, UInt32 client, UInt32 operation, UInt32 frames,
                     const AudioServerPlugInIOCycleInfo *cycle, void *main,
                     void *secondary) {
    (void)client;
    (void)cycle;
    (void)secondary;
    int deviceIndex = DeviceIndex(object);
    if (!ValidDriver(driver) || deviceIndex < 0 || stream != gDevices[deviceIndex].streamID) {
        return kAudioHardwareBadObjectError;
    }
    if (operation != kAudioServerPlugInIOOperationWriteMix) {
        return kAudioHardwareUnsupportedOperationError;
    }
    if (frames && !main) return kAudioHardwareIllegalOperationError;
    /* Consume no data and never rewrite the caller's PCM buffer. */
    return noErr;
}
