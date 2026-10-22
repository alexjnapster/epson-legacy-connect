#import "NativeUSB.h"
#import <CoreFoundation/CFPlugInCOM.h>
#import <Security/Security.h>

typedef struct {
    int (*retain)(void *); int (*release)(void *);
    int (*initialize)(void *); int (*terminate)(void *);
    int (*ioctl)(void *, int, void *);
    int (*open)(void *, CFDataRef, int); int (*close)(void *);
    int (*openChannel)(void *, void **, const char *, int);
    int (*closeChannel)(void *, void *);
    int (*write)(void *, void *, const char *, int *, char, int);
    int (*read)(void *, void *, char *, int *, char *, int);
} EWInterface;

static void EWError(NSError **error, NSInteger code, NSString *message) {
    NSString *selected = [NSUserDefaults.standardUserDefaults stringForKey:@"assistant.language"] ?: @"system";
    NSString *language = [selected isEqualToString:@"system"] ? ([NSLocale.preferredLanguages.firstObject hasPrefix:@"uk"] ? @"uk" : @"en") : selected;
    NSString *path = [NSBundle.mainBundle pathForResource:language ofType:@"lproj"];
    NSBundle *localization = path ? [NSBundle bundleWithPath:path] : NSBundle.mainBundle;
    message = [localization localizedStringForKey:message value:message table:nil];
    if (error) *error = [NSError errorWithDomain:@"EpsonWiFiAssistant.USB" code:code
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
}

@interface EWSession : NSObject
@property CFPlugInRef plugin;
@property EWInterface **interface;
@property BOOL initialized;
@property BOOL opened;
@property void *channel;
- (instancetype)initWithPlugin:(NSString *)path error:(NSError **)error;
@end

@implementation EWSession
- (instancetype)initWithPlugin:(NSString *)path error:(NSError **)error {
    if (!(self = [super init])) return nil;
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    SecStaticCodeRef code = NULL;
    SecRequirementRef requirement = NULL;
    OSStatus valid = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    if (valid == errSecSuccess) valid = SecRequirementCreateWithString(
        CFSTR("anchor apple generic and identifier \"com.epson.print.plugin.XIOCBTm\" and certificate leaf[subject.OU] = \"TXAEAV5RN4\""),
        kSecCSDefaultFlags, &requirement);
    if (valid == errSecSuccess) valid = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, requirement);
    if (requirement) CFRelease(requirement);
    if (code) CFRelease(code);
    if (valid != errSecSuccess) {
        EWError(error, valid, @"The Epson USB component is missing, modified, or does not have Epson's signature.");
        return nil;
    }
    _plugin = CFPlugInCreate(NULL, (__bridge CFURLRef)url);
    if (!_plugin) { EWError(error, 1, @"The Epson USB component could not be loaded."); return nil; }
    CFUUIDRef type = CFUUIDCreateFromString(NULL, CFSTR("7283F260-4DC6-11DD-B6F5-001B633893CF"));
    CFUUIDRef factory = CFUUIDCreateFromString(NULL, CFSTR("703686F8-4DC6-11DD-A436-001B633893CF"));
    CFUUIDRef iid = CFUUIDCreateFromString(NULL, CFSTR("9906C59E-8779-11E0-AE37-001B633893CF"));
    IUnknownVTbl **unknown = CFPlugInInstanceCreate(NULL, factory, type);
    HRESULT result = unknown ? (*unknown)->QueryInterface(unknown, CFUUIDGetUUIDBytes(iid), (void **)&_interface) : -1;
    if (unknown) (*unknown)->Release(unknown);
    CFRelease(type); CFRelease(factory); CFRelease(iid);
    if (result || !_interface) { EWError(error, 2, @"This Epson USB component does not support the required interface."); return nil; }
    int status = (*_interface)->initialize(_interface);
    if (status) { EWError(error, status, @"The Epson USB component could not start."); return nil; }
    _initialized = YES;
    return self;
}
- (void)dealloc {
    if (_interface) {
        if (_channel) (*_interface)->closeChannel(_interface, _channel);
        if (_opened) (*_interface)->close(_interface);
        if (_initialized) (*_interface)->terminate(_interface);
        (*_interface)->release(_interface);
    }
    if (_plugin) CFRelease(_plugin);
}
@end

static NSObject *EWLock(void) {
    static NSObject *lock; static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

NSData *EWEnumerate(NSString *pluginPath, NSError **error) {
    @synchronized(EWLock()) {
        EWSession *session = [[EWSession alloc] initWithPlugin:pluginPath error:error];
        if (!session) return nil;
        CFDictionaryRef devices = NULL;
        int status = (*session.interface)->ioctl(session.interface, 4, &devices);
        if (status) { EWError(error, status, @"USB discovery failed. Check the cable and printer power."); return nil; }
        if (!devices) return [NSPropertyListSerialization dataWithPropertyList:@{@"InfoPrinterList":@[]}
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:(__bridge id)devices
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:error];
        CFRelease(devices);
        return data;
    }
}

static BOOL EWWrite(EWSession *session, NSData *bytes, char end, NSError **error) {
    NSUInteger sent = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    while (sent < bytes.length) {
        int count = (int)MIN(bytes.length - sent, 2048);
        int requested = count;
        char control = end && sent + count == bytes.length ? 1 : 0;
        int status = (*session.interface)->write(session.interface, session.channel,
            (const char *)bytes.bytes + sent, &count, control, 3000);
        if (status || count < 0 || count > requested) {
            EWError(error, status ?: 10, @"The printer interrupted the USB transfer. No successful setup has been confirmed."); return NO;
        }
        sent += count;
        if (count == 0) {
            EWError(error, 11, @"The printer accepted no configuration data. Restart the printer, keep USB connected, then retry."); return NO;
        }
        if ([deadline timeIntervalSinceNow] <= 0) {
            EWError(error, 12, @"The USB transfer timed out."); return NO;
        }
    }
    return YES;
}

NSData *EWExchange(NSString *pluginPath, NSData *deviceAddress, NSData *request, NSError **error) {
    @synchronized(EWLock()) {
        if (!request.length || request.length > 65536 || !deviceAddress.length) {
            EWError(error, 13, @"Invalid printer configuration request."); return nil;
        }
        EWSession *session = [[EWSession alloc] initWithPlugin:pluginPath error:error];
        if (!session) return nil;
        int status = (*session.interface)->open(session.interface, (__bridge CFDataRef)deviceAddress, 3000);
        if (status) { EWError(error, status, @"Could not open the selected printer. Check that it is connected and not in use."); return nil; }
        session.opened = YES;
        void *channel = NULL;
        status = (*session.interface)->openChannel(session.interface, &channel, "EPSON-XCTRL", 3000);
        if (status || !channel) { EWError(error, status ?: 14, @"The printer's USB setup channel is unavailable."); return nil; }
        session.channel = channel;
        NSData *prefix = [@"WSDConfigReq:Operation\x1b\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        if (!EWWrite(session, prefix, 0, error) || !EWWrite(session, request, 1, error)) return nil;
        NSMutableData *header = [NSMutableData data];
        BOOL complete = NO;
        for (int i = 0; i < 128; i++) {
            char byte = 0, control = 0; int count = 1;
            status = (*session.interface)->read(session.interface, channel, &byte, &count, &control, 5000);
            if (status || count != 1 || control) {
                EWError(error, status ?: 15, @"The printer did not return a valid USB response header."); return nil;
            }
            [header appendBytes:&byte length:1];
            if (header.length >= 3 && memcmp((const char *)header.bytes + header.length - 3, "\x1b\r\n", 3) == 0) { complete = YES; break; }
        }
        const char *expected = "WSDRes:000\x1b\r\n";
        if (!complete || header.length != strlen(expected) || memcmp(header.bytes, expected, header.length)) {
            EWError(error, 16, @"The printer rejected the configuration request."); return nil;
        }
        NSMutableData *body = [NSMutableData data];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (body.length < 1024 * 1024 && [deadline timeIntervalSinceNow] > 0) {
            char bytes[2048], control = 0; int count = sizeof(bytes);
            status = (*session.interface)->read(session.interface, channel, bytes, &count, &control, 5000);
            if (status || count < 0 || count > sizeof(bytes)) {
                EWError(error, status ?: 17, @"The printer's USB response was interrupted."); return nil;
            }
            [body appendBytes:bytes length:count];
            if (control) {
                if (body.length) return body;
                EWError(error, 18, @"The printer returned an empty configuration response."); return nil;
            }
            if (!count) break;
        }
        EWError(error, 19, @"The printer's USB response was incomplete or too large.");
        return nil;
    }
}
