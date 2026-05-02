// Phase 11A.4c — per-lane KMS dispatcher.
//
// Sits in front of the two [KmsProvider] implementations
// (`KmsStubProvider` and `GcpSecretManagerKmsProvider`) and routes
// each `writeSecret` call to whichever provider the lane's feature
// flag selects. The flag is consulted on every call — flag flips
// take effect immediately on the next rotation, no proxy restart
// required.
//
// Wiring contract
// ---------------
// The router is constructed with both delegates plus a single
// closure ([flagLookup]) that returns the flag value for a given
// `logicalKeyKind`. Production binds [flagLookup] to a callback
// that runs `FeatureFlagsTableKmsRolloutFlag.isEnabledFor` inside
// an admin-pool tenant transaction; tests bind it to an in-memory
// closure. Either way, the router itself stays pure routing — it
// does not know about pools, transactions, or how the flag is
// resolved.
//
// Failure semantics
// -----------------
// Whichever delegate is selected handles the actual write; the
// router does not catch its exceptions. A `KmsWriteFailure` thrown
// by the chosen delegate propagates verbatim to the caller (the
// admin gateway), which already has the audit-on-failure path
// wired.

import 'kms_provider.dart';

/// Per-lane KMS dispatcher. Reads [_flagLookup] for each
/// `logicalKeyKind` and forwards the write to either the production
/// real provider (when the lane's flag is ON) or the stub (when OFF
/// or row missing). Both delegates share the [KmsProvider] contract
/// so swapping is transparent to the caller
/// (`RepositoryIntegrationAdminProxyGateway`).
class KmsLaneRouter implements KmsProvider {
  KmsLaneRouter({
    required KmsProvider stub,
    required KmsProvider real,
    required Future<bool> Function(String keyKind) flagLookup,
  }) : _stub = stub,
       _real = real,
       _flagLookup = flagLookup;

  final KmsProvider _stub;
  final KmsProvider _real;
  final Future<bool> Function(String keyKind) _flagLookup;

  @override
  Future<KmsWriteResult> writeSecret({
    required String logicalKeyKind,
    required String plaintext,
  }) async {
    final useReal = await _flagLookup(logicalKeyKind);
    final delegate = useReal ? _real : _stub;
    return delegate.writeSecret(
      logicalKeyKind: logicalKeyKind,
      plaintext: plaintext,
    );
  }
}
