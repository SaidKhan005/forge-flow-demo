# Suspicious webhook activity from {{vendorName}}

Hi {{recipientName}},

Forge & Flow received {{failedSignatureCount}} webhook calls from {{vendorName}} that failed signature verification in the last {{observationWindowHumanReadable}}. These calls were rejected and no data was written.

This usually means one of:

- {{vendorName}} rotated their webhook signing secret without notifying us. Reconnect the integration to refresh the secret.
- An external party is replaying or forging webhook payloads to your endpoint.

## What you can do

- Open the **Connected services** card and reconnect {{vendorName}}: [{{vendorName}} connection]({{integrationConsoleUrl}})
- If reconnecting fixes the alerts, no further action is needed.
- If the alerts continue after a fresh connection, reply to this email and the F&F team will investigate.

We rate-limit this alert: you will not get another for the same vendor within {{rateLimitWindowHumanReadable}}.

The Forge & Flow team
