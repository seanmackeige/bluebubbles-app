import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft_admission_probe.dart';
import 'dart:async';
import '../../../../lib/services/ui/chat/logical_draft_authority_alignment.dart';
import '../../../../lib/services/ui/chat/logical_draft_intent_guard.dart';
import '../../../../lib/services/ui/chat/logical_draft.dart';
import '../../../../lib/services/ui/chat/logical_conversation_identity.dart';
import '../../../../lib/services/ui/chat/logical_draft_storage.dart';
class Chat { final int? originalROWID; Chat(this.originalROWID); }
class Entry { final LogicalConversationId logicalId; final Set<int> sourceChatRowIds={2155,2156}; Entry(this.logicalId); }
class Messaging {final rows=<String,String>{};int saves=0;Future<void> Function()? beforeSave;String? loadLogicalDraftJson(String key)=>rows[key];Future<void> saveLogicalDraftJson(String key,String value)async{saves++;await beforeSave?.call();rows[key]=value;}Future<void> clearLogicalDraft(String key)async{rows.remove(key);}}
class PrefsSvc {static final messaging=Messaging();}
class Logger {static final reports=<Map<String,dynamic>>[];static void warn(String m,{Object? error,StackTrace? trace,String? tag}){}static void info(String m,{String? tag}){reports.add(jsonDecode(m));}}
class Service {
 LogicalAuthorityRevision? currentLogicalAuthorityRevision;bool observationCurrent=true;bool isLogicalEvidenceObservationCurrent(int epoch)=>observationCurrent;
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
 bool hasBuild99WriterCapability(Chat chat)=>true;
 LogicalAuthorityRevision? logicalWriterAuthorityRevisionFor(Chat chat)=>currentLogicalAuthorityRevision;
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
    // A completely empty container has no pending human intent to bind to an
    // old authority. The first real content captures current authority only.
    final startsNewIntent =
        !existing.hasUserIntent &&
        (text.isNotEmpty || subject.isNotEmpty || attachments.isNotEmpty || reply != null || effectId != null);
    final updated = existing.mergeUserIntent(
      observedRevision: startsNewIntent ? logicalWriterAuthorityRevisionFor(chat) : null,
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
          current.observedAuthorityEpoch != admittedDraft.observedAuthorityEpoch) {
        return false;
      }
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

  Future<LogicalDraft?> alignLogicalDraftAuthorityIfCurrent(LogicalDraft expected, LogicalAuthorityRevision observed) =>
      _withLogicalDraftLock(() async {
        final storage = _logicalDraftStorageForId(expected.logicalId);
        if (storage == null) return null;
        final slot = storage.read(PrefsSvc.messaging.loadLogicalDraftJson);
        final current = slot.draft;
        final live = currentLogicalAuthorityRevision;
        if (current == null ||
            current.actionId != expected.actionId ||
            current.contentFingerprint != expected.contentFingerprint ||
            current.observedCertificateRevision != expected.observedCertificateRevision ||
            current.observedAuthorityRevision != expected.observedAuthorityRevision ||
            current.observedAuthorityEpoch != expected.observedAuthorityEpoch ||
            live == null ||
            live.certificateRevision != observed.certificateRevision ||
            live.authorityRevision != observed.authorityRevision ||
            live.epoch != observed.epoch)
          return null;
        final aligned = current.rearm(observed, updatedAtEpochMilliseconds: DateTime.now().millisecondsSinceEpoch);
        for (final key in slot.occupiedKeys) {
          await PrefsSvc.messaging.saveLogicalDraftJson(key, jsonEncode(aligned.toJson()));
        }
        _bumpLogicalDraftPreviewRevision(storage.canonicalKey);
        return aligned;
      });


}

final debugLines=<String>[];void debugPrint(String value)=>debugLines.add(value);
class ProbeService extends Service {
 int _logicalDraftProbeCount=0;bool logical=true;bool writer=true;
 bool isLogicalConversation(Chat chat)=>logical;
 @override LogicalAuthorityRevision? logicalWriterAuthorityRevisionFor(Chat chat)=>writer?currentLogicalAuthorityRevision:null;
  void inspectLogicalDraftAdmissionSnapshot(Chat chat) {
    if (_logicalDraftProbeCount >= 8 || !isLogicalConversation(chat)) return;
    _logicalDraftProbeCount += 1;
    LogicalDraft? draft;
    var coherent = false;
    try {
      final storage = _logicalDraftStorageFor(chat);
      if (storage != null) {
        draft = storage.read(PrefsSvc.messaging.loadLogicalDraftJson).draft;
        coherent = true;
      }
    } catch (_) {
      /* Conflicting slots stay untouched. */
    }
    final report = logicalDraftAdmissionProbe(
      draft: draft,
      authority: logicalWriterAuthorityRevisionFor(chat),
      generation: logicalDraftGenerationFor(chat),
      storageCoherent: coherent,
    );
    final encoded = jsonEncode(report);
    Logger.info(encoded, tag: 'LogicalDraftPreflight');
    // Explicit bounded diagnostics remain observable on a non-debuggable release.
    debugPrint(encoded);
  }

}
void main(){
 final results=<String,Object?>{};
 for(final name in ['bounded repeated expansion','not logical','other certified read-only owner','conflicting storage']){
 PrefsSvc.messaging.rows.clear();PrefsSvc.messaging.saves=0;Logger.reports.clear();debugLines.clear();final s=ProbeService()..currentLogicalAuthorityRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:2);final chat=Chat(2156);
 final d=LogicalDraft.create(logicalId:s.entry.logicalId.value,nowEpochMilliseconds:1,observedRevision:LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:1));PrefsSvc.messaging.rows[s.storage.canonicalKey]=jsonEncode(d.toJson());
 if(name=='not logical')s.logical=false;if(name=='other certified read-only owner')s.writer=false;if(name=='conflicting storage')PrefsSvc.messaging.rows[s.storage.legacyKey]=jsonEncode(d.mergeUserIntent(text:'conflicting',subject:'',attachments:[],reply:null,effectId:null,updatedAtEpochMilliseconds:2).toJson());
 final before=jsonEncode(PrefsSvc.messaging.rows);final initialAuthority=s.currentLogicalAuthorityRevision;for(var i=0;i<(name=='bounded repeated expansion'?10:1);i++){s.inspectLogicalDraftAdmissionSnapshot(chat);}
 final expected=name=='not logical'?0:name=='bounded repeated expansion'?8:1;
 if(Logger.reports.length!=expected||debugLines.length!=expected)throw StateError('bound/logging incorrect');if(PrefsSvc.messaging.saves!=0||jsonEncode(PrefsSvc.messaging.rows)!=before||!identical(initialAuthority,s.currentLogicalAuthorityRevision)||s.logicalDraftGenerationFor(chat)!=0)throw StateError('probe mutated protected state');
 if(name=='other certified read-only owner'&&Logger.reports.single['liveAuthority']!=null)throw StateError('wrong authority scope');if(name=='conflicting storage'&&Logger.reports.single['storageCoherent']!=false)throw StateError('conflict hidden');
 results[name]={'reports':expected,'storageWrites':0,'generationUnchanged':true,'authorityUnchanged':true,'rowsUnchanged':true};
 }
 print(jsonEncode({'method':'verbatim inspectLogicalDraftAdmissionSnapshot + actual pure probe/guard/models; fake cached prefs/logger only','cases':results,'real_provider_calls':0}));
}
