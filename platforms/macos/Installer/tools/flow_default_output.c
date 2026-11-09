/*
 * Read/write helper for the macOS MEDIA default output.
 *
 * It never starts IO or asks for TCC. The only write is
 * kAudioHardwarePropertyDefaultOutputDevice, and --restore-builtin refuses to
 * select the Flow virtual device.
 */
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *FLOW_UID = "com.homepodflow.virtual-audio.surround71.v1";

static int get_uid(AudioObjectID device, char *buffer, size_t capacity) {
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
    Boolean copied = CFStringGetCString(value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(value);
    return copied ? 1 : 0;
}

static int get_name(AudioObjectID device, char *buffer, size_t capacity) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef value = NULL;
    UInt32 size = (UInt32)sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value);
    if (status != noErr || value == NULL) {
        return 0;
    }
    Boolean copied = CFStringGetCString(value, buffer, (CFIndex)capacity, kCFStringEncodingUTF8);
    CFRelease(value);
    return copied ? 1 : 0;
}

static UInt32 output_stream_count(AudioObjectID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) != noErr) {
        return 0;
    }
    return size / (UInt32)sizeof(AudioObjectID);
}

static UInt32 transport_type(AudioObjectID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 value = 0;
    UInt32 size = (UInt32)sizeof(value);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &value) != noErr) {
        return 0;
    }
    return value;
}

static int default_device(AudioObjectID *device) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = (UInt32)sizeof(*device);
    return AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, device) == noErr;
}

static int set_default_device(AudioObjectID device) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL,
                                      (UInt32)sizeof(device), &device) == noErr;
}

static int is_flow_uid(const char *uid) {
    return strcmp(uid, FLOW_UID) == 0 ||
           strncmp(uid, "com.homepodflow.virtual-audio.", 31) == 0;
}

int main(int argc, char **argv) {
    int restore_builtin = 0;
    int force_builtin = 0;
    const char *requested_uid = NULL;

    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--restore-builtin") == 0) {
            restore_builtin = 1;
        } else if (strcmp(argv[index], "--force-builtin") == 0) {
            force_builtin = 1;
        } else if (strcmp(argv[index], "--uid") == 0 && index + 1 < argc) {
            requested_uid = argv[++index];
        } else {
            fprintf(stderr,
                    "usage: %s [--restore-builtin|--force-builtin|--uid UID]\n", argv[0]);
            return 2;
        }
    }

    AudioObjectPropertyAddress devices_address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                     &devices_address, 0, NULL, &size);
    if (status != noErr || size == 0 || size % (UInt32)sizeof(AudioObjectID) != 0) {
        fprintf(stderr, "device enumeration failed (%d)\n", (int)status);
        return 2;
    }
    AudioObjectID *devices = (AudioObjectID *)malloc(size);
    if (devices == NULL) {
        fprintf(stderr, "allocation failed\n");
        return 2;
    }
    status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &devices_address,
                                        0, NULL, &size, devices);
    if (status != noErr) {
        free(devices);
        fprintf(stderr, "device read failed (%d)\n", (int)status);
        return 2;
    }

    AudioObjectID current = 0;
    char current_uid[1024] = "";
    if (default_device(&current) && get_uid(current, current_uid, sizeof(current_uid))) {
        char name[1024] = "";
        get_name(current, name, sizeof(name));
        printf("default=%s name=%s\n", current_uid, name);
    } else {
        printf("default=(unknown)\n");
    }

    AudioObjectID candidate = 0;
    for (UInt32 index = 0; index < size / (UInt32)sizeof(AudioObjectID); index++) {
        char uid[1024] = "";
        char name[1024] = "";
        if (!get_uid(devices[index], uid, sizeof(uid)) || output_stream_count(devices[index]) == 0) {
            continue;
        }
        get_name(devices[index], name, sizeof(name));
        printf("device uid=%s name=%s builtin=%d flow=%d\n", uid, name,
               transport_type(devices[index]) == kAudioDeviceTransportTypeBuiltIn,
               is_flow_uid(uid));
        if (requested_uid != NULL && strcmp(uid, requested_uid) == 0) {
            candidate = devices[index];
        }
        if (candidate == 0 && strcmp(uid, "BuiltInSpeakerDevice") == 0) {
            candidate = devices[index];
        }
        if (candidate == 0 && transport_type(devices[index]) == kAudioDeviceTransportTypeBuiltIn &&
            !is_flow_uid(uid)) {
            candidate = devices[index];
        }
    }

    free(devices);

    int must_switch = force_builtin || (restore_builtin && is_flow_uid(current_uid));
    if (!must_switch) {
        if (requested_uid != NULL) {
            fprintf(stderr, "requested UID was not found: %s\n", requested_uid);
            return 1;
        }
        printf("no change\n");
        return 0;
    }
    if (candidate == 0) {
        fprintf(stderr, "no built-in/non-Flow output device found\n");
        return 1;
    }
    if (!set_default_device(candidate)) {
        fprintf(stderr, "failed to set default output\n");
        return 1;
    }
    char uid[1024] = "";
    get_uid(candidate, uid, sizeof(uid));
    printf("changed default to uid=%s\n", uid);
    return 0;
}
