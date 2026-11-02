// Value objects handed to the delegate for context-menu, permission, and
// JavaScript dialog decisions. Permission and dialog requests own their CEF
// continuation and resolve it exactly once, on the main thread.

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

@implementation ChromiumJavaScriptDialogRequest {
    void (^_decisionHandler)(BOOL accepted, NSString *_Nullable userInput);
}

- (instancetype)initWithKind:(ChromiumJavaScriptDialogKind)kind
                   originURL:(NSURL *)originURL
                     message:(NSString *)message
           defaultPromptText:(NSString *)defaultPromptText
                      reload:(BOOL)reload
             decisionHandler:(void (^)(BOOL accepted,
                                       NSString *userInput))decisionHandler {
    self = [super init];
    if (self) {
        _kind = kind;
        _originURL = originURL;
        _message = [message copy];
        _defaultPromptText = [defaultPromptText copy];
        _reload = reload;
        _decisionHandler = [decisionHandler copy];
    }
    return self;
}

- (void)acceptWithUserInput:(NSString *)userInput {
    [self resolve:YES userInput:userInput];
}

- (void)cancel {
    [self resolve:NO userInput:nil];
}

- (void)invalidate {
    NSCAssert(NSThread.isMainThread, @"Dialog decisions require main");
    _resolved = YES;
    _decisionHandler = nil;
}

- (void)resolve:(BOOL)accepted userInput:(NSString *)userInput {
    NSCAssert(NSThread.isMainThread, @"Dialog decisions require main");
    if (_resolved) {
        return;
    }
    _resolved = YES;
    void (^handler)(BOOL, NSString *) = _decisionHandler;
    _decisionHandler = nil;
    if (handler) {
        handler(accepted,
                _kind == ChromiumJavaScriptDialogKindPrompt && accepted
                    ? (userInput ?: @"")
                    : nil);
    }
}

- (void)dealloc {
    // A page stays blocked until its dialog is answered, so a request the
    // delegate dropped is cancelled rather than leaked.
    void (^handler)(BOOL, NSString *) = _decisionHandler;
    if (_resolved || !handler) {
        return;
    }
    if (NSThread.isMainThread) {
        handler(NO, nil);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(NO, nil);
        });
    }
}

@end
