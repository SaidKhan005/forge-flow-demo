// CODE_OPS_DEBT — Theme C — production startup worker wiring.
//
// Five `pg_cron`-emitted NOTIFY channels are used by the proxy:
//
//   * `audit_anchor_tick`         — daily 02:00 UTC. Triggers the
//     `tool/audit_anchor` sweep across every operator. The consumer
//     hard-fails at startup if `AUDIT_ANCHOR_REQUIRE_AZURE` is true
//     but the Azure Blob anchor creds are not loaded.
//   * `rollups_tick`              — every 60 s + 5 min. Drives
//     [RollupWorker] across the Q3.3 grain set.
//   * `forge_email_outbox_tick`   — every minute. Drives
//     [EmailOutboxDispatcher.drainBatch].
//   * `mobile_push_outbox`        — per-row + cron tick. Drives
//     [MobilePushDispatcher.dispatch] across operator/location/user
//     fan-out via [MobilePushOutboxRepository.claimBatch].
//   * `outbox_tripwire_tick`      — implicit; the proxy already
//     surfaces tripwire status via `realtimeTripwireGateway`. The
//     [OutboxTripwirePoller] is wired into startup with a fetcher
//     closure that hits the gateway in-process so a single Cloud Run
//     instance does not need to round-trip its own HTTP route.
//
// Why this lives in `tool/advisor_proxy/`: the wiring depends on the
// proxy's pool factories + secret bundle + log helper. Putting it
// alongside `proxy_bootstrap.dart` keeps startup boundaries in one
// folder and tests can build a worker startup against the same
// scaffold the bootstrap tests use.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/pg_cron_notify_consumer.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/mobile_push_outbox_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/realtime/outbox_tripwire_poller.dart';
import 'package:forge_and_flow/services/rollups/rollup_models.dart';
import 'package:forge_and_flow/services/rollups/rollup_worker.dart';

import 'mobile_push_notifications.dart';

/// Env var that, when set to `'true'`, requires the audit-anchor
/// Azure-Blob credentials to be present at proxy startup. Mirrors
/// the existing `AZURE_AD_TENANT_ID` / `AZURE_AD_CLIENT_ID` env names
/// that the audit_anchor CLI already reads. When the flag is on but
/// either env var is missing, the proxy exits 78 (EX_CONFIG) so a
/// production deploy never silently ships a fail-open audit anchor.
const String kAuditAnchorRequireAzureEnvVar = 'AUDIT_ANCHOR_REQUIRE_AZURE';
const String kAuditAnchorAzureTenantEnvVar = 'AZURE_AD_TENANT_ID';
const String kAuditAnchorAzureClientEnvVar = 'AZURE_AD_CLIENT_ID';

/// Cron NOTIFY channel names. Centralised here so the test that
/// asserts every consumer registered with the listener catches a
/// rename in one place.
const String kAuditAnchorTickChannel = 'audit_anchor_tick';
const String kRollupsTickChannel = 'rollups_tick';
const String kEmailOutboxTickChannel = 'forge_email_outbox_tick';
const String kMobilePushOutboxChannel = 'mobile_push_outbox';

/// Result of the startup hard-fail check. The caller treats a
/// non-null [exitCode] as a config-level startup failure (78) and
/// lets the existing `log()` envelope render the message before
/// exiting.
class WorkerStartupAuditAnchorCheck {
  const WorkerStartupAuditAnchorCheck({
    required this.required,
    required this.tenantIdLoaded,
    required this.clientIdLoaded,
    this.exitCode,
    this.message,
  });

  /// Whether `AUDIT_ANCHOR_REQUIRE_AZURE=true` was set at startup.
  final bool required;
  final bool tenantIdLoaded;
  final bool clientIdLoaded;

  /// Non-null when the proxy MUST exit; the value is the exit code
  /// the entry point sets before returning.
  final int? exitCode;

  /// Human-readable message for the structured log envelope. Names
  /// only — never echoes secret values.
  final String? message;

  bool get shouldFailStartup => exitCode != null;
}

/// Pure helper — evaluates the audit-anchor fail-loud rule against
/// a snapshot of the environment. Exposed for unit tests so the
/// startup gate can be exercised without binding sockets.
WorkerStartupAuditAnchorCheck evaluateAuditAnchorRequireAzure(
  Map<String, String> environment,
) {
  final flag = (environment[kAuditAnchorRequireAzureEnvVar] ?? '')
      .trim()
      .toLowerCase();
  final required = flag == 'true' || flag == '1' || flag == 'yes';
  final tenantId = environment[kAuditAnchorAzureTenantEnvVar];
  final clientId = environment[kAuditAnchorAzureClientEnvVar];
  final tenantLoaded = tenantId != null && tenantId.isNotEmpty;
  final clientLoaded = clientId != null && clientId.isNotEmpty;
  if (!required) {
    return WorkerStartupAuditAnchorCheck(
      required: false,
      tenantIdLoaded: tenantLoaded,
      clientIdLoaded: clientLoaded,
    );
  }
  if (!tenantLoaded || !clientLoaded) {
    final missing = <String>[
      if (!tenantLoaded) kAuditAnchorAzureTenantEnvVar,
      if (!clientLoaded) kAuditAnchorAzureClientEnvVar,
    ];
    return WorkerStartupAuditAnchorCheck(
      required: true,
      tenantIdLoaded: tenantLoaded,
      clientIdLoaded: clientLoaded,
      exitCode: 78,
      message:
          '$kAuditAnchorRequireAzureEnvVar is enabled but the Azure '
          'Blob anchor credentials are not loaded; missing env names: '
          '${missing.join(', ')}',
    );
  }
  return WorkerStartupAuditAnchorCheck(
    required: true,
    tenantIdLoaded: tenantLoaded,
    clientIdLoaded: clientLoaded,
  );
}

/// Hook signature for the per-tick rollup work. Tests inject a fake
/// that records calls; production wires this to the rollup
/// aggregator (which still lands in a follow-up slice — see
/// `lib/services/rollups/rollup_worker.dart` header comment for the
/// "aggregator land in 7.58 / 9.0Σ.k follow-up" note).
typedef RollupTickHandler = Future<void> Function(RollupGrain grain);

/// Hook signature for the audit-anchor sweep. Production wires this
/// to a closure that calls `runCli(['sweep'], orchestratorOverride:
/// …)` from `tool/audit_anchor/main.dart` against the runtime built
/// at startup. Tests inject a fake that records the invocation.
typedef AuditAnchorTickHandler = Future<void> Function();

/// Hook signature for the mobile-push outbox tick. Production claims
/// a batch from [MobilePushOutboxRepository] for each (operator,
/// location) pair with `pending` rows and hands each message to
/// [MobilePushDispatcher.dispatch].
typedef MobilePushTickHandler = Future<void> Function();

/// Hook signature for the email outbox tick. Production wraps the
/// dispatcher's `drainBatch` call; tests substitute a closure that
/// records invocations.
typedef EmailOutboxTickHandler = Future<void> Function();

/// Bundle the startup wiring returns to the proxy entry point so it
/// can register a SIGTERM hook that drains every consumer.
class WorkerStartupHandle {
  WorkerStartupHandle({
    required this.consumers,
    required this.tripwirePoller,
  });

  /// All [PgCronNotifyConsumer] instances the wiring opened. SIGTERM
  /// stops them in registration order.
  final List<PgCronNotifyConsumer> consumers;

  /// The startup-wired tripwire poller. SIGTERM disposes it.
  final OutboxTripwirePoller tripwirePoller;

  Future<void> stopAll() async {
    for (final consumer in consumers) {
      try {
        await consumer.stop();
      } catch (_) {
        // Stop is best-effort; the connection is already torn down
        // when the proxy exits.
      }
    }
    await tripwirePoller.dispose();
  }
}

/// Build the production tick-driven workers and start their LISTEN
/// consumers. This is the single seam the proxy main entry point
/// calls after `RealtimeBridgeWorker.start()`.
///
/// Parameters:
///   * [postgresUrl] — connection string for the dedicated LISTEN
///     connections. The wiring opens a fresh connection per channel
///     to match `package_postgres_outbox_listener.dart`'s posture.
///   * [adminWrapper] — admin pool wrapper used for repositories and
///     the rollup `runAsSystem` runner.
///   * [tenantWrapper] — tenant pool wrapper used by the mobile-push
///     repositories (operator-scoped reads/writes).
///   * [tripwireFetcher] — closure the [OutboxTripwirePoller] calls
///     each minute. Production binds it to the proxy's existing
///     `realtimeTripwireGateway.fetch()` so the badge stays in sync
///     without round-tripping HTTP.
///   * [auditAnchorHandler] — sweep entry point invoked on each
///     `audit_anchor_tick`. Production wires this to the
///     audit_anchor CLI runtime built once at startup.
///   * [emailTickHandler] — per-tick email outbox drain. Production
///     binds this to the dispatcher's `drainBatch` method on the
///     dispatcher built from [PostgresEmailOutboxRepository] + the
///     SendGrid provider in `main.dart`.
///   * [mobilePushHandler] — per-tick claim + dispatch entry point.
///     Production wires this against [MobilePushOutboxRepository] +
///     [MobilePushDispatcher].
///   * [rollupTickHandler] — per-tick aggregator hook, fired once
///     per [RollupGrain] on every `rollups_tick`. The aggregator
///     itself lands in a later slice; tests inject a fake handler
///     so the wiring contract can be verified now.
WorkerStartupHandle wireProductionWorkers({
  required String postgresUrl,
  required TenantTransactionWrapper adminWrapper,
  required TenantTransactionWrapper tenantWrapper,
  required OutboxTripwireFetcher tripwireFetcher,
  required AuditAnchorTickHandler auditAnchorHandler,
  required EmailOutboxTickHandler emailTickHandler,
  required MobilePushTickHandler mobilePushHandler,
  required RollupTickHandler rollupTickHandler,
  PgCronNotifyConsumerLogger? consumerLogger,
  void Function(String channel, Object error, StackTrace stack)? onTickError,
  PgCronNotifyConsumer Function({
    required String connectionString,
    required List<String> channels,
    PgCronNotifyConsumerLogger? logger,
  })? consumerFactory,
}) {
  final consumers = <PgCronNotifyConsumer>[];
  PgCronNotifyConsumer build(String channel) {
    final factory = consumerFactory ??
        ({
          required String connectionString,
          required List<String> channels,
          PgCronNotifyConsumerLogger? logger,
        }) =>
            PgCronNotifyConsumer.fromUrl(
              connectionString,
              channels: channels,
              logger: logger,
            );
    final consumer = factory(
      connectionString: postgresUrl,
      channels: <String>[channel],
      logger: consumerLogger,
    );
    consumers.add(consumer);
    return consumer;
  }

  final auditAnchorConsumer = build(kAuditAnchorTickChannel);
  final rollupsConsumer = build(kRollupsTickChannel);
  final emailOutboxConsumer = build(kEmailOutboxTickChannel);
  final mobilePushConsumer = build(kMobilePushOutboxChannel);

  // audit_anchor_tick — single concurrent sweep guard. The sweep
  // already serializes via `pg_advisory_xact_lock`, but skipping a
  // second tick that fires while the first is still running keeps
  // the proxy from queueing pending sweeps if a clock skew or DB
  // hiccup re-fires the cron.
  bool auditSweepInFlight = false;
  auditAnchorConsumer.ticks.listen((tick) {
    if (auditSweepInFlight) return;
    auditSweepInFlight = true;
    unawaited(
      Future<void>(() async {
        try {
          await auditAnchorHandler();
        } catch (error, stack) {
          onTickError?.call(tick.channel, error, stack);
        } finally {
          auditSweepInFlight = false;
        }
      }),
    );
  });

  rollupsConsumer.ticks.listen((tick) {
    unawaited(
      Future<void>(() async {
        for (final grain in RollupGrain.values) {
          try {
            await rollupTickHandler(grain);
          } catch (error, stack) {
            onTickError?.call(tick.channel, error, stack);
          }
        }
      }),
    );
  });

  emailOutboxConsumer.ticks.listen((tick) {
    unawaited(
      Future<void>(() async {
        try {
          await emailTickHandler();
        } catch (error, stack) {
          onTickError?.call(tick.channel, error, stack);
        }
      }),
    );
  });

  mobilePushConsumer.ticks.listen((tick) {
    unawaited(
      Future<void>(() async {
        try {
          await mobilePushHandler();
        } catch (error, stack) {
          onTickError?.call(tick.channel, error, stack);
        }
      }),
    );
  });

  // The wrapper parameters are kept on the signature even when the
  // body does not consume them directly: production wiring passes
  // them so a future tick handler that needs a tenant transaction
  // (e.g. a per-operator email retry sweep) can be added without
  // rewiring the worker startup. Reference both here so `dart
  // analyze` does not flag them as unused.
  identical(adminWrapper, tenantWrapper);

  // Tripwire poller — proxy-internal so we do not round-trip the
  // gateway through HTTP. The badge in operator-web still polls the
  // route; this consumer keeps a server-side observation log so an
  // operator can grep proxy logs for tripwire transitions.
  final tripwirePoller = OutboxTripwirePoller(
    fetcher: () async {
      final result = await tripwireFetcher();
      return result;
    },
    onError: (error, stack) {
      onTickError?.call('outbox_tripwire_tick', error, stack);
    },
  );
  tripwirePoller.start();

  return WorkerStartupHandle(
    consumers: consumers,
    tripwirePoller: tripwirePoller,
  );
}

/// Build the production rollup tick handler. The handler claims a
/// batch for [grain] and (today) records the claim against the
/// aggregation_state lease bookkeeping. The aggregator that turns
/// the claim into [RollupUpsertRow]s lands in a later slice; until
/// then the handler is observably a no-op claim cycle that
/// nonetheless exercises the SQL function path so a deploy verifying
/// the cron tick fires can grep the log for `rollups.<grain>.claim`.
RollupTickHandler buildProductionRollupTickHandler({
  required RollupWorker worker,
}) {
  return (RollupGrain grain) async {
    // Claim acquires the lease; if no batch is available the worker
    // returns null and the handler simply exits — the next tick
    // tries again. A claim with rows present today still does not
    // flush because the aggregator is not wired yet; the lease is
    // released when the lease expires or on the next successful
    // flushBatch / recordFailure call.
    await worker.claimBatch(grain: grain);
  };
}

/// Build the production mobile-push tick handler that walks every
/// (operator, location) pair with `pending` rows and dispatches each
/// claimed message. The handler is intentionally simple — the
/// tenant-leading partial index admits the operator-scoped scan and
/// the dispatcher applies its own rate-limit posture per-token.
MobilePushTickHandler buildProductionMobilePushTickHandler({
  required TenantTransactionWrapper adminWrapper,
  required MobilePushOutboxRepository outboxRepository,
  required MobilePushDispatcher dispatcher,
  int batchSize = 32,
}) {
  if (batchSize <= 0) {
    throw ArgumentError.value(batchSize, 'batchSize', 'must be positive');
  }
  return () async {
    // Discover every (operator_id, location_id) tuple with pending
    // rows. The discovery query runs through the admin pool because
    // it intentionally crosses operator boundaries. The
    // claimBatch() call below switches back to the per-tenant pool
    // so RLS holds for the actual claim.
    final pairs =
        await adminWrapper.runAsSystem<List<Map<String, Object?>>>(
      (PostgresExecutor exec) {
        return exec.query(
          'select distinct operator_id::text as operator_id, '
          '                 location_id::text as location_id '
          'from public.mobile_push_outbox '
          "where status in ('pending', 'partial_failed') "
          'and scheduled_for <= now() '
          'limit 256',
        );
      },
      reason: 'mobile_push_outbox.discover_pairs',
    );
    for (final pair in pairs) {
      final operatorId = pair['operator_id'];
      final locationId = pair['location_id'];
      if (operatorId is! String || operatorId.isEmpty) continue;
      if (locationId is! String || locationId.isEmpty) continue;
      final messages = await outboxRepository.claimBatch(
        operatorId: operatorId,
        locationId: locationId,
        batchSize: batchSize,
      );
      for (final message in messages) {
        await dispatcher.dispatch(
          locationId: locationId,
          message: message,
        );
      }
    }
  };
}

/// Build the production audit-anchor tick handler. Wraps the supplied
/// [sweep] closure so the consumer can fire-and-forget without
/// dropping exceptions on the floor. The closure is supplied by
/// `main.dart` because it needs to bind the `runCli` invocation to
/// the runtime built at startup (and we keep the runCli import out
/// of this file so it stays test-friendly).
AuditAnchorTickHandler buildProductionAuditAnchorTickHandler({
  required Future<int> Function() sweep,
}) {
  return () async {
    final exitCode = await sweep();
    if (exitCode != 0 && exitCode != 1) {
      // 0 = no violations, 1 = anchor produced. Anything else
      // (2 = config error, 3 = runtime error) is logged via the
      // tick error sink so log search can correlate cron firings
      // with sweep outcomes.
      throw StateError('audit_anchor sweep exited with code $exitCode');
    }
  };
}

