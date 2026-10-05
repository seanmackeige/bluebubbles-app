import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft.dart';
class FakeSvc {int generation=0;LogicalDraft? current;int logicalDraftGenerationFor(Object chat)=>generation;LogicalDraft? loadLogicalDraft(Object chat)=>current;}
final ChatsSvc=FakeSvc();
LogicalDraft draft({String id='logical',String text='text',String subject='subject',int created=1,int revision=0,int updated=1,List<LogicalAttachmentIntent>? attachments,String? effect,LogicalReplyIntent? reply}) => LogicalDraft(logicalId:id,text:text,subject:subject,attachments:attachments??[],contentRevision:revision,createdAtEpochMilliseconds:created,updatedAtEpochMilliseconds:updated,effectId:effect,reply:reply);
class Scenario {final chat=Object();final generationBefore=0;final logicalDraft=draft();String? change;String? composerChange()=>change;
String? check() {
              final change = composerChange();
              if (change != null) return change;
              if (ChatsSvc.logicalDraftGenerationFor(chat) != generationBefore) return 'GENERATION_CHANGED_EXTERNAL';
              final current = ChatsSvc.loadLogicalDraft(chat);
              if (current == null) return 'DRAFT_DISAPPEARED';
              if (current.logicalId != logicalDraft.logicalId ||
                  current.createdAtEpochMilliseconds != logicalDraft.createdAtEpochMilliseconds) {
                return 'DRAFT_IDENTITY_CHANGED';
              }
              if (logicalActionIdentity('attachments', current.attachments.map((item) => item.toJson())) !=
                  logicalActionIdentity('attachments', logicalDraft.attachments.map((item) => item.toJson()))) {
                return 'ATTACHMENT_INTENT_CHANGED';
              }
              if (current.contentFingerprint != logicalDraft.contentFingerprint) return 'CONTENT_CHANGED';
              if (current.actionId != logicalDraft.actionId) return 'DRAFT_IDENTITY_CHANGED';
              return null;
            }
}
void main(){
 final results=<String,String?>{};
 void check(String name,void Function(Scenario) mutate,String? expected){ChatsSvc.generation=0;ChatsSvc.current=draft();final s=Scenario();mutate(s);final actual=s.check();if(actual!=expected)throw StateError('$name: $actual != $expected');results[name]=actual;}
 check('unchanged',(_){},null);
 check('updated metadata only',(_)=>ChatsSvc.current=draft(updated:2),null);
 check('content and derived action changed',(_)=>ChatsSvc.current=draft(text:'new'),'CONTENT_CHANGED');
 check('subject',(_)=>ChatsSvc.current=draft(subject:'new'),'CONTENT_CHANGED');
 check('effect',(_)=>ChatsSvc.current=draft(effect:'effect'),'CONTENT_CHANGED');
 check('attachment and derived action changed',(_)=>ChatsSvc.current=draft(attachments:[const LogicalAttachmentIntent(intentId:'A',name:'A',size:1,isRestorable:false)]),'ATTACHMENT_INTENT_CHANGED');
 check('immutable creation identity',(_)=>ChatsSvc.current=draft(created:2),'DRAFT_IDENTITY_CHANGED');
 check('logical owner',(_)=>ChatsSvc.current=draft(id:'other'),'DRAFT_IDENTITY_CHANGED');
 check('revision without content',(_)=>ChatsSvc.current=draft(revision:1),'DRAFT_IDENTITY_CHANGED');
 check('external generation',(_)=>ChatsSvc.generation=1,'GENERATION_CHANGED_EXTERNAL');
 check('disappeared',(_)=>ChatsSvc.current=null,'DRAFT_DISAPPEARED');
 check('live owner takes priority',(s)=>s.change='OWNER_CHANGED','OWNER_CHANGED');
 print(jsonEncode({'method':'verbatim validateCurrent closure','real_model':'LogicalDraft','fake_boundaries':'service snapshot and composer reason','cases':results,'real_provider_calls':0}));
}
