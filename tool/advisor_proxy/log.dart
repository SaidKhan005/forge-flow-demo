// Forge & Flow advisor proxy — structured JSON logging shim.
//
// HARD-G observability baseline. Canonical implementation now lives
// at `lib/services/observability/log.dart` so outbound clients in
// `lib/` (Postgres adapter, HIBP fetcher, etc.) can emit
// `request.dependency_timeout` log lines without crossing the
// `lib/` → `tool/` dependency direction. This file re-exports the
// canonical module so the contract-pinned path
// `tool/advisor_proxy/log.dart` keeps working for callers that
// already import it.

export 'package:forge_and_flow/services/observability/log.dart';
