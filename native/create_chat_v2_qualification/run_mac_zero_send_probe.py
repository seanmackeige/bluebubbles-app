#!/usr/bin/env python3
"""Build and run the bounded CREATE_CHAT_V2 zero-send probe on Sean's Mac."""

from __future__ import annotations

import base64
import json
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
SENTINEL = Path("/home/sean/projects/mac-messaging-sentinel")
sys.path.insert(0, str(SENTINEL / "src"))

from mac_messaging_sentinel.collector import SSHClient  # noqa: E402
from mac_messaging_sentinel.config import load_config  # noqa: E402


def encoded(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


source = encoded((HERE / "BBPrivateFrameworkProbe.m").read_bytes())
lldb_commands = encoded(
    b"""breakpoint set --name BBV2TraceReady
process launch -- --trace
expression void *$creator = BBV2MethodIMP("IMChatRegistry", "chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:")
expression void *$dispatch = BBV2MethodIMP("IMChat", "_sendMessage:withAccount:adjustingSender:shouldQueue:")
expression void *$registry = BBV2MethodIMP("IMChatRegistry", "_chat:sendMessage:withAccount:")
disassemble --start-address $creator --count 500 --bytes
disassemble --start-address $dispatch --count 350 --bytes
disassemble --start-address $registry --count 500 --bytes
quit
"""
)

remote = f"""set -euo pipefail
probe_root=$(/usr/bin/mktemp -d /tmp/sean-create-chat-v2-zero-send.XXXXXX)
cleanup() {{
  case "$probe_root" in
    /tmp/sean-create-chat-v2-zero-send.*) /bin/rm -rf "$probe_root" ;;
    *) exit 97 ;;
  esac
}}
trap cleanup EXIT
/usr/bin/base64 -D > "$probe_root/BBPrivateFrameworkProbe.m" <<'SOURCE_EOF'
{source}
SOURCE_EOF
/usr/bin/base64 -D > "$probe_root/probe.lldb" <<'LLDB_EOF'
{lldb_commands}
LLDB_EOF
/usr/bin/xcrun clang -arch x86_64 -fobjc-arc -fmodules -framework Foundation \
  "$probe_root/BBPrivateFrameworkProbe.m" -o "$probe_root/BBPrivateFrameworkProbe"
printf '%s\n' '===BUILD==='
/usr/bin/file "$probe_root/BBPrivateFrameworkProbe"
/usr/bin/shasum -a 256 "$probe_root/BBPrivateFrameworkProbe"
printf '%s\n' '===METHODS==='
"$probe_root/BBPrivateFrameworkProbe"
printf '%s\n' '===ACCOUNTS==='
"$probe_root/BBPrivateFrameworkProbe" --enumerate-accounts
printf '%s\n' '===DISASSEMBLY==='
/usr/bin/xcrun lldb --batch --source "$probe_root/probe.lldb" "$probe_root/BBPrivateFrameworkProbe" 2>&1 || true
"""

client = SSHClient(load_config(SENTINEL / "config.local.json"))
output = client.run_script(remote, timeout=120)

# Refuse to relay an accidental raw address even though the native probe is
# designed to emit fingerprints only.
for line in output.splitlines():
    if line.startswith("{"):
        value = json.loads(line)
        if value.get("schema") == "SEAN_CREATE_CHAT_V2_ZERO_SEND_PROBE_V1":
            evidence = value.get("account_evidence")
            if isinstance(evidence, dict) and evidence.get("raw_identity_values_emitted") is not False:
                raise RuntimeError("native probe did not attest redaction")

print(output, end="")
