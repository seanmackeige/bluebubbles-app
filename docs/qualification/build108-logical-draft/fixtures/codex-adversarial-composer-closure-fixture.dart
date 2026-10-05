import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft.dart';
class FakeFile {
 FakeFile(this.name,this.size,this.path,{this.balloonBundleId});
 final String name;final int size;String? path;final String? balloonBundleId;
 Object get bytes=>throw StateError('forbidden byte scan');
}
class Text {Text(this.text);String text;}
class Reply {Reply(this.id);final String id;Map<String,Object> toJson()=>{'id':id};}
class Controller {final textController=Text('frozen text');final subjectTextController=Text('frozen subject');final pickedAttachments=<FakeFile>[];Reply? reply=Reply('frozen reply');}
class Chat {String key='logical.owner';int physicalMember=2156;}
class FakeChats {String conversationKeyFor(Chat c)=>c.key;}
final ChatsSvc=FakeChats();
class Scenario {
 Scenario(){
 controller.pickedAttachments.addAll([FakeFile('A',100000000,'/source/A'),FakeFile('B',2,'/source/B')]);
 ownerController=controller;selectedAtFreeze=controller.pickedAttachments.toList();originalPaths=selectedAtFreeze.map((f)=>f.path).toList();
 attachments=selectedAtFreeze.map((f)=>FakeFile(f.name,f.size,f.path,balloonBundleId:f.balloonBundleId)).toList();
 }
 bool mounted=true;Controller controller=Controller();final chat=Chat();
 final text='frozen text';final subject='frozen subject';final logicalOwner='logical.owner';
 late final Controller ownerController;late final List<FakeFile> selectedAtFreeze;late final List<String?> originalPaths;late final List<FakeFile> attachments;
 final replyFingerprint=logicalActionIdentity('reply',<Object?>[{'id':'frozen reply'}]);
 Reply? _logicalReplyIntent()=>controller.reply;
  String? composerChange() {
        if (!mounted || !identical(controller, ownerController)) return 'OWNER_CHANGED';
        if (ChatsSvc.conversationKeyFor(chat) != logicalOwner) return 'DRAFT_IDENTITY_CHANGED';
        if (controller.textController.text != text || controller.subjectTextController.text != subject) {
          return 'CONTENT_CHANGED';
        }
        if (logicalActionIdentity('reply', <Object?>[_logicalReplyIntent()?.toJson()]) != replyFingerprint) {
          return 'CONTENT_CHANGED';
        }
        final current = controller.pickedAttachments;
        if (current.length != attachments.length) return 'ATTACHMENT_INTENT_CHANGED';
        for (var index = 0; index < current.length; index++) {
          final selected = current[index];
          final frozen = attachments[index];
          if (selected.name != frozen.name ||
              selected.size != frozen.size ||
              selected.balloonBundleId != frozen.balloonBundleId ||
              !identical(selected, selectedAtFreeze[index]))
            return 'ATTACHMENT_INTENT_CHANGED';
          final stagedInternally = identical(selected, selectedAtFreeze[index]) && selected.path == frozen.path;
          if (selected.path != originalPaths[index] && !stagedInternally) return 'ATTACHMENT_INTENT_CHANGED';
        }
        return null;
      }
}
Future<void> main() async {
 final tests=<String,String?>{};
 void check(String label,void Function(Scenario) mutation,String? expected){final x=Scenario();mutation(x);final actual=x.composerChange();if(actual!=expected)throw StateError('$label expected $expected got $actual');tests[label]=actual;}
 check('unchanged',(_){},null);
 check('text',(s)=>s.controller.textController.text='new','CONTENT_CHANGED');
 check('subject',(s)=>s.controller.subjectTextController.text='new','CONTENT_CHANGED');
 check('reply',(s)=>s.controller.reply=Reply('new'),'CONTENT_CHANGED');
 check('owner replaced',(s)=>s.controller=Controller(),'OWNER_CHANGED');
 check('owner unmounted',(s)=>s.mounted=false,'OWNER_CHANGED');
 check('logical identity changed',(s)=>s.chat.key='other','DRAFT_IDENTITY_CHANGED');
 check('same logical physical member rebind',(s)=>s.chat.physicalMember=2155,null);
 check('exact staged path normalization',(s){s.attachments[0].path='/staged/exact-A';s.controller.pickedAttachments[0].path='/staged/exact-A';},null);
 check('different staged path blocked',(s){s.attachments[0].path='/staged/exact-A';s.controller.pickedAttachments[0].path='/staged/different';},'ATTACHMENT_INTENT_CHANGED');
 check('same metadata replacement',(s){final f=s.controller.pickedAttachments[0];s.controller.pickedAttachments[0]=FakeFile(f.name,f.size,f.path);},'ATTACHMENT_INTENT_CHANGED');
 check('reorder',(s){final f=s.controller.pickedAttachments.removeAt(0);s.controller.pickedAttachments.add(f);},'ATTACHMENT_INTENT_CHANGED');
 check('remove',(s)=>s.controller.pickedAttachments.removeLast(),'ATTACHMENT_INTENT_CHANGED');
 final large=Scenario();final timer=Stopwatch()..start();for(var i=0;i<10000;i++){if(large.composerChange()!=null)throw StateError('large failed');}timer.stop();
 print(jsonEncode({'method':'verbatim composerChange closure','fake_boundaries':'controller/selection descriptors only','cases':tests,'huge_attachment_declared_bytes':100000000,'byte_access':'throws if touched; no access occurred','repeated_checks':10000,'elapsed_ms':timer.elapsedMilliseconds,'real_provider_calls':0}));
}
