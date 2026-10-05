import 'dart:async';
import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft_intent_guard.dart';
class Text {Text(this.text);String text;void clear()=>text='';}
class Value {Object? value='date';}
class Controller {final textController=Text('frozen');final subjectTextController=Text('subject');final pickedAttachments=<String>['A'];Object? replyToMessage='reply';final scheduledDate=Value();}
class TimerStub {bool cancelled=false;void cancel()=>cancelled=true;}
class Local {TimerStub? debounceDraftSave=TimerStub();Object? debounceTyping=Object();}
class FakeSvc {Completer<bool>? pending;Future<bool> clearLogicalDraftIfCurrent(Object? draft){pending=Completer<bool>();return pending!.future;}}
final ChatsSvc=FakeSvc();
class Scenario {
 Scenario(){owner=controller;_activeIntentGuard=LogicalDraftIntentGuard(validateCurrent:()=>null,record:(s,b){records.add(s);},composerIsCurrent:()=>composerChange()==null);_activeIntentGuard!.requestStarted();}
 final records=<String>[];Controller controller=Controller();late final Controller owner;final localController=Local();bool mounted=true;Object? logicalDraft=Object();bool _logicalDraftConsumed=false;int _logicalIntentEpoch=0;final intentEpoch=0;LogicalDraftIntentGuard? _activeIntentGuard;int saves=0;Map<String,Object?>? saved;
 String? composerChange()=>!mounted||!identical(controller,owner)?'OWNER_CHANGED':controller.textController.text!='frozen'||controller.subjectTextController.text!='subject'||controller.replyToMessage!='reply'||controller.pickedAttachments.join(',')!='A'?'CONTENT_CHANGED':null;
 Future<void> _saveLogicalDraft() async{saves++;saved={'text':controller.textController.text,'subject':controller.subjectTextController.text,'attachments':controller.pickedAttachments.toList(),'reply':controller.replyToMessage};}
 Future<void> finish() async {
        if (logicalDraft != null && !_logicalDraftConsumed) {
          if (_logicalIntentEpoch != intentEpoch) {
            await _saveLogicalDraft();
            return;
          }
          final cleared = await ChatsSvc.clearLogicalDraftIfCurrent(logicalDraft);
          if (!cleared) return;
          _activeIntentGuard?.draftConsumed();
          if (composerChange() != null) {
            _logicalDraftConsumed = false;
            if (mounted) await _saveLogicalDraft();
            return;
          }
          _logicalDraftConsumed = true;
          localController.debounceDraftSave?.cancel();
        }
      controller.pickedAttachments.clear();
      controller.textController.clear();
      controller.subjectTextController.clear();
      controller.replyToMessage = null;
      controller.scheduledDate.value = null;
      localController.debounceTyping = null;

 }
}
Future<void> main()async{
 final results=<String,Object?>{};
 Future<void> check(String name,void Function(Scenario) mutate,{bool cleared=true,bool changed=true})async{
  ChatsSvc.pending=null;final s=Scenario();final f=s.finish();if(ChatsSvc.pending==null)throw StateError('clear did not suspend');mutate(s);ChatsSvc.pending!.complete(cleared);await f;
  final shouldSave=cleared&&changed&&s.mounted;
  if(s.saves!=(shouldSave?1:0))throw StateError('$name save mismatch');
  if(s._activeIntentGuard!.draftWasConsumed!=cleared)throw StateError('$name consume marker mismatch');
  if(changed&&s.controller.textController.text.isEmpty)throw StateError('$name human text erased');
  if(!changed&&cleared&&s.controller.textController.text.isNotEmpty)throw StateError('$name old text not cleared');
  if(s._logicalDraftConsumed != (cleared&&!changed))throw StateError('$name UI consumed mismatch');
  results[name]={'savedNewIntent':s.saves,'uiConsumed':s._logicalDraftConsumed,'exactConsumptionRecorded':s._activeIntentGuard!.draftWasConsumed,'preserved':changed||!cleared};
 }
 await check('unchanged',(_){},changed:false);
 await check('text during clear',(s)=>s.controller.textController.text='human');
 await check('subject during clear',(s)=>s.controller.subjectTextController.text='human');
 await check('attachment during clear',(s)=>s.controller.pickedAttachments.add('B'));
 await check('reply during clear',(s)=>s.controller.replyToMessage='newreply');
 await check('owner replacement during clear',(s)=>s.controller=Controller());
 await check('disposed during clear',(s)=>s.mounted=false);
 await check('clear declined',(_){},cleared:false,changed:false);
 await check('clear declined with human edit',(s)=>s.controller.textController.text='human',cleared:false);
 print(jsonEncode({'method':'verbatim composer fallback clear and subsequent UI clear statements','fake_boundaries':'controller/service delayed clear; composer reason already independently source tested','cases':results,'real_provider_calls':0}));
}
