// Shared error construction and the download-quarantine policy used by both
// the CEF-backed and the artifact-free implementations.

#import "ChromiumKitInternal.h"
#import <CoreServices/CoreServices.h>

NSErrorDomain const ChromiumKitErrorDomain = @"app.blau.ChromiumKit";

NSError *ChromiumKitError(ChromiumKitErrorCode code,
                          NSString *description,
                          NSDictionary *extra) {
    NSMutableDictionary *userInfo =
        [@{NSLocalizedDescriptionKey: description} mutableCopy];
    [userInfo addEntriesFromDictionary:extra ?: @{}];
    return [NSError errorWithDomain:ChromiumKitErrorDomain
                               code:code
                           userInfo:userInfo];
}

NSError *ChromiumKitUnavailableError(void) {
    return ChromiumKitError(
        ChromiumKitErrorRuntimeUnavailable,
        @"The Chromium runtime is not installed.",
        @{NSLocalizedRecoverySuggestionErrorKey:
              @"Install the pinned CEF artifact and build Pilot with its "
               "Chromium configuration."});
}

BOOL ChromiumKitApplyDownloadQuarantine(NSURL *fileURL, NSError **error) {
    if (!fileURL.isFileURL) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorDownloadQuarantineFailed,
                @"Download quarantine requires a local file URL.",
                nil);
        }
        return NO;
    }

    NSNumber *isRegularFile = nil;
    NSError *resourceError = nil;
    if (![fileURL getResourceValue:&isRegularFile
                            forKey:NSURLIsRegularFileKey
                             error:&resourceError] ||
        !isRegularFile.boolValue) {
        if (error) {
            *error = ChromiumKitError(
                ChromiumKitErrorDownloadQuarantineFailed,
                @"Download quarantine requires an existing regular file.",
                resourceError ? @{NSUnderlyingErrorKey: resourceError} : nil);
        }
        return NO;
    }

    NSString *bundleIdentifier =
        NSBundle.mainBundle.bundleIdentifier ?: @"app.blau.pilot";
    NSDictionary *properties = @{
        (__bridge NSString *)kLSQuarantineTypeKey:
            (__bridge NSString *)kLSQuarantineTypeWebDownload,
        (__bridge NSString *)kLSQuarantineAgentBundleIdentifierKey:
            bundleIdentifier,
        (__bridge NSString *)kLSQuarantineAgentNameKey:
            NSProcessInfo.processInfo.processName,
        (__bridge NSString *)kLSQuarantineTimeStampKey: NSDate.date,
    };
    if ([fileURL setResourceValue:properties
                           forKey:NSURLQuarantinePropertiesKey
                            error:&resourceError]) {
        return YES;
    }
    if (error) {
        *error = ChromiumKitError(
            ChromiumKitErrorDownloadQuarantineFailed,
            @"Pilot could not quarantine the downloaded file.",
            resourceError ? @{NSUnderlyingErrorKey: resourceError} : nil);
    }
    return NO;
}
