#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Read-only enumeration. Plugin must be an intact, Epson-signed XIOCBTm bundle.
NSData * _Nullable EWEnumerate(NSString *pluginPath, NSError **error);
/// Exchange one IJCP request with the selected physical USB printer.
NSData * _Nullable EWExchange(NSString *pluginPath, NSData *deviceAddress,
                             NSData *request, NSError **error);
NS_ASSUME_NONNULL_END
