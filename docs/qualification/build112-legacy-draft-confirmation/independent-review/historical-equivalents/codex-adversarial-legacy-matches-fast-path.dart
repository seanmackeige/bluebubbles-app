import 'dart:convert';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_authority_alignment.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_intent_guard.dart';
class Chat {Chat(this.row);final int row;}
class Item {Chat get chat => Chat(2156);Item(this.logicalDraft,this.logicalIntentGuard);LogicalDraft? logicalDraft;LogicalDraftIntentGuard? logicalIntentGuard;}
class Block implements Exception {Block(this.reason);String reason;}
class Service {
 bool isLogicalDraftConfirmationInFlight(Chat c)=>false;
 bool logicalDraftConfirmationMatchesCurrentProof(Chat c,LogicalDraft d)=>true;
LogicalAuthorityRevision? currentLogicalAuthorityRevision;bool current=true;int writes=0;bool isLogicalEvidenceObservationCurrent(int epoch)=>current;Future<LogicalDraft?> alignLogicalDraftAuthorityIfCurrent(LogicalDraft d,LogicalAuthorityRevision r)async{writes++;return d.rearm(r,updatedAtEpochMilliseconds:2);}Future<void> persistRearmedLogicalDraft(LogicalDraft d)async{writes++;}}
class Handler {Handler(this.ChatsSvc);final Service ChatsSvc;String context='provider';String _currentLogicalProviderContextFingerprint()=>context;Never _failLogicalAdmission(List<Item> items,String reason,{LogicalDraft? rearmedDraft})=>throw Block(reason);
Future<void> evaluate(List<Item> items,LogicalAuthorityRevision revision)async {final observationEpoch=1;final providerContextAtObservationStart='provider';
    for (final item in items) {
      item.logicalIntentGuard?.check();
    }
    final presentationChat = items.first.chat;
    if (ChatsSvc.isLogicalDraftConfirmationInFlight(presentationChat)) {
      _failLogicalAdmission(items, 'SEND_BLOCKED_CONFIRMATION_IN_PROGRESS');
    }
    for (final item in items) {
      final metadata = item.logicalDraft?.metadataClass;
      if (metadata == LogicalDraftMetadataClass.legacyUnboundDraft) {
        _failLogicalAdmission(items, 'SEND_BLOCKED_DRAFT_NEEDS_HUMAN_CONFIRMATION');
      }
      if (metadata == LogicalDraftMetadataClass.partiallyBoundInvalidDraft) {
        _failLogicalAdmission(items, 'SEND_BLOCKED_INVALID_DRAFT_METADATA');
      }
    }
    if (_currentLogicalProviderContextFingerprint() != providerContextAtObservationStart) {
      _failLogicalAdmission(items, 'SEND_BLOCKED_PROVIDER_CONTEXT_CHANGED_DURING_EVIDENCE');
    }

    var draft = items.map((item) => item.logicalDraft).whereType<LogicalDraft>().firstOrNull;
    if (draft?.confirmation != null &&
        !ChatsSvc.logicalDraftConfirmationMatchesCurrentProof(presentationChat, draft!)) {
      final invalidated = draft.invalidateConfirmation();
      await ChatsSvc.persistRearmedLogicalDraft(invalidated);
      _failLogicalAdmission(items, 'SEND_BLOCKED_CONFIRMATION_AUTHORITY_CHANGED', rearmedDraft: invalidated);
    }
    // A newly saved draft must not hide authority drift during its own freeze.
    for (final item in items) {
      final anchor = item.logicalIntentGuard?.authorityAtFreeze;
      if (anchor != null && !sameLogicalAuthorityRevision(anchor, revision)) {
        LogicalDraft? rearmed;
        if (draft != null && !revision.matchesDraft(draft)) {
          for (final guarded in items) {
            guarded.logicalIntentGuard?.check();
          }
          if (ChatsSvc.isLogicalEvidenceObservationCurrent(observationEpoch) &&
              _currentLogicalProviderContextFingerprint() == providerContextAtObservationStart) {
            rearmed = await ChatsSvc.alignLogicalDraftAuthorityIfCurrent(draft, revision);
          }
        }
        // This tap always pauses. CAS merely prepares the unchanged intent for
        // the next explicit confirmation; it never grants this operation.
        _failLogicalAdmission(items, 'SEND_BLOCKED_AUTHORITY_CHANGED_DURING_FREEZE', rearmedDraft: rearmed);
      }
    }
    if (draft != null && !revision.matchesDraft(draft)) {
      final original = draft;
      final canRefreshEpoch = items.every(
        (item) =>
            item.logicalDraft?.actionId == original.actionId &&
            item.logicalIntentGuard?.frozenDraft?.actionId == original.actionId &&
            logicalDraftAuthorityAlignment(
                  draft: original,
                  frozenAuthority: item.logicalIntentGuard?.authorityAtFreeze,
                  observedAuthority: revision,
                ) ==
                LogicalDraftAuthorityAlignment.refreshEpoch,
      );
      if (canRefreshEpoch) {
        for (final item in items) {
          item.logicalIntentGuard?.check();
        }
        if (!ChatsSvc.isLogicalEvidenceObservationCurrent(observationEpoch)) {
          _failLogicalAdmission(items, 'SEND_BLOCKED_AUTHORITY_CHANGED_DURING_ADMISSION');
        }
        final aligned = await ChatsSvc.alignLogicalDraftAuthorityIfCurrent(original, revision);
        if (aligned == null) throw const LogicalDraftIntentException('DRAFT_IDENTITY_CHANGED');
        if (!ChatsSvc.isLogicalEvidenceObservationCurrent(observationEpoch) ||
            !sameLogicalAuthorityRevision(ChatsSvc.currentLogicalAuthorityRevision, revision) ||
            _currentLogicalProviderContextFingerprint() != providerContextAtObservationStart) {
          _failLogicalAdmission(items, 'SEND_BLOCKED_AUTHORITY_CHANGED_DURING_ADMISSION');
        }
        for (final guard in items.map((item) => item.logicalIntentGuard!).toSet()) {
          guard.acceptAuthorityRefresh(aligned, revision);
        }
        for (final item in items) {
          item.logicalDraft = aligned;
        }
        draft = aligned;
      } else {
        final certificateChanged = draft.observedCertificateRevision != revision.certificateRevision;
        final rearmed = draft.rearm(revision, updatedAtEpochMilliseconds: DateTime.now().millisecondsSinceEpoch);
        await ChatsSvc.persistRearmedLogicalDraft(rearmed);
        _failLogicalAdmission(
          items,
          certificateChanged ? 'SEND_BLOCKED_MEMBERSHIP_CERTIFICATE_CHANGED' : 'SEND_BLOCKED_AUTHORITY_CHANGED',
          rearmedDraft: rearmed,
        );
      }
    }


}}
Future<void> main()async {
 final results=<String,Object?>{};
 for(final name in ['same hashes ABA','material drift']){
 final anchor=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:1);
 final current=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:name=='same hashes ABA'?'A':'B',epoch:3);
 final draft=LogicalDraft.create(logicalId:'L',nowEpochMilliseconds:1,observedRevision:current).mergeUserIntent(text:'fixture',subject:'',attachments:[],reply:null,effectId:null,updatedAtEpochMilliseconds:2);
 final svc=Service()..currentLogicalAuthorityRevision=current;
 final guard=LogicalDraftIntentGuard(frozenDraft:draft,authorityAtFreeze:anchor,validateCurrent:()=>null,composerIsCurrent:()=>true,record:(r,s){},validateAuthority:()=>current.matchesDraft(draft)?null:'AUTHORITY_CHANGED');
 String result='PASSED';try {await Handler(svc).evaluate([Item(draft,guard)],current);guard.validateBeforeTransport();}on Block catch(e){result=e.reason;}on LogicalDraftIntentException catch(e){result=e.reason;}
 results[name]={'result':result,'draft_already_matches_fresh':current.matchesDraft(draft),'classifier':logicalDraftAuthorityAlignment(draft:draft,frozenAuthority:anchor,observedAuthority:current).name,'metadata_writes':svc.writes};
 }
 print(jsonEncode({'method':'verbatim handler provider-context/authority alignment block','counterexample':'draft created/reloaded after authority changes during await already matches fresh revision','results':results,'real_provider_calls':0}));
}
