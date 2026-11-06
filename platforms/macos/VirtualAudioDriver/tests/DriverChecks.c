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
int main(void) {
    assert(FlowVirtualAudioFactory(NULL,kAudioServerPlugInTypeUUID)==Driver());
    assert(Initialize(Driver(),&gMockHost)==noErr);
    assert(atomic_is_lock_free(&gAnchor));
    assert(Read32(kFlowObjectDevice,kAudioDevicePropertyLatency,kAudioObjectPropertyScopeOutput)==0);
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
