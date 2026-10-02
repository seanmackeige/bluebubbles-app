#!/usr/bin/env python3
"""Build and execute the no-Apple-call native V2 provider gate on the Mac."""

from __future__ import annotations

import base64
import sys
from pathlib import Path


HERE = Path(__file__).resolve().parent
SENTINEL = Path("/home/sean/projects/mac-messaging-sentinel")
sys.path.insert(0, str(SENTINEL / "src"))

from mac_messaging_sentinel.collector import SSHClient  # noqa: E402
from mac_messaging_sentinel.config import load_config  # noqa: E402


source = base64.b64encode((HERE / "BBCreateChatV2Qualification.m").read_bytes()).decode("ascii")
remote = f"""set -euo pipefail
gate_root=$(/usr/bin/mktemp -d /tmp/sean-create-chat-v2-native-gate.XXXXXX)
cleanup() {{
  case "$gate_root" in
    /tmp/sean-create-chat-v2-native-gate.*) /bin/rm -rf "$gate_root" ;;
    *) exit 97 ;;
  esac
}}
trap cleanup EXIT
/usr/bin/base64 -D > "$gate_root/BBCreateChatV2Qualification.m" <<'SOURCE_EOF'
{source}
SOURCE_EOF
/usr/bin/xcrun clang -arch x86_64 -fobjc-arc -fmodules -framework Foundation \
  "$gate_root/BBCreateChatV2Qualification.m" -o "$gate_root/BBCreateChatV2Qualification"
/usr/bin/file "$gate_root/BBCreateChatV2Qualification"
/usr/bin/shasum -a 256 "$gate_root/BBCreateChatV2Qualification"
"$gate_root/BBCreateChatV2Qualification"
"""

client = SSHClient(load_config(SENTINEL / "config.local.json"))
print(client.run_script(remote, timeout=60), end="")
