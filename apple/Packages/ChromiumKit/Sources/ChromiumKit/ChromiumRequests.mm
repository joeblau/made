// Value objects handed to the delegate for context-menu and permission
// decisions. A permission request owns its CEF continuation and resolves it
// exactly once, on the main thread.

#import "ChromiumKitInternal.h"

@implementation ChromiumContextMenuRequest

- (instancetype)initWithLocation:(NSPoint)location
                         linkURL:(NSURL *)linkURL
                       sourceURL:(NSURL *)sourceURL
                    selectedText:(NSString *)selectedText
                        editable:(BOOL)editable {
    self = [super init];
    if (self) {
        _location = location;
        _linkURL = linkURL;
        _sourceURL = sourceURL;
        _selectedText = [selectedText copy];
        _editable = editable;
    }
    return self;
}

@end

@implementation ChromiumPermissionRequest

- (instancetype)initWithOrigin:(NSURL *)origin
                         kinds:(ChromiumPermissionKind)kinds
             rawPermissionMask:(NSUInteger)rawPermissionMask
               decisionHandler:(void (^)(BOOL allowed))decisionHandler {
    self = [super init];
    if (self) {
        _origin = origin;
        _kinds = kinds;
        _rawPermissionMask = rawPermissionMask;
        _decisionHandler = [decisionHandler copy];
    }
    return self;
}

- (void)allow {
    [self resolve:YES];
}

- (void)deny {
    [self resolve:NO];
}

- (void)resolve:(BOOL)allowed {
    NSCAssert(NSThread.isMainThread, @"Permission decisions require main");
    if (self.resolved) {
        return;
    }
    self.resolved = YES;
    void (^handler)(BOOL) = self.decisionHandler;
    self.decisionHandler = nil;
    if (handler) {
        handler(allowed);
    }
}

@end
