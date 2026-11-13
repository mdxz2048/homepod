/*
 * Read-only HAL probe used by the installer postinstall and by manual QA.
 * It enumerates devices, looks for the exact Flow device UID, and never
 * changes the default output, starts IO, or requests TCC.
 */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int device_matches(AudioObjectID device, const char *wanted) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDeviceUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef value = NULL;
    UInt32 size = (UInt32)sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value);
    if (status != noErr || value == NULL) {
        return 0;
    }
    char buffer[1024];
    Boolean copied = CFStringGetCString(value, buffer, (CFIndex)sizeof(buffer), kCFStringEncodingUTF8);
    CFRelease(value);
    return copied && strcmp(buffer, wanted) == 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <device-uid>\n", argc > 0 ? argv[0] : "flow-audio-probe");
        return 2;
    }

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    if (status != noErr || size == 0 || size % (UInt32)sizeof(AudioObjectID) != 0) {
        fprintf(stderr, "device enumeration failed (%d)\n", (int)status);
        return 2;
    }

    AudioObjectID *devices = (AudioObjectID *)malloc(size);
    if (devices == NULL) {
        fprintf(stderr, "allocation failed\n");
        return 2;
    }
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices);
    if (status != noErr) {
        fprintf(stderr, "device read failed (%d)\n", (int)status);
        free(devices);
        return 2;
    }

    const char *wanted = argv[1];
    for (UInt32 index = 0; index < size / (UInt32)sizeof(AudioObjectID); index++) {
        if (device_matches(devices[index], wanted)) {
            printf("found=1 uid=%s\n", wanted);
            free(devices);
            return 0;
        }
    }
    printf("found=0 uid=%s\n", wanted);
    free(devices);
    return 1;
}
