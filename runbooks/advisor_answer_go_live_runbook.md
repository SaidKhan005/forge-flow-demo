# Advisor Answer Endpoint: Go-Live Runbook

Operational procedure to turn on the advisor's full written-answer
endpoint, `POST /v1/advisor/answer`, in a deployed proxy.

Audience: whoever provisions secrets and deploys the advisor proxy.

Status as of this doc: the endpoint shipped in PR #1360 (Slice A4.2b)
and is live in code on `master`. It is **fail-closed**: it returns
`503` until one new secret is provisioned. Provisioning that one secret
and restarting the proxy is the entire go-live action.

---

## TL;DR

1. Generate a 256-bit key: `openssl rand -base64 32` (a 44-character
   base64 string).
2. Store it in Secret Manager and map it to the proxy as the env var
   `ADVISOR_CONVERSATION_CMK`.
3. Redeploy / restart the proxy revision.
4. Confirm the startup log shows `conversation_cmk_loaded: true`.
5. Smoke-test with one `POST /v1/advisor/answer` (expect `200`).

The Anthropic and Voyage keys are already required at boot, so a running
proxy already has them. The advisor answer endpoint is gated on this one
new optional secret only.

---

## What the endpoint does

An operator asks a question. The advisor reads the operator's own live
operating data (active targets, the locked week plan, recent shift
variance) plus the methodology corpus, then composes a
recommendation-only answer with real citations. Every turn (the question
and the answer) is encrypted in-process before it is written to
Postgres, so the database never sees plaintext. Multi-turn memory is
carried by the client as `prior_turns` (capped). The spend is metered.

Source: `tool/advisor_proxy/advisor_answer_route_group_part.dart`.

### Promises this honors

- **HP #7** (keys server-side): the Anthropic / Voyage / conversation
  keys are never logged and never appear in any response. Chat content
  is encrypted at rest (AES-256-GCM).
- **HP #4** (per-operator isolation): every data read and every stored
  turn is scoped to the caller's own operator / location / user, taken
  from the login token, never from the request body.
- **HP #6** (recommend, never command): the advisor only reads and
  advises. No write or mutation tool is exposed.
- **HP #9** (cost metered by class): the answer is billed under usage
  class `advisor_answer`; retrieval sub-spend under
  `voyage_query_embedding` and `voyage_rerank`.

---

## Prerequisites (already true on any running proxy)

These secrets are **required at boot**: the proxy refuses to start
without them (`ProxySecretNames.required`,
`tool/advisor_proxy/advisor_proxy.dart:657`). So a proxy that is serving
traffic already has them.

| Secret | Role for the advisor |
| --- | --- |
| `ANTHROPIC_API_KEY` | Drives the agentic answer (Claude, tier-routed). |
| `VOYAGE_API_KEY` | Methodology retrieval (embeddings + rerank). |
| `POSTGRES_URL` / `POSTGRES_ADMIN_URL` | Persists the encrypted conversation log. |

No action needed on these for go-live.

---

## The one new secret: `ADVISOR_CONVERSATION_CMK`

Optional secret (`ProxySecretNames.optional`,
`tool/advisor_proxy/advisor_proxy.dart:681`). It is the base64 encoding
of a **32-byte (256-bit) AES key** used to encrypt advisor conversation
turns in-process.

- Absent: the proxy still boots; the answer endpoint returns
  `503 advisor_answer_encryption_unavailable` and never calls the
  provider.
- Present and valid (decodes to exactly 32 bytes): the endpoint goes
  live.
- Present but the wrong length: the endpoint stays fail-closed with the
  same `503`; the key length is never disclosed to the client.

### 1. Generate the key

```bash
openssl rand -base64 32
```

This prints a 44-character base64 string (one `=` of padding) that
decodes to exactly 32 bytes. Capture it with no surrounding whitespace
or trailing newline.

Verify it decodes to 32 bytes before using it:

```bash
printf '%s' '<the-base64-key>' | base64 -d | wc -c   # must print 32
```

### 2. Store it in Secret Manager and map it to the proxy

This project keeps production secrets in **GCP Secret Manager** and the
proxy reads them as environment variables at startup
(`ProxyConfig.fromEnvironment(Platform.environment)`,
`tool/advisor_proxy/main.dart:159`). Region default is
`northamerica-northeast2`.

Follow the existing secret-provisioning path rather than pasting the key
on a command line (the established discipline is that the deploy reads
Secret Manager refs; secret values are never pasted into commands, see
`runbooks/audit_anchor_cloudrun_deploy_runbook.md`):

- Add a new Secret Manager secret/version holding the base64 key.
- Map it onto the advisor proxy's deployment as the env var
  **`ADVISOR_CONVERSATION_CMK`** (the secrets-sync helper used for the
  other proxy secrets is the right tool; confirm the exact service /
  helper invocation against your proxy deploy config).
- Never commit the key to git. Never echo it in a log or a shell that
  records history.

### 3. Redeploy / restart the proxy

The proxy reads env vars only at startup, so the new revision must be
rolled out (or the service restarted) for the key to take effect.

---

## Confirm it is wired (startup log)

On boot the proxy emits one JSON log event for the answer route
(`tool/advisor_proxy/main.dart:1808`):

- `startup.advisor_answer_route.provider_wired` with
  `anthropic_key_loaded: true` and **`conversation_cmk_loaded: true`**:
  the endpoint is live. This is the green light.
- `conversation_cmk_loaded: false`: the Anthropic key loaded but the CMK
  did not. Recheck the env var name and value.
- `startup.advisor_answer_route.provider_absent`: the Anthropic key is
  missing. This should not happen on a live proxy (it is required at
  boot).

The log records booleans only, never the key value (HP #7).

---

## Smoke test

After the restart, send one authenticated request:

```bash
curl -sS -i -X POST "$PROXY_BASE/v1/advisor/answer" \
  -H "Authorization: Bearer $OPERATOR_JWT" \
  -H "Content-Type: application/json" \
  -d '{"question":"How am I tracking against my labor target this week?"}'
```

Expected: `HTTP 200` with a JSON body containing `answer`, `citations`,
`conversation_id`, `turn_index`, `model_used`, `usage_class`
(`advisor_answer`), and `query_class`. The caller's `operator_id` /
`location_id` are echoed; no key field appears anywhere.

Multi-turn continuation: pass the returned `conversation_id` and a
`prior_turns` array (`[{ "role": "user" | "assistant", "content": ... }]`,
at most 20 turns, each at most 8000 chars) on the next call.

---

## Fail-closed behavior (by design)

| Condition | Result |
| --- | --- |
| `ADVISOR_CONVERSATION_CMK` absent | `503 advisor_answer_encryption_unavailable`; no provider call; proxy keeps running |
| Key present but not 32 bytes | `503 advisor_answer_encryption_unavailable`; key length never disclosed |
| `ANTHROPIC_API_KEY` absent | `503 advisor_answer_not_configured` (should not occur on a live proxy) |
| Voyage / retrieval not wired | Endpoint still answers; the methodology tool is omitted and the engine uses the operational tools only |
| Over the operator's usage cap | Cap-refusal status (`402`) before any provider call |
| Provider or persistence error | `503 advisor_answer_unavailable`; no raw error or key text leaks |

There is no path that returns an answer without also writing an
encrypted record of it (encryption-first).

---

## Key reference and rotation

- Every encrypted row records `content_key_ref = kv://forge-flow/cmk/v1`
  (`tool/advisor_proxy/advisor_conversation_cmk_resolver.dart:36`).
- To rotate the key later: provision the new key and bump the constant
  to `kv://forge-flow/cmk/v2`. The version suffix means historical rows
  keep their `v1` reference and are not rewritten.

---

## Turn it back off (rollback)

Remove or unset `ADVISOR_CONVERSATION_CMK` and redeploy. The endpoint
reverts to `503` and the rest of the proxy keeps running. Existing
encrypted rows stay encrypted; decrypt is audit-only and MFA-gated.

---

## Cost note

- Answer LLM spend: usage class `advisor_answer` (Claude Haiku or Sonnet
  by the operator's plan tier).
- Retrieval spend: `voyage_query_embedding` and `voyage_rerank`.
- All recorded through the same metering path as every other AI surface
  (HP #8: no parallel stack, HP #9: metered by class).

---

## References

| What | Where |
| --- | --- |
| Answer route handler | `tool/advisor_proxy/advisor_answer_route_group_part.dart` |
| Route dispatch + wiring | `tool/advisor_proxy/advisor_proxy.dart` (`_handleAdvisorAnswer`) |
| Startup provider wiring + log | `tool/advisor_proxy/main.dart:1801` |
| Production bindings (fail-closed `tryCreate`) | `tool/advisor_proxy/proxy_bootstrap.dart` |
| In-process encryptor | `lib/infrastructure/crypto/advisor_conversation_envelope.dart` |
| CMK resolver + key ref | `tool/advisor_proxy/advisor_conversation_cmk_resolver.dart` |
| Secret name catalog | `tool/advisor_proxy/advisor_proxy.dart` (`ProxySecretNames`) |
| Cloud Run + Secret Manager mechanics | `runbooks/audit_anchor_cloudrun_deploy_runbook.md` |
| Devops surface contract | `docs/contracts/hardening_devops_surface_contract.md` |
| Slice | PR #1360 (A4.2b) |
