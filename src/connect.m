#import "connect.h"

#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

/* Samsung Soundbar K450. A2DP is the speaker profile. AVRCP is volume.
   Serial Port and HFP are what macOS also grabs, and those never become
   a Core Audio output. ACL alone is only the radio link. */
static const unsigned int kServiceA2DP = 0x10;
static const unsigned int kServiceAudio = 0x18; /* AVRCP | A2DP */
static NSString *const kAddressColon = @"CC:6E:A4:2F:91:22";
static NSString *const kAddressDash = @"CC-6E-A4-2F-91-22";

enum {
    PHASE_AUTH = 1,
    PHASE_RESET,
    PHASE_PAIR,
    PHASE_CONNECT,
    PHASE_WAIT,
    PHASE_SETTLE,
    PHASE_DONE
};

struct SoundbarConnection {
    int phase;
    int ok;
    int attempts;
    int auth_prompted;
    int paging;
    int paging_done;
    int paging_status;
    int pair_started;
    int pair_done;
    int pair_status;
    int a2dp_requested;
    int central_state;
    CFAbsoluteTime phase_started;
    CFAbsoluteTime started;
    id central;
    id manager;
    id bt_manager;
    id io_device;
    id peer;
    id bm_device;
    id pairer;
    id delegate;
    AudioObjectID initial_outputs[16];
    UInt32 initial_output_count;
    char status[512];
};

static Class g_delegate_class;

static void set_status(SoundbarConnection *c, const char *text) {
    strlcpy(c->status, text, sizeof c->status);
}

static void *session_of(id self) {
    Ivar ivar = class_getInstanceVariable(g_delegate_class, "session");
    return *(void **)((char *)self + ivar_getOffset(ivar));
}

static void central_state(id self, SEL _cmd, id central) {
    (void)_cmd;
    SoundbarConnection *c = session_of(self);
    if (!c || !central) {
        return;
    }
    c->central_state = (int)((NSInteger (*)(id, SEL))objc_msgSend)(
        central, sel_registerName("state"));
}

static void confirm_pairing(id self, SEL _cmd, id sender, uint32_t value) {
    (void)self;
    (void)_cmd;
    (void)value;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(
        sender, sel_registerName("replyUserConfirmation:"), YES);
}

static void pin_request(id self, SEL _cmd, id sender) {
    (void)self;
    (void)_cmd;
    BluetoothPINCode pin;
    memset(&pin, 0, sizeof pin);
    memcpy(pin.data, "0000", 4);
    ((void (*)(id, SEL, ByteCount, BluetoothPINCode *))objc_msgSend)(
        sender, sel_registerName("replyPINCode:PINCode:"), (ByteCount)4, &pin);
}

static void pairing_finished(id self, SEL _cmd, id sender, IOReturn error) {
    (void)_cmd;
    (void)sender;
    SoundbarConnection *c = session_of(self);
    if (!c) {
        return;
    }
    c->pair_done = 1;
    c->pair_status = (int)error;
}

static void connection_complete(id self, SEL _cmd, id device, IOReturn status) {
    (void)_cmd;
    (void)device;
    SoundbarConnection *c = session_of(self);
    if (!c) {
        return;
    }
    c->paging_done = 1;
    c->paging_status = (int)status;
}

static void ensure_delegate_class(void) {
    if (g_delegate_class) {
        return;
    }
    Class cls = objc_allocateClassPair(objc_getClass("NSObject"), "SoundbarBtDelegate", 0);
    class_addIvar(cls, "session", sizeof(void *), 3, "^v");
    class_addMethod(cls, sel_registerName("centralManagerDidUpdateState:"), (IMP)central_state, "v24@0:8@16");
    class_addMethod(cls, sel_registerName("devicePairingUserConfirmationRequest:numericValue:"), (IMP)confirm_pairing, "v28@0:8@16I24");
    class_addMethod(cls, sel_registerName("devicePairingPINCodeRequest:"), (IMP)pin_request, "v24@0:8@16");
    class_addMethod(cls, sel_registerName("devicePairingFinished:error:"), (IMP)pairing_finished, "v28@0:8@16i24");
    class_addMethod(cls, sel_registerName("connectionComplete:status:"), (IMP)connection_complete, "v28@0:8@16i24");
    objc_registerClassPair(cls);
    g_delegate_class = cls;
}

static id make_delegate(SoundbarConnection *c) {
    ensure_delegate_class();
    id delegate = [[g_delegate_class alloc] init];
    Ivar ivar = class_getInstanceVariable(g_delegate_class, "session");
    *(void **)((char *)delegate + ivar_getOffset(ivar)) = c;
    return delegate;
}

static BOOL name_is_soundbar(NSString *name) {
    if (name.length == 0) {
        return NO;
    }
    NSString *lower = name.lowercaseString;
    return [lower containsString:@"soundbar"] || [lower containsString:@"k450"] ||
           [lower containsString:@"samsung"] || [lower containsString:@"k-series"];
}

static BOOL device_is_output(AudioObjectID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    return status == noErr && size >= sizeof(AudioObjectID);
}

static UInt32 device_transport(AudioObjectID device) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 transport = 0;
    UInt32 size = sizeof transport;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport) != noErr) {
        return 0;
    }
    return transport;
}

static NSString *device_name(AudioObjectID device) {
    AudioObjectPropertyAddress address = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef name = NULL;
    UInt32 size = sizeof name;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) != noErr || !name) {
        return nil;
    }
    return [(NSString *)name autorelease];
}

static BOOL was_initial_output(SoundbarConnection *c, AudioObjectID device) {
    for (UInt32 i = 0; i < c->initial_output_count; i++) {
        if (c->initial_outputs[i] == device) {
            return YES;
        }
    }
    return NO;
}

static void remember_outputs(SoundbarConnection *c) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *devices = calloc(count ? count : 1, sizeof(AudioObjectID));
    if (!devices) {
        return;
    }
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        for (UInt32 i = 0; i < count && c->initial_output_count < 16; i++) {
            if (device_transport(devices[i]) == kAudioDeviceTransportTypeBluetooth && device_is_output(devices[i])) {
                c->initial_outputs[c->initial_output_count++] = devices[i];
            }
        }
    }
    free(devices);
}

static AudioObjectID find_soundbar_output(SoundbarConnection *c, BOOL allow_new_unnamed) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size);
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *devices = calloc(count ? count : 1, sizeof(AudioObjectID));
        AudioObjectID named = 0;
    AudioObjectID fresh = 0;
    if (!devices) {
        return 0;
    }
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) == noErr) {
        for (UInt32 i = 0; i < count; i++) {
            if (device_transport(devices[i]) != kAudioDeviceTransportTypeBluetooth || !device_is_output(devices[i])) {
                continue;
            }
            if (name_is_soundbar(device_name(devices[i]))) {
                named = devices[i];
                break;
            }
            if (allow_new_unnamed && !was_initial_output(c, devices[i]) && !fresh) {
                fresh = devices[i];
            }
        }
    }
    AudioObjectID found = named ? named : fresh;
    free(devices);
    return found;
}

static BOOL select_output(AudioObjectID device) {
    AudioObjectPropertyAddress output = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectPropertyAddress system = {
        kAudioHardwarePropertyDefaultSystemOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus a = AudioObjectSetPropertyData(kAudioObjectSystemObject, &output, 0, NULL, sizeof device, &device);
    OSStatus b = AudioObjectSetPropertyData(kAudioObjectSystemObject, &system, 0, NULL, sizeof device, &device);
    return a == noErr && b == noErr;
}

static BOOL finish_if_speaker_present(SoundbarConnection *c, BOOL allow_new_unnamed) {
    AudioObjectID device = find_soundbar_output(c, allow_new_unnamed);
    if (!device) {
        return NO;
    }
    if (!select_output(device)) {
        set_status(c, "De soundbar is er, maar macOS nam hem niet als uitgang.");
        c->ok = 0;
        c->phase = PHASE_DONE;
        return YES;
    }
    NSString *name = device_name(device);
    if (name.length > 0) {
        snprintf(c->status, sizeof c->status, "Geluid gaat naar %s.", name.UTF8String);
    } else {
        set_status(c, "Geluid gaat naar de soundbar.");
    }
    c->ok = 1;
    c->phase = PHASE_DONE;
    return YES;
}

static int authorization(void) {
    Class manager = objc_getClass("CBManager");
    if (!manager) {
        return 0;
    }
    return (int)((NSInteger (*)(id, SEL))objc_msgSend)(manager, sel_registerName("authorization"));
}

static void refresh_handles(SoundbarConnection *c) {
    if (!c->peer && c->manager) {
        id peer = ((id (*)(id, SEL, id))objc_msgSend)(
            c->manager, sel_registerName("retrievePeerWithAddress:"), kAddressColon);
        if (!peer) {
            peer = ((id (*)(id, SEL, id))objc_msgSend)(
                c->manager, sel_registerName("retrievePeerWithAddress:"), kAddressDash);
        }
        if (!peer) {
            uint8_t bytes[6] = {0xCC, 0x6E, 0xA4, 0x2F, 0x91, 0x22};
            NSData *data = [NSData dataWithBytes:bytes length:6];
            peer = ((id (*)(id, SEL, id))objc_msgSend)(
                c->manager, sel_registerName("retrievePeerWithAddress:"), data);
        }
        if (peer) {
            c->peer = [peer retain];
        }
    }
    if (!c->bm_device && c->bt_manager) {
        id device = ((id (*)(id, SEL, id))objc_msgSend)(
            c->bt_manager, sel_registerName("deviceFromAddressString:"), kAddressColon);
        if (!device) {
            device = ((id (*)(id, SEL, id))objc_msgSend)(
                c->bt_manager, sel_registerName("deviceFromAddressString:"), kAddressDash);
        }
        if (device) {
            c->bm_device = [device retain];
        }
    }
}

static unsigned int connected_services(SoundbarConnection *c) {
    unsigned int mask = 0;
    if (c->peer) {
        mask |= ((unsigned int (*)(id, SEL))objc_msgSend)(
            c->peer, sel_registerName("getConnectedServices"));
    }
    if (c->bm_device) {
        mask |= (unsigned int)((unsigned long long (*)(id, SEL))objc_msgSend)(
            c->bm_device, sel_registerName("connectedServices"));
    }
    return mask;
}

static void request_audio_profile(SoundbarConnection *c) {
    if (c->a2dp_requested) {
        return;
    }
    refresh_handles(c);
    BOOL paired = c->io_device && ((BOOL (*)(id, SEL))objc_msgSend)(c->io_device, sel_registerName("isPaired"));
    if (c->peer && c->manager) {
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        options[@"kCBOptionServicesKey"] = @(kServiceAudio);
        if (!paired) {
            options[@"kCBMsgIdSessionPairingRequest"] = @YES;
        }
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            c->manager, sel_registerName("connectPeer:options:"), c->peer, options);
        c->a2dp_requested = 1;
        set_status(c, "Audio-profiel openen (A2DP)…");
        return;
    }
    if (c->bm_device) {
        ((void (*)(id, SEL, unsigned int))objc_msgSend)(
            c->bm_device, sel_registerName("connectWithServices:"), kServiceAudio);
        c->a2dp_requested = 1;
        set_status(c, "Audio-profiel openen (A2DP)…");
    }
}

static void drop_link(SoundbarConnection *c) {
    if (c->io_device && ((BOOL (*)(id, SEL))objc_msgSend)(c->io_device, sel_registerName("isConnected"))) {
        ((IOReturn (*)(id, SEL))objc_msgSend)(c->io_device, sel_registerName("closeConnection"));
    }
    if (c->peer && c->manager) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(
            c->manager, sel_registerName("cancelPeerConnection:force:"), c->peer, YES);
    }
    if (c->bm_device) {
        ((void (*)(id, SEL))objc_msgSend)(c->bm_device, sel_registerName("disconnect"));
    }
    c->a2dp_requested = 0;
    c->paging = 0;
    c->paging_done = 0;
}

static void page_soundbar(SoundbarConnection *c) {
    if (c->paging || !c->io_device) {
        return;
    }
    IOReturn started = ((IOReturn (*)(id, SEL, id, BluetoothHCIPageTimeout, BOOL))objc_msgSend)(
        c->io_device,
        sel_registerName("openConnection:withPageTimeout:authenticationRequired:"),
        c->delegate,
        (BluetoothHCIPageTimeout)0x4000,
        YES);
    c->paging = 1;
    if (started != kIOReturnSuccess) {
        c->paging_done = 1;
        c->paging_status = (int)started;
    }
    set_status(c, "Soundbar opzoeken… Zet de bron op Bluetooth als het display dat nog niet toont.");
}

static void enter(SoundbarConnection *c, int phase, const char *status) {
    c->phase = phase;
    c->phase_started = CFAbsoluteTimeGetCurrent();
    if (status && status != c->status) {
        set_status(c, status);
    }
}

static void fail(SoundbarConnection *c, const char *status) {
    set_status(c, status);
    c->ok = 0;
    c->phase = PHASE_DONE;
}

static void tick(SoundbarConnection *c) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double phase_age = now - c->phase_started;

    switch (c->phase) {
    case PHASE_AUTH: {
        int auth = authorization();
        /* 1 = restricted, 2 = denied. State 3 is unauthorized, but only after
           the user has actually answered the prompt. */
        if (auth == 2 || auth == 1 || (c->central_state == 3 && auth != 0 && phase_age > 1.0)) {
            fail(c, "Bluetooth-toegang is geweigerd. Zet Soundbar aan onder Systeeminstellingen → Privacy en beveiliging → Bluetooth.");
            return;
        }
        if (c->central_state == 4) {
            fail(c, "Bluetooth staat uit. Zet Bluetooth aan en druk opnieuw.");
            return;
        }
        BOOL ready = auth == 3 || c->central_state == 5;
        if (!ready && phase_age < 45.0) {
            if (!c->auth_prompted) {
                set_status(c, "Bevestig Bluetooth-toegang als macOS daarom vraagt.");
                c->auth_prompted = 1;
            }
            return;
        }
        if (finish_if_speaker_present(c, NO)) {
            return;
        }
        BOOL connected = c->io_device && ((BOOL (*)(id, SEL))objc_msgSend)(c->io_device, sel_registerName("isConnected"));
        if (connected) {
            enter(c, PHASE_RESET, "Vorige verbinding zonder luidspreker sluiten…");
            drop_link(c);
            return;
        }
        BOOL paired = c->io_device && ((BOOL (*)(id, SEL))objc_msgSend)(c->io_device, sel_registerName("isPaired"));
        if (paired) {
            enter(c, PHASE_CONNECT, "Audio-profiel openen (A2DP)…");
        } else {
            enter(c, PHASE_PAIR, "Koppelen met de soundbar…");
        }
        return;
    }
    case PHASE_RESET:
        if (phase_age < 1.5) {
            return;
        }
        enter(c, PHASE_CONNECT, "Audio-profiel openen (A2DP)…");
        return;
    case PHASE_PAIR: {
        if (!c->pair_started) {
            c->pairer = [[IOBluetoothDevicePair pairWithDevice:c->io_device] retain];
            ((void (*)(id, SEL, id))objc_msgSend)(c->pairer, sel_registerName("setDelegate:"), c->delegate);
            IOReturn started = ((IOReturn (*)(id, SEL))objc_msgSend)(c->pairer, sel_registerName("start"));
            c->pair_started = 1;
            if (started != kIOReturnSuccess) {
                c->pair_done = 1;
                c->pair_status = (int)started;
            }
        }
        if (!c->pair_done && phase_age < 25.0) {
            return;
        }
        enter(c, PHASE_CONNECT, "Audio-profiel openen (A2DP)…");
        return;
    }
    case PHASE_CONNECT:
        refresh_handles(c);
        request_audio_profile(c);
        if (!c->a2dp_requested) {
            page_soundbar(c);
        }
        if (c->status[0] == '\0') {
            set_status(c, "Wachten tot de soundbar als luidspreker verschijnt…");
        }
        enter(c, PHASE_WAIT, NULL);
        return;
    case PHASE_WAIT: {
        refresh_handles(c);
        if (!c->a2dp_requested) {
            request_audio_profile(c);
        }
        if (c->paging_done && !c->a2dp_requested) {
            request_audio_profile(c);
        }
        unsigned int services = connected_services(c);
        if ((services & kServiceA2DP) != 0) {
            set_status(c, "A2DP staat open. Luidspreker klaarzetten…");
        }
        if (finish_if_speaker_present(c, YES)) {
            return;
        }
        if (phase_age < 18.0) {
            if ((services & kServiceA2DP) == 0 && c->a2dp_requested) {
                set_status(c, "Wachten tot de soundbar als luidspreker verschijnt…");
            }
            return;
        }
        if (c->attempts < 1) {
            c->attempts += 1;
            drop_link(c);
            enter(c, PHASE_SETTLE, "Opnieuw proberen, alleen het audio-profiel…");
            return;
        }
        fail(c, "De soundbar kwam niet als luidspreker binnen. Zet de bron op Bluetooth (BT PAIRING) en druk opnieuw.");
        return;
    }
    case PHASE_SETTLE:
        if (phase_age < 1.5) {
            return;
        }
        enter(c, PHASE_CONNECT, "Audio-profiel openen (A2DP)…");
        return;
    default:
        return;
    }
}

SoundbarConnection *soundbar_connection_start(void) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth", RTLD_LAZY);
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);

        SoundbarConnection *c = calloc(1, sizeof *c);
        c->delegate = make_delegate(c);
        c->central = [[CBCentralManager alloc]
            initWithDelegate:c->delegate
                       queue:dispatch_get_main_queue()
                     options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];

        Class classic = objc_getClass("CBClassicManager");
        if (classic) {
            id manager = [classic alloc];
            c->manager = ((id (*)(id, SEL, dispatch_queue_t, id))objc_msgSend)(
                manager,
                sel_registerName("initWithQueue:options:"),
                dispatch_get_main_queue(),
                @{@"kCBInitOptionShowPowerAlert": @NO});
        }

        Class bluetooth_manager = objc_getClass("BluetoothManager");
        if (bluetooth_manager) {
            c->bt_manager = ((id (*)(id, SEL))objc_msgSend)(
                bluetooth_manager, sel_registerName("sharedInstance"));
            [c->bt_manager retain];
        }

        c->io_device = [[IOBluetoothDevice deviceWithAddressString:kAddressDash] retain];
        if (!c->io_device) {
            c->io_device = [[IOBluetoothDevice deviceWithAddressString:kAddressColon] retain];
        }

        remember_outputs(c);
        c->started = CFAbsoluteTimeGetCurrent();
        enter(c, PHASE_AUTH, "Bluetooth openen…");
        return c;
    }
}

void soundbar_connection_poll(
    SoundbarConnection *connection,
    char *status,
    size_t status_len,
    int *finished,
    int *ok
) {
    @autoreleasepool {
        if (!connection) {
            if (finished) *finished = 1;
            if (ok) *ok = 0;
            if (status && status_len) strlcpy(status, "Geen verbinding.", status_len);
            return;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        if (connection->phase != PHASE_DONE) {
            tick(connection);
        }
        if (status && status_len) {
            strlcpy(status, connection->status, status_len);
        }
        if (finished) *finished = connection->phase == PHASE_DONE;
        if (ok) *ok = connection->ok;
    }
}

void soundbar_connection_free(SoundbarConnection *connection) {
    if (!connection) {
        return;
    }
    @autoreleasepool {
        if (connection->pairer && !connection->ok) {
            ((void (*)(id, SEL))objc_msgSend)(connection->pairer, sel_registerName("stop"));
        }
        [connection->pairer release];
        [connection->peer release];
        [connection->bm_device release];
        [connection->io_device release];
        [connection->bt_manager release];
        [connection->manager release];
        [connection->central release];
        Ivar ivar = class_getInstanceVariable(g_delegate_class, "session");
        if (connection->delegate && ivar) {
            *(void **)((char *)connection->delegate + ivar_getOffset(ivar)) = NULL;
        }
        [connection->delegate release];
        free(connection);
    }
}
