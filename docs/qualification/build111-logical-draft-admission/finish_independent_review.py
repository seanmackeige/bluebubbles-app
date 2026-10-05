"""Run ONLY independent offline review fixtures; never build/install/send.

Run on ai-worker after the remote tool's authentication issue is resolved or
through the parent review agent's independently functioning authorized tool.
Writes are confined to reviewer scratch /tmp/codex-adversarial-111-* and the
explicitly authorized docs/qualification/build111-logical-draft-admission tree.
"""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path('/home/sean/projects/android/bluebubbles/admission-correction')
DOCS = ROOT / 'docs/qualification/build111-logical-draft-admission'
DART = '/home/sean/dev/flutter/bin/cache/dart-sdk/bin/dart'
PREFIX = 'codex-adversarial-111-'

# Refresh the verbatim production branch. No copied implementation is edited.
handler = (ROOT / 'lib/services/backend/outgoing_message_handler.dart').read_text()
start = '    if (_currentLogicalProviderContextFingerprint() != providerContextAtObservationStart) {'
a = handler.index(start)
b = handler.index('    // Freeze transport capability', a)
branch = handler[a:b]
assert 'CAS merely prepares the unchanged intent' in branch
for stem, end in [('cas-handler-consume', '\n }}'), ('matches-fast-path', '\n}}')]:
    path = Path('/tmp') / f'{PREFIX}{stem}.dart'
    source = path.read_text()
    a = source.index(start)
    b = source.index(end, a)
    path.write_text(source[:a] + branch + source[b:])

path = Path('/tmp') / f'{PREFIX}cas-handler-consume.dart'
source = path.read_text()
needle = '\n const priorDifferent=LogicalAuthorityRevision'
extra = r'''
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
'''
marker = ' // Independent final optional-CAS-before-unconditional-pause transition cases.'
if marker not in source:
    assert needle in source
    source = source.replace(needle, '\n' + extra + needle, 1)
    path.write_text(source)

fixtures = ['cas-handler-consume', 'matches-fast-path', 'final-fence', 'probe-fixture', 'probe-boundary']
(DOCS / 'fixtures').mkdir(parents=True, exist_ok=True)
results = {}
for stem in fixtures:
    path = Path('/tmp') / f'{PREFIX}{stem}.dart'
    command = [DART, '--packages=' + str(ROOT / '.dart_tool/package_config.json'), str(path)]
    run = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=120)
    if run.returncode:
        print(json.dumps({'fixture': stem, 'exitCode': run.returncode, 'stdout': run.stdout, 'stderr': run.stderr}))
        raise SystemExit(run.returncode)
    parsed = json.loads(run.stdout)
    if stem == 'matches-fast-path':
        # This fixture reports its actual outcomes; require both negative controls.
        rendered = json.dumps(parsed)
        assert rendered.count('SEND_BLOCKED_AUTHORITY_CHANGED_DURING_FREEZE') == 2, rendered
        assert rendered.count('"metadata_writes": 0') == 2, rendered
    output = DOCS / 'fixtures' / f'{PREFIX}{stem}-result.json'
    output.write_text(json.dumps(parsed, indent=2) + '\n')
    portable = path.read_text().replace(str(ROOT) + '/lib/', '../../../../lib/')
    (DOCS / 'fixtures' / path.name).write_text(portable)
    results[stem] = {'status': 'PASS', 'result': str(output.relative_to(DOCS))}

paths = [
 'lib/services/ui/chat/logical_draft.dart',
 'lib/services/ui/chat/logical_draft_storage.dart',
 'lib/services/ui/chat/logical_conversation_identity.dart',
 'lib/services/ui/chat/logical_draft_authority_alignment.dart',
 'lib/services/ui/chat/logical_draft_intent_guard.dart',
 'lib/services/ui/chat/logical_draft_admission_probe.dart',
 'lib/services/ui/chat/chats_service.dart',
 'lib/services/ui/chat/conversation_view_controller.dart',
 'lib/services/backend/outgoing_message_handler.dart',
 'lib/app/layouts/conversation_view/widgets/text_field/conversation_text_field.dart',
 'lib/app/layouts/conversation_details/widgets/logical_conversation_health_card.dart',
 'test/logical_draft_authority_alignment_test.dart',
 'android/app/build.gradle',
 'android/tooling/verify_native_plugin_package.py',
]
for name in ('message_api.dart', 'send_message_actions.dart'):
    paths.extend(str(p.relative_to(ROOT)) for p in (ROOT / 'lib').rglob(name))
source_hashes = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sorted(set(paths))}
fixture_hashes = {str(p.relative_to(DOCS)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((DOCS / 'fixtures').glob(PREFIX + '*.dart'))}
manifest = {
 'scope': 'independent offline source-linked fixtures; no APK, device, provider, receipt, queue, or HTTP execution',
 'headAtReview': subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', 'HEAD'], text=True).strip(),
 'sourceSha256': source_hashes,
 'fixtureSha256': fixture_hashes,
 'fixtureResults': results,
 'currentSourceCaseCounts': {'casHandlerConsume': 46, 'fastPath': 2, 'finalFence': 8, 'pureProbe': 11, 'probeBoundary': 4, 'total': 71},
 'historicalCases': {'count': 95, 'scope': 'rerun preserved historical fixture bodies against compatible current imports; not all bodies newly extracted for 111'},
}
(DOCS / 'independent-review-source-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps({'status': 'PASS', 'currentSourceCases': 71, 'sourceFilesHashed': len(source_hashes), 'fixtureResults': results, 'manifest': str(DOCS / 'independent-review-source-manifest.json')}, indent=2))
