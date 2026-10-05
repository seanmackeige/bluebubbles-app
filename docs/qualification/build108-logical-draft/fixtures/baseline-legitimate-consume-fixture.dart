import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft.dart';
import '../../../../lib/services/ui/chat/logical_conversation_identity.dart';
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
 Entry? _registryEntryForChat(Chat chat)=>entry;
 String? logicalConversationIdFor(Chat chat)=>rawId;
 bool hasBuild99WriterCapability(Chat chat)=>false;
 LogicalAuthorityRevision? logicalWriterAuthorityRevisionFor(Chat chat)=>null;
 Future<T> _withLogicalDraftLock<T>(Future<T> Function() f)=>queue.run(f);
 void _bumpLogicalDraftPreviewRevision(String key){_logicalDraftPreviewRevisions[key]=(_logicalDraftPreviewRevisions[key]??0)+1;}
  LogicalDraft? loadLogicalDraft(Chat chat) {
    final logicalId = logicalConversationIdFor(chat);
    if (logicalId == null) return null;
    final raw = PrefsSvc.messaging.loadLogicalDraftJson(logicalId);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final draft = LogicalDraft.fromJson(decoded.cast<String, dynamic>());
      return draft.logicalId == logicalId ? draft : null;
    } catch (error, stack) {
      Logger.warn('Logical draft is unreadable and remains untouched', error: error, trace: stack, tag: 'LogicalDraft');
      return null;
    }
  }

  int logicalDraftGenerationFor(Chat chat) {
    final logicalId = logicalConversationIdFor(chat);
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
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing =
        loadLogicalDraft(chat) ??
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
    await PrefsSvc.messaging.saveLogicalDraftJson(logicalId, jsonEncode(updated.toJson()));
    _bumpLogicalDraftPreviewRevision(logicalId);
    return updated;
  }
  Future<bool> clearLogicalDraftIfCurrent(LogicalDraft admittedDraft) {
    return _withLogicalDraftLock(() async {
      final currentRaw = PrefsSvc.messaging.loadLogicalDraftJson(admittedDraft.logicalId);
      if (currentRaw == null) {
        _bumpLogicalDraftPreviewRevision(admittedDraft.logicalId);
        return true;
      }
      try {
        final current = LogicalDraft.fromJson((jsonDecode(currentRaw) as Map).cast<String, dynamic>());
        if (current.contentRevision != admittedDraft.contentRevision ||
            current.contentFingerprint != admittedDraft.contentFingerprint ||
            current.observedCertificateRevision != admittedDraft.observedCertificateRevision ||
            current.observedAuthorityRevision != admittedDraft.observedAuthorityRevision ||
            current.observedAuthorityEpoch != admittedDraft.observedAuthorityEpoch) {
          return false;
        }
      } catch (_) {
        return false;
      }
      _logicalDraftGenerations.update(admittedDraft.logicalId, (value) => value + 1, ifAbsent: () => 1);
      await PrefsSvc.messaging.clearLogicalDraft(admittedDraft.logicalId);
      _bumpLogicalDraftPreviewRevision(admittedDraft.logicalId);
      return true;
    });
  }
 Future<LogicalDraft?> freeze(Chat c,String text)=>_withLogicalDraftLock(()=>_saveLogicalDraftLocked(c,text:text,subject:'',attachments:[],reply:null,expectedDraftGeneration:logicalDraftGenerationFor(c)));
}
Future<void> main() async {
 final svc=Service(); final chat=Chat(2156);
 final first=await svc.freeze(chat,'SANITIZED_FIXTURE_UNCHANGED');
 final invisible=svc.loadLogicalDraft(chat)==null;
 await Future<void>.delayed(Duration(milliseconds:2));
 final republished=await svc.freeze(chat,'SANITIZED_FIXTURE_UNCHANGED');
 final actionChanged=first!.actionId!=republished!.actionId;
 final clearsReplacement=await svc.clearLogicalDraftIfCurrent(republished);
 final generationRead=svc.logicalDraftGenerationFor(chat);
 final generationCompared=svc._logicalDraftGenerations[svc.entry.logicalId.value]??0;
 final paused=(await svc.freeze(chat,'SANITIZED_NEXT_NATURAL_INTENT'))==null;
 final result=<String,dynamic>{
 'baseline_commit':'5ff6846f75b4e02c1cc8f6d8f93c085587346d44',
 'method_origin':'verbatim extracted baseline service methods; fake registry/preferences only',
 'original_runtime_transients':'UNKNOWN_NOT_RECONSTRUCTED',
 'same_namespace':svc.rawId==svc.entry.logicalId.value,
 'saved_draft_unreadable_by_own_service':invisible,
 'same_content_republish_changed_action_identity':actionChanged,
 'legitimate_prior_consumption_succeeded':clearsReplacement,
 'generation_first_operand':generationRead,
 'generation_second_operand':generationCompared,
 'next_tap_reproduces_null_pause':paused,
 'fixture_physical_execution_count':0,
 'current_tap_internal_consumption_count':0,
 };
 print(jsonEncode(result));
 if(!invisible||!actionChanged||!clearsReplacement||generationRead!=0||generationCompared!=1||!paused)throw StateError('fixture did not reproduce');
}
