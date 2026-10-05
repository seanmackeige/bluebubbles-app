import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft.dart';
import '../../../../lib/services/ui/chat/logical_draft_admission_probe.dart';
const current=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:2);
const old=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:1);
const changed=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'B',epoch:3);
LogicalDraft make({bool empty=false,LogicalAuthorityRevision? authority=old,bool attachment=false})=>LogicalDraft.create(logicalId:'fixture',nowEpochMilliseconds:1,observedRevision:authority).mergeUserIntent(text:empty?'':'PRIVATE_SENTINEL_TEXT',subject:'',attachments:attachment?[const LogicalAttachmentIntent(intentId:'fixture',name:'PRIVATE_SENTINEL_NAME',size:100000000,isRestorable:false)]:[],reply:null,effectId:null,updatedAtEpochMilliseconds:2);
void main(){
 final results=<String,Object?>{};
 final samples=<String,({LogicalDraft? draft,LogicalAuthorityRevision? live,bool coherent})>{
 'no draft':(draft:null,live:current,coherent:true),
 'empty current':(draft:make(empty:true,authority:current),live:current,coherent:true),
 'empty old epoch':(draft:make(empty:true),live:current,coherent:true),
 'empty material changed':(draft:make(empty:true),live:changed,coherent:true),
 'empty no observed proof':(draft:make(empty:true,authority:null),live:current,coherent:true),
 'nonempty current':(draft:make(authority:current),live:current,coherent:true),
 'nonempty old epoch':(draft:make(),live:current,coherent:true),
 'nonempty material changed':(draft:make(),live:changed,coherent:true),
 'live missing':(draft:make(),live:null,coherent:true),
 'storage conflict':(draft:null,live:current,coherent:false),
 'large attachment metadata':(draft:make(attachment:true),live:current,coherent:true),
 };
 final timer=Stopwatch()..start();
 for(final entry in samples.entries){final v=entry.value;final before=v.draft?.toJson();final report=logicalDraftAdmissionProbe(draft:v.draft,authority:v.live,generation:7,storageCoherent:v.coherent);final encoded=jsonEncode(report);
 if(report['policyChecksPass']!=true)throw StateError('policy failed');
 for(final key in ['freshProviderObservationExercised','persistenceExercised','reservationExercised','transportExercised']){if(report[key]!=false)throw StateError('overclaim $key');}
 if(encoded.contains('PRIVATE_SENTINEL'))throw StateError('raw content leak');if(jsonEncode(before)!=jsonEncode(v.draft?.toJson()))throw StateError('draft mutated');
 if(entry.key=='nonempty material changed'&&report['localAlignment']!='authorityChanged')throw StateError('drift concealed');if(entry.key=='storage conflict'&&report['storageCoherent']!=false)throw StateError('conflict concealed');
 results[entry.key]={'policyChecksPass':report['policyChecksPass'],'localAlignment':report['localAlignment'],'emptyIntent':report['emptyIntent'],'nextNonemptyIntentUsesCurrentAuthority':report['nextNonemptyIntentUsesCurrentAuthority'],'rawContentAbsent':true,'inputUnchanged':true};
 }
 timer.stop();print(jsonEncode({'source':'imports actual logicalDraftAdmissionProbe','cases':results,'elapsed_ms':timer.elapsedMilliseconds,'large_attachment_declared_bytes':100000000,'byte_payload_exists':false,'real_provider_calls':0}));
}
