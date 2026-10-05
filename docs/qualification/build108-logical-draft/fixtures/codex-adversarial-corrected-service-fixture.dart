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

  Future<bool> clearLogicalDraftIfCurrent(LogicalDraft admittedDraft) {
    return _withLogicalDraftLock(() async {
      final storage = _logicalDraftStorageForId(admittedDraft.logicalId);
      if (storage == null) return false;
      final slot = storage.read(PrefsSvc.messaging.loadLogicalDraftJson);
      final current = slot.draft;
      if (current == null) return false;
      if (current.actionId != admittedDraft.actionId ||
          current.contentRevision != admittedDraft.contentRevision ||
          current.contentFingerprint != admittedDraft.contentFingerprint ||
          current.observedCertificateRevision != admittedDraft.observedCertificateRevision ||
          current.observedAuthorityRevision != admittedDraft.observedAuthorityRevision ||
          current.observedAuthorityEpoch != admittedDraft.observedAuthorityEpoch)
        return false;
      _logicalDraftGenerations.update(storage.canonicalKey, (value) => value + 1, ifAbsent: () => 1);
      for (final key in slot.occupiedKeys) {
        await PrefsSvc.messaging.clearLogicalDraft(key);
      }
      _bumpLogicalDraftPreviewRevision(storage.canonicalKey);
      return true;
    });
  }

  Future<void> persistRearmedLogicalDraft(LogicalDraft draft) {
    return _withLogicalDraftLock(() async {
      final storage = _logicalDraftStorageForId(draft.logicalId);
      if (storage == null) throw StateError('LOGICAL_DRAFT_OWNER_UNAVAILABLE');
      final slot = storage.read(PrefsSvc.messaging.loadLogicalDraftJson);
      final current = slot.draft;
      if (current == null || current.actionId != draft.actionId ||
          current.contentFingerprint != draft.contentFingerprint) return;
      for (final key in slot.occupiedKeys.isEmpty ? <String>[slot.storageKey] : slot.occupiedKeys) {
        await PrefsSvc.messaging.saveLogicalDraftJson(key, jsonEncode(draft.toJson()));
      }
      _bumpLogicalDraftPreviewRevision(storage.canonicalKey);
    });
  }
 Future<LogicalDraft?> freeze(Chat c,String text)=>_withLogicalDraftLock(()=>_saveLogicalDraftLocked(c,text:text,subject:'',attachments:[],reply:null,expectedDraftGeneration:logicalDraftGenerationFor(c)));
}
Future<void> main() async {
 final svc=Service();final chat=Chat(2156);final checks=<String,bool>{};
 final first=(await svc.freeze(chat,'SANITIZED_A'))!;
 checks['saved_readable']=svc.loadLogicalDraft(chat)!.actionId==first.actionId;
 await Future<void>.delayed(Duration(milliseconds:2));
 final republication=(await svc.freeze(chat,'SANITIZED_A'))!;
 checks['same_content_action_stable']=first.actionId==republication.actionId;
 checks['consume_current']=await svc.clearLogicalDraftIfCurrent(republication);
 checks['generation_reader_tracks_consume']=svc.logicalDraftGenerationFor(chat)==1;
 await svc.persistRearmedLogicalDraft(first);
 checks['stale_rearm_does_not_resurrect']=svc.loadLogicalDraft(chat)==null;
 final second=(await svc.freeze(chat,'SANITIZED_A'))!;
 checks['next_tap_not_poisoned']=second.actionId!=first.actionId;
 checks['old_identity_does_not_consume_replacement']=!await svc.clearLogicalDraftIfCurrent(first);
 PrefsSvc.messaging.rows.clear();
 final legacy=LogicalDraft.create(logicalId:svc.rawId,nowEpochMilliseconds:1).mergeUserIntent(text:'SANITIZED_A',subject:'',attachments:[],reply:null,effectId:null,updatedAtEpochMilliseconds:2);
 PrefsSvc.messaging.rows[svc.storage.canonicalKey]=jsonEncode(legacy.toJson());
 final compatible=(await svc.freeze(chat,'SANITIZED_A'))!;
 checks['mixed_key_payload_action_preserved']=compatible.actionId==legacy.actionId;
 checks['mixed_key_payload_consumes_correct_slot']=await svc.clearLogicalDraftIfCurrent(compatible)&&PrefsSvc.messaging.rows.isEmpty;
 for(final legacySlot in [false,true]) {
  for(final legacyIdentity in [false,true]) {
   PrefsSvc.messaging.rows.clear();
   final trial=Service();
   final key=legacySlot?trial.storage.legacyKey:trial.storage.canonicalKey;
   final identity=legacyIdentity?trial.storage.legacyKey:trial.storage.canonicalKey;
   final seed=LogicalDraft.create(logicalId:identity,nowEpochMilliseconds:10).mergeUserIntent(text:'SANITIZED_MATRIX',subject:'',attachments:[],reply:null,effectId:null,updatedAtEpochMilliseconds:11);
   PrefsSvc.messaging.rows[key]=jsonEncode(seed.toJson());
   final saved=(await trial.freeze(chat,'SANITIZED_MATRIX'))!;
   final prefix='matrix_slotLegacy=$legacySlot,identityLegacy=$legacyIdentity';
   checks['$prefix:action_preserved']=saved.actionId==seed.actionId;
   checks['$prefix:slot_preserved']=PrefsSvc.messaging.rows.keys.single==key;
   checks['$prefix:consumed']=await trial.clearLogicalDraftIfCurrent(saved);
   checks['$prefix:canonical_generation']=trial.logicalDraftGenerationFor(chat)==1;
   await trial.persistRearmedLogicalDraft(saved);
   checks['$prefix:no_resurrection']=PrefsSvc.messaging.rows.isEmpty;
   checks['$prefix:next_freeze_proceeds']=(await trial.freeze(chat,'SANITIZED_NEXT'))!=null;
  }
 }
 PrefsSvc.messaging.rows.clear();
 final dual=Service();
 final identicalDraft=LogicalDraft.create(logicalId:dual.rawId,nowEpochMilliseconds:100).mergeUserIntent(text:'SANITIZED_DUAL',subject:'',attachments:[],reply:null,effectId:null,updatedAtEpochMilliseconds:101);
 PrefsSvc.messaging.rows[dual.storage.canonicalKey]=jsonEncode(identicalDraft.toJson());
 PrefsSvc.messaging.rows[dual.storage.legacyKey]=jsonEncode(identicalDraft.toJson());
 final dualSaved=(await dual.freeze(chat,'SANITIZED_DUAL'))!;
 checks['identical_dual_action_preserved']=dualSaved.actionId==identicalDraft.actionId;
 checks['identical_dual_remain_equivalent']=PrefsSvc.messaging.rows.values.toSet().length==1;
 checks['identical_dual_consumed_together']=await dual.clearLogicalDraftIfCurrent(dualSaved)&&PrefsSvc.messaging.rows.isEmpty;
 PrefsSvc.messaging.rows[dual.storage.canonicalKey]=jsonEncode(identicalDraft.toJson());
 PrefsSvc.messaging.rows[dual.storage.legacyKey]=jsonEncode(identicalDraft.mergeUserIntent(text:'DIFFERENT_SANITIZED',subject:'',attachments:[],reply:null,effectId:null,updatedAtEpochMilliseconds:102).toJson());
 final conflictBefore=jsonEncode(PrefsSvc.messaging.rows);
 var conflictBlocked=false;
 try {await dual.freeze(chat,'SANITIZED_DUAL');}on StateError{conflictBlocked=true;}
 checks['conflict_blocks']=conflictBlocked;
 checks['conflict_rows_untouched']=jsonEncode(PrefsSvc.messaging.rows)==conflictBefore;
 print(jsonEncode({'actual_methods':'verbatim current correction','fake_boundaries':'registry/preferences only','checks':checks,'real_provider_calls':0}));
 for(final c in checks.entries){if(!c.value)throw StateError(c.key);}
}
