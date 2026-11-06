/* Exercise the real single-device build through the existing mock host. */
#if !MC_SINGLE_DEVICE || !MC_PRODUCTION_IDENTITY
#error "Compile with MC_SINGLE_DEVICE=1 and MC_PRODUCTION_IDENTITY=1"
#endif
#define main FamilyChecksMain
#include "MultichannelChecks.c"
#undef main

int main(void) {
    assert(FamilyChecksMain() == 0);
    assert(MC_DEVICE_COUNT == 1);
    assert(gDevices[0].deviceID == kMCObjectDevice71);
    assert(gDevices[0].streamID == kMCObjectStream71);
    assert(DeviceChannels(&gDevices[0]) == 8 && !gDevices[0].hidden);
    assert(strcmp(gDevices[0].name, "HomePod Flow Audio") == 0);
    CFStringRef removed[] = {CFSTR(MC_DEVICE_UID_STEREO), CFSTR(MC_DEVICE_UID_MONO),
        CFSTR(MC_DEVICE_UID_30), CFSTR(MC_DEVICE_UID_40),
        CFSTR(MC_DEVICE_UID_51S), CFSTR(MC_DEVICE_UID_51B)};
    AudioObjectPropertyAddress address = Global(kAudioPlugInPropertyTranslateUIDToDevice);
    for (UInt32 i = 0; i < 6; ++i) {
        AudioObjectID device = UINT32_MAX;
        UInt32 written = 0;
        assert(GetData(Driver(), kAudioObjectPlugInObject, 0, &address, sizeof(CFStringRef),
                       &removed[i], sizeof(device), &written, &device) == noErr);
        assert(device == kAudioObjectUnknown && written == sizeof(device));
    }
    puts("PASS single product device: one device/stream, 8ch, six legacy UIDs absent");
    return 0;
}
