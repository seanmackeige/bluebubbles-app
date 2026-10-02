#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>

static NSDictionary *BBMethodEvidence(NSString *className, NSString *selectorName, BOOL classMethod) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = Nil;
    if (cls != Nil) {
        method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    }
    const char *encoding = method == Nil ? NULL : method_getTypeEncoding(method);
    IMP implementation = method == Nil ? NULL : method_getImplementation(method);
    return @{
        @"class": className,
        @"selector": selectorName,
        @"dispatch": classMethod ? @"class" : @"instance",
        @"present": @(method != Nil),
        @"type_encoding": encoding == NULL ? [NSNull null] : [NSString stringWithUTF8String:encoding],
        @"implementation_present": @(implementation != NULL),
    };
}

__attribute__((visibility("default")))
void *BBV2MethodIMP(const char *className, const char *selectorName) {
    Class cls = objc_getClass(className);
    if (cls == Nil) return NULL;
    Method method = class_getInstanceMethod(cls, sel_registerName(selectorName));
    return method == Nil ? NULL : (void *)method_getImplementation(method);
}

__attribute__((noinline, visibility("default")))
void BBV2TraceReady(void) {
    __asm__ volatile("");
}

static id BBInvokeObject0(id target, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:selector]) return nil;
    id (*invoke)(id, SEL) = (id (*)(id, SEL))[target methodForSelector:selector];
    return invoke(target, selector);
}

static BOOL BBInvokeBool0(id target, NSString *selectorName, BOOL *available) {
    SEL selector = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:selector]) {
        *available = NO;
        return NO;
    }
    *available = YES;
    BOOL (*invoke)(id, SEL) = (BOOL (*)(id, SEL))[target methodForSelector:selector];
    return invoke(target, selector);
}

static id BBInvokeObject1(id target, NSString *selectorName, id argument) {
    SEL selector = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:selector]) return nil;
    id (*invoke)(id, SEL, id) = (id (*)(id, SEL, id))[target methodForSelector:selector];
    return invoke(target, selector, argument);
}

static NSDictionary *BBAccountEvidence(void) {
    Class controllerClass = NSClassFromString(@"IMAccountController");
    id controller = BBInvokeObject0(controllerClass, @"sharedInstance");
    NSArray *accounts = BBInvokeObject0(controller, @"accounts");
    if (![accounts isKindOfClass:[NSArray class]]) accounts = @[];

    NSUInteger imessageAccountCount = 0;
    NSUInteger usableAccountCount = 0;
    NSUInteger vettedAliasCount = 0;
    NSUInteger resolvedAliasCount = 0;
    NSUInteger exactAccountRelationCount = 0;
    NSUInteger exactServiceRelationCount = 0;
    NSUInteger activeRouteInVettedAliasesCount = 0;

    for (id account in accounts) {
        NSString *serviceName = BBInvokeObject0(account, @"serviceName");
        if (![serviceName isEqualToString:@"iMessage"]) continue;
        imessageAccountCount += 1;

        BOOL canSendAvailable = NO;
        BOOL usableAvailable = NO;
        BOOL canSend = BBInvokeBool0(account, @"canSendMessages", &canSendAvailable);
        BOOL usable = BBInvokeBool0(account, @"_isUsableForSending", &usableAvailable);
        if (canSendAvailable && usableAvailable && canSend && usable) usableAccountCount += 1;

        NSArray *vettedAliases = BBInvokeObject0(account, @"vettedAliases");
        if (![vettedAliases isKindOfClass:[NSArray class]]) vettedAliases = @[];
        vettedAliasCount += vettedAliases.count;
        NSString *activeRoute = BBInvokeObject0(account, @"displayName");
        if ([activeRoute isKindOfClass:[NSString class]] && activeRoute.length > 0) {
            if ([vettedAliases containsObject:activeRoute]) activeRouteInVettedAliasesCount += 1;
        }

        id accountService = BBInvokeObject0(account, @"service");
        for (id alias in vettedAliases) {
            if (![alias isKindOfClass:[NSString class]] || [alias length] == 0) continue;
            id handle = BBInvokeObject1(account, @"imHandleWithID:", alias);
            if (handle == nil) continue;
            resolvedAliasCount += 1;
            if (BBInvokeObject0(handle, @"account") == account) exactAccountRelationCount += 1;
            if (BBInvokeObject0(handle, @"service") == accountService) exactServiceRelationCount += 1;
        }
    }

    return @{
        @"controller_present": @(controller != nil),
        @"account_count": @(accounts.count),
        @"imessage_account_count": @(imessageAccountCount),
        @"usable_imessage_account_count": @(usableAccountCount),
        @"vetted_alias_count": @(vettedAliasCount),
        @"resolved_alias_count": @(resolvedAliasCount),
        @"exact_account_relation_count": @(exactAccountRelationCount),
        @"exact_service_relation_count": @(exactServiceRelationCount),
        @"active_route_in_vetted_aliases_count": @(activeRouteInVettedAliasesCount),
        @"raw_identity_values_emitted": @NO,
    };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSArray *frameworks = @[
            @"/System/Library/PrivateFrameworks/IMFoundation.framework/IMFoundation",
            @"/System/Library/PrivateFrameworks/IMSharedUtilities.framework/IMSharedUtilities",
            @"/System/Library/PrivateFrameworks/IMCore.framework/IMCore",
        ];
        NSMutableArray *loads = [NSMutableArray array];
        for (NSString *path in frameworks) {
            void *handle = dlopen(path.UTF8String, RTLD_LAZY | RTLD_LOCAL);
            [loads addObject:@{@"path": path.lastPathComponent, @"loaded": @(handle != NULL)}];
        }

        NSArray *methods = @[
            BBMethodEvidence(@"IMAccountController", @"sharedInstance", YES),
            BBMethodEvidence(@"IMAccountController", @"accountForUniqueID:", NO),
            BBMethodEvidence(@"IMAccount", @"imHandleWithID:", NO),
            BBMethodEvidence(@"IMAccount", @"vettedAliases", NO),
            BBMethodEvidence(@"IMAccount", @"displayName", NO),
            BBMethodEvidence(@"IMHandle", @"account", NO),
            BBMethodEvidence(@"IMHandle", @"service", NO),
            BBMethodEvidence(@"IMChatRegistry", @"chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:", NO),
            BBMethodEvidence(@"IMChat", @"lastAddressedHandleID", NO),
            BBMethodEvidence(@"IMChat", @"_sendMessage:withAccount:adjustingSender:shouldQueue:", NO),
            BBMethodEvidence(@"IMMessage", @"initWithSender:time:text:messageSubject:fileTransferGUIDs:flags:error:guid:subject:balloonBundleID:payloadData:expressiveSendStyleID:", NO),
            BBMethodEvidence(@"IMMessage", @"sender", NO),
        ];

        BOOL enumerateAccounts = argc == 2 && strcmp(argv[1], "--enumerate-accounts") == 0;
        if (argc == 2 && strcmp(argv[1], "--trace") == 0) {
            BBV2TraceReady();
            return 0;
        }
        NSDictionary *output = @{
            @"schema": @"SEAN_CREATE_CHAT_V2_ZERO_SEND_PROBE_V1",
            @"framework_loads": loads,
            @"methods": methods,
            @"account_evidence": enumerateAccounts ? BBAccountEvidence() : (id)[NSNull null],
            @"creator_invocations": @0,
            @"chat_objects_created": @0,
            @"message_objects_created": @0,
            @"send_selector_invocations": @0,
            @"chat_db_accesses": @0,
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return 0;
}
