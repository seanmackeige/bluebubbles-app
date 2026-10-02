from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parent
SOURCE = (ROOT / "BBCreateChatV2Qualification.m").read_text(encoding="utf-8")


class NativeGateSourceTest(unittest.TestCase):
    def test_gate_requires_every_native_sender_condition(self):
        for field in (
            "creatorABIExact",
            "explicitRouteCaptured",
            "downstreamRoutePreserved",
            "unavailableRouteRejectsWithoutFallback",
            "providerConditionalRevision",
        ):
            self.assertIn(f"!evidence.{field}", SOURCE)

    def test_gate_has_no_apple_execution_primitive(self):
        for forbidden in (
            "chatForIMHandles",
            "_sendMessage:",
            "sendMessage:",
            "activeIMessageAccount",
            "chat.db",
        ):
            self.assertNotIn(forbidden, SOURCE)

    def test_sender_route_and_message_sender_are_not_collapsed(self):
        self.assertIn("senderRouteExact", SOURCE)
        self.assertNotIn("messageSenderExact", SOURCE)

    def test_failure_injections_cover_provider_boundary(self):
        for case in (
            "wrong account",
            "inactive account",
            "wrong sender",
            "alias mismatch",
            "service mismatch",
            "recipient mismatch",
            "provider revision drift",
            "duplicate operation",
            "old helper",
            "TOCTOU unbounded",
        ):
            self.assertIn(case, SOURCE)


if __name__ == "__main__":
    unittest.main()
