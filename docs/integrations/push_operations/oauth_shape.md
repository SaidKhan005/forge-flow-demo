N/A — auth shape documented in `api_consumed.md`.

Push Operations uses a partner-issued static **bearer token**
(`Authorization: Bearer <token>`) — no OAuth flow, no refresh-token
rotation. The adapter declares `authMode = keyPaste` and the operator
pastes the partner-issued bearer into the F&F admin connect dialog.
There is no end-user authorization hop to document here; see
`api_consumed.md` "Auth method" section and `partnership_status.md`
for the partner-approval gate that issues the bearer.
