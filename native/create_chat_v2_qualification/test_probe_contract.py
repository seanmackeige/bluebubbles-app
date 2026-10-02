from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parent
SOURCE = (ROOT / "BBPrivateFrameworkProbe.m").read_text(encoding="utf-8")


class PrivateFrameworkProbeContractTest(unittest.TestCase):
    def test_probe_has_no_chat_creator_invocation(self):
        self.assertIn('BBMethodEvidence(@"IMChatRegistry", @"chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:"', SOURCE)
        self.assertNotRegex(SOURCE, r'BBInvokeObject\d\([^\n]+chatForIMHandles')

    def test_probe_has_no_send_invocation(self):
        self.assertIn('BBMethodEvidence(@"IMChat", @"_sendMessage:withAccount:adjustingSender:shouldQueue:"', SOURCE)
        self.assertNotRegex(SOURCE, r'BBInvokeObject\d\([^\n]+_sendMessage')
        self.assertNotRegex(SOURCE, r'performSelector[^\n]+send')

    def test_probe_emits_no_raw_provider_identity(self):
        self.assertIn('@"raw_identity_values_emitted": @NO', SOURCE)
        self.assertNotIn('@"unique_id":', SOURCE)
        self.assertNotIn('@"active_route":', SOURCE)
        self.assertNotIn("fingerprint", SOURCE.casefold())

    def test_only_read_only_account_methods_are_invoked(self):
        calls = set(re.findall(r'BBInvoke(?:Object|Bool)\d\([^,]+, @"([^"]+)"', SOURCE))
        self.assertEqual(
            calls,
            {
                "sharedInstance",
                "accounts",
                "serviceName",
                "canSendMessages",
                "_isUsableForSending",
                "vettedAliases",
                "displayName",
                "service",
                "imHandleWithID:",
                "account",
            },
        )


if __name__ == "__main__":
    unittest.main()
