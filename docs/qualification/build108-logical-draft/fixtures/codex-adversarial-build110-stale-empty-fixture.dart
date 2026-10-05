import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft.dart';
import '../../../../lib/services/ui/chat/logical_conversation_identity.dart';
import '../../../../lib/services/ui/chat/logical_draft_storage.dart';
class Chat { final int? originalROWID; Chat(this.originalROWID); }
class Entry { final LogicalConversationId logicalId; final Set<int> sourceChatRowIds={2155,2156}; Entry(this.logicalId); }
class Messaging { final rows=<String,String>{}; String? loadLogicalDraftJson(String key)=>rows[key]; Future<void> saveLogicalDraftJson(String key,String value) async {rows[key]=value;} Future<void> clearLogicalDraft(String key) async {rows.remove(key);} }
class PrefsSvc {static final messaging=Messaging();}
class Logger {static void warn(String m,{Object? error,StackTrace? trace,String? tag}){}}
class Service {
 final rawId='fixture.sanitized.certified-conversation';
 late final entry=Entry(LogicalConversationId.certified(rawId));
 final _logicalDraftGenerations=<String,int>{};
 final _logicalDraftPreviewRevisions=<String,int>{};
 final _logicalAuthorityRevisionTracker=LogicalAuthorityRevisionTracker(seedEpoch:10);
 final queue=LogicalDraftSaveTransactionQueue();
 late final storage=LogicalDraftStorage(rawId);
 LogicalDraftStorage? _logicalDraftStorageFor(Chat chat)=>storage;
 LogicalDraftStorage? _logicalDraftStorageForId(String id)=>(id==storage.canonicalKey||id==storage.legacyKey)?storage:null;
 Entry? _registryEntryForChat(Chat chat)=>entry;
 String? logicalConversationIdFor(Chat chat)=>rawId;
 bool hasBuild99WriterCapability(Chat chat)=>false;
 LogicalAuthorityRevision? logicalWriterAuthorityRevisionFor(Chat chat)=>null;
 Future<T> _withLogicalDraftLock<T>(Future<T> Function() f)=>queue.run(f);
 void _bumpLogicalDraftPreviewRevision(String key){_logicalDraftPreviewRevisions[key]=(_logicalDraftPreviewRevisions[key]??0)+1;}
  LogicalDraft? loadLogicalDraft(Chat chat) {
    try {
      return _logicalDraftStorageFor(chat)?.read(PrefsSvc.messaging.loadLogicalDraftJson).draft;
    } catch (error, stack) {
      Logger.warn('Logical draft custody conflict remains untouched', error: error, trace: stack, tag: 'LogicalDraft');
      return null;
    }
  }

  int logicalDraftGenerationFor(Chat chat) {
    final logicalId = _logicalDraftStorageFor(chat)?.canonicalKey;
    return logicalId == null ? 0 : (_logicalDraftGenerations[logicalId] ?? 0);
  }

  Future<LogicalDraft?> _saveLogicalDraftLocked(
    Chat chat, {
    required String text,
    required String subject,
    required List<LogicalAttachmentIntent> attachments,
    required LogicalReplyIntent? reply,
    String? effectId,
    int? expectedDraftGeneration,
  }) async {
    final entry = _registryEntryForChat(chat);
    final sourceRowId = chat.originalROWID;
    if (entry == null || sourceRowId == null || !entry.sourceChatRowIds.contains(sourceRowId)) {
      throw StateError('NOT_A_CERTIFIED_LOGICAL_CONVERSATION');
    }
    final logicalId = entry.logicalId.value;
    if (expectedDraftGeneration != null && (_logicalDraftGenerations[logicalId] ?? 0) != expectedDraftGeneration) {
      return null;
    }
    final storage = _logicalDraftStorageFor(chat)!;
    final slot = storage.read(PrefsSvc.messaging.loadLogicalDraftJson);
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing =
        slot.draft ??
        LogicalDraft.create(
          logicalId: logicalId,
          nowEpochMilliseconds: now,
          observedRevision: hasBuild99WriterCapability(chat)
              ? _logicalAuthorityRevisionTracker.lastObserved ?? logicalWriterAuthorityRevisionFor(chat)
              : null,
        );
    final updated = existing.mergeUserIntent(
      text: text,
      subject: subject,
      attachments: attachments,
      reply: reply,
      effectId: effectId,
      updatedAtEpochMilliseconds: now,
    );
    for (final key in slot.occupiedKeys.isEmpty ? <String>[slot.storageKey] : slot.occupiedKeys) {
      await PrefsSvc.messaging.saveLogicalDraftJson(key, jsonEncode(updated.toJson()));
    }
    _bumpLogicalDraftPreviewRevision(logicalId);
    return updated;
  }

  Future<void> persistRearmedLogicalDraft(LogicalDraft draft) {
    return _withLogicalDraftLock(() async {
      final storage = _logicalDraftStorageForId(draft.logicalId);
      if (storage == null) throw StateError('LOGICAL_DRAFT_OWNER_UNAVAILABLE');
      final slot = storage.read(PrefsSvc.messaging.loadLogicalDraftJson);
      final current = slot.draft;
      if (current == null ||
          current.actionId != draft.actionId ||
          current.contentFingerprint != draft.contentFingerprint) {
        return;
      }
      for (final key in slot.occupiedKeys.isEmpty ? <String>[slot.storageKey] : slot.occupiedKeys) {
        await PrefsSvc.messaging.saveLogicalDraftJson(key, jsonEncode(draft.toJson()));
      }
      _bumpLogicalDraftPreviewRevision(storage.canonicalKey);
    });
  }
}

class Item {Item(this.logicalDraft);LogicalDraft? logicalDraft;}
class RearmPause implements Exception {RearmPause(this.reason,this.rearmedDraft);final String reason;final LogicalDraft? rearmedDraft;}
class AdmissionGuard {
 AdmissionGuard(this.ChatsSvc,this.revision);
 final Service ChatsSvc;final LogicalAuthorityRevision revision;int branchPasses=0;
 Never _failLogicalAdmission(List<Item> items,String reason,{LogicalDraft? rearmedDraft})=>throw RearmPause(reason,rearmedDraft);
 Future<void> validate(List<Item> items)async {
    final draft = items.map((item) => item.logicalDraft).whereType<LogicalDraft>().firstOrNull;
    if (draft != null && !revision.matchesDraft(draft)) {
      final certificateChanged = draft.observedCertificateRevision != revision.certificateRevision;
      final rearmed = draft.rearm(revision, updatedAtEpochMilliseconds: DateTime.now().millisecondsSinceEpoch);
      await ChatsSvc.persistRearmedLogicalDraft(rearmed);
      _failLogicalAdmission(
        items,
        certificateChanged ? 'SEND_BLOCKED_MEMBERSHIP_CERTIFICATE_CHANGED' : 'SEND_BLOCKED_AUTHORITY_CHANGED',
        rearmedDraft: rearmed,
      );
    }


  branchPasses++;
 }
}
Future<void> main()async {
 final results=<String,Object?>{};
 final oldRevision=LogicalAuthorityRevision(certificateRevision:'certA',authorityRevision:'authorityA',epoch:101);
 for(final entry in <String,LogicalAuthorityRevision>{
 'process epoch only':LogicalAuthorityRevision(certificateRevision:'certA',authorityRevision:'authorityA',epoch:202),
 'actual authority change':LogicalAuthorityRevision(certificateRevision:'certA',authorityRevision:'authorityB',epoch:202),
 'certificate change':LogicalAuthorityRevision(certificateRevision:'certB',authorityRevision:'authorityA',epoch:202),
 }.entries){
 PrefsSvc.messaging.rows.clear();final service=Service();final chat=Chat(2156);final now=DateTime.now().millisecondsSinceEpoch;
 final empty=LogicalDraft.create(logicalId:service.entry.logicalId.value,nowEpochMilliseconds:now,observedRevision:oldRevision);
 await PrefsSvc.messaging.saveLogicalDraftJson(service.storage.canonicalKey,jsonEncode(empty.toJson()));
 if(entry.value.matchesDraft(empty))throw StateError('empty unexpectedly fresh');
 final typed=(await service._saveLogicalDraftLocked(chat,text:'fixture legitimate content',subject:'',attachments:[],reply:null,expectedDraftGeneration:0))!;
 if(typed.text.isEmpty||typed.contentRevision!=empty.contentRevision+1||entry.value.matchesDraft(typed))throw StateError('fresh typing did not preserve stale metadata');
 final frozen=(await service._saveLogicalDraftLocked(chat,text:typed.text,subject:'',attachments:[],reply:null,expectedDraftGeneration:0))!;
 if(frozen.actionId!=typed.actionId)throw StateError('freeze changed action');
 final guard=AdmissionGuard(service,entry.value);RearmPause? pause;
 try{await guard.validate([Item(frozen)]);}on RearmPause catch(e){pause=e;}
 if(pause==null||guard.branchPasses!=0)throw StateError('first attempt did not pause');
 final persisted=service.loadLogicalDraft(chat)!;
 if(!entry.value.matchesDraft(persisted)||persisted.actionId!=frozen.actionId||persisted.contentFingerprint!=frozen.contentFingerprint||persisted.text!=frozen.text)throw StateError('rearm changed or lost user intent');
 final confirmation=(await service._saveLogicalDraftLocked(chat,text:typed.text,subject:'',attachments:[],reply:null,expectedDraftGeneration:0))!;
 await guard.validate([Item(confirmation)]);
 if(guard.branchPasses!=1||confirmation.actionId!=frozen.actionId)throw StateError('fresh confirmation did not pass same-intent revision check');
 final expected=entry.key=='certificate change'?'SEND_BLOCKED_MEMBERSHIP_CERTIFICATE_CHANGED':'SEND_BLOCKED_AUTHORITY_CHANGED';if(pause.reason!=expected)throw StateError('incorrect pause reason');
 results[entry.key]={'empty_health':'STALE','after_human_content_health':'STALE','first_attempt':pause.reason,'same_content_action_preserved':true,'after_rearm_health':'SAFE_FOR_CURRENT_AUTHORITY','next_confirmation':'PASSES_STALE_REVISION_BRANCH_ONLY','transport_path_in_fixture':false};
 }
 print(jsonEncode({'source_commit':'66d12ad68','source_link':'verbatim load/generation/save/rearm service methods plus exact _admitLogicalBatch stale branch; real immutable models','fake_boundaries':'registry/preferences; already-observed current revision; no receipt preparation or transport implementation','scenarios':results,'real_provider_calls':0,'original_device_staleness_cause':'UNKNOWN: no private preference operands available'}));
}
