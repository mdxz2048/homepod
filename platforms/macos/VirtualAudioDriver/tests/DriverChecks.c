/* Standalone ABI/policy checks; does not install or enumerate a system device. */
#include "../src/FlowVirtualAudio.c"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static UInt32 gStreamGlobalNotifications, gStreamOutputNotifications, gRevisionNotifications;
static OSStatus gRequestResult;
static AudioObjectID gRequestedDevice;
static UInt64 gRequestedRate;
static OSStatus MockPropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    (void)host;
    for (UInt32 i=0;i<count;++i) {
        if (object == kFlowObjectOutputStream && addresses[i].mSelector == kAudioStreamPropertyLatency) {
            if (addresses[i].mScope == kAudioObjectPropertyScopeGlobal) ++gStreamGlobalNotifications;
            if (addresses[i].mScope == kAudioObjectPropertyScopeOutput) ++gStreamOutputNotifications;
        }
        if (object == kFlowObjectDevice && addresses[i].mSelector == kFlowLatencyRevision) ++gRevisionNotifications;
    }
    return noErr;
}
static OSStatus MockRequestChange(AudioServerPlugInHostRef host, AudioObjectID device, UInt64 action, void *info) {
    (void)host; (void)info; gRequestedDevice=device; gRequestedRate=action; return gRequestResult;
}
static AudioServerPlugInHostInterface gMockHost = {
    .PropertiesChanged=MockPropertiesChanged,
    .RequestDeviceConfigurationChange=MockRequestChange
};

static UInt32 Read32(AudioObjectID object, AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {selector,scope,kAudioObjectPropertyElementMain};
    UInt32 value=UINT32_MAX, written=0;
    assert(GetData(Driver(),object,0,&address,0,NULL,sizeof(value),&written,&value)==noErr);
    assert(written==sizeof(value)); return value;
}
static void CheckLatencyScope(AudioObjectPropertyScope scope, Boolean expected) {
    AudioObjectPropertyAddress address={kAudioStreamPropertyLatency,scope,kAudioObjectPropertyElementMain};
    UInt32 size=0,written=0,value=0; Boolean settable=true;
    assert(HasProperty(Driver(),kFlowObjectOutputStream,0,&address)==expected);
    OSStatus wanted=expected ? noErr : kAudioHardwareUnknownPropertyError;
    assert(IsSettable(Driver(),kFlowObjectOutputStream,0,&address,&settable)==wanted);
    assert(DataSize(Driver(),kFlowObjectOutputStream,0,&address,0,NULL,&size)==wanted);
    assert(GetData(Driver(),kFlowObjectOutputStream,0,&address,0,NULL,sizeof(value),&written,&value)==wanted);
    if (expected) assert(!settable && size==sizeof(UInt32) && written==sizeof(UInt32) && value==96000);
}
/* This list covers the original sample's output-device initialization properties,
 * excluding optional artwork and non-existent input-channel layout. It is not a
 * substitute for the actual HAL's initialization query sequence. */
static void CheckInitializationProperties(void) {
    const AudioObjectPropertySelector pluginSelectors[] = {
        kAudioPlugInPropertyBundleID,kAudioPlugInPropertyDeviceList,kAudioPlugInPropertyResourceBundle,kAudioPlugInPropertyBoxList
    };
    const AudioObjectPropertySelector deviceGlobal[] = {
        kAudioObjectPropertyBaseClass,kAudioObjectPropertyClass,kAudioObjectPropertyOwner,
        kAudioObjectPropertyName,kAudioObjectPropertyManufacturer,kAudioObjectPropertyOwnedObjects,
        kAudioDevicePropertyDeviceUID,kAudioDevicePropertyModelUID,kAudioDevicePropertyTransportType,
        kAudioDevicePropertyRelatedDevices,kAudioDevicePropertyClockDomain,kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyControlList,kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyAvailableNominalSampleRates,kAudioDevicePropertyIsHidden,
        kAudioDevicePropertyZeroTimeStampPeriod,kAudioDevicePropertyStreams
    };
    const AudioObjectPropertySelector directional[] = {
        kAudioDevicePropertyDeviceCanBeDefaultDevice,kAudioDevicePropertyDeviceCanBeDefaultSystemDevice,
        kAudioDevicePropertyLatency,kAudioDevicePropertySafetyOffset,kAudioDevicePropertyStreams,kAudioObjectPropertyOwnedObjects
    };
    for (UInt32 group=0;group<4;++group) {
        const AudioObjectPropertySelector *selectors = group==0 ? pluginSelectors : group==1 ? deviceGlobal : directional;
        size_t count=group==0 ? sizeof(pluginSelectors)/sizeof(pluginSelectors[0]) : group==1 ? sizeof(deviceGlobal)/sizeof(deviceGlobal[0]) : sizeof(directional)/sizeof(directional[0]);
        AudioObjectID object=group==0 ? kAudioObjectPlugInObject : kFlowObjectDevice;
        AudioObjectPropertyScope scope=group<2 ? kAudioObjectPropertyScopeGlobal : group==2 ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
        for(size_t i=0;i<count;++i) {
            AudioObjectPropertyAddress address={selectors[i],scope,kAudioObjectPropertyElementMain};
            UInt32 size=0,written=UINT32_MAX; Boolean settable=false; unsigned char bytes[256]={0};
            assert(HasProperty(Driver(),object,0,&address));
            assert(IsSettable(Driver(),object,0,&address,&settable)==noErr);
            assert(DataSize(Driver(),object,0,&address,0,NULL,&size)==noErr && size<=sizeof(bytes));
            assert(GetData(Driver(),object,0,&address,0,NULL,size,&written,size ? bytes : NULL)==noErr && written==size);
            if (selectors[i]==kAudioObjectPropertyName || selectors[i]==kAudioObjectPropertyManufacturer
                || selectors[i]==kAudioPlugInPropertyBundleID || selectors[i]==kAudioPlugInPropertyResourceBundle
                || selectors[i]==kAudioDevicePropertyDeviceUID || selectors[i]==kAudioDevicePropertyModelUID) {
                CFStringRef string; memcpy(&string,bytes,sizeof(string)); assert(string); CFRelease(string);
            }
        }
    }
    for (AudioObjectPropertyElement channel=0;channel<=2;++channel) {
        AudioObjectPropertyAddress address={kAudioObjectPropertyElementName,kAudioObjectPropertyScopeOutput,channel};
        UInt32 size=0,written=0; CFStringRef name=NULL;
        assert(DataSize(Driver(),kFlowObjectDevice,0,&address,0,NULL,&size)==noErr && size==sizeof(name));
        assert(GetData(Driver(),kFlowObjectDevice,0,&address,0,NULL,sizeof(name),&written,&name)==noErr && name);
        CFRelease(name);
    }
}
int main(void) {
    assert(FlowVirtualAudioFactory(NULL,kAudioServerPlugInTypeUUID)==Driver());
    assert(Initialize(Driver(),&gMockHost)==noErr);
    CheckInitializationProperties();
    assert(atomic_is_lock_free(&gAnchor));
    assert(Read32(kFlowObjectDevice,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeOutput)==0);
    assert(Read32(kFlowObjectDevice,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeInput)==0);
    assert(Read32(kFlowObjectDevice,kAudioDevicePropertySafetyOffset,kAudioObjectPropertyScopeInput)==0);
    assert(Read32(kFlowObjectDevice,kAudioDevicePropertyRelatedDevices,kAudioObjectPropertyScopeGlobal)==kFlowObjectDevice);
    assert(Read32(kFlowObjectDevice,kAudioObjectPropertyOwnedObjects,kAudioObjectPropertyScopeOutput)==kFlowObjectOutputStream);
    AudioObjectPropertyAddress emptyOwned={kAudioObjectPropertyOwnedObjects,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
    UInt32 emptySize=99;
    assert(DataSize(Driver(),kFlowObjectDevice,0,&emptyOwned,0,NULL,&emptySize)==noErr && emptySize==0);
    assert(Read32(kFlowObjectOutputStream,kAudioStreamPropertyLatency,kAudioObjectPropertyScopeGlobal)==0);
    AudioObjectPropertyAddress address=Global(kFlowLatencyFrames);
    UInt32 latency=96000;
    assert(SetData(Driver(),kFlowObjectDevice,0,&address,0,NULL,sizeof(latency),&latency)==noErr);
    assert(Read32(kFlowObjectOutputStream,kAudioStreamPropertyLatency,kAudioObjectPropertyScopeGlobal)==96000);
    assert(Read32(kFlowObjectOutputStream,kAudioStreamPropertyLatency,kAudioObjectPropertyScopeOutput)==96000);
    assert(Read32(kFlowObjectDevice,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeOutput)==0);
    CheckLatencyScope(kAudioObjectPropertyScopeGlobal,true);
    CheckLatencyScope(kAudioObjectPropertyScopeOutput,true);
    CheckLatencyScope(kAudioObjectPropertyScopeInput,false);
    assert(gStreamGlobalNotifications==1 && gStreamOutputNotifications==1 && gRevisionNotifications==1);
    assert(SetData(Driver(),kFlowObjectDevice,0,&address,0,NULL,sizeof(latency),&latency)==noErr);
    assert(gStreamGlobalNotifications==1 && gStreamOutputNotifications==1 && gRevisionNotifications==1);
    AudioObjectPropertyAddress invalidLatency={kAudioStreamPropertyLatency,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
    UInt32 badSize=0; assert(DataSize(Driver(),kFlowObjectOutputStream,0,&invalidLatency,0,NULL,&badSize)==kAudioHardwareUnknownPropertyError);
    assert(StartIO(Driver(),kFlowObjectDevice,1)==noErr);
    assert(StartIO(Driver(),kFlowObjectDevice,1)==kAudioHardwareIllegalOperationError);
    assert(StartIO(Driver(),kFlowObjectDevice,2)==noErr);
    assert(SetData(Driver(),kFlowObjectDevice,0,&address,0,NULL,sizeof(latency),&latency)==kAudioHardwareIllegalOperationError);
    Float64 sample1,sample2; UInt64 host1,host2,seed1,seed2;
    assert(ZeroTime(Driver(),kFlowObjectDevice,1,&sample1,&host1,&seed1)==noErr);
    usleep(400000);
    assert(ZeroTime(Driver(),kFlowObjectDevice,1,&sample2,&host2,&seed2)==noErr);
    assert(sample2>sample1 && host2>host1 && host2<=mach_absolute_time() && seed1==seed2);
    assert(fmod(sample2,kFlowZeroTimeStampPeriod)==0);
    assert(StopIO(Driver(),kFlowObjectDevice,1)==noErr);
    assert(StopIO(Driver(),kFlowObjectDevice,1)==kAudioHardwareIllegalOperationError);
    assert(atomic_load(&gRunning)==1);
    assert(StopIO(Driver(),kFlowObjectDevice,2)==noErr);
    AudioStreamBasicDescription requestFormat=Format(44100);
    AudioObjectPropertyAddress virtualFormat=Global(kAudioStreamPropertyVirtualFormat);
    gRequestResult=kAudioHardwareUnspecifiedError;
    assert(SetData(Driver(),kFlowObjectOutputStream,0,&virtualFormat,0,NULL,sizeof(requestFormat),&requestFormat)==gRequestResult);
    assert(!gRatePending && atomic_load(&gRate)==48000);
    gRequestResult=noErr;
    gHost=NULL;
    assert(SetData(Driver(),kFlowObjectOutputStream,0,&virtualFormat,0,NULL,sizeof(requestFormat),&requestFormat)==kAudioHardwareNotReadyError);
    assert(!gRatePending); gHost=&gMockHost;
    assert(SetData(Driver(),kFlowObjectOutputStream,0,&virtualFormat,0,NULL,sizeof(requestFormat),&requestFormat)==noErr);
    assert(gRatePending && atomic_load(&gRate)==48000 && gRequestedRate==44100 && gRequestedDevice==kFlowObjectDevice);
    assert(StartIO(Driver(),kFlowObjectDevice,1)==kAudioHardwareIllegalOperationError);
    assert(PerformChange(Driver(),kFlowObjectDevice,44100,NULL)==noErr);
    assert(atomic_load(&gRate)==44100 && atomic_load(&gLatency)==88200);
    assert(gStreamGlobalNotifications==2 && gStreamOutputNotifications==2 && gRevisionNotifications==2);
    requestFormat=Format(48000);
    assert(SetData(Driver(),kFlowObjectOutputStream,0,&virtualFormat,0,NULL,sizeof(requestFormat),&requestFormat)==noErr);
    assert(AbortChange(Driver(),kFlowObjectDevice,48000,NULL)==noErr && !gRatePending && atomic_load(&gRate)==44100);
    assert(StartIO(Driver(),kFlowObjectDevice,1)==noErr);
    assert(ZeroTime(Driver(),kFlowObjectDevice,1,&sample2,&host2,&seed2)==noErr && seed2!=seed1);
    Boolean will=false,inPlace=false;
    assert(WillIO(Driver(),kFlowObjectDevice,1,kAudioServerPlugInIOOperationWriteMix,&will,&inPlace)==noErr && will && inPlace);
    float samples[8]={1,-1,.5f,-.5f,0,0,.1f,-.1f}, copy[8]; memcpy(copy,samples,sizeof(copy));
    assert(DoIO(Driver(),kFlowObjectDevice,kFlowObjectOutputStream,1,kAudioServerPlugInIOOperationWriteMix,4,NULL,samples,NULL)==noErr);
    assert(!memcmp(copy,samples,sizeof(copy)));
    assert(StopIO(Driver(),kFlowObjectDevice,1)==noErr);
    latency=480001;
    assert(SetData(Driver(),kFlowObjectDevice,0,&address,0,NULL,sizeof(latency),&latency)==kAudioHardwareIllegalOperationError);
    AudioObjectPropertyAddress inputs={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
    UInt32 size=99; assert(DataSize(Driver(),kFlowObjectDevice,0,&inputs,0,NULL,&size)==noErr && size==0);
    AudioStreamBasicDescription bad=Format(44100); bad.mChannelsPerFrame=6; assert(!ValidFormat(&bad));
    bad=Format(44100); bad.mSampleRate=NAN; assert(!ValidFormat(&bad));
    bad.mSampleRate=INFINITY; assert(!ValidFormat(&bad));
    assert(ValidFormat(&(AudioStreamBasicDescription){44100,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagsNativeEndian|kAudioFormatFlagIsPacked,8,1,8,2,32,0}));
    puts("PASS driver factory, scopes, latency policy, stopped rate change, current-time clock, RT sink, stereo-only formats");
    return 0;
}
