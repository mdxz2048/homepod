/* In-process signature proof for the hfla write guard.
 *
 * This compiles the real production single-device driver source and drives
 * SetData() directly through the same mock host used by the driver's own
 * shipped tests.  It does NOT install anything, load into coreaudiod, touch
 * a system device, or change the default output.
 *
 * It demonstrates, on the exact installed source:
 *   - baseline idle: SetData('hfla', 0) -> noErr and no revision bump;
 *   - running   : StartIO then SetData('hfla', 0) -> kAudioHardwareIllegalOperationError;
 *   - ratePending: a granted-but-not-completed rate change leaves
 *                  state.ratePending true; then SetData('hfla', 0) ->
 *                  kAudioHardwareIllegalOperationError while DeviceIsRunning==0.
 *
 * Output lines are `PASS <name>`; the process returns nonzero on failure.
 */

#define MC_SINGLE_DEVICE 1
#define MC_PRODUCTION_IDENTITY 1

#include "../../../platforms/macos/VirtualAudioDriver/src/FlowMultichannelMap.c"
#include "../../../platforms/macos/VirtualAudioDriver/src/FlowVirtualAudioMultichannel.c"

#include <assert.h>
#include <stdio.h>

static OSStatus MockRequestChange(AudioServerPlugInHostRef host, AudioObjectID device,
                                  UInt64 action, void *info) {
    (void)host;
    (void)device;
    (void)action;
    (void)info;
    /* Return success and deliberately never complete the change: this is the
     * exact situation that leaves state.ratePending true. */
    return noErr;
}

static OSStatus MockPropertiesChanged(AudioServerPlugInHostRef host, AudioObjectID object,
                                      UInt32 count,
                                      const AudioObjectPropertyAddress *addresses) {
    (void)host;
    (void)object;
    (void)count;
    (void)addresses;
    return noErr;
}

static AudioServerPlugInHostInterface gFakeHost = {
    .PropertiesChanged = MockPropertiesChanged,
    .RequestDeviceConfigurationChange = MockRequestChange,
};

static UInt32 RunFlag(void) {
    AudioObjectPropertyAddress address = Global(kAudioDevicePropertyDeviceIsRunning);
    UInt32 value = 0, written = 0;
    assert(GetData(Driver(), gDevices[0].deviceID, 0, &address, 0, NULL, sizeof(value),
                   &written, &value) == noErr);
    assert(written == sizeof(value));
    return value;
}

static UInt64 Revision(void) {
    AudioObjectPropertyAddress address = Global(kMCLatencyRevision);
    CFNumberRef number = NULL;
    UInt32 written = 0;
    assert(GetData(Driver(), gDevices[0].deviceID, 0, &address, 0, NULL, sizeof(number),
                   &written, &number) == noErr);
    assert(written == sizeof(number) && number &&
           CFGetTypeID(number) == CFNumberGetTypeID());
    SInt64 value = 0;
    assert(CFNumberGetValue(number, kCFNumberSInt64Type, &value));
    CFRelease(number);
    return (UInt64)value;
}

static OSStatus SetLatencyNoop(void) {
    AudioObjectPropertyAddress address = Global(kMCLatencyFrames);
    SInt64 zero = 0;
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &zero);
    assert(number);
    OSStatus status = SetData(Driver(), gDevices[0].deviceID, 0, &address, 0, NULL,
                              sizeof(number), &number);
    CFRelease(number);
    return status;
}

static void RequestRateChangeWithoutCompletion(Float64 rate) {
    AudioObjectPropertyAddress address = Global(kAudioDevicePropertyNominalSampleRate);
    OSStatus status = SetData(Driver(), gDevices[0].deviceID, 0, &address, 0, NULL,
                              sizeof(rate), &rate);
    assert(status == noErr);
}

int main(void) {
    assert(FlowVirtualAudioMultichannelFactory(NULL, kAudioServerPlugInTypeUUID) == Driver());
    assert(Initialize(Driver(), &gFakeHost) == noErr);
    assert(MC_DEVICE_COUNT == 1);

    /* Baseline: an effective no-op write on an idle, non-pending device. */
    UInt64 revisionBefore = Revision();
    OSStatus baseline = SetLatencyNoop();
    assert(baseline == noErr);
    assert(Revision() == revisionBefore);
    puts("PASS baseline no-op write accepted without revision bump");

    /* Running clients win the guard. */
    assert(StartIO(Driver(), gDevices[0].deviceID, 77) == noErr);
    OSStatus runningStatus = SetLatencyNoop();
    assert(runningStatus == kAudioHardwareIllegalOperationError);
    assert(StopIO(Driver(), gDevices[0].deviceID, 77) == noErr);
    puts("PASS running client rejects no-op hfla write with IllegalOperation");

    /* ratePending wins the guard even when the device reports not running. */
    RequestRateChangeWithoutCompletion(44100);
    assert(RunFlag() == 0);
    OSStatus pendingStatus = SetLatencyNoop();
    assert(pendingStatus == kAudioHardwareIllegalOperationError);
    assert(RunFlag() == 0);

    /* Clear the pending change so the in-process state is left tidy. */
    AudioObjectPropertyAddress rateAddress =
        Global(kAudioDevicePropertyNominalSampleRate);
    assert(AbortChange(Driver(), gDevices[0].deviceID, (UInt64)44100, NULL) == noErr);
    assert(SetLatencyNoop() == noErr);
    puts("PASS ratePending rejects no-op hfla write with IllegalOperation while running=0");
    return 0;
}
