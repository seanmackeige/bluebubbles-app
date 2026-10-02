#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, BBV2Qualification) {
    BBV2Qualified,
    BBV2RejectedContract,
    BBV2RejectedAccount,
    BBV2RejectedSenderRoute,
    BBV2RejectedService,
    BBV2RejectedRecipients,
    BBV2RejectedRevision,
    BBV2RejectedNativePrimitive,
};

typedef struct {
    BOOL requestComplete;
    BOOL operationIdUnique;
    BOOL accountExact;
    BOOL accountActive;
    BOOL senderRouteExact;
    BOOL senderRouteVettedForAccount;
    BOOL serviceExact;
    BOOL recipientFingerprintExact;
    BOOL providerRevisionExact;
    BOOL creatorABIExact;
    BOOL explicitRouteCaptured;
    BOOL downstreamRoutePreserved;
    BOOL unavailableRouteRejectsWithoutFallback;
    BOOL providerConditionalRevision;
} BBV2Evidence;

static BBV2Qualification BBQualify(BBV2Evidence evidence) {
    if (!evidence.requestComplete || !evidence.operationIdUnique) return BBV2RejectedContract;
    if (!evidence.accountExact || !evidence.accountActive) return BBV2RejectedAccount;
    if (!evidence.senderRouteExact || !evidence.senderRouteVettedForAccount) return BBV2RejectedSenderRoute;
    if (!evidence.serviceExact) return BBV2RejectedService;
    if (!evidence.recipientFingerprintExact) return BBV2RejectedRecipients;
    if (!evidence.providerRevisionExact) return BBV2RejectedRevision;
    if (!evidence.creatorABIExact ||
        !evidence.explicitRouteCaptured ||
        !evidence.downstreamRoutePreserved ||
        !evidence.unavailableRouteRejectsWithoutFallback ||
        !evidence.providerConditionalRevision) {
        return BBV2RejectedNativePrimitive;
    }
    return BBV2Qualified;
}

static BBV2Evidence BBCompleteEvidence(void) {
    return (BBV2Evidence){
        .requestComplete = YES,
        .operationIdUnique = YES,
        .accountExact = YES,
        .accountActive = YES,
        .senderRouteExact = YES,
        .senderRouteVettedForAccount = YES,
        .serviceExact = YES,
        .recipientFingerprintExact = YES,
        .providerRevisionExact = YES,
        .creatorABIExact = YES,
        .explicitRouteCaptured = YES,
        .downstreamRoutePreserved = YES,
        .unavailableRouteRejectsWithoutFallback = YES,
        .providerConditionalRevision = YES,
    };
}

static NSUInteger checks = 0;
static NSUInteger failures = 0;

static void BBExpect(NSString *name, BBV2Qualification actual, BBV2Qualification expected) {
    checks += 1;
    if (actual != expected) {
        failures += 1;
        fprintf(stderr, "FAIL %s actual=%ld expected=%ld\n", name.UTF8String, (long)actual, (long)expected);
    }
}

int main(void) {
    @autoreleasepool {
        BBV2Evidence evidence = BBCompleteEvidence();
        BBExpect(@"complete", BBQualify(evidence), BBV2Qualified);

        evidence = BBCompleteEvidence(); evidence.requestComplete = NO;
        BBExpect(@"incomplete request", BBQualify(evidence), BBV2RejectedContract);
        evidence = BBCompleteEvidence(); evidence.operationIdUnique = NO;
        BBExpect(@"duplicate operation", BBQualify(evidence), BBV2RejectedContract);
        evidence = BBCompleteEvidence(); evidence.accountExact = NO;
        BBExpect(@"wrong account", BBQualify(evidence), BBV2RejectedAccount);
        evidence = BBCompleteEvidence(); evidence.accountActive = NO;
        BBExpect(@"inactive account", BBQualify(evidence), BBV2RejectedAccount);
        evidence = BBCompleteEvidence(); evidence.senderRouteExact = NO;
        BBExpect(@"wrong sender", BBQualify(evidence), BBV2RejectedSenderRoute);
        evidence = BBCompleteEvidence(); evidence.senderRouteVettedForAccount = NO;
        BBExpect(@"alias mismatch", BBQualify(evidence), BBV2RejectedSenderRoute);
        evidence = BBCompleteEvidence(); evidence.serviceExact = NO;
        BBExpect(@"service mismatch", BBQualify(evidence), BBV2RejectedService);
        evidence = BBCompleteEvidence(); evidence.recipientFingerprintExact = NO;
        BBExpect(@"recipient mismatch", BBQualify(evidence), BBV2RejectedRecipients);
        evidence = BBCompleteEvidence(); evidence.providerRevisionExact = NO;
        BBExpect(@"provider revision drift", BBQualify(evidence), BBV2RejectedRevision);
        evidence = BBCompleteEvidence(); evidence.creatorABIExact = NO;
        BBExpect(@"old helper", BBQualify(evidence), BBV2RejectedNativePrimitive);
        evidence = BBCompleteEvidence(); evidence.explicitRouteCaptured = NO;
        BBExpect(@"route capture unproven", BBQualify(evidence), BBV2RejectedNativePrimitive);
        evidence = BBCompleteEvidence(); evidence.downstreamRoutePreserved = NO;
        BBExpect(@"downstream substitution possible", BBQualify(evidence), BBV2RejectedNativePrimitive);
        evidence = BBCompleteEvidence(); evidence.unavailableRouteRejectsWithoutFallback = NO;
        BBExpect(@"fallback possible", BBQualify(evidence), BBV2RejectedNativePrimitive);
        evidence = BBCompleteEvidence(); evidence.providerConditionalRevision = NO;
        BBExpect(@"TOCTOU unbounded", BBQualify(evidence), BBV2RejectedNativePrimitive);

        NSDictionary *result = @{
            @"schema": @"SEAN_CREATE_CHAT_V2_NATIVE_GATE_TEST_V1",
            @"checks": @(checks),
            @"failures": @(failures),
            @"send_selector_invocations": @0,
            @"chat_creator_invocations": @0,
            @"status": failures == 0 ? @"PASS" : @"FAIL",
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:nil];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
    }
    return failures == 0 ? 0 : 1;
}
