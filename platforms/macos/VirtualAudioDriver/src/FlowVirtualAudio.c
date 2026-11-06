/* Original implementation of Apple's public AudioServerPlugIn ABI.
 * No PCM queue, allocation, locks, IPC, network, or file access in IO callbacks.
 * WriteMix is a sink; obtaining its actual PCM through a device Tap is a separate
 * integration gate. Merely loading this driver does not forward any audio.
 */
#include "FlowVirtualAudio.h"
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreAudio/AudioHardware.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <stddef.h>
#include <os/log.h>

static AudioServerPlugInHostRef gHost;
static pthread_mutex_t gControl = PTHREAD_MUTEX_INITIALIZER;
static _Atomic UInt32 gReferences = 1;
static _Atomic UInt32 gRunning = 0;
static _Atomic UInt32 gRate = 48000;
static _Atomic UInt32 gLatency = 0;
static _Atomic UInt64 gRevision = 1;
static _Atomic UInt64 gClockSequence = 0;
static _Atomic UInt64 gAnchor = 0;
static _Atomic UInt64 gSeed = 1;
static mach_timebase_info_data_t gTimebase;
static Float64 gPendingRate;
static Boolean gRatePending;
static UInt32 gLatencyBudgetFrames = 0, gLatencyBudgetRate = 48000;
static UInt32 gRunningClients[64];
static Boolean gClientSlotUsed[64];
static _Atomic UInt32 gPropertyErrorLogs;

static HRESULT QueryInterface(void *, REFIID, LPVOID *);
static ULONG AddRef(void *);
static ULONG Release(void *);
static OSStatus Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo *, AudioObjectID *);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus Client(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo *);
static OSStatus PerformChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static OSStatus AbortChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void *);
static Boolean HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *);
static OSStatus IsSettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, Boolean *);
static OSStatus DataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
static OSStatus GetData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, UInt32 *, void *);
static OSStatus SetData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32, const void *);
static OSStatus StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus ZeroTime(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64 *, UInt64 *, UInt64 *);
static OSStatus WillIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean *, Boolean *);
static OSStatus BeginIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *);
static OSStatus DoIO(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo *, void *, void *);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice,
    Client, Client, PerformChange, AbortChange, HasProperty, IsSettable, DataSize,
    GetData, SetData, StartIO, StopIO, ZeroTime, WillIO, BeginIO, DoIO, BeginIO
};
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef Driver(void) { return &gInterfacePointer; }
static Boolean ValidDriver(AudioServerPlugInDriverRef driver) { return driver == Driver(); }
static Boolean ValidObject(AudioObjectID object) {
    return object == kAudioObjectPlugInObject || object == kFlowObjectDevice || object == kFlowObjectOutputStream;
}
static AudioObjectPropertyAddress Global(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}
/* Control-plane diagnostics only. Never called by the realtime IO callbacks. */
static void PropertyReadFailure(AudioObjectID object, const AudioObjectPropertyAddress *address, OSStatus status) {
    if (!address) return;
    UInt32 count=atomic_load(&gPropertyErrorLogs);
    while (count < 32 && !atomic_compare_exchange_weak(&gPropertyErrorLogs,&count,count+1)) {}
    if (count >= 32) return;
    os_log_error(OS_LOG_DEFAULT,
        "HomePodFlowAudio property read rejected object=%{public}u selector=%{public}u scope=%{public}u element=%{public}u status=%{public}d",
        object,address->mSelector,address->mScope,address->mElement,(int)status);
}
static void Notify(AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    if (gHost) gHost->PropertiesChanged(gHost, object, count, addresses);
}
void *FlowVirtualAudioFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    (void)allocator;
    return type && CFEqual(type, kAudioServerPlugInTypeUUID) ? Driver() : NULL;
}
static HRESULT QueryInterface(void *driver, REFIID iid, LPVOID *result) {
    if (!result) return E_POINTER;
    *result = NULL;
    if (!ValidDriver(driver)) return E_NOINTERFACE;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean supported = uuid && (CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID));
    if (uuid) CFRelease(uuid);
    if (!supported) return E_NOINTERFACE;
    AddRef(driver); *result = Driver(); return S_OK;
}
static ULONG AddRef(void *driver) {
    if (!ValidDriver(driver)) return 0;
    return atomic_fetch_add(&gReferences, 1) + 1;
}
static ULONG Release(void *driver) {
    if (!ValidDriver(driver)) return 0;
    UInt32 old = atomic_load(&gReferences);
    while (old > 1 && !atomic_compare_exchange_weak(&gReferences, &old, old - 1)) {}
    return old > 1 ? old - 1 : 1; /* Static singleton remains alive for server lifetime. */
}
static OSStatus Initialize(AudioServerPlugInDriverRef driver, AudioServerPlugInHostRef host) {
    if (!ValidDriver(driver) || !host) return kAudioHardwareBadObjectError;
    if (!atomic_is_lock_free(&gAnchor) || !atomic_is_lock_free(&gClockSequence) || !atomic_is_lock_free(&gRate))
        return kAudioHardwareUnsupportedOperationError;
    if (mach_timebase_info(&gTimebase) != KERN_SUCCESS || !gTimebase.numer || !gTimebase.denom)
        return kAudioHardwareUnspecifiedError;
    gHost = host; atomic_store(&gAnchor, mach_absolute_time()); return noErr;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef driver, CFDictionaryRef properties, const AudioServerPlugInClientInfo *client, AudioObjectID *object) {
    (void)driver; (void)properties; (void)client; if (object) *object = kAudioObjectUnknown;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef driver, AudioObjectID object) {
    (void)driver; (void)object; return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Client(AudioServerPlugInDriverRef driver, AudioObjectID object, const AudioServerPlugInClientInfo *client) {
    return ValidDriver(driver) && object == kFlowObjectDevice && client ? noErr : kAudioHardwareBadObjectError;
}
static AudioStreamBasicDescription Format(UInt32 rate) {
    return (AudioStreamBasicDescription){rate, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        8, 1, 8, 2, 32, 0};
}
static Boolean ValidFormat(const AudioStreamBasicDescription *format) {
    if (format->mSampleRate != 44100 && format->mSampleRate != 48000) return false;
    AudioStreamBasicDescription wanted = Format((UInt32)format->mSampleRate);
    return format->mFormatID == wanted.mFormatID && format->mFormatFlags == wanted.mFormatFlags
        && format->mBytesPerPacket == 8 && format->mFramesPerPacket == 1
        && format->mBytesPerFrame == 8 && format->mChannelsPerFrame == 2 && format->mBitsPerChannel == 32;
}
static void ResetClock(void) {
    atomic_fetch_add_explicit(&gClockSequence, 1, memory_order_acq_rel);
    atomic_store_explicit(&gAnchor, mach_absolute_time(), memory_order_relaxed);
    atomic_fetch_add_explicit(&gSeed, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&gClockSequence, 1, memory_order_release);
}
static OSStatus PerformChange(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt64 action, void *info) {
    (void)info;
    if (!ValidDriver(driver) || object != kFlowObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gControl);
    if (!gRatePending || action != (UInt64)gPendingRate || atomic_load(&gRunning)) {
        pthread_mutex_unlock(&gControl); return kAudioHardwareIllegalOperationError;
    }
    UInt32 rate = (UInt32)gPendingRate;
    UInt32 latency = (UInt32)(((UInt64)gLatencyBudgetFrames * rate + gLatencyBudgetRate / 2) / gLatencyBudgetRate);
    atomic_fetch_add(&gClockSequence, 1);
    atomic_store(&gRate, rate); atomic_store(&gLatency, latency);
    atomic_store(&gAnchor, mach_absolute_time()); atomic_fetch_add(&gSeed, 1);
    atomic_fetch_add(&gClockSequence, 1); atomic_fetch_add(&gRevision, 1); gRatePending = false;
    pthread_mutex_unlock(&gControl);
    AudioObjectPropertyAddress device[] = {Global(kAudioDevicePropertyNominalSampleRate), Global(kFlowLatencyFrames), Global(kFlowLatencyRevision)};
    AudioObjectPropertyAddress stream[] = {Global(kAudioStreamPropertyVirtualFormat), Global(kAudioStreamPropertyPhysicalFormat), Global(kAudioStreamPropertyLatency),
        {kAudioStreamPropertyLatency,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain}};
    Notify(kFlowObjectDevice, 3, device); Notify(kFlowObjectOutputStream, 4, stream); return noErr;
}
static OSStatus AbortChange(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt64 action, void *info) {
    (void)info;
    if (!ValidDriver(driver) || object != kFlowObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gControl); if (gRatePending && action == (UInt64)gPendingRate) gRatePending = false;
    pthread_mutex_unlock(&gControl); return noErr;
}

/* Property table is the single source of truth for HasProperty and size queries. */
static OSStatus PropertyDataSize(AudioObjectID object, const AudioObjectPropertyAddress *a, UInt32 *size) {
    if (!a || !size || !ValidObject(object)) return kAudioHardwareBadObjectError;
    if (object == kFlowObjectDevice && a->mSelector == kAudioObjectPropertyElementName) {
        if ((a->mScope == kAudioObjectPropertyScopeGlobal && a->mElement == kAudioObjectPropertyElementMain)
            || (a->mScope == kAudioObjectPropertyScopeOutput && a->mElement <= 2)) {
            *size=sizeof(CFStringRef); return noErr;
        }
        return kAudioHardwareUnknownPropertyError;
    }
    if (a->mElement != kAudioObjectPropertyElementMain) return kAudioHardwareUnknownPropertyError;
    Boolean global = a->mScope == kAudioObjectPropertyScopeGlobal;
    Boolean output = a->mScope == kAudioObjectPropertyScopeOutput;
    Boolean input = a->mScope == kAudioObjectPropertyScopeInput;
    if (!global && !output && !input) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
            if (global) { *size = sizeof(UInt32); return noErr; } break;
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer:
            if (global) { *size = sizeof(CFStringRef); return noErr; } break;
        case kAudioObjectPropertyOwnedObjects:
            if (global || (object == kFlowObjectDevice && (input || output))) {
                *size = object == kFlowObjectOutputStream || (object == kFlowObjectDevice && input) ? 0 : sizeof(AudioObjectID);
                return noErr;
            } break;
    }
    if (object == kAudioObjectPlugInObject && global) {
        switch (a->mSelector) {
            case kAudioPlugInPropertyBundleID: case kAudioPlugInPropertyResourceBundle:
                *size = sizeof(CFStringRef); return noErr;
            case kAudioPlugInPropertyBoxList: *size = 0; return noErr;
            case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyTranslateUIDToBox: *size = sizeof(AudioObjectID); return noErr;
        }
    }
    if (object == kFlowObjectDevice) {
        switch (a->mSelector) {
            case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID:
                if (global) { *size = sizeof(CFStringRef); return noErr; } break;
            case kAudioDevicePropertyRelatedDevices:
                if (global) { *size = sizeof(AudioObjectID); return noErr; } break;
            case kAudioDevicePropertyStreams:
                if (global || output || input) { *size = input ? 0 : sizeof(AudioObjectID); return noErr; } break;
            case kAudioObjectPropertyControlList:
                if (global) { *size = 0; return noErr; } break;
            case kAudioDevicePropertyNominalSampleRate:
                if (global) { *size = sizeof(Float64); return noErr; } break;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                if (global) { *size = 2 * sizeof(AudioValueRange); return noErr; } break;
            case kAudioDevicePropertyBufferFrameSizeRange:
                if (global) { *size = sizeof(AudioValueRange); return noErr; } break;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                if (output) { *size = 2 * sizeof(UInt32); return noErr; } break;
            case kAudioDevicePropertyPreferredChannelLayout:
                if (output) { *size = offsetof(AudioChannelLayout, mChannelDescriptions); return noErr; } break;
            case kAudioObjectPropertyCustomPropertyInfoList:
                if (global) { *size = 2 * sizeof(AudioServerPlugInCustomPropertyInfo); return noErr; } break;
            case kFlowLatencyRevision:
                if (global) { *size = sizeof(UInt64); return noErr; } break;
            case kFlowLatencyFrames: case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceIsRunningSomewhere:
            case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyBufferFrameSize:
                if (global) { *size = sizeof(UInt32); return noErr; } break;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (output || input) { *size = sizeof(UInt32); return noErr; } break;
            case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset:
                if (output || input) { *size = sizeof(UInt32); return noErr; } break;
        }
    }
    if (object == kFlowObjectOutputStream && output && a->mSelector == kAudioStreamPropertyLatency) {
        *size = sizeof(UInt32); return noErr;
    }
    if (object == kFlowObjectOutputStream && global) {
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency: *size = sizeof(UInt32); return noErr;
            case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
                *size = sizeof(AudioStreamBasicDescription); return noErr;
            case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
                *size = 2 * sizeof(AudioStreamRangedDescription); return noErr;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}
static Boolean HasProperty(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a) {
    (void)pid; UInt32 size; return ValidDriver(driver) && PropertyDataSize(object, a, &size) == noErr;
}
static OSStatus IsSettable(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *settable) {
    (void)pid; UInt32 size;
    if (!ValidDriver(driver) || !settable) return kAudioHardwareBadObjectError;
    OSStatus status = PropertyDataSize(object, a, &size); if (status) return status;
    *settable = (object == kFlowObjectDevice && (a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == kFlowLatencyFrames || a->mSelector == kAudioDevicePropertyBufferFrameSize))
        || (object == kFlowObjectOutputStream && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat));
    return noErr;
}
static OSStatus DataSize(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier, UInt32 *size) {
    (void)pid; (void)qualifierSize; (void)qualifier;
    if (!ValidDriver(driver)) return kAudioHardwareBadObjectError;
    OSStatus status=PropertyDataSize(object,a,size);
    if (status) PropertyReadFailure(object,a,status);
    return status;
}
static OSStatus GetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier, UInt32 capacity, UInt32 *written, void *data) {
    (void)pid;
    if (!ValidDriver(driver) || !written) return kAudioHardwareBadObjectError;
    *written = 0; UInt32 size; OSStatus status = PropertyDataSize(object, a, &size);
    if (status) { PropertyReadFailure(object,a,status); return status; }
    if (capacity < size || (size && !data)) return kAudioHardwareBadPropertySizeError;
    if (!size) return noErr;
    UInt32 u = 0; CFStringRef string = NULL;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: u = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass: u = object == kAudioObjectPlugInObject ? kAudioPlugInClassID : object == kFlowObjectDevice ? kAudioDeviceClassID : kAudioStreamClassID; break;
        case kAudioObjectPropertyOwner: u = object == kAudioObjectPlugInObject ? kAudioObjectUnknown : object == kFlowObjectDevice ? kAudioObjectPlugInObject : kFlowObjectDevice; break;
        case kAudioObjectPropertyName: string = object == kAudioObjectPlugInObject ? CFSTR("HomePod Flow Audio Plug-in") : object == kFlowObjectDevice ? CFSTR("HomePod Flow Audio") : CFSTR("HomePod Flow Stereo Output"); break;
        case kAudioObjectPropertyManufacturer: string = CFSTR("HomePod Flow"); break;
        case kAudioObjectPropertyElementName:
            string = a->mElement == 1 ? CFSTR("Left") : a->mElement == 2 ? CFSTR("Right") : CFSTR("Main"); break;
        case kAudioPlugInPropertyBundleID: string = CFSTR(FLOW_BUNDLE_ID); break;
        case kAudioPlugInPropertyResourceBundle: string = CFSTR(""); break;
        case kAudioDevicePropertyDeviceUID: string = CFSTR(FLOW_DEVICE_UID); break;
        case kAudioDevicePropertyModelUID: string = CFSTR(FLOW_MODEL_UID); break;
        case kAudioObjectPropertyOwnedObjects: u = object == kAudioObjectPlugInObject ? kFlowObjectDevice : kFlowObjectOutputStream; break;
        case kAudioPlugInPropertyDeviceList: u = kFlowObjectDevice; break;
        case kAudioDevicePropertyRelatedDevices: u = kFlowObjectDevice; break;
        case kAudioPlugInPropertyTranslateUIDToBox:
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            u = kAudioObjectUnknown; break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            u = *(CFStringRef const *)qualifier && CFEqual(*(CFStringRef const *)qualifier, CFSTR(FLOW_DEVICE_UID)) ? kFlowObjectDevice : kAudioObjectUnknown; break;
        case kAudioDevicePropertyStreams: u = kFlowObjectOutputStream; break;
        case kAudioDevicePropertyTransportType: u = kAudioDeviceTransportTypeVirtual; break;
        case kAudioDevicePropertyDeviceIsAlive: case kAudioStreamPropertyIsActive: u = 1; break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: u = a->mScope == kAudioObjectPropertyScopeOutput; break;
        case kAudioDevicePropertyDeviceIsRunning: case kAudioDevicePropertyDeviceIsRunningSomewhere: u = atomic_load(&gRunning) > 0; break;
        case kAudioDevicePropertyZeroTimeStampPeriod: u = kFlowZeroTimeStampPeriod; break;
        case kAudioDevicePropertyBufferFrameSize: u = 512; break;
        case kAudioStreamPropertyDirection: u = 0; break;
        case kAudioStreamPropertyTerminalType: u = kAudioStreamTerminalTypeSpeaker; break;
        case kAudioStreamPropertyStartingChannel: u = 1; break;
        case kAudioStreamPropertyLatency: u = object == kFlowObjectOutputStream ? atomic_load(&gLatency) : 0; break;
        case kFlowLatencyFrames: u = atomic_load(&gLatency); break;
        case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertySafetyOffset: u = 0; break;
        case kFlowLatencyRevision: { UInt64 revision = atomic_load(&gRevision); memcpy(data, &revision, size); *written = size; return noErr; }
        case kAudioDevicePropertyNominalSampleRate: { Float64 rate = atomic_load(&gRate); memcpy(data, &rate, size); *written = size; return noErr; }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange ranges[] = {{44100,44100},{48000,48000}}; memcpy(data,ranges,size); *written=size; return noErr;
        }
        case kAudioDevicePropertyBufferFrameSizeRange: {
            AudioValueRange range = {512,512}; memcpy(data,&range,size); *written=size; return noErr;
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: { UInt32 channels[] = {1,2}; memcpy(data,channels,size); *written=size; return noErr; }
        case kAudioDevicePropertyPreferredChannelLayout: {
            AudioChannelLayout layout = {.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo}; memcpy(data,&layout,size); *written=size; return noErr;
        }
        case kAudioObjectPropertyCustomPropertyInfoList: {
            AudioServerPlugInCustomPropertyInfo properties[] = {
                {kFlowLatencyFrames,kAudioServerPlugInCustomPropertyDataTypeNone,kAudioServerPlugInCustomPropertyDataTypeNone},
                {kFlowLatencyRevision,kAudioServerPlugInCustomPropertyDataTypeNone,kAudioServerPlugInCustomPropertyDataTypeNone}
            }; memcpy(data,properties,size); *written=size; return noErr;
        }
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription format = Format(atomic_load(&gRate)); memcpy(data,&format,size); *written=size; return noErr;
        }
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription formats[] = {{Format(44100),{44100,44100}},{Format(48000),{48000,48000}}};
            memcpy(data,formats,size); *written=size; return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
    if (string) { CFRetain(string); memcpy(data,&string,size); } else memcpy(data,&u,size);
    *written=size; return noErr;
}
static OSStatus SetData(AudioServerPlugInDriverRef driver, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    (void)qualifierSize; (void)qualifier; Boolean settable;
    OSStatus status = IsSettable(driver,object,pid,a,&settable); if (status) return status;
    if (!settable) return kAudioHardwareUnknownPropertyError;
    if (!data) return kAudioHardwareBadPropertySizeError;
    if (a->mSelector == kAudioDevicePropertyBufferFrameSize) {
        UInt32 frames;
        if (size != sizeof(frames)) return kAudioHardwareBadPropertySizeError;
        memcpy(&frames,data,sizeof(frames));
        return frames == 512 ? noErr : kAudioHardwareIllegalOperationError;
    }
    if (a->mSelector == kFlowLatencyFrames) {
        if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        UInt32 frames; memcpy(&frames,data,sizeof(frames));
        pthread_mutex_lock(&gControl);
        if (atomic_load(&gRunning) || gRatePending || frames > 10 * atomic_load(&gRate)) {
            pthread_mutex_unlock(&gControl); return kAudioHardwareIllegalOperationError;
        }
        Boolean changed = frames != atomic_load(&gLatency);
        if (changed) {
            atomic_store(&gLatency,frames); atomic_fetch_add(&gRevision,1);
            gLatencyBudgetFrames=frames; gLatencyBudgetRate=atomic_load(&gRate);
        }
        pthread_mutex_unlock(&gControl);
        if (changed) {
            AudioObjectPropertyAddress stream[] = {Global(kAudioStreamPropertyLatency),
                {kAudioStreamPropertyLatency,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain}};
            AudioObjectPropertyAddress device[] = {Global(kFlowLatencyFrames),Global(kFlowLatencyRevision)};
            Notify(kFlowObjectOutputStream,2,stream); Notify(kFlowObjectDevice,2,device);
        }
        return noErr;
    }
    Float64 rate;
    if (a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(rate)) return kAudioHardwareBadPropertySizeError; memcpy(&rate,data,sizeof(rate));
    } else {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        AudioStreamBasicDescription format; memcpy(&format,data,sizeof(format));
        if (!ValidFormat(&format)) return kAudioDeviceUnsupportedFormatError; rate = format.mSampleRate;
    }
    if (rate != 44100 && rate != 48000) return kAudioDeviceUnsupportedFormatError;
    pthread_mutex_lock(&gControl);
    if (atomic_load(&gRunning) || gRatePending) { pthread_mutex_unlock(&gControl); return kAudioHardwareIllegalOperationError; }
    if (rate == atomic_load(&gRate)) { pthread_mutex_unlock(&gControl); return noErr; }
    gPendingRate=rate; gRatePending=true; pthread_mutex_unlock(&gControl);
    if (!gHost) { AbortChange(driver,kFlowObjectDevice,(UInt64)rate,NULL); return kAudioHardwareNotReadyError; }
    status = gHost->RequestDeviceConfigurationChange(gHost,kFlowObjectDevice,(UInt64)rate,NULL);
    if (status) AbortChange(driver,kFlowObjectDevice,(UInt64)rate,NULL);
    return status;
}
static OSStatus StartIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client) {
    if (!ValidDriver(driver) || object != kFlowObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gControl);
    int freeSlot=-1;
    for (int i=0;i<64;++i) {
        if (gClientSlotUsed[i] && gRunningClients[i]==client) { pthread_mutex_unlock(&gControl); return kAudioHardwareIllegalOperationError; }
        if (!gClientSlotUsed[i]) freeSlot=i;
    }
    if (gRatePending || freeSlot<0) { pthread_mutex_unlock(&gControl); return kAudioHardwareIllegalOperationError; }
    if (!atomic_load(&gRunning)) ResetClock();
    gClientSlotUsed[freeSlot]=true; gRunningClients[freeSlot]=client;
    atomic_fetch_add(&gRunning,1); pthread_mutex_unlock(&gControl);
    AudioObjectPropertyAddress a = Global(kAudioDevicePropertyDeviceIsRunning); Notify(object,1,&a); return noErr;
}
static OSStatus StopIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client) {
    if (!ValidDriver(driver) || object != kFlowObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gControl);
    int slot=-1;
    for(int i=0;i<64;++i) if(gClientSlotUsed[i] && gRunningClients[i]==client) { slot=i; break; }
    if (slot<0) { pthread_mutex_unlock(&gControl); return kAudioHardwareIllegalOperationError; }
    gClientSlotUsed[slot]=false;
    atomic_fetch_sub(&gRunning,1); pthread_mutex_unlock(&gControl);
    AudioObjectPropertyAddress a = Global(kAudioDevicePropertyDeviceIsRunning); Notify(object,1,&a); return noErr;
}
static OSStatus ZeroTime(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client, Float64 *sample, UInt64 *host, UInt64 *seed) {
    (void)client;
    if (!ValidDriver(driver) || object != kFlowObjectDevice || !sample || !host || !seed) return kAudioHardwareBadObjectError;
    for (int attempt=0; attempt<8; ++attempt) {
        UInt64 sequence=atomic_load_explicit(&gClockSequence,memory_order_acquire); if (sequence & 1) continue;
        UInt64 anchor=atomic_load_explicit(&gAnchor,memory_order_relaxed), epoch=atomic_load_explicit(&gSeed,memory_order_relaxed);
        UInt32 rate=atomic_load_explicit(&gRate,memory_order_relaxed); UInt64 now=mach_absolute_time();
        if (sequence != atomic_load_explicit(&gClockSequence,memory_order_acquire)) continue;
        if (!gTimebase.numer || !gTimebase.denom || now < anchor) return kAudioHardwareNotReadyError;
        __uint128_t elapsed=(__uint128_t)(now-anchor)*gTimebase.numer*rate;
        __uint128_t periodWide=elapsed/((__uint128_t)gTimebase.denom*1000000000ULL*kFlowZeroTimeStampPeriod);
        if (periodWide > UINT64_MAX / kFlowZeroTimeStampPeriod) return kAudioHardwareIllegalOperationError;
        UInt64 period=(UInt64)periodWide;
        UInt64 frames=period*kFlowZeroTimeStampPeriod;
        __uint128_t ticksWide=(__uint128_t)frames*1000000000ULL*gTimebase.denom/((__uint128_t)rate*gTimebase.numer);
        if (ticksWide > UINT64_MAX - anchor) return kAudioHardwareIllegalOperationError;
        UInt64 ticks=(UInt64)ticksWide;
        *sample=(Float64)frames; *host=anchor+ticks; *seed=epoch; return noErr;
    }
    return kAudioHardwareNotReadyError;
}
static OSStatus WillIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client, UInt32 operation, Boolean *will, Boolean *inPlace) {
    (void)client;
    if (!ValidDriver(driver) || object != kFlowObjectDevice || !will || !inPlace) return kAudioHardwareBadObjectError;
    *will=operation == kAudioServerPlugInIOOperationWriteMix; *inPlace=true; return noErr;
}
static OSStatus BeginIO(AudioServerPlugInDriverRef driver, AudioObjectID object, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client; (void)operation; (void)frames; (void)cycle;
    return ValidDriver(driver) && object == kFlowObjectDevice ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus DoIO(AudioServerPlugInDriverRef driver, AudioObjectID object, AudioObjectID stream, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    (void)client; (void)cycle; (void)secondary;
    if (!ValidDriver(driver) || object != kFlowObjectDevice || stream != kFlowObjectOutputStream) return kAudioHardwareBadObjectError;
    if (operation != kAudioServerPlugInIOOperationWriteMix) return kAudioHardwareUnsupportedOperationError;
    if (frames && !main) return kAudioHardwareIllegalOperationError;
    /* Intentionally consumes no data. Tap visibility of this render stream must
     * be demonstrated externally; this sink is not itself a loopback device. */
    return noErr;
}
