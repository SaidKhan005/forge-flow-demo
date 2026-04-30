// Forge & Flow MFA removal worker - Cloud Run Job entrypoint.
//
// Intended schedule: every 5-15 minutes. It completes due 24-hour MFA removal
// requests in bounded batches and exits. Cloud Scheduler retries are safe
// because the worker claims rows with SKIP LOCKED and each completion update is
// guarded by pending state.

import 'dart:io';

import '../advisor_proxy/advisor_proxy.dart';
import '../advisor_proxy/proxy_bootstrap.dart';

Future<void> main(List<String> args) async {
  final batchSize = _batchSize(args);
  ProxyConfig config;
  try {
    config = ProxyConfig.fromEnvironment(Platform.environment);
  } on ProxyConfigError catch (error) {
    stderr.writeln('mfa removal worker startup failed: ${error.message}');
    exitCode = 78;
    return;
  }

  final bindings = buildProxyProductionBindings(config);
  final result = await bindings.mfaRemovalWorker.processDue(
    batchSize: batchSize,
  );
  stdout.writeln(
    'mfa removal worker completed: '
    'claimed=${result.claimed} completed=${result.completed} '
    'failed=${result.failed}',
  );
  if (result.failed > 0) {
    exitCode = 1;
  }
}

int _batchSize(List<String> args) {
  const fallback = 50;
  for (final arg in args) {
    if (!arg.startsWith('--batch-size=')) continue;
    final value = int.tryParse(arg.substring('--batch-size='.length));
    if (value != null && value > 0) return value;
  }
  final fromEnv = int.tryParse(
    Platform.environment['MFA_REMOVAL_BATCH_SIZE'] ?? '',
  );
  if (fromEnv != null && fromEnv > 0) return fromEnv;
  return fallback;
}
