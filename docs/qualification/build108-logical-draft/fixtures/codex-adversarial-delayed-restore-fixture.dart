import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft.dart';
class Value<T>{Value(this.value);T value;}
class Local {final oldText=Value('');}
class Edit {String _text='';void Function()? notify;String get text=>_text;set text(String v){_text=v;notify?.call();}}
class PlatformFile {PlatformFile({required this.name,this.bytes,required this.size,this.path});final String name;final List<int>? bytes;final int size;final String? path;}
class Files extends ListBase<PlatformFile>{final data=<PlatformFile>[];void Function()? notify;@override int get length=>data.length;@override set length(int n){data.length=n;notify?.call();}@override PlatformFile operator[](int i)=>data[i];@override void operator[]=(int i,PlatformFile v){data[i]=v;notify?.call();}@override void add(PlatformFile v){data.add(v);notify?.call();}@override void addAll(Iterable<PlatformFile> v){data.addAll(v);notify?.call();}@override void clear(){data.clear();notify?.call();}}
class Controller {final textController=Edit();final subjectTextController=Edit();final pickedAttachments=Files();Object? _reply;void Function()? replyNotify;Object? get replyToMessage=>_reply;set replyToMessage(Object? v){_reply=v;replyNotify?.call();}}
class Source {final originalROWID=2155;final guid='sanitized-source';}
class Link {final target=Source();}
class Message {final chat=Link();static Message? findOne({required String guid})=>Message();}
class MessageReplyContext {MessageReplyContext(this.message,this.part);final Message message;final int part;}
class Chat {final textFieldAttachments=<String>[];}
class ChatState {final textFieldAttachments=<String>[];}
class Service {LogicalDraft? draft;LogicalDraft? loadLogicalDraft(Chat chat)=>draft;ChatState? getChatState(String key)=>null;}
final ChatsSvc=Service();
class File {File(this.path);final String path;static Completer<bool> existsGate=Completer<bool>();Future<bool> exists()=>existsGate.future;Future<List<int>> readAsBytes()async=>[1,2,3];}
String basename(String p)=>p.split('/').last;
class Scenario {
 Scenario(){
 controller.textController.notify=()=>onText(false);controller.subjectTextController.notify=()=>onText(true);
 controller.pickedAttachments.notify=onAttachment;controller.replyNotify=onReply;
 }
 final controller=Controller();final localController=Local();final chat=Chat();final chatGuid='logical';
 bool _hasLogicalDraftIdentity=true;bool _isProtectedLogicalSource=true;bool mounted=true;bool _logicalDraftConsumed=false;bool _restoringLogicalDraft=false;int _logicalUiGeneration=0;bool listeners=false;
 LogicalReplyIntent? _retainedLogicalReplyIntent;final _logicalReplyResolutionPending=Value(false);
 void getTextDraft(){}
 void onText(bool subject){if(!listeners)return;
    final semanticText = "${controller.subjectTextController.text}\n${controller.textController.text}";
    if (!_restoringLogicalDraft && semanticText != localController.oldText.value) _logicalUiGeneration += 1;

 localController.oldText.value="${controller.subjectTextController.text}\n${controller.textController.text}";
 }
 void onAttachment(){if(!listeners)return;
        if (_restoringLogicalDraft) return;
        _logicalUiGeneration += 1;

 }
 void onReply(){if(!listeners)return;
        if (_restoringLogicalDraft) return;
        _logicalUiGeneration += 1;

 }
  Future<void> getDrafts() async {
    if (_hasLogicalDraftIdentity) {
      final generation = _logicalUiGeneration;
      bool isCurrent() => mounted && !_logicalDraftConsumed && generation == _logicalUiGeneration;
      _restoringLogicalDraft = true;
      try {
        final draft = ChatsSvc.loadLogicalDraft(chat);
        if (draft == null || !isCurrent()) return;
        if (draft.text.isNotEmpty) controller.textController.text = draft.text;
        if (draft.subject.isNotEmpty) controller.subjectTextController.text = draft.subject;
        // Suppress only synchronous restoration writes. Human events during
        // file IO must invalidate the pending restore generation.
        _restoringLogicalDraft = false;
        await getAttachmentDrafts(
          attachments: draft.attachments
              .where((item) => item.isRestorable)
              .map((item) => item.path)
              .whereType<String>()
              .toList(),
          isCurrent: isCurrent,
        );
        if (!isCurrent()) return;
        _restoringLogicalDraft = true;
        final reply = draft.reply;
        _logicalReplyResolutionPending.value = false;
        if (reply != null) {
          _retainedLogicalReplyIntent = reply;
          final message = Message.findOne(guid: reply.messageGuid);
          final source = message?.chat.target;
          if (message != null &&
              source?.originalROWID == reply.sourceChatRowId &&
              source?.guid == reply.sourceChatGuid) {
            controller.replyToMessage = MessageReplyContext(message, reply.part);
          } else {
            _logicalReplyResolutionPending.value = true;
          }
        }
      } finally {
        _restoringLogicalDraft = false;
      }
      return;
    }
    if (_isProtectedLogicalSource) return;
    getTextDraft();
    await getAttachmentDrafts();
  }
  Future<void> getAttachmentDrafts({List<String> attachments = const [], bool Function()? isCurrent}) async {
    // Read from ChatState — it is the source of truth and is always up-to-date.
    // Fall back to chat.textFieldAttachments for the first load after a cold start
    // (before ChatState has been updated by any setChatTextFieldAttachments call).
    final incomingAttachments = isCurrent != null || attachments.isNotEmpty
        ? attachments
        : (ChatsSvc.getChatState(chatGuid)?.textFieldAttachments.toList() ?? chat.textFieldAttachments);
    final currentPicked = controller.pickedAttachments.map((element) => element.path).toList();
    final restored = <PlatformFile>[];
    for (String s in incomingAttachments) {
      final file = File(s);
      if (!currentPicked.contains(s) && await file.exists()) {
        final bytes = await file.readAsBytes();
        if (isCurrent != null && !isCurrent()) return;
        restored.add(PlatformFile(name: basename(file.path), bytes: bytes, size: bytes.length, path: s));
      }
    }
    if (isCurrent != null && !isCurrent()) return;
    final wasRestoring = _restoringLogicalDraft;
    if (isCurrent != null) _restoringLogicalDraft = true;
    try {
    if (incomingAttachments.any((element) => !currentPicked.contains(element))) {
      controller.pickedAttachments.clear();
    }
    controller.pickedAttachments.addAll(restored);
    } finally {
      _restoringLogicalDraft = wasRestoring;
    }
  }
}
Future<void> main()async {
 final rows=<String,Map<String,Object>>{};
 for(final event in ['none','text','subject','attachment','reply','cursor','disposed']){
 File.existsGate=Completer<bool>();final s=Scenario();
 ChatsSvc.draft=LogicalDraft.create(logicalId:'sanitized',nowEpochMilliseconds:1).mergeUserIntent(text:'old draft',subject:'old subject',attachments:[LogicalAttachmentIntent(intentId:'sanitized',name:'old',size:3,isRestorable:true,path:'/fixture/old')],reply:LogicalReplyIntent(messageGuid:'old',relationshipTargetGuid:'old',sourceChatRowId:2155,sourceChatGuid:'sanitized-source',part:0),effectId:null,updatedAtEpochMilliseconds:2);
 final restoring=s.getDrafts();
 s.listeners=true;s.localController.oldText.value="${s.controller.subjectTextController.text}\n${s.controller.textController.text}";
 final humanReply=Object();
 switch(event){
 case 'text':s.controller.textController.text='new human text';break;
 case 'subject':s.controller.subjectTextController.text='new human subject';break;
 case 'attachment':s.controller.pickedAttachments.add(PlatformFile(name:'human',size:1,path:'/human/new'));break;
 case 'reply':s.controller.replyToMessage=humanReply;break;
 case 'cursor':s.onText(false);break;
 case 'disposed':s.mounted=false;break;
 }
 File.existsGate.complete(true);await restoring;
 final changed=['text','subject','attachment','reply','disposed'].contains(event);
 final expectedAttachments=event=='attachment'?1:changed?0:1;
 if(s.controller.pickedAttachments.length!=expectedAttachments)throw StateError('$event stale attachment restore');
 if(event=='attachment'&&s.controller.pickedAttachments.single.path!='/human/new')throw StateError('human attachment replaced');
 if(event=='reply'&&!identical(s.controller.replyToMessage,humanReply))throw StateError('human reply overwritten');
 if(changed&&s._retainedLogicalReplyIntent!=null)throw StateError('$event stale reply restored');
 if(event=='text'&&s.controller.textController.text!='new human text')throw StateError('human text overwritten');
 if(event=='subject'&&s.controller.subjectTextController.text!='new human subject')throw StateError('human subject overwritten');
 if(!changed&&s._retainedLogicalReplyIntent==null)throw StateError('$event valid restore blocked');
 if(s._restoringLogicalDraft)throw StateError('suppression stuck');
 rows[event]={'generation':s._logicalUiGeneration,'stale_restore_blocked':changed,'human_state_preserved':true,'suppression_released':true};
 }
 print(jsonEncode({'method_origin':'verbatim getDrafts/getAttachmentDrafts plus production generation-listener prefixes','fake_boundaries':'controller/IO/model bindings','scenarios':rows,'real_provider_calls':0}));
}
