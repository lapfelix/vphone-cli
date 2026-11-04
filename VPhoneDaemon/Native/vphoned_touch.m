/*
 * vphoned_touch — multi-finger digitizer injection.
 *
 * icli's `input.touch` carries a single finger, so a pinch (two fingers moving
 * together) cannot be expressed through it. This builds one hand event holding
 * several fingers and dispatches it, the shape WebKit's HIDEventGenerator and
 * TrollVNC's STHIDEventGenerator use.
 *
 * Every entry point is resolved with dlsym, so a base without the private
 * digitizer symbols still starts; injection then logs once and stays a no-op.
 *
 * Coordinates are normalized to 0..1 with the origin at the top-left, matching
 * what `GuestAPI` hands a gesture.
 */

#import "Include/VphonedNative.h"

#import <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef double IOHIDFloat;

static IOHIDEventSystemClientRef (*pCreate)(CFAllocatorRef);
static void (*pSetSender)(IOHIDEventRef, uint64_t);
static void (*pDispatch)(IOHIDEventSystemClientRef, IOHIDEventRef);

static IOHIDEventRef (*pDigitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                   uint32_t, uint32_t, uint32_t, IOHIDFloat,
                                   IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                   boolean_t, boolean_t, uint32_t);
static IOHIDEventRef (*pFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat,
                                IOHIDFloat, IOHIDFloat, boolean_t, boolean_t, uint32_t);
static void (*pAppend)(IOHIDEventRef, IOHIDEventRef, uint32_t);
static void (*pSetInt)(IOHIDEventRef, uint32_t, int);
static IOHIDEventRef (*pKeyboard)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, boolean_t, uint32_t);

static IOHIDEventSystemClientRef gTouchClient;
static dispatch_queue_t gTouchQueue;
static bool gTouchUnavailableLogged;

// Apple's Research Guests host has no USB touchscreen. Publish the same
// four-finger HID descriptor as VZ's Virtual USB Touch Screen, captured in
// Research/Guest/Evidence/iphone_duo_inner_hid_service_20261026.json, only
// when the daemon uses the authenticated Research Guests TCP transport.
typedef struct __IOHIDUserDevice *VPResearchHIDDeviceRef;
static VPResearchHIDDeviceRef (*pResearchCreate)(CFAllocatorRef, CFDictionaryRef, IOOptionBits);
static void (*pResearchSchedule)(VPResearchHIDDeviceRef, dispatch_queue_t);
static IOReturn (*pResearchHandleReport)(VPResearchHIDDeviceRef, uint8_t *, CFIndex);
static VPResearchHIDDeviceRef gResearchDevice;
static dispatch_queue_t gResearchDeviceQueue;
static dispatch_queue_t gResearchReportQueue;
static bool gResearchTouchMode;
static atomic_int gResearchLastStatus = ATOMIC_VAR_INIT(kIOReturnNotReady);
static atomic_uint_fast64_t gResearchLastEdgeSender;
static NSString *gResearchTouchError = @"not_started";
// Accessed only from gResearchReportQueue while one edge gesture is active.
static IOHIDEventSystemClientRef gResearchEdgeClient;
static uint64_t gResearchEdgeSender;
static uint32_t gResearchEdgeFlags;

bool vp_research_touch_start(void) {
    if (gResearchTouchMode) return gResearchDevice != NULL;
    gResearchTouchMode = true;

    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    pResearchCreate = ioKit ? dlsym(ioKit, "IOHIDUserDeviceCreateWithOptions") : NULL;
    pResearchSchedule = ioKit ? dlsym(ioKit, "IOHIDUserDeviceScheduleWithDispatchQueue") : NULL;
    pResearchHandleReport = ioKit ? dlsym(ioKit, "IOHIDUserDeviceHandleReport") : NULL;
    if (!pResearchCreate || !pResearchSchedule || !pResearchHandleReport) {
        gResearchTouchError = @"symbols_unavailable";
        NSLog(@"vphoned: Research touchscreen: IOHIDUserDevice APIs unavailable");
        return false;
    }

    // No report ID. Each of four fingers has a six-bit index, in-range and
    // tip bits, then X and Y as 16-bit little-endian values: 20 bytes total.
    NSString *encoded = @"BQ0JBKEBBQ0JIqECCTh1BpUBgQIJMgkzFQAlAXUBlQKBAgUBCTAJMRUAJv9/dRCVAoECwAUNCSKhAgk4dQaVAYECCTIJMxUAJQF1AZUCgQIFAQkwCTEVACb/f3UQlQKBAsAFDQkioQIJOHUGlQGBAgkyCTMVACUBdQGVAoECBQEJMAkxFQAm/391EJUCgQLABQ0JIqECCTh1BpUBgQIJMgkzFQAlAXUBlQKBAgUBCTAJMRUAJv9/dRCVAoECwMA=";
    NSData *descriptor = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (descriptor.length != 191) {
        gResearchTouchError = @"invalid_descriptor";
        NSLog(@"vphoned: Research touchscreen: captured HID descriptor is invalid");
        return false;
    }
    NSDictionary *properties = @{
        @"ReportDescriptor": descriptor,
        @"Product": @"Virtual USB Touch Screen",
        @"Manufacturer": @"VPhone",
        @"Transport": @"USB",
        @"VendorID": @0x05ac,
        @"ProductID": @33032,
        @"PhysicalDeviceUniqueID": @"vphone-research-touch",
        @"DeviceUsagePage": @13,
        @"DeviceUsage": @4,
        @"DisplayIntegrated": @YES,
        @"Built-In": @YES,
        @"Authenticated": @YES,
    };
    gResearchDeviceQueue = dispatch_queue_create("com.vphone.vphoned.research-touch.device", DISPATCH_QUEUE_SERIAL);
    gResearchReportQueue = dispatch_queue_create("com.vphone.vphoned.research-touch.report", DISPATCH_QUEUE_SERIAL);
    gResearchDevice = pResearchCreate(kCFAllocatorDefault, (__bridge CFDictionaryRef)properties, 1 << 0);
    if (!gResearchDevice) {
        gResearchTouchError = @"device_creation_failed";
        NSLog(@"vphoned: Research touchscreen: virtual HID device creation failed");
        return false;
    }
    pResearchSchedule(gResearchDevice, gResearchDeviceQueue);
    atomic_store(&gResearchLastStatus, kIOReturnSuccess);
    gResearchTouchError = @"";
    NSLog(@"vphoned: Research touchscreen: virtual HID device registered");
    return true;
}

bool vp_research_touch_mode(void) { return gResearchTouchMode; }

int vp_research_touch_report(int phase, double x, double y) {
    if (!gResearchDevice || !pResearchHandleReport) return kIOReturnNotReady;
    if (!isfinite(x) || !isfinite(y) ||
        x < 0 || x > 1 || y < 0 || y > 1 || (phase != 0 && phase != 1 && phase != 3)) {
        return kIOReturnBadArgument;
    }
    uint16_t px = (uint16_t)lround(x * 32767.0);
    uint16_t py = (uint16_t)lround(y * 32767.0);
    uint8_t report[20] = {
        (uint8_t)(phase == 3 ? 1 : 0xC1),
        (uint8_t)px, (uint8_t)(px >> 8), (uint8_t)py, (uint8_t)(py >> 8),
    };
    NSMutableData *reportData = [NSMutableData dataWithBytes:report length:sizeof(report)];
    __block IOReturn status;
    dispatch_sync(gResearchReportQueue, ^{
        status = pResearchHandleReport(gResearchDevice, reportData.mutableBytes, reportData.length);
        atomic_store(&gResearchLastStatus, status);
    });
    return status;
}

NSDictionary<NSString *, id> *vp_hid_input_devices(void) {
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    IOHIDEventSystemClientRef (*create)(CFAllocatorRef) = ioKit ? dlsym(ioKit, "IOHIDEventSystemClientCreate") : NULL;
    CFArrayRef (*copyServices)(IOHIDEventSystemClientRef) = ioKit ? dlsym(ioKit, "IOHIDEventSystemClientCopyServices") : NULL;
    CFTypeRef (*copyProperty)(const void *, CFStringRef) = ioKit ? dlsym(ioKit, "IOHIDServiceClientCopyProperty") : NULL;
    CFTypeRef (*registryID)(const void *) = ioKit ? dlsym(ioKit, "IOHIDServiceClientGetRegistryID") : NULL;
    if (!create || !copyServices || !copyProperty) return @{@"available": @NO, @"reason": @"HID service APIs unavailable"};
    IOHIDEventSystemClientRef client = create(kCFAllocatorDefault);
    if (!client) return @{@"available": @NO, @"reason": @"HID read client unavailable"};
    CFArrayRef services = copyServices(client);
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *keys = @[@"Product", @"Transport", @"VendorID", @"ProductID", @"PrimaryUsagePage", @"PrimaryUsage",
        @"DeviceUsagePairs", @"DisplayIntegrated", @"DisplayID", @"DisplayIdentifier", @"DisplayUUID",
        @"PixelWidth", @"PixelHeight", @"DigitizerSurfaceDimensions", @"DisplaySurfaceDimensions",
        @"DigitizerSurfaceWidth", @"DigitizerSurfaceHeight", @"PhysicalMaxX", @"PhysicalMaxY",
        @"LogicalMaxX", @"LogicalMaxY", @"MinX", @"MinY", @"MaxX", @"MaxY", @"ReportDescriptor"];
    for (CFIndex index = 0; services && index < CFArrayGetCount(services) && index < 64; index++) {
        const void *service = CFArrayGetValueAtIndex(services, index);
        NSMutableDictionary *row = [NSMutableDictionary dictionaryWithObject:@(index) forKey:@"index"];
        CFTypeRef identifier = registryID ? registryID(service) : NULL;
        if (identifier && CFGetTypeID(identifier) == CFNumberGetTypeID()) row[@"registryID"] = (__bridge NSNumber *)identifier;
        for (NSString *key in keys) {
            CFTypeRef copied = copyProperty(service, (__bridge CFStringRef)key);
            if (!copied) continue;
            id value = CFBridgingRelease(copied);
            if ([value isKindOfClass:NSData.class]) {
                NSData *data = value;
                row[key] = @{@"byteCount": @(data.length), @"base64": [[data subdataWithRange:NSMakeRange(0, MIN(data.length, 4096))] base64EncodedStringWithOptions:0]};
            } else if ([NSJSONSerialization isValidJSONObject:@[value]]) row[key] = value;
        }
        [rows addObject:row];
    }
    NSUInteger count = services ? (NSUInteger)CFArrayGetCount(services) : 0;
    if (services) CFRelease(services);
    CFRelease(client);
    return @{@"available": @YES, @"serviceCount": @(count), @"services": rows,
             @"researchTouchMode": @(gResearchTouchMode),
             @"researchTouchRegistered": @(gResearchDevice != NULL),
             @"researchTouchError": gResearchTouchError,
             @"researchTouchLastStatus": @(atomic_load(&gResearchLastStatus)),
             @"researchEdgeSender": @(atomic_load(&gResearchLastEdgeSender))};
}

// Digitizer event-mask bits and transducer types (IOHIDEventTypes.h).
#define VP_DIG_RANGE 0x00000001u
#define VP_DIG_TOUCH 0x00000002u
#define VP_DIG_POSITION 0x00000004u
#define VP_DIG_IDENTITY 0x00000020u
// Edge flags as touch firmware reports them for a touch that starts at a screen
// edge. UIKit (_UIEventHIDTouchEdgeTypeForHIDEvent) maps 0x800 to edge type 1,
// which UIScreenEdgePanGestureRecognizer requires to begin, and bits 24-27 to
// the edge aim (1 bottom, 2 top, 4 right, 8 left). Without them SpringBoard's
// bottom-edge home gesture (and Control Center / Notification Center from the
// top) never starts. The VZ USB touchscreen reports none of this: its HID
// report has only index, range, touch, x and y per finger.
#define VP_DIG_FROM_EDGE 0x00000800u
#define VP_DIG_AIM_SHIFT 24
#define VP_TRANSDUCER_HAND 1
// kIOHIDEventFieldDigitizerIsDisplayIntegrated: (kIOHIDEventTypeDigitizer << 16) | offset.
#define VP_FIELD_IS_DISPLAY_INTEGRATED ((((uint32_t)11) << 16) | 25)

bool vp_hid_load(void) {
    if (gTouchClient) return true;

    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!ioKit) {
        NSLog(@"vphoned: dlopen IOKit failed, touch injection disabled");
        return false;
    }

    pCreate = dlsym(ioKit, "IOHIDEventSystemClientCreate");
    pSetSender = dlsym(ioKit, "IOHIDEventSetSenderID");
    pDispatch = dlsym(ioKit, "IOHIDEventSystemClientDispatchEvent");
    pDigitizer = dlsym(ioKit, "IOHIDEventCreateDigitizerEvent");
    pFinger = dlsym(ioKit, "IOHIDEventCreateDigitizerFingerEvent");
    pAppend = dlsym(ioKit, "IOHIDEventAppendEvent");
    pSetInt = dlsym(ioKit, "IOHIDEventSetIntegerValue");
    pKeyboard = dlsym(ioKit, "IOHIDEventCreateKeyboardEvent");

    if (!pCreate || !pSetSender || !pDispatch || !pDigitizer || !pFinger || !pAppend || !pSetInt) {
        NSLog(@"vphoned: digitizer symbols missing, touch injection disabled");
        return false;
    }

    gTouchClient = pCreate(kCFAllocatorDefault);
    if (!gTouchClient) {
        NSLog(@"vphoned: IOHIDEventSystemClientCreate returned NULL");
        return false;
    }

    dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
    gTouchQueue = dispatch_queue_create("com.vphone.vphoned.touch", attributes);
    return true;
}

bool vp_hid_keyboard_hold(uint16_t page, uint16_t usage, bool down) {
    if (!vp_hid_load() || !pKeyboard) return false;
    IOHIDEventRef event = pKeyboard(kCFAllocatorDefault, mach_absolute_time(), page, usage, down, 0);
    if (!event) return false;
    // The same built-in marker and sender as IcliKit's ordinary key events.
    pSetInt(event, 4, 1);
    // kIOHIDEventFieldKeyboardLongPress. SBHPIOHID reads this field for Center.
    pSetInt(event, (3u << 16) | 5u, 1);
    pSetSender(event, 0x8000000817319372);
    // Input RPCs are ordered; finish dispatch before acknowledging the hold.
    dispatch_sync(gTouchQueue, ^{ pDispatch(gTouchClient, event); });
    CFRelease(event);
    return true;
}

// One hand event carrying `count` fingers, dispatched as a single gesture.
static void dispatch_digitizer_points(const double *xs, const double *ys,
                                      int count, boolean_t range, boolean_t touch,
                                      uint32_t mask) {
    if (!gTouchClient || !pDigitizer || !pFinger || !pAppend || !pSetInt || count <= 0) return;

    uint64_t timestamp = mach_absolute_time();
    IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, timestamp, VP_TRANSDUCER_HAND,
                                    0, 0, mask, 0, xs[0], ys[0], 0, 0, 0, range, touch, 0);
    if (!hand) return;
    pSetInt(hand, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);

    for (int index = 0; index < count; index++) {
        // Finger 0 keeps index 1 / identity 2 so the single-finger path is
        // unchanged; extra fingers carry their own identity so the guest tracks
        // them as separate touches instead of collapsing them into one.
        IOHIDEventRef finger = pFinger(kCFAllocatorDefault, timestamp, (uint32_t)(index + 1),
                                       (uint32_t)(index + 2), mask, xs[index], ys[index],
                                       0, 0, 0, range, touch, 0);
        if (!finger) continue;
        pSetInt(finger, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);
        pAppend(hand, finger, 0);
        CFRelease(finger);
    }

    IOHIDEventRef strong = (IOHIDEventRef)CFRetain(hand);
    dispatch_async(gTouchQueue, ^{
        pSetSender(strong, 0x8000000817319372);
        pDispatch(gTouchClient, strong);
        CFRelease(strong);
    });
    CFRelease(hand);
}

void vp_hid_touch2(int phase, double x1, double y1, double x2, double y2) {
    if (!gTouchClient) {
        if (!vp_hid_load() && !gTouchUnavailableLogged) {
            gTouchUnavailableLogged = true;
            NSLog(@"vphoned: two-finger injection unavailable on this base");
        }
        if (!gTouchClient) return;
    }

    const double xs[2] = {x1, x2};
    const double ys[2] = {y1, y2};
    switch (phase) {
        case 0: // down
            dispatch_digitizer_points(xs, ys, 2, 1, 1, VP_DIG_TOUCH | VP_DIG_IDENTITY);
            break;
        case 1: // move
            dispatch_digitizer_points(xs, ys, 2, 1, 1, VP_DIG_POSITION);
            break;
        case 3: // up
        default:
            dispatch_digitizer_points(xs, ys, 2, 0, 0, VP_DIG_TOUCH | VP_DIG_IDENTITY);
            break;
    }
}

// Host edge code (`_VZTouch` swipeAim: 1 top, 2 bottom, 4 right, 8 left) to the
// HID edge flags, kept for the whole touch like real firmware does.
static uint32_t edge_flags(int edge) {
    uint32_t aim = 0;
    if (edge & 1) aim |= 2; // top
    if (edge & 2) aim |= 1; // bottom
    if (edge & 4) aim |= 4; // right
    if (edge & 8) aim |= 8; // left
    return aim ? (VP_DIG_FROM_EDGE | (aim << VP_DIG_AIM_SHIFT)) : 0;
}

// The synthetic report device has its own HID service. A client-dispatched
// edge event must use that service's sender ID; the old hard-coded sender is
// not mapped to a display by backboardd on Apple's Research Guests host.
static uint64_t research_digitizer_sender(IOHIDEventSystemClientRef client) {
    void *ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    CFArrayRef (*copyServices)(IOHIDEventSystemClientRef) = ioKit ? dlsym(ioKit, "IOHIDEventSystemClientCopyServices") : NULL;
    CFTypeRef (*copyProperty)(const void *, CFStringRef) = ioKit ? dlsym(ioKit, "IOHIDServiceClientCopyProperty") : NULL;
    CFTypeRef (*registryID)(const void *) = ioKit ? dlsym(ioKit, "IOHIDServiceClientGetRegistryID") : NULL;
    if (!copyServices || !copyProperty || !registryID) return 0;

    CFArrayRef services = copyServices(client);
    uint64_t selected = 0;
    int matches = 0;
    for (CFIndex index = 0; services && index < CFArrayGetCount(services); index++) {
        const void *service = CFArrayGetValueAtIndex(services, index);
        CFTypeRef product = copyProperty(service, CFSTR("Product"));
        CFTypeRef builtIn = copyProperty(service, CFSTR("Built-In"));
        if (product && CFGetTypeID(product) == CFStringGetTypeID() &&
            CFEqual(product, CFSTR("Virtual USB Touch Screen")) && builtIn == kCFBooleanTrue) {
            CFTypeRef identifier = registryID(service); // borrowed CFNumber
            int64_t value = 0;
            if (identifier && CFGetTypeID(identifier) == CFNumberGetTypeID() &&
                CFNumberGetValue((CFNumberRef)identifier, kCFNumberSInt64Type, &value) && value > 0) {
                selected = (uint64_t)value;
                matches++;
            }
        }
        if (product) CFRelease(product);
        if (builtIn) CFRelease(builtIn);
    }
    if (services) CFRelease(services);
    return matches == 1 ? selected : 0;
}

static int research_edge_locked(int phase, double x, double y, int edge) {
    if (phase == 0) {
        if (gResearchEdgeClient) CFRelease(gResearchEdgeClient);
        gResearchEdgeClient = pCreate(kCFAllocatorDefault);
        gResearchEdgeSender = gResearchEdgeClient ? research_digitizer_sender(gResearchEdgeClient) : 0;
        gResearchEdgeFlags = edge_flags(edge);
        if (!gResearchEdgeSender) {
            if (gResearchEdgeClient) CFRelease(gResearchEdgeClient);
            gResearchEdgeClient = NULL;
            NSLog(@"vphoned: Research touchscreen sender is missing or ambiguous");
            return kIOReturnNotReady;
        }
        uint64_t previous = atomic_exchange(&gResearchLastEdgeSender, gResearchEdgeSender);
        if (previous != gResearchEdgeSender) {
            NSLog(@"vphoned: Research touchscreen sender 0x%llx", (unsigned long long)gResearchEdgeSender);
        }
    }
    if (!gResearchEdgeClient || !gResearchEdgeSender) return kIOReturnNotReady;

    uint32_t mask = (phase == 1 ? VP_DIG_POSITION : VP_DIG_TOUCH | VP_DIG_IDENTITY) | gResearchEdgeFlags;
    boolean_t active = phase != 3;
    uint64_t timestamp = mach_absolute_time();
    IOHIDEventRef hand = pDigitizer(kCFAllocatorDefault, timestamp, VP_TRANSDUCER_HAND,
                                   0, 0, mask, 0, x, y, 0, 0, 0, active, active, 0);
    IOHIDEventRef finger = pFinger(kCFAllocatorDefault, timestamp, 1, 2, mask,
                                   x, y, 0, 0, 0, active, active, 0);
    if (!hand || !finger) {
        if (hand) CFRelease(hand);
        if (finger) CFRelease(finger);
        return kIOReturnNoMemory;
    }
    pSetInt(hand, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);
    pSetInt(finger, VP_FIELD_IS_DISPLAY_INTEGRATED, 1);
    pAppend(hand, finger, 0);
    pSetSender(hand, gResearchEdgeSender);
    pDispatch(gResearchEdgeClient, hand);
    CFRelease(finger);
    CFRelease(hand);

    if (phase == 3) {
        CFRelease(gResearchEdgeClient);
        gResearchEdgeClient = NULL;
        gResearchEdgeSender = 0;
        gResearchEdgeFlags = 0;
    }
    return kIOReturnSuccess;
}

int vp_research_touch_edge(int phase, double x, double y, int edge) {
    if (!gResearchDevice || !gResearchReportQueue || !vp_hid_load()) return kIOReturnNotReady;
    if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1 ||
        (phase != 0 && phase != 1 && phase != 3) || edge_flags(edge) == 0) {
        return kIOReturnBadArgument;
    }
    __block int status;
    dispatch_sync(gResearchReportQueue, ^{
        status = research_edge_locked(phase, x, y, edge);
        atomic_store(&gResearchLastStatus, status);
    });
    return status;
}

void vp_hid_touch_edge(int phase, double x, double y, int edge) {
    if (!gTouchClient) {
        if (!vp_hid_load() && !gTouchUnavailableLogged) {
            gTouchUnavailableLogged = true;
            NSLog(@"vphoned: edge touch injection unavailable on this base");
        }
        if (!gTouchClient) return;
    }

    const uint32_t flags = edge_flags(edge);
    const double xs[1] = {x};
    const double ys[1] = {y};
    switch (phase) {
        case 0: // down
            dispatch_digitizer_points(xs, ys, 1, 1, 1, VP_DIG_TOUCH | VP_DIG_IDENTITY | flags);
            break;
        case 1: // move
            dispatch_digitizer_points(xs, ys, 1, 1, 1, VP_DIG_POSITION | flags);
            break;
        case 3: // up
        default:
            dispatch_digitizer_points(xs, ys, 1, 0, 0, VP_DIG_TOUCH | VP_DIG_IDENTITY | flags);
            break;
    }
}
