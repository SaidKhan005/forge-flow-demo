# Operator-Web Proxy Error-Envelope Contract

Updated: 2026-05-23
Owner: G63 cross-surface error-envelope parity
Status: Active authority

## Why This Exists

The operator-web proxy answers every failure with one stable envelope.
Before G63, each operator-web gateway (`web_team_roles_gateway.dart`,
`web_team_users_gateway.dart`, `web_security_gateway.dart`) interpreted
that envelope its own way: it invented its own fallback error code, none
distinguished a 409 idempotency replay from a real domain conflict, and
403 two-factor-freshness was recognised inconsistently (the security
surface listed two codes by hand; the canonical client used a typed
flag). This contract codifies the single shared interpretation so every
operator-web surface classifies a proxy failure the same way.

This document is DESCRIPTIVE: it codifies what the proxy already returns
plus the canonical client/classifier interpretation. It does NOT
introduce new proxy behaviour. See CLAUDE.md "Proxy & API Conventions"
for the broader proxy rules (versioning, idempotency, key custody).

Handoff between:

- `lib/operator_web/services/operator_web_proxy_client.dart` -
  `_throwIfUnsuccessful` parses the envelope into the typed
  `OperatorWebProxyException`.
- `lib/operator_web/services/operator_web_error_envelope.dart` - the
  shared, pure classifier (`classifyOperatorWebError`,
  `OperatorWebErrorKind`, `operatorWebErrorMessageFor`, and the
  `OperatorWebProxyException.kind` extension).
- `tool/advisor_proxy/auth_handoff_routes.dart` +
  `tool/advisor_proxy/admin_integrations_routes.dart` - the proxy 409
  idempotency-replay vs. domain-conflict semantics codified below.
- `lib/auth/mfa_freshness_redirect_listener.dart` +
  `lib/operator_web/auth/step_up_challenge_handler.dart` - the two 403
  freshness sentinels.

When this document and code disagree, the proxy routes and the canonical
client/classifier code win for wire shape and mapping; this document
explains intent and the binding rule.

## The Envelope Shape

Every non-2xx proxy response carries:

- A JSON body `{ "error": <code>, "message": <message> }`. `error` is a
  stable machine code; `message` is human-readable.
- The HTTP status code.

The canonical client (`_throwIfUnsuccessful`) reads `body['error']` into
`OperatorWebProxyException.code`, `body['message']` into `.message`, the
status into `.statusCode`, and (for the freshness 403) the redirect hint
into `.redirectUri` / `.isMfaFreshnessRedirect`. A 2xx is never a
failure and never reaches the classifier.

## Canonical Error Kinds

`OperatorWebErrorKind` is the canonical category. The classifier maps the
`(statusCode, code, isMfaFreshnessRedirect)` triple to exactly one kind:

| Kind | Trigger | Operator-facing copy (canonical fallback) |
| --- | --- | --- |
| `mfaFreshnessRedirect` | The client flagged `isMfaFreshnessRedirect`, OR a 403 whose code is `mfa_freshness_required` or the RFC 9470 step-up sentinel `insufficient_user_authentication`. | "Please sign in again to continue. This protects your account." |
| `permissionDenied` | HTTP 403 that is NOT a freshness redirect. | "You do not have permission to do this. Ask an owner or admin if you need access." |
| `idempotencyReplayConflict` | HTTP 409 with code `idempotency_key_conflict`. | "This change was already applied. No action is needed." |
| `resourceConflict` | HTTP 409 with any other code (a domain conflict). | "This conflicts with something already saved. Refresh the page to see the latest, then try again." |
| `notFound` | HTTP 404. | "We could not find that item. It may have been removed. Refresh the page to see the latest." |
| `validation` | HTTP 400 or 422. | "Some details need fixing before we can save. Check your entries and try again." |
| `transient` | HTTP 408, 429, or any 5xx. | "Something went wrong on our end. Try again in a moment." |
| `unknown` | Any unmapped status, or a synthesised exception with no HTTP status (e.g. a malformed-response or no-id-token guard). | "Action could not be completed. Try again in a moment, or refresh the page if the problem keeps happening." |

The canonical copy is plain English, reads as guidance, carries no
engineering jargon, and uses no em dash (U+2014) as punctuation
(CLAUDE.md "UX no-em-dash law" + the UX writing standard). A surface MAY
render its own more specific copy for a known envelope code (e.g.
"Revoke this role from every member before deleting it" for a
`role_has_active_grants` 409); the table above is the SHARED fallback so
the generic case reads the same everywhere.

## The 409 Replay vs. Real Conflict Distinction

The proxy's `proxy_requests` UNIQUE guard (and the per-route idempotency
caches in `auth_handoff_routes.dart` /
`admin_integrations_routes.dart`) define two distinct 409 cases:

- **Replay collision: 409 `idempotency_key_conflict`.** The same
  `Idempotency-Key` was reused with a DIFFERENT request body. A SAME-body
  retry instead REPLAYS the prior 2xx response (it is never a 409), so a
  409 with this code means the logical action this key identifies was
  already processed. Operator-web surfaces treat this as "already
  applied", not a hard error. Idempotent boolean/void writes (delete,
  revoke, suspend/reactivate/soft-delete, password reset, cancel removal,
  recovery request) return their success outcome instead of throwing.
  Writes that must return a server-generated identifier (role/invite/
  role-grant CREATE) cannot fabricate one, so they still surface the
  error, now classified as `idempotencyReplayConflict`.
- **Real conflict: 409 with a domain code.** A genuine domain conflict
  (e.g. `role_has_active_grants`, an org unit that still has children, a
  uniqueness violation). Classified `resourceConflict`. The remedy is
  operator action, not a retry; the surface keeps surfacing it.

## The 403 Freshness vs. Permission Distinction

A 403 has two meanings, distinguished by code:

- **Freshness redirect.** Code `mfa_freshness_required` (the proxy's
  `auth_time`-window 403, see `mfa_freshness_redirect_listener.dart`) OR
  the RFC 9470 step-up sentinel `insufficient_user_authentication` (see
  `step_up_challenge_handler.dart`). Both classify as
  `mfaFreshnessRedirect` because both drive the same "sign in again"
  remedy. The canonical client already recognises the freshness 403 via
  `isMfaFreshnessRedirect` and hands the redirect hint to the
  `MfaFreshnessRedirectListener`; the classifier folds the step-up
  sentinel in so a gateway that only has the envelope code reaches the
  same kind.
- **Plain permission denial.** Any other 403. Classified
  `permissionDenied`. Signing in again does not help; the caller's role
  lacks the permission the route gates on.

## Binding Rule

Operator-web gateways and screens MUST classify proxy failures through
this shared envelope (`classifyOperatorWebError` /
`OperatorWebProxyException.kind`), not by inventing a per-gateway error
code or by re-listing status/code branches inline. Each gateway MAY keep
its own typed error class for its existing callers, but that class
DELEGATES its classification (and its canonical-message fallback) to this
envelope rather than duplicating the mapping. The shared classifier is
PURE (no I/O, no Flutter widget imports) so every surface — web client
path and own-transport gateway path alike — shares one source of truth.

## Scope Notes

- The three named gateways own their own `package:http` transport (they
  intentionally do not route through `OperatorWebProxyClient`, to stay
  free of `dart:io` on the web target). They classify off the raw
  `(statusCode, code)` pair via `classifyOperatorWebError`; the
  `OperatorWebProxyException.kind` extension is for surfaces that DO use
  the canonical client.
- Admin-side gateways (`lib/admin/services/**`) still carry their own
  bespoke 409 handling. Folding them onto this same classifier idea is a
  clean follow-up, not part of G63's operator-web scope.
