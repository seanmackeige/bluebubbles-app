
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bluebubbles/services/ui/chat/logical_draft.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_storage.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_confirmation_transaction.dart';
import 'package:bluebubbles/services/ui/chat/logical_draft_diagnostics.dart';
import 'independent_model_fixture.dart' as m;
class Chat {Chat([this.member=2156]);int member;}
class Definition {String id='scope';String revision=m.current.certificateRevision;}
class Certificate {String expectedExternalParticipantSetSha256=m.digest('participants');String providerFactContractRevision=m.digest('contract');String currentService='SMS';}
class Authority {bool isReady=true;String currentGenerationId='generation';String revisionMaterial='writer-material';int writerRowId=2156;}
class Evidence {Certificate? executionGenerationCertificate=Certificate();String certificateId='scope';String? accountSnapshotBeforeSha256=m.digest('account');String accountSnapshotAfterSha256=m.digest('account');final authority=Authority();}
class LogicalConversationOutboundRoutePolicy {static Authority? executionAuthority(Evidence e)=>e.authority;}
enum LogicalMutationClass {newMessage}
class LogicalMutationRequest {const LogicalMutationRequest({required this.mutationClass});final LogicalMutationClass mutationClass;}
enum LogicalTransportSendDisposition {blocked, ready}
class Readiness {bool blocked=false;LogicalTransportSendDisposition sendDispositionAt(int now)=>blocked?LogicalTransportSendDisposition.blocked:LogicalTransportSendDisposition.ready;}
class Decision {bool isSingleTarget=true;}
class Result {LogicalAuthorityRevision? revision=m.current;int? observationEpoch=1;List<Decision> decisions=[Decision()];List<Readiness> transportReadiness=[Readiness()];String? providerAccountSnapshotSha256=m.digest('account');String? providerFactContractRevision=m.digest('contract');}
class Messaging {final rows=<String,String>{};int writes=0;Future<void> Function()? hook;String? loadLogicalDraftJson(String key)=>rows[key];Future<void> saveLogicalDraftJson(String key,String value)async{writes++;rows[key]=value;await hook?.call();}}
class PrefsSvc {static final messaging=Messaging();}
class Logger {static void info(String frame,{String? tag}){if(utf8.encode(frame).length>=900)throw StateError('LOG_OVERSIZED');}}
void debugPrint(String frame){}
class Service {
 final storage=LogicalDraftStorage('scope');final _logicalConfirmationInFlight=<String>{};final queue=LogicalDraftSaveTransactionQueue();
 Evidence? _logicalRouteEvidence=Evidence();final definition=Definition();LogicalAuthorityRevision? live=m.current;
 bool writer=true,observationCurrent=true;int generation=0,reads=0,previews=0;String owner='logical-owner',providerContext=m.digest('provider-context');
 final result=Result();Future<void> Function()? duringObserve;
 String conversationKeyFor(Chat c)=>owner;
 bool hasBuild99WriterCapability(Chat c)=>writer;
 LogicalAuthorityRevision? logicalWriterAuthorityRevisionFor(Chat c)=>writer?live:null;
 int logicalDraftGenerationFor(Chat c)=>generation;
 bool isLogicalEvidenceObservationCurrent(int epoch)=>observationCurrent;
 LogicalDraftStorage? _logicalDraftStorageFor(Chat c)=>storage;
 Definition? _logicalDefinitionForChat(Chat c)=>definition;
 String _confirmationProviderContext()=>providerContext;
 bool isLogicalDraftConfirmationInFlight(Chat c)=>_logicalConfirmationInFlight.contains(owner);
 LogicalDraft? loadLogicalDraft(Chat c)=>storage.read(PrefsSvc.messaging.loadLogicalDraftJson).draft;
 Future<T> _withLogicalDraftLock<T>(Future<T> Function() body)=>queue.run(body);
 void _bumpLogicalDraftPreviewRevision(String key){previews++;}
 Future<Result> resolveLogicalMutationBatch(Chat c,List<LogicalMutationRequest> requests,{bool force=false})async{reads++;if(!force||requests.length!=1)throw StateError('BAD_OBSERVATION');await duringObserve?.call();return result;}
   Map<String, String> _currentLogicalConfirmationFacts(Chat chat, LogicalDraft draft) {
    final evidence = _logicalRouteEvidence;
    final definition = _logicalDefinitionForChat(chat);
    final certificate = evidence?.executionGenerationCertificate;
    final revision = logicalWriterAuthorityRevisionFor(chat);
    final authority = evidence == null ? null : LogicalConversationOutboundRoutePolicy.executionAuthority(evidence);
    if (!hasBuild99WriterCapability(chat) ||
        evidence == null ||
        certificate == null ||
        revision == null ||
        definition?.id != evidence.certificateId ||
        definition?.revision != revision.certificateRevision ||
        authority?.isReady != true ||
        evidence.accountSnapshotBeforeSha256 != evidence.accountSnapshotAfterSha256) {
      throw StateError('CONFIRMATION_CURRENT_PROOF_UNAVAILABLE');
    }
    return {
      'action': draft.actionId,
      'content': draft.contentFingerprint,
      'logical': draft.logicalFingerprint,
      'certificate': revision.certificateRevision,
      'authority': revision.authorityRevision,
      'participants': certificate.expectedExternalParticipantSetSha256,
      'account': evidence.accountSnapshotAfterSha256,
      'providerContract': certificate.providerFactContractRevision,
      'providerContext': _confirmationProviderContext(),
      'generation': logicalActionIdentity('confirmed-generation', [authority!.currentGenerationId]),
      'writer': logicalActionIdentity('confirmed-writer', [authority.revisionMaterial, authority.writerRowId]),
      'service': logicalActionIdentity('confirmed-service', [certificate.currentService]),
    };
  }
  bool logicalDraftConfirmationMatchesCurrentProof(Chat chat, LogicalDraft draft) {
    final record = draft.confirmation;
    if (record == null) return true;
    if (record.invalidated) return false;
    try {
      final fresh = _currentLogicalConfirmationFacts(chat, draft);
      return LogicalDraftConfirmation.requiredFacts.every((key) => fresh[key] == record.facts[key]);
    } catch (_) {
      return false;
    }
  }
  Future<LogicalDraft> confirmLegacyLogicalDraft(
    Chat chat, {
    required LogicalDraft expected,
    required LogicalAuthorityRevision authorityAtReview,
    required bool Function() composerIsCurrent,
  }) async {
    final owner = conversationKeyFor(chat);
    if (!_logicalConfirmationInFlight.add(owner)) throw StateError('CONFIRMATION_ALREADY_IN_PROGRESS');
    try {
      return await _withLogicalDraftLock(() async {
        final storage = _logicalDraftStorageFor(chat);
        if (storage == null ||
            !hasBuild99WriterCapability(chat) ||
            !composerIsCurrent() ||
            expected.metadataClass != LogicalDraftMetadataClass.legacyUnboundDraft ||
            !expected.hasUserIntent ||
            logicalWriterAuthorityRevisionFor(chat)?.certificateRevision != authorityAtReview.certificateRevision ||
            logicalWriterAuthorityRevisionFor(chat)?.authorityRevision != authorityAtReview.authorityRevision ||
            logicalWriterAuthorityRevisionFor(chat)?.epoch != authorityAtReview.epoch) {
          throw StateError('CONFIRMATION_NOT_ELIGIBLE');
        }
        final before = storage.read(PrefsSvc.messaging.loadLogicalDraftJson);
        if (before.occupiedKeys.length != 1 ||
            before.draft == null ||
            jsonEncode(before.draft!.toJson()) != jsonEncode(expected.toJson()) ||
            expected.attachments.any((item) => !item.isRestorable)) {
          throw StateError('CONFIRMATION_CUSTODY_UNAVAILABLE');
        }
        final generation = logicalDraftGenerationFor(chat);
        final providerContext = _confirmationProviderContext();
        final result = await resolveLogicalMutationBatch(chat, const [
          LogicalMutationRequest(mutationClass: LogicalMutationClass.newMessage),
        ], force: true);
        final revision = result.revision;
        final observation = result.observationEpoch;
        final evidence = _logicalRouteEvidence;
        final certificate = evidence?.executionGenerationCertificate;
        final authority = evidence == null ? null : LogicalConversationOutboundRoutePolicy.executionAuthority(evidence);
        if (revision == null ||
            observation == null ||
            certificate == null ||
            authority?.isReady != true ||
            revision.certificateRevision != authorityAtReview.certificateRevision ||
            revision.authorityRevision != authorityAtReview.authorityRevision ||
            revision.epoch != authorityAtReview.epoch ||
            result.decisions.length != 1 ||
            !result.decisions.single.isSingleTarget ||
            result.transportReadiness.length != 1 ||
            result.transportReadiness.single.sendDispositionAt(DateTime.now().millisecondsSinceEpoch) ==
                LogicalTransportSendDisposition.blocked ||
            result.providerAccountSnapshotSha256 == null ||
            result.providerFactContractRevision == null ||
            evidence!.accountSnapshotBeforeSha256 != result.providerAccountSnapshotSha256) {
          throw StateError('CONFIRMATION_CURRENT_AUTHORITY_UNAVAILABLE');
        }
        bool contextIsCurrent() {
          final live = logicalWriterAuthorityRevisionFor(chat);
          return composerIsCurrent() &&
              conversationKeyFor(chat) == owner &&
              hasBuild99WriterCapability(chat) &&
              logicalDraftGenerationFor(chat) == generation &&
              isLogicalEvidenceObservationCurrent(observation) &&
              live?.certificateRevision == revision.certificateRevision &&
              live?.authorityRevision == revision.authorityRevision &&
              live?.epoch == revision.epoch &&
              _confirmationProviderContext() == providerContext;
        }

        final proof = LogicalDraftConfirmation(
          revision: (expected.confirmation?.revision ?? 0) + 1,
          invalidated: false,
          authorityEpoch: revision.epoch,
          facts: _currentLogicalConfirmationFacts(chat, expected),
        );
        final confirmed = await confirmLogicalDraftAtomically(
          expected: expected,
          proof: proof,
          read: () => storage.read(PrefsSvc.messaging.loadLogicalDraftJson),
          write: PrefsSvc.messaging.saveLogicalDraftJson,
          contextIsCurrent: contextIsCurrent,
          nowEpochMilliseconds: DateTime.now().millisecondsSinceEpoch,
        );
        _bumpLogicalDraftPreviewRevision(storage.canonicalKey);
        for (final frame in logicalDraftDiagnosticFrames(<String, Object?>{
          'schema': 'LOGICAL_DRAFT_CONFIRMATION_RESULT_V1',
          'draftClass': confirmed.metadataClass.diagnosticName,
          'contentFingerprint': confirmed.contentFingerprint,
          'logicalFingerprint': confirmed.logicalFingerprint,
          'confirmationRevision': proof.revision,
          'certificateRevision': revision.certificateRevision,
          'authorityRevision': revision.authorityRevision,
          'epoch': revision.epoch,
          'confirmationResult': 'READY_TO_SEND_SEPARATE_HUMAN_TAP_REQUIRED',
          'sendAdmissionResult': 'NOT_ENTERED',
          'physicalDispatchCount': 0,
        })) {
          Logger.info(frame, tag: 'LogicalDraftConfirmation');
          debugPrint(frame);
        }
        return confirmed;
      });
    } finally {
      _logicalConfirmationInFlight.remove(owner);
    }
  }
}
class TextController {TextController(this.text);String text;}
class FileSelection {FileSelection(this.path);String? path;String name='sanitized';int size=1;String? balloonBundleId;}
class Controller {final textController=TextController('SANITIZED_RUNTIME_SHAPE');final subjectTextController=TextController('');final pickedAttachments=<FileSelection>[];}
class UiScenario {
 final ChatsSvc=Service();Controller controller=Controller();Chat chat=Chat();bool mounted=true,_logicalDraftConsumed=false;LogicalReplyIntent? reply;
 LogicalReplyIntent? _logicalReplyIntent()=>reply;
 bool Function() capture() {
     final ownerController = controller;
    final owner = ChatsSvc.conversationKeyFor(chat);
    final generation = ChatsSvc.logicalDraftGenerationFor(chat);
    final authorityAtReview = ChatsSvc.logicalWriterAuthorityRevisionFor(chat);
    var confirmationDraft = ChatsSvc.loadLogicalDraft(chat);
    final effectAtReview = confirmationDraft?.effectId;
    final text = controller.textController.text;
    final subject = controller.subjectTextController.text;
    final reply = jsonEncode(_logicalReplyIntent()?.toJson());
    final attachments = controller.pickedAttachments.toList(growable: false);
    final names = attachments.map((item) => item.name).toList(growable: false);
    final sizes = attachments.map((item) => item.size).toList(growable: false);
    final bundles = attachments.map((item) => item.balloonBundleId).toList(growable: false);
    bool visibleIsCurrent() =>
        mounted &&
        identical(controller, ownerController) &&
        ChatsSvc.conversationKeyFor(chat) == owner &&
        ChatsSvc.logicalDraftGenerationFor(chat) == generation &&
        !_logicalDraftConsumed &&
        controller.textController.text == text &&
        controller.subjectTextController.text == subject &&
        jsonEncode(_logicalReplyIntent()?.toJson()) == reply &&
        controller.pickedAttachments.length == attachments.length &&
        List.generate(attachments.length, (index) => index).every(
          (index) =>
              identical(controller.pickedAttachments[index], attachments[index]) &&
              attachments[index].name == names[index] &&
              attachments[index].size == sizes[index] &&
              attachments[index].balloonBundleId == bundles[index],
        );

 return visibleIsCurrent;
 }
}
class Item {Item(this.logicalDraft);final chat=Chat();LogicalDraft? logicalDraft;dynamic logicalIntentGuard;}
class Block implements Exception {Block(this.reason);String reason;}
class Handler {
 Handler(this.ChatsSvc);final Service ChatsSvc;
 Never _failLogicalAdmission(List<Item> items,String reason)=>throw Block(reason);
 void checkEntry(List<Item> items) {
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

 }
}
final checks=<String,Object?>{},failures=<String>[];
Future<void> test(String name,FutureOr<void> Function() body)async{try{await body();checks[name]='PASS';}catch(e){checks[name]='FAIL: $e';failures.add(name);}}
void require(bool ok,String detail){if(!ok)throw StateError(detail);}
void reset(){PrefsSvc.messaging.rows.clear();PrefsSvc.messaging.writes=0;PrefsSvc.messaging.hook=null;}
Future<void> main()async{
 for(final scenario in ['success','legacy occupied slot','restorable attachment','read-only member activity','missing storage','equal dual','no writer','missing live authority','modern draft','partial draft','ephemeral attachment','human edits during observation','owner changed','generation changed','provider context changed','observation superseded','certificate drift','authority drift','ABA epoch','missing fresh revision','route not ready','transport blocked','account mismatch','newer saved draft','context changes during commit']) {
  await test('service '+scenario,()async{
   reset();final s=Service();final chat=Chat();var draft=m.legacy(logicalId:s.storage.canonicalKey);bool composerCurrent=true;
   if(scenario=='modern draft')draft=draft.rearm(m.current,updatedAtEpochMilliseconds:3);
   if(scenario=='partial draft')draft=LogicalDraft.fromJson(draft.toJson()..['observedAuthorityEpoch']=20);
   if(scenario.contains('attachment'))draft=m.edit(draft,attachments:[LogicalAttachmentIntent(intentId:'attachment',name:'sanitized',size:1,isRestorable:scenario=='restorable attachment',path:scenario=='restorable attachment'?'/private/sanitized':null)]);
   final key=scenario=='legacy occupied slot'?s.storage.legacyKey:s.storage.canonicalKey;
   PrefsSvc.messaging.rows[key]=jsonEncode(draft.toJson());
   if(scenario=='missing storage')PrefsSvc.messaging.rows.clear();
   if(scenario=='equal dual')PrefsSvc.messaging.rows[s.storage.legacyKey]=jsonEncode(draft.toJson());
   if(scenario=='no writer')s.writer=false;
   if(scenario=='missing live authority')s.live=null;
   s.duringObserve=()async{
    switch(scenario){
     case 'human edits during observation':composerCurrent=false;
     case 'owner changed':s.owner='other-owner';
     case 'generation changed':s.generation++;
     case 'provider context changed':s.providerContext=m.digest('other-context');
     case 'observation superseded':s.observationCurrent=false;
     case 'certificate drift':s.live=s.result.revision=LogicalAuthorityRevision(certificateRevision:m.digest('changed-cert'),authorityRevision:m.current.authorityRevision,epoch:21);s.definition.revision=s.live!.certificateRevision;
     case 'authority drift':s.live=s.result.revision=LogicalAuthorityRevision(certificateRevision:m.current.certificateRevision,authorityRevision:m.digest('changed-authority'),epoch:21);
     case 'ABA epoch':s.live=s.result.revision=LogicalAuthorityRevision(certificateRevision:m.current.certificateRevision,authorityRevision:m.current.authorityRevision,epoch:22);
     case 'missing fresh revision':s.result.revision=null;
     case 'route not ready':s._logicalRouteEvidence!.authority.isReady=false;
     case 'transport blocked':s.result.transportReadiness.single.blocked=true;
     case 'account mismatch':s._logicalRouteEvidence!.accountSnapshotBeforeSha256=m.digest('different-account');
     case 'newer saved draft':PrefsSvc.messaging.rows[key]=jsonEncode(m.legacy(logicalId:s.storage.canonicalKey,text:'NEWER_INTENT',created:99).toJson());
     case 'read-only member activity':chat.member=2155;
    }
   };
   if(scenario=='context changes during commit')PrefsSvc.messaging.hook=()async{composerCurrent=false;};
   LogicalDraft? bound;try{bound=await s.confirmLegacyLogicalDraft(chat,expected:draft,authorityAtReview:m.current,composerIsCurrent:()=>composerCurrent);}catch(_){}
   final success=['success','legacy occupied slot','restorable attachment','read-only member activity'].contains(scenario);
   require((bound!=null)==success,'Unexpected service outcome');
   require(s._logicalConfirmationInFlight.isEmpty,'Busy owner poisoned');
   if(success){require(s.reads==1&&PrefsSvc.messaging.writes==1&&bound!.actionId==draft.actionId,'Not one read/one metadata upgrade');require(s.logicalDraftConfirmationMatchesCurrentProof(chat,bound!),'New proof did not match');}
   else if(scenario=='context changes during commit'){require(s.loadLogicalDraft(chat)!.metadataClass!=LogicalDraftMetadataClass.modernBoundDraft,'Failed commit remained ready');}
   else {require(PrefsSvc.messaging.writes==0,'Rejected service wrote metadata');}
  });
 }
 for(final key in LogicalDraftConfirmation.requiredFacts){
  await test('shared proof gate checks '+key,()async{reset();final s=Service(),chat=Chat();final d=m.legacy(logicalId:s.storage.canonicalKey);final f=s._currentLogicalConfirmationFacts(chat,d);final record=LogicalDraftConfirmation(revision:1,invalidated:false,facts:f,authorityEpoch:20);final good=d.confirm(record,nowEpochMilliseconds:100);require(s.logicalDraftConfirmationMatchesCurrentProof(chat,good),'Baseline proof mismatch');final bad=f..[key]=m.digest('changed '+key);final altered=LogicalDraft.fromJson(good.toJson()..['confirmation']=LogicalDraftConfirmation(revision:1,invalidated:false,facts:bad,authorityEpoch:20).toJson());require(!s.logicalDraftConfirmationMatchesCurrentProof(chat,altered),'Proof field ignored');});
 }
 for(final scenario in ['legacy','partial','modern','confirmation in flight']){
  await test('actual Send entry '+scenario,()async{reset();final s=Service();var d=m.legacy(logicalId:s.storage.canonicalKey);if(scenario=='partial')d=LogicalDraft.fromJson(d.toJson()..['observedAuthorityEpoch']=20);if(scenario=='modern')d=d.rearm(m.current,updatedAtEpochMilliseconds:3);if(scenario=='confirmation in flight')s._logicalConfirmationInFlight.add(s.owner);bool passed=true;try{Handler(s).checkEntry([Item(d)]);}on Block{passed=false;}require(passed==(scenario=='modern'),'Wrong Send entry result');require(s.reads==0&&PrefsSvc.messaging.writes==0,'Send gate invoked provider or binding');});
 }
 for(final scenario in ['unchanged','text','subject','reply','owner','controller','generation','consumed','unmounted','attachment replaced','attachment removed','attachment added','attachment reordered','name','size','bundle','physical member same owner']){
  await test('actual visible closure '+scenario,()async{reset();final u=UiScenario();u.controller.pickedAttachments.addAll([FileSelection('/sanitized/a'),FileSelection('/sanitized/b')]);final guard=u.capture();
   switch(scenario){case'text':u.controller.textController.text='changed';case'subject':u.controller.subjectTextController.text='changed';case'reply':u.reply=const LogicalReplyIntent(messageGuid:'g',relationshipTargetGuid:'p',sourceChatRowId:2155,sourceChatGuid:'s',part:0);case'owner':u.ChatsSvc.owner='changed';case'controller':u.controller=Controller();case'generation':u.ChatsSvc.generation++;case'consumed':u._logicalDraftConsumed=true;case'unmounted':u.mounted=false;case'attachment replaced':u.controller.pickedAttachments[0]=FileSelection('/sanitized/a');case'attachment removed':u.controller.pickedAttachments.removeLast();case'attachment added':u.controller.pickedAttachments.add(FileSelection('/sanitized/c'));case'attachment reordered':final a=u.controller.pickedAttachments.removeAt(0);u.controller.pickedAttachments.add(a);case'name':u.controller.pickedAttachments.first.name='changed';case'size':u.controller.pickedAttachments.first.size=2;case'bundle':u.controller.pickedAttachments.first.balloonBundleId='changed';case'physical member same owner':u.chat.member=2155;}
   require(guard()==['unchanged','physical member same owner'].contains(scenario),'Visible semantic gate wrong');
  });
 }
 print(jsonEncode({'scope':'Verbatim service coordinator/current proof helper/Send entry/visible composer closure; real pure model+transaction+frames; fake provider snapshot and preferences; no outgoing queue, ledger, reservation or transport implementation exists','caseCount':checks.length,'failures':failures,'results':checks}));if(failures.isNotEmpty)exitCode=1;
}
