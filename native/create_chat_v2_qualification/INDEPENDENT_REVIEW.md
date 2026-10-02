# Independent CREATE_CHAT_V2 native review

Verdict: `NATIVE_V2_PROVIDER_BLOCKED_EXPLICIT_SENDER_BINDING`

The independent review confirms that the current branch must fail closed:

1. Legacy `sender:nil` remains unchanged; V2 dispatch is absent.
2. No V2 resolver can fall back globally because no provider implementation
   exists, but exact-account fallback prevention is unproven rather than solved.
3. Vetted-alias membership does not prove unique sibling selection.
4. No helper-to-daemon compare-and-dispatch primitive closes the sender-route
   race.
5. No native provider journal rejects duplicate operation IDs.
6. No native restart durability exists.
7. Old/new helper/server skew is safe only because V2 is unreachable.
8. Apple-success/provider-failure correlation is unimplemented.
9. Ambiguous replay is blocked in the retained client model only.
10. Official BlueBubbles source/runtime is unchanged; future extension
    compatibility remains unproven.
11. Build 99 Comcast paths are unchanged and the full regression passed.
12. Neither probe nor harness crossed the creator, send, or database boundary.

The review also verified the privacy correction: the probe emits count-only
account evidence with no raw or hashed stable provider identities.

The native Boolean gate is a policy harness, not a provider implementation.
Its synthetic successful row establishes only that every required proof must be
present before capability publication. The actual Sonoma evidence does not
satisfy that row.

Last proven zero-mutation step: framework load and selector/ABI inspection.

First conservatively possible Apple mutation:
`chatForIMHandles:lastAddressedHandle:lastAddressedSIMID:`.

Exact Apple persistence point: `UNKNOWN`, because the creator was correctly
not invoked.
