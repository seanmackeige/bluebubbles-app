import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import '../../../../lib/services/ui/chat/logical_draft_intent_guard.dart';
class OutgoingQueueItem {
 OutgoingQueueItem(this.id,this.logicalIntentGuard):chat='chat-$id';
 final String id;final String chat;final LogicalDraftIntentGuard logicalIntentGuard;
 final logicalDispatchReservationCompleter=Completer<void>();
 final completer=Completer<void>();
}
class Entry {Entry(this.item);final OutgoingQueueItem item;}
class Pending {Set<String> values={};void assignAll(Iterable<String> v){values=v.toSet();}}
class Runner {
 final _queue=Queue<Entry>();final pendingChatGuids=Pending();final ledger=<String>{};final prepared=<String>{};final events=<String>[];
 String failure='none';String failId='0';int physicalRequests=0;
 String _conversationKey(String chat)=>chat;
 Future<void> _rollbackPreparedBeforeProviderDispatch(OutgoingQueueItem item,{bool strict=false}) async {
  events.add('cleanup:${item.id}:strict=$strict');
  if(!strict)throw StateError('missing strict flag');
  if(failure=='delete'&&item.id==failId)throw StateError('fake delete failure');
  prepared.remove(item.id);
  await Future<void>.delayed(Duration.zero);
  if(failure=='latest'&&item.id==failId)throw StateError('fake latest restoration failure');
 }
 Future<void> _rollbackLogicalAdmissionBeforeDispatchBatch(Iterable<OutgoingQueueItem> items) async {
  events.add('ledger rollback');
  if(failure=='ledger')throw StateError('fake ledger persistence failure');
  ledger.removeAll(items.map((x)=>x.id));
 }
  Future<void> _abortUnstartedLogicalIntentBatch(OutgoingQueueItem item,
      LogicalDraftIntentGuard guard, Object error, StackTrace stack) async {
    final untouched = <OutgoingQueueItem>[
      item,
      ..._queue.where((entry) => identical(entry.item.logicalIntentGuard, guard)).map((entry) => entry.item),
    ];
    _queue.removeWhere((entry) => identical(entry.item.logicalIntentGuard, guard));
    Object outcome = error;
    try {
      for (final pending in untouched) {
        await _rollbackPreparedBeforeProviderDispatch(pending, strict: true);
      }
      // Retain durable replay custody if any prepared-message cleanup fails.
      await _rollbackLogicalAdmissionBeforeDispatchBatch(untouched);
    } catch (_) {
      outcome = StateError('LOGICAL_DRAFT_CLEANUP_UNVERIFIED');
    } finally {
      for (final pending in untouched) {
        final reservation = pending.logicalDispatchReservationCompleter;
        if (reservation != null && !reservation.isCompleted) reservation.completeError(outcome, stack);
        final completer = pending.completer;
        if (completer != null && !completer.isCompleted) completer.completeError(outcome, stack);
      }
      pendingChatGuids.assignAll(_queue.map((entry) => _conversationKey(entry.item.chat)).toSet());
    }
  }
}
void ensure(bool value,String note){if(!value)throw StateError(note);}
LogicalDraftIntentGuard guard()=>LogicalDraftIntentGuard(validateCurrent:()=>null,composerIsCurrent:()=>true,record:(_,__){});
Future<Map<String,Object>> scenario(int count,String failure,bool alreadyReserved) async {
 final run=Runner()..failure=failure..failId='${count-1}';
 final sameGuard=guard();final otherGuard=guard();
 final items=List.generate(count,(i)=>OutgoingQueueItem('$i',sameGuard));
 final foreign=OutgoingQueueItem('foreign',otherGuard);
 final outcomes=<String,String>{};final waits=<Future<void>>[];
 for(final item in items){
  run.ledger.add(item.id);run.prepared.add(item.id);
  for(final pair in {'reservation':item.logicalDispatchReservationCompleter,'completion':item.completer}.entries){
   // Production attaches immediate error observers before admission/processing.
   unawaited(pair.value.future.catchError((Object _){}));
   waits.add(pair.value.future.then((_) {outcomes['${item.id}:${pair.key}']='success';},onError:(Object e){outcomes['${item.id}:${pair.key}']=e.toString();}));
  }
 }
 if(alreadyReserved)items.first.logicalDispatchReservationCompleter.complete();
 for(final item in items.skip(1)){run._queue.add(Entry(item));}
 run._queue.add(Entry(foreign));
 await run._abortUnstartedLogicalIntentBatch(items.first,sameGuard,const LogicalDraftIntentException('CONTENT_CHANGED'),StackTrace.current);
 await Future.wait(waits).timeout(Duration(seconds:1));
 await Future<void>.delayed(Duration.zero);
 ensure(outcomes.length==count*2,'unsettled outcomes');
 ensure(items.every((x)=>x.completer.isCompleted&&x.logicalDispatchReservationCompleter.isCompleted),'unsettled futures');
 ensure(run._queue.length==1&&identical(run._queue.single.item,foreign),'foreign queue lost');
 ensure(run.pendingChatGuids.values.single=='chat-foreign','pending recompute failed');
 ensure(!foreign.completer.isCompleted&&!foreign.logicalDispatchReservationCompleter.isCompleted,'unrelated future settled');
 if(failure=='none'){
  ensure(run.ledger.isEmpty&&run.prepared.isEmpty,'successful abort retained state');
  ensure(outcomes.values.every((x)=>x=='success'||x.contains('CONTENT_CHANGED')),'wrong rejection');
  ensure(run.events.last=='ledger rollback','ledger released before cleanup');
  // Exact same action ids can now be admitted by a fresh explicit operation.
  ensure(items.every((x)=>!run.ledger.contains(x.id)),'next reviewed operation poisoned');
 }else{
  ensure(run.ledger.length==count,'failed cleanup lost replay custody');
  ensure(outcomes.values.every((x)=>x=='success'||x.contains('CLEANUP_UNVERIFIED')),'failure not classified');
  if(failure!='ledger')ensure(!run.events.contains('ledger rollback'),'ledger rollback before verified cleanup');
 }
 sameGuard.close();otherGuard.close();
 return {'items':count,'failure_injection':failure,'first_already_reserved':alreadyReserved,'all_futures_settled':true,'other_operation_untouched':true,'durable_custody_expected':true,'physical_requests':run.physicalRequests};
}
Future<void> main() async {
 final unhandled=<String>[];final done=Completer<void>();final rows=<Map<String,Object>>[];
 runZonedGuarded(() async {
  try{
   for(final count in [1,3])for(final fail in ['none','delete','latest','ledger'])for(final reserved in [false,true]){rows.add(await scenario(count,fail,reserved));}
   await Future<void>.delayed(Duration.zero);done.complete();
  }catch(e,st){done.completeError(e,st);}
 },(e,st){unhandled.add(e.toString());});
 await done.future.timeout(Duration(seconds:10));
 ensure(unhandled.isEmpty,'unhandled async errors: $unhandled');
 print(jsonEncode({'method_origin':'verbatim correction _abortUnstartedLogicalIntentBatch','fake_boundaries':'queue objects, prepared cleanup callbacks, durable ledger callbacks','scenarios':rows,'unhandled_errors':unhandled,'real_provider_calls':0}));
}
