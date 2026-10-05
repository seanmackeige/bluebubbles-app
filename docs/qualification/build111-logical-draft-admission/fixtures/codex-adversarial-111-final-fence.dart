import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft.dart';
import '../../../../lib/services/ui/chat/logical_draft_intent_guard.dart';
class Service {LogicalAuthorityRevision? currentLogicalAuthorityRevision;}
class Scenario {
 Scenario(this._authorityBefore,LogicalDraft d,LogicalAuthorityRevision? current){ChatsSvc.currentLogicalAuthorityRevision=current;intentGuard=LogicalDraftIntentGuard(frozenDraft:d,authorityAtFreeze:_authorityBefore,validateCurrent:()=>null,composerIsCurrent:()=>true,record:(_,__){},validateAuthority:validate);}
 final ChatsSvc=Service();final LogicalAuthorityRevision? _authorityBefore;late final LogicalDraftIntentGuard intentGuard;
 String? validate(){final authorityBefore=_authorityBefore;String? actualClosure() {
              final expected = intentGuard.effectiveDraft!;
              final revision = ChatsSvc.currentLogicalAuthorityRevision;
              if (revision?.certificateRevision != expected.observedCertificateRevision) {
                return 'CERTIFICATE_CHANGED';
              }
              if (revision?.authorityRevision != expected.observedAuthorityRevision ||
                  revision?.epoch != expected.observedAuthorityEpoch ||
                  (authorityBefore != null &&
                      (revision?.certificateRevision != authorityBefore.certificateRevision ||
                          revision?.authorityRevision != authorityBefore.authorityRevision ||
                          revision?.epoch != authorityBefore.epoch))) {
                return 'AUTHORITY_CHANGED';
              }
              return null;
            } return actualClosure();}

}
const old=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:1);
const fresh=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:2);
void main(){final result=<String,Object?>{};final draft=LogicalDraft.create(logicalId:'L',nowEpochMilliseconds:1,observedRevision:old);
for(final name in ['stale before refresh','aligned stable','late epoch ABA','late authority','late certificate','late null','already current hides anchor drift','closed owner']){
 final initial=name=='already current hides anchor drift'?draft.rearm(fresh,updatedAtEpochMilliseconds:2):draft;final s=Scenario(name=='already current hides anchor drift'?old:fresh,initial,fresh);
 if(name!='stale before refresh'&&name!='already current hides anchor drift')s.intentGuard.acceptAuthorityRefresh(draft.rearm(fresh,updatedAtEpochMilliseconds:2),fresh);
 switch(name){case 'late epoch ABA':s.ChatsSvc.currentLogicalAuthorityRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'A',epoch:4);case 'late authority':s.ChatsSvc.currentLogicalAuthorityRevision=LogicalAuthorityRevision(certificateRevision:'C',authorityRevision:'B',epoch:3);case 'late certificate':s.ChatsSvc.currentLogicalAuthorityRevision=LogicalAuthorityRevision(certificateRevision:'D',authorityRevision:'A',epoch:3);case 'late null':s.ChatsSvc.currentLogicalAuthorityRevision=null;case 'closed owner':s.intentGuard.close();}
 String verdict='PASS';try{s.intentGuard.validateBeforeTransport();}on LogicalDraftIntentException catch(e){verdict=e.reason;}
 if((verdict=='PASS')!=(name=='aligned stable'))throw StateError('$name $verdict');result[name]=verdict;
}
print(jsonEncode({'method':'verbatim final composer validateAuthority closure plus actual guard/model','cases':result,'real_provider_calls':0}));}
