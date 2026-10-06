import 'dart:convert';
import 'dart:async';
import 'package:bluebubbles/services/ui/chat/logical_draft_authority_alignment.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_intent_guard.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/services/ui/chat/logical_conversation_identity.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_storage.dart';
class Chat { final int? originalROWID; Chat(this.originalROWID); }
class Entry { final LogicalConversationId logicalId; final Set<int> sourceChatRowIds={2155,2156}; Entry(this.logicalId); }
class Messaging {final rows=<String,String>{};int saves=0;Future<void> Function()? beforeSave;String? loadLogicalDraftJson(String key)=>rows[key];Future<void> saveLogicalDraftJson(String key,String value)async{saves++;await beforeSave?.call();rows[key]=value;}Future<void> clearLogicalDraft(String key)async{rows.remove(key);}}
class PrefsSvc {static final messaging=Messaging();}
class Logger {static void warn(String m,{Object? error,StackTrace? trace,String? tag}){}}
class Service {
 bool isLogicalDraftConfirmationInFlight(Chat c)=>false;
 bool logicalDraftConfirmationMatchesCurrentProof(Chat c,LogicalDraft d)=>true;

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
          current.metadataClass != LogicalDraftMetadataClass.modernBoundDraft ||
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
            current.metadataClass != LogicalDraftMetadataClass.modernBoundDraft ||
            current.actionId != expected.actionId ||
            current.contentFingerprint != expected.contentFingerprint ||
            current.observedCertificateRevision != expected.observedCertificateRevision ||
            current.observedAuthorityRevision != expected.observedAuthorityRevision ||
            current.observedAuthorityEpoch != expected.observedAuthorityEpoch ||
            live == null ||
            live.certificateRevision != observed.certificateRevision ||
            live.authorityRevision != observed.authorityRevision ||
            live.epoch != observed.epoch) {
          return null;
        }
        final aligned = current.rearm(observed, updatedAtEpochMilliseconds: DateTime.now().millisecondsSinceEpoch);
        for (final key in slot.occupiedKeys) {
          await PrefsSvc.messaging.saveLogicalDraftJson(key, jsonEncode(aligned.toJson()));
        }
        _bumpLogicalDraftPreviewRevision(storage.canonicalKey);
        return aligned;
      });


}

class Item {Chat get chat => Chat(2156);Item(this.logicalDraft,this.logicalIntentGuard);LogicalDraft? logicalDraft;LogicalDraftIntentGuard? logicalIntentGuard;}
class Block implements Exception {Block(this.reason);final String reason;}
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
class Data {Data(this.logicalIntentGuard);final LogicalDraftIntentGuard? logicalIntentGuard;}
class Consumer {Consumer(this.ChatsSvc);final Service ChatsSvc;int calls=0;void Function()? get logicalDraftConsumedFunc=>()=>calls++;
 Future<void> consume(LogicalDraft draft,LogicalDraftIntentGuard guard)async {final data=Data(guard);
    if (data.logicalIntentGuard != null && !data.logicalIntentGuard!.composerStillCurrent) return;
    draft = data.logicalIntentGuard?.effectiveDraft ?? draft;
    if (await ChatsSvc.clearLogicalDraftIfCurrent(draft)) {
      data.logicalIntentGuard?.draftConsumed();
      if (data.logicalIntentGuard != null && !data.logicalIntentGuard!.composerStillCurrent) return;
      logicalDraftConsumedFunc?.call();
    }
 }}
const oldRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:1);
const freshRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:2);
LogicalDraft make(Service s,{String text='fixture',int created=1,LogicalAuthorityRevision? observed=oldRevision})=>LogicalDraft.create(logicalId:s.entry.logicalId.value,nowEpochMilliseconds:created,observedRevision:observed).mergeUserIntent(text:text,subject:'',attachments:[],reply:null,effectId:null,updatedAtEpochMilliseconds:created+1);
void ensure(bool value,String name){if(!value)throw StateError(name);}
Future<void> main()async {
 final checks=<String,Object?>{};
 Service setup(){PrefsSvc.messaging.rows.clear();PrefsSvc.messaging.saves=0;PrefsSvc.messaging.beforeSave=null;return Service()..currentLogicalAuthorityRevision=freshRevision;}
 Future<void> seed(Service s,LogicalDraft d,{bool legacy=false})async{PrefsSvc.messaging.rows[legacy?s.storage.legacyKey:s.storage.canonicalKey]=jsonEncode(d.toJson());}
 for(final kind in ['same','updated timestamp','missing','replacement','content','observed changed','live null','live epoch changed','live authority changed','unknown owner','dual identical','dual conflict']){
 final s=setup();var expected=make(s);await seed(s,expected);final rows=PrefsSvc.messaging.rows;
 switch(kind){
 case 'updated timestamp':await seed(s,expected.rearm(oldRevision,updatedAtEpochMilliseconds:999));
 case 'missing':rows.clear();
 case 'replacement':await seed(s,make(s,created:99));
 case 'content':await seed(s,make(s,text:'new content'));
 case 'observed changed':await seed(s,expected.rearm(freshRevision,updatedAtEpochMilliseconds:999));
 case 'live null':s.currentLogicalAuthorityRevision=null;
 case 'live epoch changed':s.currentLogicalAuthorityRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:3);
 case 'live authority changed':s.currentLogicalAuthorityRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'B',epoch:2);
 case 'unknown owner':expected=LogicalDraft.create(logicalId:'other',nowEpochMilliseconds:1,observedRevision:oldRevision);
 case 'dual identical':await seed(s,expected,legacy:true);
 case 'dual conflict':await seed(s,make(s,text:'conflict'),legacy:true);
 }
 final before=jsonEncode(rows);LogicalDraft? aligned;String? failure;
 try{aligned=await s.alignLogicalDraftAuthorityIfCurrent(expected,freshRevision);}on StateError catch(e){failure=e.toString();}
 final allow=['same','updated timestamp','dual identical'].contains(kind);
 if(allow){ensure(aligned!=null,'$kind null');ensure(aligned!.actionId==expected.actionId&&aligned.contentFingerprint==expected.contentFingerprint,'$kind identity');ensure(freshRevision.matchesDraft(aligned),'$kind fresh');ensure(aligned.compositionAuthorityEpoch==expected.compositionAuthorityEpoch,'$kind composition');}
 else {ensure(aligned==null,'$kind accepted');ensure(jsonEncode(rows)==before,'$kind mutated');}
 if(kind=='dual conflict')ensure(failure!=null,'conflict not rejected');
 checks['CAS $kind']={'aligned':aligned!=null,'rejectedWithoutMutation':!allow,'storageException':failure!=null};
 }
 for(final legacy in [false,true]){
 final s=setup();final old=make(s);await seed(s,old,legacy:legacy);final aligned=await s.alignLogicalDraftAuthorityIfCurrent(old,freshRevision);ensure(aligned!=null,'legacy CAS');ensure(PrefsSvc.messaging.rows.keys.single==(legacy?s.storage.legacyKey:s.storage.canonicalKey),'slot changed');checks['slot legacy=$legacy']='PRESERVED';
 }
 for(final kind in ['single','shared three','two distinct guards','human change during CAS','authority ABA during CAS','observation superseded during CAS','provider context during CAS','missing anchor','missing prior proof','missing old epoch','material authority changed']){
 final s=setup();var original=make(s,observed:kind=='missing prior proof'?null:oldRevision);if(kind=='missing old epoch'){final raw=original.toJson();raw['observedAuthorityEpoch']=null;original=LogicalDraft.fromJson(raw);}await seed(s,original);final handler=Handler(s);String? semantic;final records=<String>[];
 LogicalDraftIntentGuard guard(){late final LogicalDraftIntentGuard g;g=LogicalDraftIntentGuard(frozenDraft:original,authorityAtFreeze:kind=='missing anchor'?null:freshRevision,validateCurrent:()=>semantic,composerIsCurrent:()=>semantic==null,record:(r,b)=>records.add(r),validateAuthority:()=>s.currentLogicalAuthorityRevision?.matchesDraft(g.effectiveDraft!)==true?null:'AUTHORITY_CHANGED');return g;}
 final g=guard();final items=<Item>[Item(original,g)];if(kind=='shared three')items.addAll([Item(original,g),Item(original,g)]);if(kind=='two distinct guards')items.add(Item(original,guard()));
 final revision=kind=='material authority changed'?LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'B',epoch:2):freshRevision;
 PrefsSvc.messaging.beforeSave=()async{
 if(kind=='human change during CAS')semantic='CONTENT_CHANGED';
 if(kind=='authority ABA during CAS')s.currentLogicalAuthorityRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:4);
 if(kind=='observation superseded during CAS')s.observationCurrent=false;
 if(kind=='provider context during CAS')handler.context='changed';
 };
 String result='PASS';try{await handler.evaluate(items,revision);g.validateBeforeTransport();}on Block catch(e){result=e.reason;}on LogicalDraftIntentException catch(e){result=e.reason;}
 final allow=['single','shared three','two distinct guards'].contains(kind);ensure((result=='PASS')==allow,'handler $kind $result');
 if(allow){ensure(items.every((i)=>freshRevision.matchesDraft(i.logicalDraft!)&&i.logicalDraft!.actionId==original.actionId),'item propagation');ensure(g.effectiveDraft!.observedAuthorityEpoch==2,'guard propagation');final consumer=Consumer(s);await consumer.consume(original,g);ensure(consumer.calls==1,'consumer callback');ensure(s.loadLogicalDraft(Chat(2156))==null,'not consumed');ensure(s.logicalDraftGenerationFor(Chat(2156))==1,'generation not canonical');ensure(g.draftWasConsumed,'consume diagnostic');final next=await s._saveLogicalDraftLocked(Chat(2156),text:'next intent',subject:'',attachments:[],reply:null,expectedDraftGeneration:1);ensure(next!=null,'next freeze poisoned');}
 checks['handler $kind']={'result':result,'epochRefreshRecords':records.where((r)=>r=='AUTHORITY_EPOCH_REFRESHED_EXPECTED_INTERNAL').length,'consumerPropagationVerified':allow};
 }


 // Independent final optional-CAS-before-unconditional-pause transition cases.
 for(final kind in ['material drift','ABA epoch drift','human edit blocks optional rearm','observation stale skips optional rearm','newer persisted draft skips optional rearm']) {
 final s=setup();final original=make(s);await seed(s,original);final handler=Handler(s);final records=<String>[];
 final observed=kind=='material drift'?const LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'B',epoch:3):const LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:4);
 s.currentLogicalAuthorityRevision=observed;
 if(kind=='observation stale skips optional rearm')s.observationCurrent=false;
 if(kind=='newer persisted draft skips optional rearm')await seed(s,make(s,text:'new human intent',created:19));
 final before=jsonEncode(PrefsSvc.messaging.rows);
 final guard=LogicalDraftIntentGuard(frozenDraft:original,authorityAtFreeze:freshRevision,validateCurrent:()=>kind=='human edit blocks optional rearm'?'CONTENT_CHANGED':null,composerIsCurrent:()=>true,record:(r,b)=>records.add(r),validateAuthority:()=>null);
 String first='PASS';try{await handler.evaluate([Item(original,guard)],observed);}on Block catch(e){first=e.reason;}on LogicalDraftIntentException catch(e){first=e.reason;}
 ensure(first==(kind=='human edit blocks optional rearm'?'CONTENT_CHANGED':'SEND_BLOCKED_AUTHORITY_CHANGED_DURING_FREEZE'),'$kind firsttap $first');
 ensure(identical(guard.effectiveDraft,original),'$kind firsttap guard authorized');
 ensure(!records.contains('AUTHORITY_EPOCH_REFRESHED_EXPECTED_INTERNAL'),'$kind unexpected acceptrefresh');
 final expectedRearm=['material drift','ABA epoch drift'].contains(kind);
 if(expectedRearm){
 final rearmed=s.loadLogicalDraft(Chat(2156))!;
 ensure(observed.matchesDraft(rearmed),'$kind missing rearm');
 ensure(rearmed.actionId==original.actionId&&rearmed.contentFingerprint==original.contentFingerprint&&rearmed.compositionAuthorityEpoch==original.compositionAuthorityEpoch,'$kind custody changed');
 final writes=PrefsSvc.messaging.saves;
 final freshGuard=LogicalDraftIntentGuard(frozenDraft:rearmed,authorityAtFreeze:observed,validateCurrent:()=>null,composerIsCurrent:()=>true,record:(_,__){},validateAuthority:()=>null);
 await handler.evaluate([Item(rearmed,freshGuard)],observed);
 freshGuard.validateBeforeTransport();
 ensure(PrefsSvc.messaging.saves==writes,'$kind second confirmation caused more metadata writes');
 }else {ensure(PrefsSvc.messaging.saves==0&&jsonEncode(PrefsSvc.messaging.rows)==before,'$kind rearmed despite changed evidence');}
 checks['first pause then confirmation $kind']={'firstTap':first,'firstGuardNotGranted':true,'optionalRearm':expectedRearm,'nextFreshConfirmationPassesWithoutRearm':expectedRearm,'transportAbsent':true};
 }

 const priorDifferent=LogicalAuthorityRevision(certificateRevision:'OLD_C',authorityRevision:'OLD_A',epoch:9);
 const attachment=LogicalAttachmentIntent(intentId:'fixture-attachment',name:'fixture',size:1,isRestorable:false);
 const reply=LogicalReplyIntent(messageGuid:'fixture-guid',relationshipTargetGuid:'fixture-parent',sourceChatRowId:2156,sourceChatGuid:'fixture-source',part:0);
 for(final kind in ['new text','new subject','new attachment','new reply','new effect','still empty','existing text','existing whitespace','existing subject','existing attachment','existing reply','existing effect','missing current','missing prior']){
 final s=setup();if(kind=='missing current'){s.currentLogicalAuthorityRevision=null;s._logicalAuthorityRevisionTracker.observe(certificateRevision:'STALE_LAST',authorityRevision:'STALE_LAST');}
 var initial=LogicalDraft.create(logicalId:s.entry.logicalId.value,nowEpochMilliseconds:1,observedRevision:kind=='missing prior'?null:priorDifferent);
 if(kind.startsWith('existing'))initial=initial.mergeUserIntent(text:kind=='existing text'?'old':kind=='existing whitespace'?' ':'',subject:kind=='existing subject'?'old':'',attachments:kind=='existing attachment'?[attachment]:[],reply:kind=='existing reply'?reply:null,effectId:kind=='existing effect'?'old-effect':null,updatedAtEpochMilliseconds:2);
 await seed(s,initial);
 final isExisting=kind.startsWith('existing');
 final saved=(await s._saveLogicalDraftLocked(Chat(2156),text:kind=='still empty'?'':(isExisting||['new text','missing current','missing prior'].contains(kind))?'fresh':'',subject:kind=='new subject'?'subject':'',attachments:kind=='new attachment'?[attachment]:[],reply:kind=='new reply'?reply:null,effectId:kind=='new effect'?'effect':null,expectedDraftGeneration:0))!;
 final adopts=(!isExisting&&kind!='still empty'&&kind!='missing current');
 if(adopts){ensure(freshRevision.matchesDraft(saved),'$kind did not capture current');ensure(saved.actionId!=initial.actionId,'$kind did not change action');}
 else {ensure(saved.observedCertificateRevision==initial.observedCertificateRevision&&saved.observedAuthorityRevision==initial.observedAuthorityRevision&&saved.observedAuthorityEpoch==initial.observedAuthorityEpoch,'$kind incorrectly upgraded proof');}
 ensure(saved.compositionAuthorityRevision==initial.compositionAuthorityRevision,'$kind composition changed');
 checks['empty policy $kind']={'capturesCurrent':adopts,'priorHumanIntent':initial.hasUserIntent,'actionChanged':saved.actionId!=initial.actionId};
 }

 for(final dual in [false,true]){
 final s=setup();final original=make(s);await seed(s,original);if(dual)await seed(s,original,legacy:true);final handler=Handler(s);
 final guard=LogicalDraftIntentGuard(frozenDraft:original,authorityAtFreeze:freshRevision,validateCurrent:()=>null,composerIsCurrent:()=>true,record:(_,__){},validateAuthority:()=>null);
 final before=Map<String,String>.from(PrefsSvc.messaging.rows);int writes=0;PrefsSvc.messaging.beforeSave=()async{writes++;if(!dual||writes==2)throw StateError('FIXTURE_STORAGE_WRITE_FAILURE');};
 bool failed=false;try{await handler.evaluate([Item(original,guard)],freshRevision);}on StateError catch(e){failed=e.message=='FIXTURE_STORAGE_WRITE_FAILURE';}
 ensure(failed,'write failure swallowed');ensure(guard.effectiveDraft!.observedAuthorityEpoch==1,'failed write granted refreshed guard');ensure(PrefsSvc.messaging.rows.values.every((raw)=>LogicalDraft.fromJson(jsonDecode(raw)).contentFingerprint==original.contentFingerprint),'write failure lost content');
 checks['storage failure dual=$dual']={'blocked':failed,'guardUnrefreshed':guard.effectiveDraft!.observedAuthorityEpoch==1,'contentRetained':true,'partialMetadataConflictPossible':dual};
 }
 print(jsonEncode({'method_origin':'verbatim CAS/save/load/clear/persist methods + handler alignment block + CVC consumption tail; actual policy/guard/models','fake_boundaries':'registry/preferences/provider snapshot/composer callback only; transport absent','checks':checks,'real_provider_calls':0}));
}
