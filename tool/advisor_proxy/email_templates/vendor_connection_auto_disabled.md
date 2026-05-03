# {{vendorName}} connection disabled

Hi {{recipientName}},

We disabled the connection between Forge & Flow and {{vendorName}} at {{disabledAtHumanReadable}}. Recent OAuth refresh attempts kept failing, and after {{strikeCount}} consecutive failures we paused the connection so you do not silently see stale numbers.

The most recent error: {{lastErrorSummary}}

While the connection is disabled, F&F will not read new data from {{vendorName}}. Existing data already in F&F stays available.

## What to do

Reconnect {{vendorName}} from the **Connected services** card:

[Reconnect {{vendorName}}]({{integrationConsoleUrl}})

This usually means signing in to {{vendorName}} once and approving the F&F permission scopes. Once reconnection succeeds, sync resumes automatically.

If the reconnect screen surfaces an error you do not recognise, reply to this email and the F&F team will help.

The Forge & Flow team
