/* Standalone ABI/property/clock checks for the experimental N-channel family.
 * Includes the implementation in-process; does not install, load into
 * coreaudiod, enumerate a system device, or play audio. */
#include "../src/FlowMultichannelMap.c"
#include "../src/FlowVirtualAudioMultichannel.c"

#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static UInt32 gLatencyGlobal[MC_DEVICE_COUNT];
static UInt32 gLatencyOutput[MC_DEVICE_COUNT];
static UInt32 gRevisionNotifications[MC_DEVICE_COUNT];
static UInt32 gRunningNotifications[MC_DEVICE_COUNT];
static UInt32 gFormatNotifications[MC_DEVICE_COUNT];
static UInt32 gVolumeNotifications[MC_DEVICE_COUNT];
static UInt32 gMuteNotifications[MC_DEVICE_COUNT];
static OSStatus gRequestResult;
static AudioObjectID gRequestedDevice;
static UInt64 gRequestedAction;

static int NotifyIndex(AudioObjectID object) {
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        if (gDevices[i].deviceID == object || gDevices[i].streamID == object) return (int)i;
    }
    return -1;
}

static OSStatus MockPropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object,
                                      UInt32 count,
                                      const AudioObjectPropertyAddress *addresses) {
    (void)host;
    int index = NotifyIndex(object);
    if (index < 0) return noErr;
    for (UInt32 i = 0; i < count; ++i) {
        switch (addresses[i].mSelector) {
            case kAudioStreamPropertyLatency:
                if (addresses[i].mScope == kAudioObjectPropertyScopeGlobal) {
                    ++gLatencyGlobal[index];
                } else if (addresses[i].mScope == kAudioObjectPropertyScopeOutput) {
                    ++gLatencyOutput[index];
                }
                break;
            case kMCLatencyRevision:
                ++gRevisionNotifications[index];
                break;
            case kAudioDevicePropertyDeviceIsRunning:
                ++gRunningNotifications[index];
                break;
            case kAudioDevicePropertyVolumeScalar:
                ++gVolumeNotifications[index];
                break;
            case kAudioDevicePropertyMute:
                ++gMuteNotifications[index];
                break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                ++gFormatNotifications[index];
                break;
            default:
                break;
        }
    }
    return noErr;
}

static OSStatus MockRequestChange(AudioServerPlugInHostRef host, AudioObjectID device,
                                  UInt64 action, void *info) {
    (void)host;
    (void)info;
    gRequestedDevice = device;
    gRequestedAction = action;
    return gRequestResult;
}

static AudioServerPlugInHostInterface gMockHost = {
    .PropertiesChanged = MockPropertiesChanged,
    .RequestDeviceConfigurationChange = MockRequestChange};

/* Deterministic injected scheduler: the test runs the host request work item
 * synchronously instead of relying on the global dispatch queue, so queue
 * timing cannot race the assertions below. */
static void MockHostRequestSubmit(MCHostRequestFunction function, void *context) {
    function(context);
}

static UInt32 Read32(AudioObjectID object, AudioObjectPropertySelector selector,
                     AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 value = UINT32_MAX, written = 0;
    assert(GetData(Driver(), object, 0, &address, 0, NULL, sizeof(value), &written,
                   &value) == noErr);
    assert(written == sizeof(value));
    return value;
}

static Float64 ReadFloat64(AudioObjectID object, AudioObjectPropertySelector selector,
                           AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    Float64 value = 0;
    UInt32 written = 0;
    assert(GetData(Driver(), object, 0, &address, 0, NULL, sizeof(value), &written,
                   &value) == noErr);
    assert(written == sizeof(value));
    return value;
}

static Float32 ReadFloat32(AudioObjectID object, AudioObjectPropertySelector selector,
                           AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    Float32 value = 0;
    UInt32 written = 0;
    assert(GetData(Driver(), object, 0, &address, 0, NULL, sizeof(value), &written,
                   &value) == noErr);
    assert(written == sizeof(value));
    return value;
}

static UInt32 ReadCustom32(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Global(selector);
    CFNumberRef number = NULL;
    UInt32 written = 0;
    assert(GetData(Driver(), object, 0, &address, 0, NULL, sizeof(number), &written,
                   &number) == noErr);
    assert(written == sizeof(number) && number &&
           CFGetTypeID(number) == CFNumberGetTypeID());
    SInt32 value = 0;
    assert(CFNumberGetValue(number, kCFNumberSInt32Type, &value));
    CFRelease(number);
    return (UInt32)value;
}

static UInt64 ReadCustom64(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Global(selector);
    CFNumberRef number = NULL;
    UInt32 written = 0;
    assert(GetData(Driver(), object, 0, &address, 0, NULL, sizeof(number), &written,
                   &number) == noErr);
    assert(written == sizeof(number) && number &&
           CFGetTypeID(number) == CFNumberGetTypeID());
    SInt64 value = 0;
    assert(CFNumberGetValue(number, kCFNumberSInt64Type, &value));
    CFRelease(number);
    return (UInt64)value;
}

static SInt32 ReadStatus(AudioObjectID object) {
    AudioObjectPropertyAddress address = Global(kMCLatencyStatus);
    CFNumberRef number = NULL;
    UInt32 written = 0;
    assert(GetData(Driver(), object, 0, &address, 0, NULL, sizeof(number), &written,
                   &number) == noErr);
    assert(written == sizeof(number) && number &&
           CFGetTypeID(number) == CFNumberGetTypeID());
    SInt32 value = 0;
    assert(CFNumberGetValue(number, kCFNumberSInt32Type, &value));
    CFRelease(number);
    return value;
}

static OSStatus SetCustom32(AudioObjectID object, AudioObjectPropertySelector selector,
                            SInt64 value) {
    AudioObjectPropertyAddress address = Global(selector);
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    assert(number);
    OSStatus status = SetData(Driver(), object, 0, &address, 0, NULL, sizeof(number),
                              &number);
    CFRelease(number);
    return status;
}

static CFStringRef CopyString(AudioObjectID object, AudioObjectPropertySelector selector,
                              AudioObjectPropertyScope scope, AudioObjectPropertyElement element) {
    AudioObjectPropertyAddress address = {selector, scope, element};
    CFStringRef string = NULL;
    UInt32 size = 0, written = 0;
    assert(DataSize(Driver(), object, 0, &address, 0, NULL, &size) == noErr);
    assert(size == sizeof(string));
    assert(GetData(Driver(), object, 0, &address, 0, NULL, sizeof(string), &written,
                   &string) == noErr);
    assert(written == sizeof(string) && string);
    return string;
}

static void CheckString(AudioObjectID object, AudioObjectPropertySelector selector,
                        AudioObjectPropertyScope scope, AudioObjectPropertyElement element,
                        const char *expected) {
    CFStringRef string = CopyString(object, selector, scope, element);
    char buffer[256] = {0};
    assert(CFStringGetCString(string, buffer, sizeof(buffer), kCFStringEncodingUTF8));
    assert(strcmp(buffer, expected) == 0);
    CFRelease(string);
}

static UInt32 ReadIDs(AudioObjectID object, AudioObjectPropertySelector selector,
                      AudioObjectPropertyScope scope, AudioObjectID *ids, UInt32 capacity) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0, written = 0;
    assert(DataSize(Driver(), object, 0, &address, 0, NULL, &size) == noErr);
    assert(size <= capacity * sizeof(AudioObjectID));
    if (!size) {
        assert(GetData(Driver(), object, 0, &address, 0, NULL, 0, &written, NULL) == noErr);
        assert(written == 0);
        return 0;
    }
    assert(GetData(Driver(), object, 0, &address, 0, NULL, size, &written, ids) == noErr);
    assert(written == size);
    return size / sizeof(AudioObjectID);
}

static AudioStreamBasicDescription ReadFormat(AudioObjectID stream,
                                              AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = Global(selector);
    AudioStreamBasicDescription format;
    UInt32 written = 0;
    assert(GetData(Driver(), stream, 0, &address, 0, NULL, sizeof(format), &written,
                   &format) == noErr);
    assert(written == sizeof(format));
    return format;
}

static void CheckFormatValue(const AudioStreamBasicDescription *format, UInt32 rate,
                             UInt32 channels) {
    assert(format->mSampleRate == rate);
    assert(format->mFormatID == kAudioFormatLinearPCM);
    assert(format->mFormatFlags ==
           (kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
            kAudioFormatFlagIsPacked));
    assert(format->mBytesPerPacket == 4 * channels);
    assert(format->mFramesPerPacket == 1);
    assert(format->mBytesPerFrame == 4 * channels);
    assert(format->mChannelsPerFrame == channels);
    assert(format->mBitsPerChannel == 32);
}

static void CheckPreferredLayout(const MCDeviceInfo *info) {
    UInt32 channels = DeviceChannels(info);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyPreferredChannelLayout,
                                          kAudioObjectPropertyScopeOutput,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 0, written = 0;
    assert(DataSize(Driver(), info->deviceID, 0, &address, 0, NULL, &size) == noErr);
    assert(size == PreferredLayoutSize(channels));
    MCLayoutStorage storage;
    memset(&storage, 0, sizeof(storage));
    assert(GetData(Driver(), info->deviceID, 0, &address, 0, NULL, sizeof(storage),
                   &written, &storage) == noErr);
    assert(written == size);
    assert(storage.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions);
    assert(storage.mChannelBitmap == 0);
    assert(storage.mNumberChannelDescriptions == channels);

    MCLabel labels[MC_MAX_CHANNELS];
    UInt32 labelCount = 0;
    assert(MCLayoutLabels(info->layout, labels, &labelCount));
    assert(labelCount == channels);
    for (UInt32 i = 0; i < channels; ++i) {
        const AudioChannelDescription *description = &storage.mChannelDescriptions[i];
        assert(description->mChannelLabel == CoreAudioLabel(labels[i]));
        assert(description->mChannelFlags == kAudioChannelFlags_SphericalCoordinates);
        assert(description->mCoordinates[1] == CoreAudioElevation(labels[i]));
        assert(description->mCoordinates[2] == 1.0f);
        assert(description->mCoordinates[0] == CoreAudioAzimuth(labels[i]));
        if (labels[i] == MC_LABEL_SL) {
            assert(description->mChannelLabel == kAudioChannelLabel_LeftSurroundDirect);
            assert(description->mCoordinates[0] == -90.0f);
        }
        if (labels[i] == MC_LABEL_BL) {
            assert(description->mChannelLabel == kAudioChannelLabel_LeftSurround);
            assert(description->mCoordinates[0] == -135.0f);
        }
    }
}

static void CheckStreamFormats(const MCDeviceInfo *info) {
    UInt32 channels = DeviceChannels(info);
    AudioStreamBasicDescription virtualFormat =
        ReadFormat(info->streamID, kAudioStreamPropertyVirtualFormat);
    AudioStreamBasicDescription physicalFormat =
        ReadFormat(info->streamID, kAudioStreamPropertyPhysicalFormat);
    CheckFormatValue(&virtualFormat, 48000, channels);
    assert(memcmp(&virtualFormat, &physicalFormat, sizeof(virtualFormat)) == 0);

    AudioObjectPropertyAddress address = Global(kAudioStreamPropertyAvailableVirtualFormats);
    AudioStreamRangedDescription ranges[2];
    UInt32 size = 0, written = 0;
    assert(DataSize(Driver(), info->streamID, 0, &address, 0, NULL, &size) == noErr);
    assert(size == sizeof(ranges));
    assert(GetData(Driver(), info->streamID, 0, &address, 0, NULL, sizeof(ranges),
                   &written, ranges) == noErr);
    assert(written == sizeof(ranges));
    CheckFormatValue(&ranges[0].mFormat, 44100, channels);
    CheckFormatValue(&ranges[1].mFormat, 48000, channels);
    assert(ranges[0].mSampleRateRange.mMinimum == 44100 &&
           ranges[0].mSampleRateRange.mMaximum == 44100);
    assert(ranges[1].mSampleRateRange.mMinimum == 48000 &&
           ranges[1].mSampleRateRange.mMaximum == 48000);
}

static void CheckLatencyScope(AudioObjectID stream, UInt32 expected) {
    const AudioObjectPropertyScope scopes[] = {kAudioObjectPropertyScopeGlobal,
                                               kAudioObjectPropertyScopeOutput};
    for (UInt32 i = 0; i < 2; ++i) {
        AudioObjectPropertyAddress address = {kAudioStreamPropertyLatency, scopes[i],
                                              kAudioObjectPropertyElementMain};
        UInt32 size = 0, written = 0, value = UINT32_MAX;
        Boolean settable = true;
        assert(HasProperty(Driver(), stream, 0, &address));
        assert(IsSettable(Driver(), stream, 0, &address, &settable) == noErr);
        assert(!settable);
        assert(DataSize(Driver(), stream, 0, &address, 0, NULL, &size) == noErr);
        assert(size == sizeof(UInt32));
        assert(GetData(Driver(), stream, 0, &address, 0, NULL, sizeof(value), &written,
                       &value) == noErr);
        assert(written == sizeof(value) && value == expected);
    }
    AudioObjectPropertyAddress invalid = {kAudioStreamPropertyLatency,
                                          kAudioObjectPropertyScopeInput,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    Boolean settable = true;
    assert(!HasProperty(Driver(), stream, 0, &invalid));
    assert(DataSize(Driver(), stream, 0, &invalid, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);
    assert(IsSettable(Driver(), stream, 0, &invalid, &settable) ==
           kAudioHardwareUnknownPropertyError);
}

static void CheckElementNames(const MCDeviceInfo *info) {
    UInt32 channels = DeviceChannels(info);
    MCLabel labels[MC_MAX_CHANNELS];
    UInt32 count = 0;
    assert(MCLayoutLabels(info->layout, labels, &count));
    assert(count == channels);
    CheckString(info->deviceID, kAudioObjectPropertyElementName,
                kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain, "Main");
    for (UInt32 i = 0; i < channels; ++i) {
        CheckString(info->deviceID, kAudioObjectPropertyElementName,
                    kAudioObjectPropertyScopeOutput, i + 1, MCLabelName(labels[i]));
    }
    AudioObjectPropertyAddress tooMany = {kAudioObjectPropertyElementName,
                                          kAudioObjectPropertyScopeOutput,
                                          channels + 1};
    UInt32 size = 0;
    assert(DataSize(Driver(), info->deviceID, 0, &tooMany, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);
}

static void ExerciseProperty(AudioObjectID object, AudioObjectPropertySelector selector,
                             AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = 0, written = UINT32_MAX;
    Boolean settable = false;
    unsigned char bytes[512] = {0};
    assert(HasProperty(Driver(), object, 0, &address));
    assert(IsSettable(Driver(), object, 0, &address, &settable) == noErr);
    assert(DataSize(Driver(), object, 0, &address, 0, NULL, &size) == noErr);
    assert(size <= sizeof(bytes));
    assert(GetData(Driver(), object, 0, &address, 0, NULL, size, &written,
                   size ? bytes : NULL) == noErr);
    assert(written == size);
    if (selector == kAudioObjectPropertyName ||
        selector == kAudioObjectPropertyManufacturer ||
        selector == kAudioPlugInPropertyBundleID ||
        selector == kAudioPlugInPropertyResourceBundle ||
        selector == kAudioDevicePropertyDeviceUID ||
        selector == kAudioDevicePropertyModelUID ||
        selector == kAudioObjectPropertyElementName) {
        CFStringRef string = NULL;
        memcpy(&string, bytes, sizeof(string));
        assert(string);
        CFRelease(string);
    } else if (selector == kMCLatencyFrames || selector == kMCLatencyRevision ||
               selector == kMCLatencyStatus) {
        CFNumberRef number = NULL;
        memcpy(&number, bytes, sizeof(number));
        assert(number);
        CFRelease(number);
    }
}

static void CheckInitializationMatrix(void) {
    const AudioObjectPropertySelector pluginSelectors[] = {
        kAudioPlugInPropertyBundleID, kAudioPlugInPropertyDeviceList,
        kAudioPlugInPropertyResourceBundle, kAudioPlugInPropertyBoxList,
        kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner, kAudioObjectPropertyName,
        kAudioObjectPropertyManufacturer, kAudioObjectPropertyOwnedObjects};
    for (UInt32 i = 0; i < sizeof(pluginSelectors) / sizeof(pluginSelectors[0]); ++i) {
        ExerciseProperty(kAudioObjectPlugInObject, pluginSelectors[i],
                         kAudioObjectPropertyScopeGlobal);
    }

    const AudioObjectPropertySelector deviceGlobal[] = {
        kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner, kAudioObjectPropertyName,
        kAudioObjectPropertyManufacturer, kAudioObjectPropertyOwnedObjects,
        kAudioDevicePropertyDeviceUID, kAudioDevicePropertyModelUID,
        kAudioDevicePropertyTransportType, kAudioDevicePropertyRelatedDevices,
        kAudioDevicePropertyClockDomain, kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyDeviceIsRunning, kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioObjectPropertyControlList, kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyAvailableNominalSampleRates, kAudioDevicePropertyIsHidden,
        kAudioDevicePropertyZeroTimeStampPeriod, kAudioDevicePropertyStreams,
        kAudioDevicePropertyBufferFrameSizeRange, kAudioDevicePropertyBufferFrameSize,
        kAudioObjectPropertyCustomPropertyInfoList, kMCLatencyFrames,
        kMCLatencyRevision, kMCLatencyStatus};
    const AudioObjectPropertySelector deviceBoth[] = {
        kAudioDevicePropertyDeviceCanBeDefaultDevice,
        kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
        kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset,
        kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration,
        kAudioObjectPropertyOwnedObjects};
    const AudioObjectPropertySelector deviceOutputOnly[] = {
        kAudioDevicePropertyPreferredChannelsForStereo,
        kAudioDevicePropertyPreferredChannelLayout};
    const AudioObjectPropertySelector streamGlobal[] = {
        kAudioObjectPropertyBaseClass, kAudioObjectPropertyClass,
        kAudioObjectPropertyOwner, kAudioObjectPropertyName,
        kAudioObjectPropertyManufacturer, kAudioObjectPropertyOwnedObjects,
        kAudioStreamPropertyIsActive, kAudioStreamPropertyDirection,
        kAudioStreamPropertyTerminalType, kAudioStreamPropertyStartingChannel,
        kAudioStreamPropertyLatency, kAudioStreamPropertyVirtualFormat,
        kAudioStreamPropertyPhysicalFormat,
        kAudioStreamPropertyAvailableVirtualFormats,
        kAudioStreamPropertyAvailablePhysicalFormats};

    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        for (UInt32 s = 0; s < sizeof(deviceGlobal) / sizeof(deviceGlobal[0]); ++s) {
            ExerciseProperty(info->deviceID, deviceGlobal[s],
                             kAudioObjectPropertyScopeGlobal);
        }
        for (UInt32 s = 0; s < sizeof(deviceBoth) / sizeof(deviceBoth[0]); ++s) {
            ExerciseProperty(info->deviceID, deviceBoth[s], kAudioObjectPropertyScopeInput);
            ExerciseProperty(info->deviceID, deviceBoth[s], kAudioObjectPropertyScopeOutput);
        }
        for (UInt32 s = 0; s < sizeof(deviceOutputOnly) / sizeof(deviceOutputOnly[0]); ++s) {
            ExerciseProperty(info->deviceID, deviceOutputOnly[s],
                             kAudioObjectPropertyScopeOutput);
        }
        for (UInt32 s = 0; s < sizeof(streamGlobal) / sizeof(streamGlobal[0]); ++s) {
            ExerciseProperty(info->streamID, streamGlobal[s],
                             kAudioObjectPropertyScopeGlobal);
        }
        ExerciseProperty(info->streamID, kAudioStreamPropertyLatency,
                         kAudioObjectPropertyScopeOutput);
    }
}

static void CheckPlugin(void) {
    CheckString(kAudioObjectPlugInObject, kAudioObjectPropertyName,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
                MC_PLUGIN_NAME);
    CheckString(kAudioObjectPlugInObject, kAudioObjectPropertyManufacturer,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
                "HomePod Flow");
    CheckString(kAudioObjectPlugInObject, kAudioPlugInPropertyBundleID,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
                MC_BUNDLE_ID);

    AudioObjectID ids[MC_MAX_CHANNELS];
    UInt32 count = ReadIDs(kAudioObjectPlugInObject, kAudioPlugInPropertyDeviceList,
                           kAudioObjectPropertyScopeGlobal, ids, MC_MAX_CHANNELS);
    assert(count == MC_DEVICE_COUNT);
    for (UInt32 i = 0; i < count; ++i) assert(ids[i] == gDevices[i].deviceID);

    count = ReadIDs(kAudioObjectPlugInObject, kAudioObjectPropertyOwnedObjects,
                    kAudioObjectPropertyScopeGlobal, ids, MC_MAX_CHANNELS);
    assert(count == MC_DEVICE_COUNT);

    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        AudioObjectPropertyAddress translate = Global(kAudioPlugInPropertyTranslateUIDToDevice);
        CFStringRef uid = DeviceUIDString(&gDevices[i]);
        AudioObjectID translated = kAudioObjectUnknown;
        UInt32 written = 0;
        assert(GetData(Driver(), kAudioObjectPlugInObject, 0, &translate, sizeof(uid),
                       &uid, sizeof(translated), &written, &translated) == noErr);
        assert(written == sizeof(translated) && translated == gDevices[i].deviceID);
    }
    AudioObjectPropertyAddress translate = Global(kAudioPlugInPropertyTranslateUIDToDevice);
    CFStringRef missing = CFSTR("com.homepodflow.virtual-audio.unknown.v1");
    AudioObjectID translated = gDevices[0].deviceID;
    UInt32 written = 0;
    assert(GetData(Driver(), kAudioObjectPlugInObject, 0, &translate, sizeof(missing),
                   &missing, sizeof(translated), &written, &translated) == noErr);
    assert(written == sizeof(translated) && translated == kAudioObjectUnknown);
}

static void CheckStaticDevice(UInt32 index) {
    const MCDeviceInfo *info = &gDevices[index];
    UInt32 channels = DeviceChannels(info);
    CheckString(info->deviceID, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain, info->name);
    CheckString(info->deviceID, kAudioDevicePropertyDeviceUID,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain, info->uid);
    CheckString(info->deviceID, kAudioDevicePropertyModelUID,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
                info->modelUID);
    CheckString(info->streamID, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain, info->streamName);

    assert(Read32(info->deviceID, kAudioDevicePropertyRelatedDevices,
                  kAudioObjectPropertyScopeGlobal) == info->deviceID);
    AudioObjectID ids[MC_MAX_CHANNELS];
    UInt32 count = ReadIDs(info->deviceID, kAudioDevicePropertyStreams,
                           kAudioObjectPropertyScopeOutput, ids, MC_MAX_CHANNELS);
    assert(count == 1 && ids[0] == info->streamID);
    count = ReadIDs(info->deviceID, kAudioObjectPropertyOwnedObjects,
                    kAudioObjectPropertyScopeOutput, ids, MC_MAX_CHANNELS);
    assert(count == 1 && ids[0] == info->streamID);
    count = ReadIDs(info->deviceID, kAudioObjectPropertyOwnedObjects,
                    kAudioObjectPropertyScopeInput, ids, MC_MAX_CHANNELS);
    assert(count == 0);
    count = ReadIDs(info->streamID, kAudioObjectPropertyOwnedObjects,
                    kAudioObjectPropertyScopeGlobal, ids, MC_MAX_CHANNELS);
    assert(count == 0);

    AudioObjectPropertyAddress configAddress = {
        kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain};
    UInt32 configSize = 0, configWritten = 0;
    assert(DataSize(Driver(), info->deviceID, 0, &configAddress, 0, NULL,
                    &configSize) == noErr);
    assert(configSize == sizeof(AudioBufferList));
    AudioBufferList configuration;
    memset(&configuration, 0, sizeof(configuration));
    assert(GetData(Driver(), info->deviceID, 0, &configAddress, 0, NULL,
                   sizeof(configuration), &configWritten, &configuration) == noErr);
    assert(configWritten == configSize);
    assert(configuration.mNumberBuffers == 1);
    assert(configuration.mBuffers[0].mNumberChannels == channels);
    assert(configuration.mBuffers[0].mDataByteSize == 0);
    AudioObjectPropertyAddress inputConfig = {
        kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput,
        kAudioObjectPropertyElementMain};
    assert(DataSize(Driver(), info->deviceID, 0, &inputConfig, 0, NULL,
                    &configSize) == noErr && configSize == 0);

    CheckElementNames(info);
    CheckPreferredLayout(info);
    CheckStreamFormats(info);

    AudioObjectPropertyAddress stereoChannels = {
        kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain};
    UInt32 preferred[2] = {0, 0}, written = 0;
    assert(GetData(Driver(), info->deviceID, 0, &stereoChannels, 0, NULL,
                   sizeof(preferred), &written, preferred) == noErr);
    assert(written == sizeof(preferred) && preferred[0] == 1);
    assert(preferred[1] == (info->layout == MC_LAYOUT_MONO ? 1 : 2));

    assert(ReadFloat64(info->deviceID, kAudioDevicePropertyNominalSampleRate,
                       kAudioObjectPropertyScopeGlobal) == 48000);
    AudioObjectPropertyAddress ratesAddress = Global(
        kAudioDevicePropertyAvailableNominalSampleRates);
    AudioValueRange rates[2];
    UInt32 size = 0;
    assert(DataSize(Driver(), info->deviceID, 0, &ratesAddress, 0, NULL, &size) == noErr);
    assert(size == sizeof(rates));
    assert(GetData(Driver(), info->deviceID, 0, &ratesAddress, 0, NULL, sizeof(rates),
                   &written, rates) == noErr);
    assert(rates[0].mMinimum == 44100 && rates[0].mMaximum == 44100);
    assert(rates[1].mMinimum == 48000 && rates[1].mMaximum == 48000);

    AudioObjectPropertyAddress bufferRangeAddress = Global(
        kAudioDevicePropertyBufferFrameSizeRange);
    AudioValueRange bufferRange;
    assert(GetData(Driver(), info->deviceID, 0, &bufferRangeAddress, 0, NULL,
                   sizeof(bufferRange), &written, &bufferRange) == noErr);
    assert(bufferRange.mMinimum == 15 && bufferRange.mMaximum == 4096);
    assert(Read32(info->deviceID, kAudioDevicePropertyBufferFrameSize,
                  kAudioObjectPropertyScopeGlobal) == 512);
    assert(Read32(info->deviceID, kAudioDevicePropertyZeroTimeStampPeriod,
                  kAudioObjectPropertyScopeGlobal) == kMCZeroTimeStampPeriod);
    assert(Read32(info->deviceID, kAudioDevicePropertyTransportType,
                  kAudioObjectPropertyScopeGlobal) == kAudioDeviceTransportTypeVirtual);
    assert(Read32(info->deviceID, kAudioDevicePropertyClockDomain,
                  kAudioObjectPropertyScopeGlobal) == 0);
    assert(Read32(info->deviceID, kAudioDevicePropertyDeviceIsAlive,
                  kAudioObjectPropertyScopeGlobal) == 1);
    assert(Read32(info->deviceID, kAudioDevicePropertyDeviceIsRunning,
                  kAudioObjectPropertyScopeGlobal) == 0);
    assert(Read32(info->deviceID, kAudioDevicePropertyIsHidden,
                  kAudioObjectPropertyScopeGlobal) == (info->hidden ? 1u : 0u));
    assert(Read32(info->deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                  kAudioObjectPropertyScopeOutput) == 1);
    assert(Read32(info->deviceID, kAudioDevicePropertyDeviceCanBeDefaultDevice,
                  kAudioObjectPropertyScopeInput) == 0);
    assert(Read32(info->deviceID, kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
                  kAudioObjectPropertyScopeOutput) ==
           (info->systemDefaultEligible ? 1 : 0));
    assert(Read32(info->deviceID, kAudioDevicePropertyLatency,
                  kAudioObjectPropertyScopeOutput) == 0);
    assert(Read32(info->deviceID, kAudioDevicePropertyLatency,
                  kAudioObjectPropertyScopeInput) == 0);
    assert(Read32(info->deviceID, kAudioDevicePropertySafetyOffset,
                  kAudioObjectPropertyScopeInput) == 0);
    assert(Read32(info->streamID, kAudioStreamPropertyLatency,
                  kAudioObjectPropertyScopeGlobal) == 0);
    assert(Read32(info->streamID, kAudioStreamPropertyLatency,
                  kAudioObjectPropertyScopeOutput) == 0);
    CheckLatencyScope(info->streamID, 0);
    assert(Read32(info->streamID, kAudioStreamPropertyIsActive,
                  kAudioObjectPropertyScopeGlobal) == 1);
    assert(Read32(info->streamID, kAudioStreamPropertyDirection,
                  kAudioObjectPropertyScopeGlobal) == 0);
    assert(Read32(info->streamID, kAudioStreamPropertyTerminalType,
                  kAudioObjectPropertyScopeGlobal) == kAudioStreamTerminalTypeSpeaker);
    assert(Read32(info->streamID, kAudioStreamPropertyStartingChannel,
                  kAudioObjectPropertyScopeGlobal) == 1);
    assert(ReadCustom32(info->deviceID, kMCLatencyFrames) == 0);
    assert(ReadCustom64(info->deviceID, kMCLatencyRevision) == 1);
    assert(ReadStatus(info->deviceID) == MCLatencyStatusIdle);

    AudioObjectPropertyAddress infoAddress = Global(kAudioObjectPropertyCustomPropertyInfoList);
    AudioServerPlugInCustomPropertyInfo properties[3];
    assert(DataSize(Driver(), info->deviceID, 0, &infoAddress, 0, NULL, &size) == noErr);
    assert(size == sizeof(properties));
    assert(GetData(Driver(), info->deviceID, 0, &infoAddress, 0, NULL, sizeof(properties),
                   &written, properties) == noErr);
    assert(properties[0].mSelector == kMCLatencyFrames);
    assert(properties[0].mPropertyDataType ==
           kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(properties[1].mSelector == kMCLatencyRevision);
    assert(properties[1].mPropertyDataType ==
           kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(properties[2].mSelector == kMCLatencyStatus);
    assert(properties[2].mPropertyDataType ==
           kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    assert(channels == MCLayoutChannelCount(info->layout));
}

static void CheckFormatValidation(void) {
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        UInt32 channels = DeviceChannels(info);
        assert(ValidFormatForDevice(info, NULL) == false);
        AudioStreamBasicDescription format = Format(48000, channels);
        assert(ValidFormatForDevice(info, &format));
        format = Format(44100, channels);
        assert(ValidFormatForDevice(info, &format));

        UInt32 otherChannels = channels == 2 ? 6 : channels == 6 ? 8 : 6;
        format = Format(48000, otherChannels);
        assert(!ValidFormatForDevice(info, &format));

        format = Format(48000, channels);
        format.mBytesPerFrame = 4 * channels + 4;
        format.mBytesPerPacket = 4 * channels + 4;
        assert(!ValidFormatForDevice(info, &format));
        format = Format(48000, channels);
        format.mBytesPerPacket = 4 * channels + 4;
        assert(!ValidFormatForDevice(info, &format));
        format = Format(48000, channels);
        format.mChannelsPerFrame = channels + 1;
        assert(!ValidFormatForDevice(info, &format));
        format = Format(48000, channels);
        format.mBitsPerChannel = 16;
        assert(!ValidFormatForDevice(info, &format));
        format = Format(48000, channels);
        format.mFormatFlags = 0;
        assert(!ValidFormatForDevice(info, &format));
        format = Format(48000, channels);
        format.mSampleRate = NAN;
        assert(!ValidFormatForDevice(info, &format));
        format = Format(48000, channels);
        format.mSampleRate = INFINITY;
        assert(!ValidFormatForDevice(info, &format));
        format = Format(48000, channels);
        format.mSampleRate = 96000;
        assert(!ValidFormatForDevice(info, &format));
    }
}

static void Check2chRejectedOnWideStreams(void) {
    AudioObjectPropertyAddress virtualFormat = Global(kAudioStreamPropertyVirtualFormat);
    AudioStreamBasicDescription stereoFormat = Format(48000, 2);
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        UInt32 channels = DeviceChannels(info);
        UInt32 rateBefore = atomic_load(&gState[i].rate);
        OSStatus status = SetData(Driver(), info->streamID, 0, &virtualFormat, 0, NULL,
                                  sizeof(stereoFormat), &stereoFormat);
        if (channels == 2) {
            assert(status == noErr);
        } else {
            assert(status == kAudioDeviceUnsupportedFormatError);
            assert(gState[i].pendingKind == MCPendingNone);
            assert(atomic_load(&gState[i].rate) == rateBefore);
            assert(ReadFormat(info->streamID, kAudioStreamPropertyVirtualFormat)
                       .mChannelsPerFrame == channels);
        }
        UInt32 otherChannels = channels == 6 ? 8 : 6;
        AudioStreamBasicDescription other = Format(48000, otherChannels);
        if (otherChannels != channels) {
            assert(SetData(Driver(), info->streamID, 0, &virtualFormat, 0, NULL,
                           sizeof(other), &other) == kAudioDeviceUnsupportedFormatError);
        }
    }
}

static void CheckLatencyIsolation(void) {
    UInt32 expected[MC_DEVICE_COUNT] = {0};
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        UInt32 value = 1000 * (i + 1);
        UInt32 previous = ReadCustom32(info->deviceID, kMCLatencyFrames);
        UInt64 revisionBefore = ReadCustom64(info->deviceID, kMCLatencyRevision);
        UInt32 globalBefore = gLatencyGlobal[i];
        UInt32 outputBefore = gLatencyOutput[i];
        UInt32 revisionNotesBefore = gRevisionNotifications[i];

        gRequestResult = noErr;
        gRequestedDevice = kAudioObjectUnknown;
        gRequestedAction = 0;
        assert(SetCustom32(info->deviceID, kMCLatencyFrames, value) == noErr);
        assert(gState[i].pendingKind == MCPendingLatency);
        assert(gRequestedDevice == info->deviceID &&
               gRequestedAction == gState[i].pendingAction);
        assert(ReadStatus(info->deviceID) == MCLatencyStatusPending);
        /* The old readback is preserved until the host commits. */
        assert(ReadCustom32(info->deviceID, kMCLatencyFrames) == previous);
        assert(ReadCustom64(info->deviceID, kMCLatencyRevision) == revisionBefore);
        assert(Read32(info->streamID, kAudioStreamPropertyLatency,
                      kAudioObjectPropertyScopeOutput) == previous);
        assert(StartIO(Driver(), info->deviceID, 8000 + i) ==
               kAudioHardwareIllegalOperationError);
        /* A second write while the transaction is pending is busy-rejected. */
        assert(SetCustom32(info->deviceID, kMCLatencyFrames, value + 1) ==
               kAudioHardwareIllegalOperationError);

        assert(PerformChange(Driver(), info->deviceID, gState[i].pendingAction, NULL) ==
               noErr);
        expected[i] = value;
        assert(gState[i].pendingKind == MCPendingNone);
        assert(ReadCustom32(info->deviceID, kMCLatencyFrames) == value);
        assert(ReadCustom64(info->deviceID, kMCLatencyRevision) == revisionBefore + 1);
        assert(ReadStatus(info->deviceID) == MCLatencyStatusIdle);
        assert(Read32(info->streamID, kAudioStreamPropertyLatency,
                      kAudioObjectPropertyScopeGlobal) == value);
        assert(Read32(info->streamID, kAudioStreamPropertyLatency,
                      kAudioObjectPropertyScopeOutput) == value);
        assert(gLatencyGlobal[i] == globalBefore + 1);
        assert(gLatencyOutput[i] == outputBefore + 1);
        assert(gRevisionNotifications[i] == revisionNotesBefore + 1);
        for (UInt32 j = 0; j < MC_DEVICE_COUNT; ++j) {
            if (j == i) continue;
            assert(ReadCustom32(gDevices[j].deviceID, kMCLatencyFrames) == expected[j]);
            assert(ReadCustom64(gDevices[j].deviceID, kMCLatencyRevision) ==
                   (expected[j] ? 2 : 1));
            assert(Read32(gDevices[j].streamID, kAudioStreamPropertyLatency,
                          kAudioObjectPropertyScopeOutput) == expected[j]);
        }
    }

    const MCDeviceInfo *first = &gDevices[0];
    UInt32 globalBefore = gLatencyGlobal[0];
    UInt32 outputBefore = gLatencyOutput[0];
    UInt32 revisionNotesBefore = gRevisionNotifications[0];
    gRequestResult = noErr;
    gRequestedDevice = kAudioObjectUnknown;
    gRequestedAction = 0;
    assert(SetCustom32(first->deviceID, kMCLatencyFrames, expected[0]) == noErr);
    assert(ReadCustom64(first->deviceID, kMCLatencyRevision) == 2);
    assert(gState[0].pendingKind == MCPendingNone);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusIdle);
    assert(gRequestedDevice == kAudioObjectUnknown && gRequestedAction == 0);
    assert(gLatencyGlobal[0] == globalBefore &&
           gLatencyOutput[0] == outputBefore &&
           gRevisionNotifications[0] == revisionNotesBefore);

    assert(SetCustom32(first->deviceID, kMCLatencyFrames, -1) ==
           kAudioHardwareIllegalOperationError);
    assert(gState[0].pendingKind == MCPendingNone);
    assert(SetCustom32(first->deviceID, kMCLatencyFrames, 5000000000LL) ==
           kAudioHardwareIllegalOperationError);
    assert(SetCustom32(first->deviceID, kMCLatencyFrames,
                       10 * 48000 + 1) == kAudioHardwareIllegalOperationError);
    assert(ReadCustom64(first->deviceID, kMCLatencyRevision) == 2);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusIdle);

    AudioObjectPropertyAddress address = Global(kMCLatencyFrames);
    UInt32 wrongSize = 123;
    assert(SetData(Driver(), first->deviceID, 0, &address, 0, NULL, sizeof(wrongSize),
                   &wrongSize) == kAudioHardwareBadPropertySizeError);
    CFStringRef text = CFSTR("not-a-number");
    assert(SetData(Driver(), first->deviceID, 0, &address, 0, NULL, sizeof(text),
                   &text) == kAudioHardwareBadPropertySizeError);
    assert(SetData(Driver(), first->streamID, 0, &address, 0, NULL, sizeof(text),
                   &text) == kAudioHardwareUnknownPropertyError);

    AudioObjectPropertyAddress input = {kMCLatencyFrames, kAudioObjectPropertyScopeInput,
                                        kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    assert(DataSize(Driver(), first->deviceID, 0, &input, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);
    AudioObjectPropertyAddress element = {kMCLatencyFrames,
                                          kAudioObjectPropertyScopeGlobal, 1};
    assert(DataSize(Driver(), first->deviceID, 0, &element, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);
}

static void CheckRateIsolation(void) {
    UInt32 expected[MC_DEVICE_COUNT];
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        expected[i] = ReadCustom32(gDevices[i].deviceID, kMCLatencyFrames);
    }
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        UInt32 channels = DeviceChannels(info);
        AudioStreamBasicDescription request = Format(44100, channels);
        AudioObjectPropertyAddress address = Global(kAudioStreamPropertyVirtualFormat);
        UInt64 revisionBefore = ReadCustom64(info->deviceID, kMCLatencyRevision);
        gRequestResult = noErr;
        gRequestedDevice = kAudioObjectUnknown;
        gRequestedAction = 0;
        assert(SetData(Driver(), info->streamID, 0, &address, 0, NULL, sizeof(request),
                       &request) == noErr);
        assert(gState[i].pendingKind == MCPendingRate);
        assert(gRequestedDevice == info->deviceID &&
               gRequestedAction == gState[i].pendingAction);
        assert(ReadStatus(info->deviceID) == MCLatencyStatusPending);
        /* Rate and latency stay at their committed values until PerformChange. */
        assert(atomic_load(&gState[i].rate) == 48000);
        assert(ReadCustom32(info->deviceID, kMCLatencyFrames) == expected[i]);
        assert(StartIO(Driver(), info->deviceID, 500 + i) ==
               kAudioHardwareIllegalOperationError);
        assert(PerformChange(Driver(), info->deviceID, gState[i].pendingAction, NULL) ==
               noErr);
        UInt32 scaled = (UInt32)(((UInt64)expected[i] * 44100 + 24000) / 48000);
        expected[i] = scaled;
        assert(atomic_load(&gState[i].rate) == 44100);
        assert(gState[i].pendingKind == MCPendingNone);
        assert(ReadCustom32(info->deviceID, kMCLatencyFrames) == scaled);
        assert(ReadCustom64(info->deviceID, kMCLatencyRevision) == revisionBefore + 1);
        assert(ReadStatus(info->deviceID) == MCLatencyStatusIdle);
        assert(Read32(info->streamID, kAudioStreamPropertyLatency,
                      kAudioObjectPropertyScopeGlobal) == scaled);
        assert(Read32(info->streamID, kAudioStreamPropertyLatency,
                      kAudioObjectPropertyScopeOutput) == scaled);
        AudioStreamBasicDescription virtualFormat =
            ReadFormat(info->streamID, kAudioStreamPropertyVirtualFormat);
        AudioStreamBasicDescription physicalFormat =
            ReadFormat(info->streamID, kAudioStreamPropertyPhysicalFormat);
        CheckFormatValue(&virtualFormat, 44100, channels);
        CheckFormatValue(&physicalFormat, 44100, channels);
        for (UInt32 j = 0; j < MC_DEVICE_COUNT; ++j) {
            if (j == i) continue;
            assert(ReadCustom32(gDevices[j].deviceID, kMCLatencyFrames) == expected[j]);
            assert(ReadCustom64(gDevices[j].deviceID, kMCLatencyRevision) ==
                   (j < i ? 3 : 2));
        }
    }

    const MCDeviceInfo *first = &gDevices[0];
    AudioStreamBasicDescription back = Format(48000, DeviceChannels(first));
    AudioObjectPropertyAddress address = Global(kAudioStreamPropertyVirtualFormat);

    /* Host request failure clears the pending slot and preserves the device.
     * The test injected scheduler runs the queued request before SetData
     * returns; in production the block runs on a dispatch queue and SetData
     * has already returned noErr when AbortChange clears the reservation. */
    gRequestResult = kAudioHardwareUnspecifiedError;
    gRequestedDevice = kAudioObjectUnknown;
    gRequestedAction = 0;
    assert(SetData(Driver(), first->streamID, 0, &address, 0, NULL, sizeof(back),
                   &back) == noErr);
    assert(gRequestedDevice == first->deviceID);
    assert(gRequestedAction != 0);
    assert(gState[0].pendingKind == MCPendingNone &&
           atomic_load(&gState[0].rate) == 44100);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusRejected);

    /* A missing host is refused the same way, never left pending. */
    gHost = NULL;
    assert(SetData(Driver(), first->streamID, 0, &address, 0, NULL, sizeof(back),
                   &back) == kAudioHardwareNotReadyError);
    assert(gState[0].pendingKind == MCPendingNone &&
           atomic_load(&gState[0].rate) == 44100);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusRejected);
    gHost = &gMockHost;

    /* A stale callback must not clear a newer transaction. */
    gRequestResult = noErr;
    assert(SetData(Driver(), first->streamID, 0, &address, 0, NULL, sizeof(back),
                   &back) == noErr);
    assert(gState[0].pendingKind == MCPendingRate);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusPending);
    UInt64 action = gState[0].pendingAction;
    assert(AbortChange(Driver(), first->deviceID, action - 1, NULL) == noErr);
    assert(gState[0].pendingKind == MCPendingRate &&
           atomic_load(&gState[0].rate) == 44100);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusPending);
    assert(AbortChange(Driver(), first->deviceID, action, NULL) == noErr);
    assert(gState[0].pendingKind == MCPendingNone &&
           atomic_load(&gState[0].rate) == 44100);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusRejected);

    assert(StartIO(Driver(), first->deviceID, 600) == noErr);
    assert(StopIO(Driver(), first->deviceID, 600) == noErr);
}

static void CheckClockAndIO(void) {
    Float64 sample1[MC_DEVICE_COUNT], sample2[MC_DEVICE_COUNT];
    UInt64 host1[MC_DEVICE_COUNT], host2[MC_DEVICE_COUNT];
    UInt64 seed1[MC_DEVICE_COUNT], seed2[MC_DEVICE_COUNT];

    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        assert(StartIO(Driver(), info->deviceID, 1000 + i) == noErr);
        assert(StartIO(Driver(), info->deviceID, 1000 + i) ==
               kAudioHardwareIllegalOperationError);
        assert(Read32(info->deviceID, kAudioDevicePropertyDeviceIsRunning,
                      kAudioObjectPropertyScopeGlobal) == 1);
        assert(gRunningNotifications[i] >= 1);
        assert(ZeroTime(Driver(), info->deviceID, 1000 + i, &sample1[i], &host1[i],
                        &seed1[i]) == noErr);
    }
    usleep(400000);
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        assert(ZeroTime(Driver(), info->deviceID, 1000 + i, &sample2[i], &host2[i],
                        &seed2[i]) == noErr);
        assert(sample2[i] > sample1[i]);
        assert(host2[i] > host1[i]);
        assert(host2[i] <= mach_absolute_time());
        assert(seed1[i] == seed2[i]);
        assert(fmod(sample2[i], kMCZeroTimeStampPeriod) == 0);
    }
    assert(ZeroTime(Driver(), gDevices[0].streamID, 1000, &sample2[0], &host2[0],
                    &seed2[0]) == kAudioHardwareBadObjectError);

    float samples[MC_MAX_CHANNELS * 4];
    float copy[MC_MAX_CHANNELS * 4];
    for (UInt32 i = 0; i < MC_MAX_CHANNELS * 4; ++i) samples[i] = (float)i - 8.0f;
    memcpy(copy, samples, sizeof(copy));
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        const MCDeviceInfo *info = &gDevices[i];
        assert(DoIO(Driver(), info->deviceID, info->streamID, 1000 + i,
                    kAudioServerPlugInIOOperationWriteMix, 4, NULL, samples, NULL) == noErr);
        assert(memcmp(copy, samples, sizeof(copy)) == 0);
        assert(DoIO(Driver(), info->deviceID, info->streamID, 1000 + i,
                    kAudioServerPlugInIOOperationWriteMix, 0, NULL, NULL, NULL) == noErr);
        assert(DoIO(Driver(), info->deviceID, info->streamID, 1000 + i,
                    kAudioServerPlugInIOOperationWriteMix, 4, NULL, NULL, NULL) ==
               kAudioHardwareIllegalOperationError);
        assert(DoIO(Driver(), info->deviceID, info->streamID, 1000 + i,
                    kAudioServerPlugInIOOperationReadInput, 4, NULL, samples, NULL) ==
               kAudioHardwareUnsupportedOperationError);
        if (MC_DEVICE_COUNT > 1) {
            AudioObjectID otherStream = gDevices[(i + 1) % MC_DEVICE_COUNT].streamID;
            assert(DoIO(Driver(), info->deviceID, otherStream, 1000 + i,
                        kAudioServerPlugInIOOperationWriteMix, 4, NULL, samples, NULL) ==
                   kAudioHardwareBadObjectError);
        }
        Boolean will = true, inPlace = true;
        assert(WillIO(Driver(), info->deviceID, 1000 + i,
                      kAudioServerPlugInIOOperationWriteMix, &will, &inPlace) == noErr);
        assert(will && inPlace);
        will = true;
        inPlace = true;
        assert(WillIO(Driver(), info->deviceID, 1000 + i,
                      kAudioServerPlugInIOOperationReadInput, &will, &inPlace) == noErr);
        assert(!will && !inPlace);
        assert(BeginIO(Driver(), info->deviceID, 1000 + i,
                       kAudioServerPlugInIOOperationWriteMix, 4, NULL) == noErr);
    }

    const MCDeviceInfo *first = &gDevices[0];
    assert(StartIO(Driver(), first->deviceID, 2000) == noErr);
    assert(Read32(first->deviceID, kAudioDevicePropertyDeviceIsRunning,
                  kAudioObjectPropertyScopeGlobal) == 1);
    assert(StopIO(Driver(), first->deviceID, 1000) == noErr);
    assert(Read32(first->deviceID, kAudioDevicePropertyDeviceIsRunning,
                  kAudioObjectPropertyScopeGlobal) == 1);
    assert(StopIO(Driver(), first->deviceID, 2000) == noErr);
    assert(Read32(first->deviceID, kAudioDevicePropertyDeviceIsRunning,
                  kAudioObjectPropertyScopeGlobal) == 0);
    assert(StopIO(Driver(), first->deviceID, 2000) ==
           kAudioHardwareIllegalOperationError);
    for (UInt32 i = 1; i < MC_DEVICE_COUNT; ++i) {
        assert(StopIO(Driver(), gDevices[i].deviceID, 1000 + i) == noErr);
        assert(Read32(gDevices[i].deviceID, kAudioDevicePropertyDeviceIsRunning,
                      kAudioObjectPropertyScopeGlobal) == 0);
    }

    /* Latency mutation is blocked only on the device with active IO, and the
     * idle device commits through the host transaction. */
    assert(StartIO(Driver(), first->deviceID, 3000) == noErr);
    UInt32 revisionBefore = ReadCustom64(first->deviceID, kMCLatencyRevision);
    UInt32 latencyBefore = ReadCustom32(first->deviceID, kMCLatencyFrames);
    assert(ReadStatus(first->deviceID) == MCLatencyStatusBusy);
    assert(SetCustom32(first->deviceID, kMCLatencyFrames, latencyBefore + 1) ==
           kAudioHardwareIllegalOperationError);
    assert(ReadCustom64(first->deviceID, kMCLatencyRevision) == revisionBefore);
    assert(gState[0].pendingKind == MCPendingNone);
    if (MC_DEVICE_COUNT > 1) {
        const MCDeviceInfo *second = &gDevices[1];
        UInt32 secondRevision = ReadCustom64(second->deviceID, kMCLatencyRevision);
        UInt32 secondLatency = ReadCustom32(second->deviceID, kMCLatencyFrames);
        UInt32 target = secondLatency + 7;
        gRequestResult = noErr;
        assert(SetCustom32(second->deviceID, kMCLatencyFrames, target) == noErr);
        assert(gState[1].pendingKind == MCPendingLatency);
        assert(ReadStatus(second->deviceID) == MCLatencyStatusPending);
        /* Readback is unchanged until the host commits. */
        assert(ReadCustom32(second->deviceID, kMCLatencyFrames) == secondLatency);
        assert(PerformChange(Driver(), second->deviceID, gState[1].pendingAction, NULL) ==
               noErr);
        assert(ReadCustom64(second->deviceID, kMCLatencyRevision) ==
               secondRevision + 1);
        assert(ReadCustom32(second->deviceID, kMCLatencyFrames) == target);
        assert(ReadStatus(second->deviceID) == MCLatencyStatusIdle);
        assert(ReadCustom32(first->deviceID, kMCLatencyFrames) == latencyBefore);
    }
    assert(StopIO(Driver(), first->deviceID, 3000) == noErr);
}

static void CheckScopeStrictness(void) {
    const MCDeviceInfo *info = &gDevices[0];
    UInt32 size = 0;
    Boolean settable = true;

    AudioObjectPropertyAddress layoutGlobal = {kAudioDevicePropertyPreferredChannelLayout,
                                               kAudioObjectPropertyScopeGlobal,
                                               kAudioObjectPropertyElementMain};
    assert(DataSize(Driver(), info->deviceID, 0, &layoutGlobal, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);
    AudioObjectPropertyAddress layoutInput = {kAudioDevicePropertyPreferredChannelLayout,
                                              kAudioObjectPropertyScopeInput,
                                              kAudioObjectPropertyElementMain};
    assert(DataSize(Driver(), info->deviceID, 0, &layoutInput, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);

    AudioObjectPropertyAddress latencyInput = {kAudioStreamPropertyLatency,
                                               kAudioObjectPropertyScopeInput,
                                               kAudioObjectPropertyElementMain};
    assert(DataSize(Driver(), info->streamID, 0, &latencyInput, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);
    AudioObjectPropertyAddress latencyElement = {kAudioStreamPropertyLatency,
                                                 kAudioObjectPropertyScopeOutput, 1};
    assert(DataSize(Driver(), info->streamID, 0, &latencyElement, 0, NULL, &size) ==
           kAudioHardwareUnknownPropertyError);

    AudioObjectPropertyAddress latencyWrite = {kAudioStreamPropertyLatency,
                                               kAudioObjectPropertyScopeGlobal,
                                               kAudioObjectPropertyElementMain};
    UInt32 zero = 0;
    assert(SetData(Driver(), info->streamID, 0, &latencyWrite, 0, NULL, sizeof(zero),
                   &zero) == kAudioHardwareUnknownPropertyError);

    AudioObjectPropertyAddress formatOnDevice = {kAudioStreamPropertyVirtualFormat,
                                                 kAudioObjectPropertyScopeGlobal,
                                                 kAudioObjectPropertyElementMain};
    AudioStreamBasicDescription format = Format(48000, DeviceChannels(info));
    assert(SetData(Driver(), info->deviceID, 0, &formatOnDevice, 0, NULL,
                   sizeof(format), &format) == kAudioHardwareUnknownPropertyError);
    assert(SetData(Driver(), info->streamID, 0, &formatOnDevice, 0, NULL, 0, NULL) ==
           kAudioHardwareBadPropertySizeError);
    assert(SetData(Driver(), info->streamID, 0, &formatOnDevice, 0, NULL,
                   sizeof(format), NULL) == kAudioHardwareBadPropertySizeError);

    AudioObjectPropertyAddress buffer = Global(kAudioDevicePropertyBufferFrameSize);
    UInt32 frames = 15;
    assert(SetData(Driver(), info->deviceID, 0, &buffer, 0, NULL, sizeof(frames),
                   &frames) == noErr);
    frames = 4096;
    assert(SetData(Driver(), info->deviceID, 0, &buffer, 0, NULL, sizeof(frames),
                   &frames) == noErr);
    frames = 14;
    assert(SetData(Driver(), info->deviceID, 0, &buffer, 0, NULL, sizeof(frames),
                   &frames) == kAudioHardwareIllegalOperationError);
    frames = 4097;
    assert(SetData(Driver(), info->deviceID, 0, &buffer, 0, NULL, sizeof(frames),
                   &frames) == kAudioHardwareIllegalOperationError);

    AudioObjectPropertyAddress hflaOnStream = Global(kMCLatencyFrames);
    assert(SetData(Driver(), info->streamID, 0, &hflaOnStream, 0, NULL, sizeof(zero),
                   &zero) == kAudioHardwareUnknownPropertyError);
    assert(IsSettable(Driver(), info->streamID, 0, &hflaOnStream, &settable) ==
           kAudioHardwareUnknownPropertyError);
}

static void CheckRunningRateRejected(void) {
    const MCDeviceInfo *info = &gDevices[0];
    assert(StartIO(Driver(), info->deviceID, 4000) == noErr);
    assert(ReadStatus(info->deviceID) == MCLatencyStatusBusy);
    AudioObjectPropertyAddress rateAddress = Global(kAudioDevicePropertyNominalSampleRate);
    Float64 rate = 48000;
    assert(SetData(Driver(), info->deviceID, 0, &rateAddress, 0, NULL, sizeof(rate),
                   &rate) == kAudioHardwareIllegalOperationError);
    assert(gState[0].pendingKind == MCPendingNone);
    assert(StopIO(Driver(), info->deviceID, 4000) == noErr);
}

static void CheckVolumeControl(void) {
    AudioObjectPropertyAddress volumeAddress = {
        kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain};
    AudioObjectPropertyAddress muteAddress = {
        kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain};
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        AudioObjectID device = gDevices[i].deviceID;
        UInt32 size = 0;
        Boolean settable = false;
        assert(DataSize(Driver(), device, 0, &volumeAddress, 0, NULL, &size) == noErr);
        assert(size == sizeof(Float32));
        assert(IsSettable(Driver(), device, 0, &volumeAddress, &settable) == noErr);
        assert(settable);
        assert(ReadFloat32(device, kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput) == 1.0f);

        Float32 volume = 0.25f;
        UInt32 before = gVolumeNotifications[i];
        assert(SetData(Driver(), device, 0, &volumeAddress, 0, NULL, sizeof(volume),
                       &volume) == noErr);
        assert(ReadFloat32(device, kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput) == volume);
        assert(gVolumeNotifications[i] == before + 1);
        volume = -0.01f;
        assert(SetData(Driver(), device, 0, &volumeAddress, 0, NULL, sizeof(volume),
                       &volume) == kAudioHardwareIllegalOperationError);
        volume = 1.01f;
        assert(SetData(Driver(), device, 0, &volumeAddress, 0, NULL, sizeof(volume),
                       &volume) == kAudioHardwareIllegalOperationError);

        assert(DataSize(Driver(), device, 0, &muteAddress, 0, NULL, &size) == noErr);
        assert(size == sizeof(UInt32));
        assert(IsSettable(Driver(), device, 0, &muteAddress, &settable) == noErr);
        assert(settable);
        assert(Read32(device, kAudioDevicePropertyMute,
                      kAudioObjectPropertyScopeOutput) == 0);
        UInt32 mute = 1;
        before = gMuteNotifications[i];
        assert(SetData(Driver(), device, 0, &muteAddress, 0, NULL, sizeof(mute),
                       &mute) == noErr);
        assert(Read32(device, kAudioDevicePropertyMute,
                      kAudioObjectPropertyScopeOutput) == 1);
        assert(gMuteNotifications[i] == before + 1);
        mute = 2;
        assert(SetData(Driver(), device, 0, &muteAddress, 0, NULL, sizeof(mute),
                       &mute) == kAudioHardwareIllegalOperationError);
        mute = 0;
        assert(SetData(Driver(), device, 0, &muteAddress, 0, NULL, sizeof(mute),
                       &mute) == noErr);

        volume = 1.0f;
        assert(SetData(Driver(), device, 0, &volumeAddress, 0, NULL, sizeof(volume),
                       &volume) == noErr);
    }
}

/* macOS only exposes volume keys for a device whose control list carries a
 * level control, so the master controls are verified as real Core Audio
 * control objects rather than device-level properties. */
static void CheckControlObjects(void) {
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) {
        AudioObjectID device = gDevices[i].deviceID;
        AudioObjectID controls[2] = {0, 0};
        UInt32 count = ReadIDs(device, kAudioObjectPropertyControlList,
                               kAudioObjectPropertyScopeGlobal, controls, 2);
        assert(count == 2);
        AudioObjectID volumeControl = controls[0];
        AudioObjectID muteControl = controls[1];
        assert(volumeControl != muteControl);
        assert(volumeControl != kAudioObjectUnknown && muteControl != kAudioObjectUnknown);

        assert(Read32(volumeControl, kAudioObjectPropertyBaseClass,
                      kAudioObjectPropertyScopeGlobal) ==
               (UInt32)kAudioLevelControlClassID);
        assert(Read32(volumeControl, kAudioObjectPropertyClass,
                      kAudioObjectPropertyScopeGlobal) ==
               (UInt32)kAudioVolumeControlClassID);
        assert(Read32(muteControl, kAudioObjectPropertyBaseClass,
                      kAudioObjectPropertyScopeGlobal) ==
               (UInt32)kAudioBooleanControlClassID);
        assert(Read32(muteControl, kAudioObjectPropertyClass,
                      kAudioObjectPropertyScopeGlobal) ==
               (UInt32)kAudioMuteControlClassID);
        for (int c = 0; c < 2; ++c) {
            AudioObjectID control = controls[c];
            assert(Read32(control, kAudioObjectPropertyOwner,
                          kAudioObjectPropertyScopeGlobal) == device);
            assert(Read32(control, kAudioControlPropertyScope,
                          kAudioObjectPropertyScopeGlobal) == kAudioObjectPropertyScopeOutput);
            assert(Read32(control, kAudioControlPropertyElement,
                          kAudioObjectPropertyScopeGlobal) ==
                   kAudioObjectPropertyElementMain);
            assert(Read32(control, kAudioControlPropertyVariant,
                          kAudioObjectPropertyScopeGlobal) == 0);
        }
        CheckString(volumeControl, kAudioObjectPropertyName,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
                    "Volume");
        CheckString(muteControl, kAudioObjectPropertyName,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain,
                    "Mute");

        AudioObjectPropertyAddress scalarAddress = {
            kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        Boolean settable = false;
        assert(IsSettable(Driver(), volumeControl, 0, &scalarAddress, &settable) == noErr);
        assert(settable);
        assert(ReadFloat32(volumeControl, kAudioLevelControlPropertyScalarValue,
                           kAudioObjectPropertyScopeGlobal) == 1.0f);

        Float32 scalar = 0.25f;
        assert(SetData(Driver(), volumeControl, 0, &scalarAddress, 0, NULL, sizeof(scalar),
                       &scalar) == noErr);
        assert(ReadFloat32(volumeControl, kAudioLevelControlPropertyScalarValue,
                           kAudioObjectPropertyScopeGlobal) == scalar);
        assert(ReadFloat32(device, kAudioDevicePropertyVolumeScalar,
                           kAudioObjectPropertyScopeOutput) == scalar);
        /* The device-level property stays a mirror of the control. */
        Float32 mirrored = 0.75f;
        AudioObjectPropertyAddress deviceAddress = {
            kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain};
        assert(SetData(Driver(), device, 0, &deviceAddress, 0, NULL, sizeof(mirrored),
                       &mirrored) == noErr);
        assert(ReadFloat32(volumeControl, kAudioLevelControlPropertyScalarValue,
                           kAudioObjectPropertyScopeGlobal) == mirrored);

        AudioObjectPropertyAddress decibelAddress = {
            kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        AudioValueRange range;
        UInt32 size = sizeof(range);
        UInt32 written = 0;
        AudioObjectPropertyAddress rangeAddress = {
            kAudioLevelControlPropertyDecibelRange, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        assert(GetData(Driver(), volumeControl, 0, &rangeAddress, 0, NULL, size, &written,
                       &range) == noErr);
        assert(written == sizeof(range));
        assert(range.mMaximum == 0.0f && range.mMinimum < -60.0f);

        Float32 decibels = -6.0206f; /* ~0.5 */
        assert(SetData(Driver(), volumeControl, 0, &decibelAddress, 0, NULL,
                       sizeof(decibels), &decibels) == noErr);
        Float32 fromDecibels = ReadFloat32(volumeControl,
                                           kAudioLevelControlPropertyScalarValue,
                                           kAudioObjectPropertyScopeGlobal);
        assert(fabsf(fromDecibels - 0.5f) < 0.001f);
        /* -96 dB is the floor and must clamp to silence, not negative. */
        decibels = -96.0f;
        assert(SetData(Driver(), volumeControl, 0, &decibelAddress, 0, NULL,
                       sizeof(decibels), &decibels) == noErr);
        assert(ReadFloat32(volumeControl, kAudioLevelControlPropertyScalarValue,
                           kAudioObjectPropertyScopeGlobal) == 0.0f);
        decibels = 1.0f;
        assert(SetData(Driver(), volumeControl, 0, &decibelAddress, 0, NULL,
                       sizeof(decibels), &decibels) == kAudioHardwareIllegalOperationError);

        scalar = 1.0f;
        assert(SetData(Driver(), volumeControl, 0, &scalarAddress, 0, NULL, sizeof(scalar),
                       &scalar) == noErr);
        scalar = 1.5f;
        assert(SetData(Driver(), volumeControl, 0, &scalarAddress, 0, NULL, sizeof(scalar),
                       &scalar) == kAudioHardwareIllegalOperationError);

        AudioObjectPropertyAddress muteAddress = {
            kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain};
        assert(IsSettable(Driver(), muteControl, 0, &muteAddress, &settable) == noErr);
        assert(settable);
        UInt32 mute = 1;
        assert(SetData(Driver(), muteControl, 0, &muteAddress, 0, NULL, sizeof(mute),
                       &mute) == noErr);
        assert(Read32(muteControl, kAudioBooleanControlPropertyValue,
                      kAudioObjectPropertyScopeGlobal) == 1);
        assert(Read32(device, kAudioDevicePropertyMute,
                      kAudioObjectPropertyScopeOutput) == 1);
        mute = 0;
        assert(SetData(Driver(), muteControl, 0, &muteAddress, 0, NULL, sizeof(mute),
                       &mute) == noErr);
        assert(Read32(device, kAudioDevicePropertyMute,
                      kAudioObjectPropertyScopeOutput) == 0);
        mute = 2;
        assert(SetData(Driver(), muteControl, 0, &muteAddress, 0, NULL, sizeof(mute),
                       &mute) == kAudioHardwareIllegalOperationError);

        /* Controls are not enumerable as owned objects of the device. */
        assert(HasProperty(Driver(), volumeControl, 0, &scalarAddress));
    }
}

int main(void) {
    gHostRequestSubmitter = MockHostRequestSubmit;
    assert(FlowVirtualAudioMultichannelFactory(NULL, kAudioServerPlugInTypeUUID) == Driver());
    assert(Initialize(Driver(), &gMockHost) == noErr);
    CheckPlugin();
    CheckInitializationMatrix();
    for (UInt32 i = 0; i < MC_DEVICE_COUNT; ++i) CheckStaticDevice(i);
    CheckFormatValidation();
    Check2chRejectedOnWideStreams();
    CheckLatencyIsolation();
    CheckRateIsolation();
    CheckClockAndIO();
    CheckScopeStrictness();
    CheckRunningRateRejected();
    CheckVolumeControl();
    CheckControlObjects();
    puts("PASS multichannel driver family: property matrix, per-layout ASBD/layout/slots, "
         "per-device latency/revision, per-device clock, 2ch format rejection");
    return 0;
}
