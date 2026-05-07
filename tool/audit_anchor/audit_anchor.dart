// Phase 9.0Σ.f — audit chain anchor + verify orchestrator.
//
// Item 13 from `phase_9_scalability_decisions_2026-04-27.md` and B27
// from `phase_9_execution_backlog.md` lock the daily Azure Blob
// immutable anchor flow:
//
//   1. Daily, the F&F Cloud Run scheduled job (this tool) finds every
//      `(operator_id, chain_date)` where the chain is *complete*
//      (chain_date is in the past, UTC) and has no existing row in
//      `public.audit_chain_anchors`.
//
//   2. For each unanchored completed chain, the tool reads every row
//      ordered by `id`, recomputes every row hash from the canonical
//      payload bytes, and verifies the chain is internally consistent
//      *before* anchoring. A chain that fails self-verification is
//      flagged as a violation; no anchor is written.
//
//   3. The terminal `(row_id, row_hash, row_count)` plus a small
//      operator/day envelope is encoded as deterministic JSON
//      ("evidence") and written to the F&F-owned immutable Azure
//      Blob container via [AuditAnchorBlobClient.writeImmutable]. The
//      returned URI and ETag are recorded with the anchor row.
//
//   4. A single `audit_chain_anchors` row is inserted: append-only at
//      the grant shape (the migration revokes UPDATE/DELETE), so the
//      anchor record itself is tamper-evident at the database layer.
//
// The verify path mirrors the anchor path: read the chain, recompute,
// then compare the terminal hash against the existing anchor row AND
// the Blob evidence. A mismatch in any of the three (DB chain ↔ DB
// anchor row ↔ Blob ETag/body) is a forensic violation that surfaces
// for runbook escalation.
//
// CLAUDE.md hard rules carried in this file:
//
//   * "Direct `package:postgres` imports forbidden outside
//     `lib/infrastructure/persistence/postgres/`." This file uses the
//     [PostgresExecutor] abstract seam exclusively.
//
//   * "No live Azure, Firebase, provider, billing, or database calls
//     [...] No secrets, tokens, SAS URLs, or real account names in
//     repo/tests." [AuditAnchorBlobClient] is an interface; the
//     production wiring in `main.dart` reads env *names* only and
//     fails closed if the live wiring is not configured. Tests pass a
//     [FakeAuditAnchorBlobClient].
//
//   * "RLS performance discipline." Anchor reads cross operator
//     boundaries (the job sweeps every operator with unanchored
//     chains) so they run through `runAsSystem` with a non-blank audit
//     reason. Verify reads stay inside `runInTenantContext` for the
//     single operator under verification.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

// ─── Pure data classes ────────────────────────────────────────────────

/// One row from `public.audit_logs`, projected with `payload::text` so
/// the canonical bytes the trigger hashed are reproducible verbatim.
///
/// `payloadText` IS the canonical jsonb representation: PG normalizes
/// jsonb on storage (keys sorted alphabetically, whitespace fixed), so
/// `payload::text` returns deterministic bytes the verifier can feed
/// straight into the SHA-256 input. Re-canonicalizing in Dart would
/// risk byte-level drift (e.g. JSON Canonical Scheme RFC 8785 differs
/// from PG's representation in number formatting and key escaping).
class AuditLogRow {
  AuditLogRow({
    required this.id,
    required this.operatorId,
    required this.locationId,
    required this.chainDate,
    required this.occurredAt,
    required this.actorKind,
    required this.actorUserId,
    required this.actorPrincipalId,
    required this.targetKind,
    required this.targetId,
    required this.action,
    required this.payloadText,
    required this.prevRowHash,
    required this.rowHash,
  });

  final BigInt id;
  final String operatorId;
  final String? locationId;

  /// UTC date the chain belongs to. Matches `chain_date` in PG.
  final DateTime chainDate;

  /// Source-truth instant. Stored as `timestamptz`, projected as a
  /// UTC `DateTime` so the canonical encoding is timezone-stable.
  final DateTime occurredAt;

  final String actorKind;
  final String? actorUserId;
  final String? actorPrincipalId;
  final String? targetKind;
  final String? targetId;
  final String action;

  /// `payload::text` from PG (canonical jsonb representation).
  final String payloadText;

  final Uint8List? prevRowHash;
  final Uint8List rowHash;
}

/// One `audit_chain_anchors` row.
class AuditChainAnchor {
  const AuditChainAnchor({
    required this.operatorId,
    required this.chainDate,
    required this.terminalRowHash,
    required this.terminalRowId,
    required this.rowCount,
    required this.blobUri,
    required this.blobEtag,
    required this.anchoredAt,
  });

  final String operatorId;
  final DateTime chainDate;
  final Uint8List terminalRowHash;
  final BigInt terminalRowId;
  final BigInt rowCount;
  final String blobUri;
  final String blobEtag;
  final DateTime anchoredAt;
}

/// One unanchored completed chain identified by the sweep query.
class AuditChainSummary {
  const AuditChainSummary({required this.operatorId, required this.chainDate});

  final String operatorId;
  final DateTime chainDate;
}

// ─── Canonical encoding + hash recomputation (pure) ───────────────────

/// Pure functions that mirror the SQL trigger
/// `public.audit_logs_set_chain()`. Producing identical bytes on both
/// sides is the chain's correctness contract — every test in this
/// slice ultimately backs onto these helpers.
class AuditChainHasher {
  const AuditChainHasher();

  /// Canonical preimage bytes for `row`. Layout matches the SQL
  /// trigger:
  ///
  ///   operator_id || \x1F || location_id || \x1F || chain_date ||
  ///   \x1F || occurred_at_utc_iso_micros || \x1F || actor_kind ||
  ///   \x1F || actor_user_id || \x1F || actor_principal_id || \x1F ||
  ///   target_kind || \x1F || target_id || \x1F || action || \x1F ||
  ///   payload::text || \x1F
  ///
  /// NULL columns collapse to empty strings; the verifier reproduces
  /// the same bytes regardless of the driver's NULL representation.
  Uint8List canonicalPayload(AuditLogRow row) {
    final buffer = StringBuffer();
    void writeField(String value) {
      buffer.write(value);
      buffer.writeCharCode(0x1f);
    }

    writeField(row.operatorId);
    writeField(row.locationId ?? '');
    writeField(_formatChainDate(row.chainDate));
    writeField(_formatOccurredAtUtc(row.occurredAt));
    writeField(row.actorKind);
    writeField(row.actorUserId ?? '');
    writeField(row.actorPrincipalId ?? '');
    writeField(row.targetKind ?? '');
    writeField(row.targetId ?? '');
    writeField(row.action);
    writeField(row.payloadText);
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  /// `SHA256(prev_row_hash || canonical(row))`.
  Uint8List recomputeRowHash(AuditLogRow row) {
    final preimage = BytesBuilder();
    if (row.prevRowHash != null) {
      preimage.add(row.prevRowHash!);
    }
    preimage.add(canonicalPayload(row));
    return Uint8List.fromList(sha256.convert(preimage.toBytes()).bytes);
  }

  /// Walks `rows` (sorted by id ascending) and returns a list of
  /// row-level violations. A clean chain returns an empty list.
  ///
  /// Checks per row:
  ///   * `prev_row_hash` matches the previous row's `row_hash` (or is
  ///     NULL on the first row).
  ///   * `row_hash` matches `recomputeRowHash(row)`.
  List<ChainHashViolation> verifyChain(List<AuditLogRow> rows) {
    final violations = <ChainHashViolation>[];
    Uint8List? expectedPrev;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (!_byteEquals(row.prevRowHash, expectedPrev)) {
        violations.add(
          ChainHashViolation(
            rowId: row.id,
            kind: ChainHashViolationKind.prevHashMismatch,
            expected: expectedPrev,
            actual: row.prevRowHash,
          ),
        );
      }
      final recomputed = recomputeRowHash(row);
      if (!_byteEquals(row.rowHash, recomputed)) {
        violations.add(
          ChainHashViolation(
            rowId: row.id,
            kind: ChainHashViolationKind.rowHashMismatch,
            expected: recomputed,
            actual: row.rowHash,
          ),
        );
      }
      expectedPrev = row.rowHash;
    }
    return violations;
  }
}

/// `to_char(occurred_at at time zone 'UTC',
///          'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')` — six-digit microseconds,
/// ISO 8601 with literal `T` + `Z`. PG's `to_char` always produces
/// six-digit fractional seconds; Dart's [DateTime] uses microsecond
/// precision so we render the same width.
String _formatOccurredAtUtc(DateTime instant) {
  final utc = instant.toUtc();
  final micros = (utc.microsecondsSinceEpoch).remainder(1000000);
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}T'
      '${utc.hour.toString().padLeft(2, '0')}:'
      '${utc.minute.toString().padLeft(2, '0')}:'
      '${utc.second.toString().padLeft(2, '0')}.'
      '${micros.abs().toString().padLeft(6, '0')}Z';
}

/// `chain_date::text` from PG (`YYYY-MM-DD`).
String _formatChainDate(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

bool _byteEquals(Uint8List? a, Uint8List? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One row-level violation surfaced by [AuditChainHasher.verifyChain].
class ChainHashViolation {
  const ChainHashViolation({
    required this.rowId,
    required this.kind,
    required this.expected,
    required this.actual,
  });

  final BigInt rowId;
  final ChainHashViolationKind kind;
  final Uint8List? expected;
  final Uint8List? actual;

  @override
  String toString() {
    String hex(Uint8List? bytes) {
      if (bytes == null) return '<null>';
      final sb = StringBuffer();
      for (final b in bytes) {
        sb.write(b.toRadixString(16).padLeft(2, '0'));
      }
      return sb.toString();
    }

    return 'row $rowId: ${kind.name} '
        '(expected ${hex(expected)} vs actual ${hex(actual)})';
  }
}

enum ChainHashViolationKind { prevHashMismatch, rowHashMismatch }

// ─── Anchor evidence (deterministic JSON written to Blob) ─────────────

/// The deterministic JSON envelope written to the immutable Blob.
/// Field order is fixed by encoding sorted keys; the encoder uses
/// `JsonEncoder` with a `convert` step to ensure stable output across
/// Dart versions.
class AnchorEvidence {
  const AnchorEvidence({
    required this.schemaVersion,
    required this.operatorId,
    required this.chainDate,
    required this.terminalRowId,
    required this.terminalRowHashHex,
    required this.rowCount,
    required this.anchoredAt,
  });

  final int schemaVersion;
  final String operatorId;
  final DateTime chainDate;
  final BigInt terminalRowId;
  final String terminalRowHashHex;
  final BigInt rowCount;
  final DateTime anchoredAt;

  Map<String, Object?> toCanonicalMap() {
    // Keys MUST stay in this order and the Blob writer MUST encode
    // with a deterministic JSON encoder. Verifier code re-reads the
    // Blob and parses these fields by name; reordering would break
    // bytewise re-hash but key-name lookup remains stable either way.
    return <String, Object?>{
      'anchored_at': _formatOccurredAtUtc(anchoredAt),
      'chain_date': _formatChainDate(chainDate),
      'operator_id': operatorId,
      'row_count': rowCount.toString(),
      'schema_version': schemaVersion,
      'terminal_row_hash_hex': terminalRowHashHex,
      'terminal_row_id': terminalRowId.toString(),
    };
  }
}

class AnchorEvidenceCodec {
  const AnchorEvidenceCodec();

  /// Encodes `evidence` to canonical bytes:
  ///   * keys sorted alphabetically (handled by [AnchorEvidence.toCanonicalMap]),
  ///   * indent-free JSON,
  ///   * UTF-8 encoded.
  Uint8List encode(AnchorEvidence evidence) {
    final body = jsonEncode(evidence.toCanonicalMap());
    return Uint8List.fromList(utf8.encode(body));
  }

  AnchorEvidence decode(List<int> bytes) {
    final text = utf8.decode(bytes);
    final raw = jsonDecode(text);
    if (raw is! Map<String, Object?>) {
      throw const FormatException('anchor evidence is not a JSON object');
    }
    return AnchorEvidence(
      schemaVersion: raw['schema_version']! as int,
      operatorId: raw['operator_id']! as String,
      chainDate: DateTime.parse('${raw['chain_date']! as String}T00:00:00Z'),
      terminalRowId: BigInt.parse(raw['terminal_row_id']! as String),
      terminalRowHashHex: raw['terminal_row_hash_hex']! as String,
      rowCount: BigInt.parse(raw['row_count']! as String),
      anchoredAt: DateTime.parse(raw['anchored_at']! as String),
    );
  }
}

// ─── Blob client interface (production wiring lives in main.dart) ─────

/// Result of writing one immutable Blob.
class AnchorBlobWriteResult {
  const AnchorBlobWriteResult({required this.uri, required this.etag});
  final String uri;
  final String etag;
}

/// Result of reading one immutable Blob.
class AnchorBlobReadResult {
  const AnchorBlobReadResult({required this.bytes, required this.etag});
  final List<int> bytes;
  final String etag;
}

/// Abstract Azure Blob client. Production wiring builds a real client
/// from env names only (`AZURE_BLOB_AUDIT_*`); the tool never receives
/// raw secrets — the Cloud Run runtime injects a managed-identity
/// credential through the Azure SDK at request time. The orchestrator
/// only sees this interface, so tests can pass a deterministic fake.
abstract class AuditAnchorBlobClient {
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  });

  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  });
}

/// Names of env vars the production runtime reads. Names ONLY; never
/// values. CLI startup logs the first set so the operator can confirm
/// wiring without echoing the actual config to logs.
class AuditAnchorEnvNames {
  const AuditAnchorEnvNames();
  static const String postgresUrl = 'POSTGRES_URL';
  static const String postgresAdminUrl = 'POSTGRES_ADMIN_URL';
  static const String azureBlobContainer = 'AZURE_BLOB_AUDIT_CONTAINER';
  static const String azureBlobEndpoint = 'AZURE_BLOB_AUDIT_ENDPOINT';

  /// Azure AD tenant ID hosting the federated app registration. Optional
  /// at the env layer: when both [azureAdTenantId] and [azureAdClientId]
  /// are set, the production blob-client factory builds a live
  /// `AzureBlobAuditAnchorBlobClient`; when either is unset, the factory
  /// keeps the fail-closed [ScaffoldRejectingAuditAnchorBlobClient] so
  /// local/dev runs do not silently no-op.
  static const String azureAdTenantId = 'AZURE_AD_TENANT_ID';

  /// Azure AD app-registration client id for the federated identity
  /// trust relationship. The matching federated credential's `subject`
  /// must equal the GCP Cloud Run service account's numeric unique id;
  /// `issuer=https://accounts.google.com`; `audience=api://AzureADTokenExchange`.
  static const String azureAdClientId = 'AZURE_AD_CLIENT_ID';

  /// Fixed order so startup diagnostics print a stable list.
  static const List<String> required = <String>[
    postgresUrl,
    azureBlobContainer,
    azureBlobEndpoint,
  ];

  static const List<String> optional = <String>[
    postgresAdminUrl,
    azureAdTenantId,
    azureAdClientId,
  ];
}

/// Thrown by the production wiring when a required env var is missing.
/// The CLI surfaces the error message but NEVER echoes any env value;
/// `name` is the missing env var's name.
class AuditAnchorConfigError implements Exception {
  AuditAnchorConfigError(this.name);
  final String name;
  @override
  String toString() =>
      'audit_anchor: required env var "$name" is not set; see '
      'runbooks/audit_chain_verify_runbook.md for the configuration '
      'checklist (no live Azure mutation will run before configuration '
      'is in place).';
}

/// Production-default Blob client. Throws on every call so the CLI
/// fails closed when live Azure wiring has not landed yet. Pattern
/// matches `ScaffoldRejectingProxyLlmProvider` in `tool/advisor_proxy/`.
class ScaffoldRejectingAuditAnchorBlobClient implements AuditAnchorBlobClient {
  const ScaffoldRejectingAuditAnchorBlobClient();

  static const String _msg =
      'audit_anchor blob client is not wired to live Azure yet; '
      'configure AZURE_BLOB_AUDIT_* and inject a real client. See '
      'runbooks/audit_chain_verify_runbook.md.';

  @override
  Future<AnchorBlobWriteResult> writeImmutable({
    required String containerName,
    required String blobName,
    required List<int> evidenceBytes,
  }) async {
    throw const AuditAnchorBlobUnavailable(_msg);
  }

  @override
  Future<AnchorBlobReadResult> readImmutable({
    required String containerName,
    required String blobName,
  }) async {
    throw const AuditAnchorBlobUnavailable(_msg);
  }
}

/// Thrown when the Blob client cannot complete the request. The
/// orchestrator maps this to a 1-line CLI error code (no secrets in
/// the message); the runbook documents triage for each variant.
class AuditAnchorBlobUnavailable implements Exception {
  const AuditAnchorBlobUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'AuditAnchorBlobUnavailable: $reason';
}

/// Thrown by [AuditAnchorBlobClient.writeImmutable] when the destination
/// blob already exists (HTTP 409 `BlobAlreadyExists`) or the container
/// immutability policy refused a rewrite (HTTP 403 `ImmutableBlob`).
///
/// Carries the live blob's URI, ETag, and evidence body so the
/// orchestrator's `_anchorOne` recovery path can revalidate the
/// existing evidence against the current in-DB chain and insert the
/// missing `audit_chain_anchors` row using the *original* anchored_at
/// recorded in the immutable evidence body. This makes the daily
/// `sweep` idempotent across crashed-and-restarted runs without ever
/// rewriting an immutable blob.
class AuditAnchorBlobAlreadyAnchored implements Exception {
  const AuditAnchorBlobAlreadyAnchored({
    required this.uri,
    required this.etag,
    required this.evidenceBytes,
  });

  final String uri;
  final String etag;
  final List<int> evidenceBytes;

  @override
  String toString() =>
      'AuditAnchorBlobAlreadyAnchored: $uri (existing ETag $etag)';
}

/// Deterministic blob name for one anchored chain. Layout:
///
///   `audit_anchors/{operator_id}/{chain_date_yyyy_mm_dd}.json`
///
/// Operator UUIDs are lowercased to keep the blob path predictable.
String anchorBlobName({
  required String operatorId,
  required DateTime chainDate,
}) {
  return 'audit_anchors/'
      '${operatorId.toLowerCase()}/'
      '${_formatChainDate(chainDate)}.json';
}

// ─── Reader / anchor-writer interfaces (DB seam) ──────────────────────

/// Reads chains and anchors from Postgres. Production wiring uses
/// [PostgresAuditChainReader] (this file) which routes through the
/// [TenantTransactionWrapper] from `lib/.../postgres/`. Tests pass a
/// recording fake.
abstract class AuditChainReader {
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  });

  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  });

  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  });
}

abstract class AuditChainAnchorWriter {
  Future<void> insertAnchor(AuditChainAnchor anchor);
}

/// Production reader. Routes every read through
/// [TenantTransactionWrapper.runInTenantContext] so the per-tenant
/// RLS policy admits the row. The anchor sweep that crosses operator
/// boundaries (`findUnanchoredCompletedChains` for many operators) is
/// the orchestrator's responsibility — it loops over the operators
/// list (provided to the CLI) and calls this reader once per
/// operator.
class PostgresAuditChainReader implements AuditChainReader {
  PostgresAuditChainReader({
    required TenantTransactionWrapper wrapper,
    required String defaultLocationId,
    required String defaultUserId,
  }) : _wrapper = wrapper,
       _defaultLocationId = defaultLocationId,
       _defaultUserId = defaultUserId;

  final TenantTransactionWrapper _wrapper;
  final String _defaultLocationId;
  final String _defaultUserId;

  TenantContext _ctx(String operatorId) => TenantContext(
    operatorId: operatorId,
    locationId: _defaultLocationId,
    userId: _defaultUserId,
  );

  @override
  Future<List<AuditChainSummary>> findUnanchoredCompletedChains({
    required String operatorId,
    required DateTime asOfUtc,
  }) {
    return _wrapper.runInTenantContext<List<AuditChainSummary>>(
      _ctx(operatorId),
      (exec) async {
        final rows = await exec.query(
          'select distinct al.chain_date as chain_date '
          '  from audit_logs al '
          ' where al.operator_id = @operator_id::uuid '
          '   and al.chain_date < @as_of_utc::date '
          '   and not exists ( '
          '     select 1 from audit_chain_anchors a '
          '      where a.operator_id = al.operator_id '
          '        and a.chain_date = al.chain_date '
          '   ) '
          ' order by al.chain_date',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'as_of_utc': _formatChainDate(asOfUtc),
          },
        );
        return <AuditChainSummary>[
          for (final row in rows)
            AuditChainSummary(
              operatorId: operatorId,
              chainDate: _coerceUtcDate(row['chain_date']),
            ),
        ];
      },
    );
  }

  @override
  Future<List<AuditLogRow>> readChainRows({
    required String operatorId,
    required DateTime chainDate,
  }) {
    return _wrapper.runInTenantContext<List<AuditLogRow>>(_ctx(operatorId), (
      exec,
    ) async {
      final rows = await exec.query(
        'select id::text as id, operator_id::text as operator_id, '
        '       location_id::text as location_id, chain_date, '
        '       occurred_at, actor_kind, '
        '       actor_user_id::text as actor_user_id, '
        '       actor_principal_id, target_kind, target_id, '
        '       action, payload::text as payload_text, '
        '       prev_row_hash, row_hash '
        '  from audit_logs '
        ' where operator_id = @operator_id::uuid '
        '   and chain_date  = @chain_date::date '
        ' order by id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'chain_date': _formatChainDate(chainDate),
        },
      );
      return <AuditLogRow>[for (final row in rows) _coerceRow(row)];
    });
  }

  @override
  Future<AuditChainAnchor?> readAnchor({
    required String operatorId,
    required DateTime chainDate,
  }) {
    return _wrapper.runInTenantContext<AuditChainAnchor?>(_ctx(operatorId), (
      exec,
    ) async {
      final rows = await exec.query(
        'select operator_id::text as operator_id, chain_date, '
        '       terminal_row_hash, terminal_row_id::text as '
        '       terminal_row_id, row_count::text as row_count, '
        '       blob_uri, blob_etag, anchored_at '
        '  from audit_chain_anchors '
        ' where operator_id = @operator_id::uuid '
        '   and chain_date  = @chain_date::date '
        ' limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'chain_date': _formatChainDate(chainDate),
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      return AuditChainAnchor(
        operatorId: row['operator_id']! as String,
        chainDate: _coerceUtcDate(row['chain_date']),
        terminalRowHash: _coerceBytes(row['terminal_row_hash'])!,
        terminalRowId: BigInt.parse(row['terminal_row_id']! as String),
        rowCount: BigInt.parse(row['row_count']! as String),
        blobUri: row['blob_uri']! as String,
        blobEtag: row['blob_etag']! as String,
        anchoredAt: (row['anchored_at']! as DateTime).toUtc(),
      );
    });
  }
}

/// Production anchor writer. Inserts one row into
/// `public.audit_chain_anchors` inside the tenant's transaction so the
/// per-tenant RLS INSERT policy admits the row.
///
/// L9 (Code-Health Lane): the INSERT also stamps the breadcrumb columns
/// `last_anchor_blob_url` and `last_anchor_blob_at` (added by migration
/// `202605070200_audit_anchor_advisory_lock_infra.sql`) so the sweep's
/// crash-recovery path has a durable record of the immutable blob URL
/// the run published. The append-only grant shape (no UPDATE/DELETE)
/// means the breadcrumbs land on INSERT exactly once; subsequent
/// recovery sweeps read the existing blob via `readImmutable` and
/// reuse it idempotently.
class PostgresAuditChainAnchorWriter implements AuditChainAnchorWriter {
  PostgresAuditChainAnchorWriter({
    required TenantTransactionWrapper wrapper,
    required String defaultLocationId,
    required String defaultUserId,
  }) : _wrapper = wrapper,
       _defaultLocationId = defaultLocationId,
       _defaultUserId = defaultUserId;

  final TenantTransactionWrapper _wrapper;
  final String _defaultLocationId;
  final String _defaultUserId;

  @override
  Future<void> insertAnchor(AuditChainAnchor anchor) {
    return _wrapper.runInTenantContext<void>(
      TenantContext(
        operatorId: anchor.operatorId,
        locationId: _defaultLocationId,
        userId: _defaultUserId,
      ),
      (exec) async {
        await exec.execute(
          'insert into audit_chain_anchors ( '
          '  operator_id, chain_date, terminal_row_hash, '
          '  terminal_row_id, row_count, blob_uri, blob_etag, '
          '  anchored_at, last_anchor_blob_url, last_anchor_blob_at) '
          'values ( '
          '  @operator_id::uuid, @chain_date::date, '
          '  @terminal_row_hash, @terminal_row_id::bigint, '
          '  @row_count::bigint, @blob_uri, @blob_etag, '
          '  @anchored_at, @last_anchor_blob_url, @last_anchor_blob_at)',
          parameters: <String, Object?>{
            'operator_id': anchor.operatorId,
            'chain_date': _formatChainDate(anchor.chainDate),
            'terminal_row_hash': anchor.terminalRowHash,
            'terminal_row_id': anchor.terminalRowId.toString(),
            'row_count': anchor.rowCount.toString(),
            'blob_uri': anchor.blobUri,
            'blob_etag': anchor.blobEtag,
            'anchored_at': anchor.anchoredAt.toUtc(),
            // Breadcrumbs duplicate blob_uri / anchored_at by design.
            // The original columns hold the immutable evidence the
            // verifier compares against; the breadcrumbs record the
            // L9 sweep's most-recent successful blob write so the
            // crash-recovery path can roll forward without rewriting
            // an immutable blob. They diverge only when a future
            // recovery sweep re-stamps the breadcrumb timestamp.
            'last_anchor_blob_url': anchor.blobUri,
            'last_anchor_blob_at': anchor.anchoredAt.toUtc(),
          },
        );
      },
    );
  }
}

// ─── Advisory-lock seam (sweep guard) ─────────────────────────────────

/// Looks up the integer advisory-lock id used to serialize concurrent
/// `audit_anchor sweep` invocations. Reads the row identified by
/// `lock_kind = 'audit_anchor_sweep'` from
/// `public.audit_anchor_advisory_locks` (constants table seeded by
/// migration `202605070200_audit_anchor_advisory_lock_infra.sql`).
///
/// Production wiring uses [PostgresSweepLockIdReader]; tests pass a
/// fake. The seam keeps the lock id out of the application binary —
/// DBAs can audit / rotate the live id without redeploying the worker.
abstract class SweepLockIdReader {
  /// Returns the advisory-lock id for the daily anchor sweep.
  Future<int> readSweepLockId();
}

class PostgresSweepLockIdReader implements SweepLockIdReader {
  PostgresSweepLockIdReader({required TenantTransactionWrapper wrapper})
      : _wrapper = wrapper;

  final TenantTransactionWrapper _wrapper;

  @override
  Future<int> readSweepLockId() {
    return _wrapper.runAsSystem<int>(
      (exec) async {
        final rows = await exec.query(
          "select lock_id from public.audit_anchor_advisory_locks "
          "where lock_kind = 'audit_anchor_sweep' limit 1",
        );
        if (rows.isEmpty) {
          throw const SweepLockUnavailable(
            'audit_anchor_advisory_locks has no row for '
            "lock_kind='audit_anchor_sweep'; apply migration "
            '202605070200_audit_anchor_advisory_lock_infra.sql',
          );
        }
        final raw = rows.first['lock_id'];
        if (raw is int) return raw;
        if (raw is BigInt) return raw.toInt();
        if (raw is String) return int.parse(raw);
        throw SweepLockUnavailable(
          'audit_anchor_advisory_locks.lock_id has unexpected '
          'shape: ${raw.runtimeType}',
        );
      },
      reason: 'audit_anchor.lock_id_lookup',
    );
  }
}

/// Thrown when the advisory-lock id cannot be resolved (missing row,
/// unexpected shape). The CLI maps this to a runtime error (exit 3)
/// rather than a config error (exit 2) — the migration is wired but
/// the data plane is mis-seeded, which is an operations issue.
class SweepLockUnavailable implements Exception {
  const SweepLockUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'SweepLockUnavailable: $reason';
}

/// Acquires an advisory lock around `body`. Production wiring uses
/// [PostgresSweepAdvisoryLock] which calls
/// `pg_advisory_lock(<lockId>) ... pg_advisory_unlock(<lockId>)`;
/// tests pass a recording fake to assert mutual exclusion of two
/// concurrent invocations.
abstract class SweepAdvisoryLock {
  /// Acquires the advisory lock keyed by [lockId], runs [body], and
  /// releases the lock when [body] completes (success or failure).
  /// Returns whatever [body] returns. If the lock is held by another
  /// session, [withSweepLock] blocks (Postgres semantics) — concurrent
  /// sweeps serialize rather than racing.
  Future<R> withSweepLock<R>({
    required int lockId,
    required Future<R> Function() body,
  });
}

class PostgresSweepAdvisoryLock implements SweepAdvisoryLock {
  PostgresSweepAdvisoryLock({required TenantTransactionWrapper wrapper})
      : _wrapper = wrapper;

  final TenantTransactionWrapper _wrapper;

  @override
  Future<R> withSweepLock<R>({
    required int lockId,
    required Future<R> Function() body,
  }) async {
    // Acquire on a session, run the body outside any tx, then release.
    // We cannot run the entire sweep inside one transaction because
    // each per-operator anchor uses its own tenant-scoped tx; instead
    // the lock is taken via session-scoped pg_advisory_lock and
    // released after the sweep completes. Both halves run via
    // runAsSystem with a non-blank reason so the bypass-RLS audit
    // marker explains the lock acquisition / release.
    await _wrapper.runAsSystem<void>(
      (exec) async {
        await exec.execute(
          'select pg_advisory_lock(@lock_id::int)',
          parameters: <String, Object?>{'lock_id': lockId},
        );
      },
      reason: 'audit_anchor.sweep_lock_acquire',
    );
    try {
      return await body();
    } finally {
      await _wrapper.runAsSystem<void>(
        (exec) async {
          await exec.execute(
            'select pg_advisory_unlock(@lock_id::int)',
            parameters: <String, Object?>{'lock_id': lockId},
          );
        },
        reason: 'audit_anchor.sweep_lock_release',
      );
    }
  }
}

DateTime _coerceUtcDate(Object? raw) {
  if (raw is DateTime) return DateTime.utc(raw.year, raw.month, raw.day);
  if (raw is String) {
    final parsed = DateTime.parse(raw);
    return DateTime.utc(parsed.year, parsed.month, parsed.day);
  }
  throw FormatException('expected DateTime/String for chain_date, got $raw');
}

Uint8List? _coerceBytes(Object? raw) {
  if (raw == null) return null;
  if (raw is Uint8List) return raw;
  if (raw is List<int>) return Uint8List.fromList(raw);
  if (raw is String) {
    // PG hex format starts with `\x` for bytea text mode.
    final hex = raw.startsWith(r'\x') ? raw.substring(2) : raw;
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
  throw FormatException('expected bytea-shaped value, got ${raw.runtimeType}');
}

AuditLogRow _coerceRow(Map<String, Object?> row) {
  return AuditLogRow(
    id: BigInt.parse(row['id']! as String),
    operatorId: row['operator_id']! as String,
    locationId: row['location_id'] as String?,
    chainDate: _coerceUtcDate(row['chain_date']),
    occurredAt: (row['occurred_at']! as DateTime).toUtc(),
    actorKind: row['actor_kind']! as String,
    actorUserId: row['actor_user_id'] as String?,
    actorPrincipalId: row['actor_principal_id'] as String?,
    targetKind: row['target_kind'] as String?,
    targetId: row['target_id'] as String?,
    action: row['action']! as String,
    payloadText: row['payload_text']! as String,
    prevRowHash: _coerceBytes(row['prev_row_hash']),
    rowHash: _coerceBytes(row['row_hash'])!,
  );
}

// ─── Operator-id reader (sweep-mode dependency) ───────────────────────

/// Resolves the list of operator ids the daily Cloud Run Job should
/// sweep. The orchestrator (and `runAnchor` per-operator) deliberately
/// does NOT enumerate operators — that boundary stays in this seam so
/// the orchestrator's `runInTenantContext` posture is preserved per-
/// operator. The sweep entry point in `main.dart` calls this once at
/// the top of a daily run and then dispatches the existing
/// per-operator anchor logic.
abstract class OperatorIdReader {
  /// Returns the operator ids in stable order (ascending UUID) so the
  /// daily Cloud Run log line ordering is reproducible.
  Future<List<String>> listOperatorIds();
}

/// Postgres-backed [OperatorIdReader]. Reads `public.operators` via
/// `runAsSystem` (cross-tenant by definition; the audit reason is
/// `audit_anchor.sweep` so the bypass-RLS event is attributed at
/// `auth_events_audit` ingest time).
class PostgresOperatorIdReader implements OperatorIdReader {
  PostgresOperatorIdReader({required TenantTransactionWrapper wrapper})
      : _wrapper = wrapper;

  final TenantTransactionWrapper _wrapper;

  @override
  Future<List<String>> listOperatorIds() {
    return _wrapper.runAsSystem<List<String>>(
      (exec) async {
        final rows = await exec.query(
          'select operator_id::text as operator_id '
          '  from public.operators '
          ' order by operator_id',
        );
        return <String>[
          for (final row in rows) row['operator_id']! as String,
        ];
      },
      reason: 'audit_anchor.sweep',
    );
  }
}

// ─── Orchestrator ─────────────────────────────────────────────────────

/// Result of one anchor run.
class AnchorRunResult {
  const AnchorRunResult({
    required this.operatorId,
    required this.chainDate,
    required this.outcome,
    this.anchor,
    this.violations = const <ChainHashViolation>[],
    this.message,
  });

  final String operatorId;
  final DateTime chainDate;
  final AnchorOutcome outcome;
  final AuditChainAnchor? anchor;
  final List<ChainHashViolation> violations;
  final String? message;
}

enum AnchorOutcome {
  anchored,
  alreadyAnchored,
  chainHashMismatch,
  empty,

  /// L9 startup-recovery outcome (committed): a previous run wrote the
  /// immutable blob but crashed before inserting the
  /// `audit_chain_anchors` row. The recovery sweep recomputed the
  /// chain prefix, the blob's evidence agreed, and the missing anchor
  /// row was inserted using the blob's original `anchored_at`.
  recoveredCommitted,

  /// L9 startup-recovery outcome (failed): an existing immutable blob
  /// disagrees with the current in-DB chain. The recovery sweep
  /// refused to insert an anchor row; the row stays unanchored and
  /// the result surfaces for runbook escalation.
  recoveredFailed,
}

/// Result of one verify run.
class VerifyRunResult {
  const VerifyRunResult({
    required this.operatorId,
    required this.chainDate,
    required this.outcome,
    this.violations = const <ChainHashViolation>[],
    this.message,
  });

  final String operatorId;
  final DateTime chainDate;
  final VerifyOutcome outcome;
  final List<ChainHashViolation> violations;
  final String? message;
}

enum VerifyOutcome {
  ok,
  chainHashMismatch,
  anchorMissing,
  anchorTerminalMismatch,
  blobUnavailable,
  blobEvidenceMismatch,
}

class AuditAnchorOrchestrator {
  const AuditAnchorOrchestrator({
    required AuditChainReader reader,
    required AuditChainAnchorWriter anchorWriter,
    required AuditAnchorBlobClient blobClient,
    required String containerName,
    AuditChainHasher hasher = const AuditChainHasher(),
    AnchorEvidenceCodec codec = const AnchorEvidenceCodec(),
  }) : _reader = reader,
       _anchorWriter = anchorWriter,
       _blobClient = blobClient,
       _containerName = containerName,
       _hasher = hasher,
       _codec = codec;

  final AuditChainReader _reader;
  final AuditChainAnchorWriter _anchorWriter;
  final AuditAnchorBlobClient _blobClient;
  final String _containerName;
  final AuditChainHasher _hasher;
  final AnchorEvidenceCodec _codec;

  /// Anchors every unanchored completed chain for `operatorId` whose
  /// `chain_date < asOfUtc`. Returns one [AnchorRunResult] per chain
  /// considered (so the CLI can print a per-chain status line).
  Future<List<AnchorRunResult>> runAnchor({
    required String operatorId,
    required DateTime asOfUtc,
    required DateTime nowUtc,
  }) async {
    final summaries = await _reader.findUnanchoredCompletedChains(
      operatorId: operatorId,
      asOfUtc: asOfUtc,
    );
    final results = <AnchorRunResult>[];
    for (final summary in summaries) {
      results.add(await _anchorOne(summary, nowUtc: nowUtc));
    }
    return results;
  }

  /// L9 startup crash-recovery sweep.
  ///
  /// Drives a deterministic recovery pass for the case where a prior
  /// run wrote the immutable Azure Blob but crashed before inserting
  /// the matching `audit_chain_anchors` row (a "writing" sentinel —
  /// the table is append-only, so there is no in-progress row to
  /// transition; instead the recovery sentinel is the orphan blob).
  ///
  /// For every unanchored completed chain found by
  /// [AuditChainReader.findUnanchoredCompletedChains], the recovery
  /// path attempts a [AuditAnchorBlobClient.readImmutable] probe at
  /// the deterministic blob name [anchorBlobName]:
  ///
  ///   * Blob exists and the recomputed chain hash prefix matches the
  ///     blob evidence's terminal — emit
  ///     [AnchorOutcome.recoveredCommitted] and insert the missing
  ///     anchor row using the blob's original `anchored_at`.
  ///
  ///   * Blob exists and disagrees with the in-DB chain (terminal
  ///     hash, terminal id, row count, operator/date envelope) — emit
  ///     [AnchorOutcome.recoveredFailed]. No anchor row is inserted;
  ///     the chain stays unanchored, the result surfaces for runbook
  ///     escalation.
  ///
  ///   * Blob does not exist — recovery has nothing to do for this
  ///     chain; the regular `runAnchor` pass will write it on the next
  ///     forward sweep. No result is emitted.
  ///
  ///   * Blob probe fails for transport / availability reasons (Azure
  ///     unreachable) — bubbles [AuditAnchorBlobUnavailable] to the
  ///     caller; the CLI surfaces a runtime error and skips the
  ///     forward sweep until Azure is reachable.
  ///
  /// Determinism: every decision reads only from the in-DB chain and
  /// the immutable blob; no human intervention. Idempotent: a recovery
  /// sweep that finds no orphan blobs returns an empty list and is a
  /// safe no-op.
  Future<List<AnchorRunResult>> runStartupRecovery({
    required String operatorId,
    required DateTime asOfUtc,
  }) async {
    final summaries = await _reader.findUnanchoredCompletedChains(
      operatorId: operatorId,
      asOfUtc: asOfUtc,
    );
    final results = <AnchorRunResult>[];
    for (final summary in summaries) {
      final result = await _recoverOne(summary);
      if (result != null) {
        results.add(result);
      }
    }
    return results;
  }

  Future<AnchorRunResult?> _recoverOne(AuditChainSummary summary) async {
    final blobName = anchorBlobName(
      operatorId: summary.operatorId,
      chainDate: summary.chainDate,
    );
    AnchorBlobReadResult existing;
    try {
      existing = await _blobClient.readImmutable(
        containerName: _containerName,
        blobName: blobName,
      );
    } on AuditAnchorBlobUnavailable catch (error) {
      // 404-shaped errors come back as AuditAnchorBlobUnavailable.
      // For startup recovery we treat "blob not found" as "nothing to
      // recover for this chain"; transport failures still surface so
      // the operator can see Azure is unreachable. The reason string
      // is the only signal we have — match the live client's 404
      // message verbatim and the test fake's contract exactly.
      if (_isBlobNotFound(error)) {
        return null;
      }
      rethrow;
    }
    final rows = await _reader.readChainRows(
      operatorId: summary.operatorId,
      chainDate: summary.chainDate,
    );
    if (rows.isEmpty) {
      // Orphan blob with no in-DB chain — forensic alert. Refuse to
      // insert an anchor; surface for runbook triage.
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.recoveredFailed,
        message:
            'recovery: immutable blob exists but in-DB chain is empty '
            'for $blobName; refusing to insert anchor row; see '
            'runbooks/audit_chain_verify_runbook.md',
      );
    }
    // Recompute the chain prefix. If the in-DB chain is internally
    // inconsistent we treat that as a failed recovery — runbook
    // escalation, no anchor row written.
    final violations = _hasher.verifyChain(rows);
    if (violations.isNotEmpty) {
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.recoveredFailed,
        violations: violations,
        message:
            'recovery: in-DB chain failed self-verification; refusing '
            'to insert anchor row even though an immutable blob '
            'exists at $blobName',
      );
    }
    final terminal = rows.last;
    final AnchorEvidence evidence;
    try {
      evidence = _codec.decode(existing.bytes);
    } on FormatException catch (error) {
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.recoveredFailed,
        message:
            'recovery: immutable blob at $blobName is not parseable '
            'evidence ($error); refusing to insert anchor row',
      );
    }
    final mismatch = _checkRecoveryEvidence(
      evidence: evidence,
      terminal: terminal,
      rowCount: BigInt.from(rows.length),
      chainDate: summary.chainDate,
      operatorId: summary.operatorId,
    );
    if (mismatch != null) {
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.recoveredFailed,
        message:
            'recovery: existing immutable blob disagrees with current '
            'in-DB chain — refusing to insert anchor row; $mismatch; '
            'see runbooks/audit_chain_verify_runbook.md',
      );
    }
    // Hash chain prefix matches evidence. Stamp the anchor row using
    // the blob's *original* anchored_at so the recovered row remains
    // forensically faithful to the run that produced the immutable
    // evidence.
    final anchor = AuditChainAnchor(
      operatorId: summary.operatorId,
      chainDate: summary.chainDate,
      terminalRowHash: terminal.rowHash,
      terminalRowId: terminal.id,
      rowCount: BigInt.from(rows.length),
      // The probe path doesn't carry the live PUT URI — the blob
      // name + container endpoint reproduces a stable handle that
      // future verifier reads route through the deterministic blob
      // name regardless. Verifier compares ETags, not URI strings.
      blobUri: _blobUriFor(
        containerName: _containerName,
        blobName: blobName,
      ),
      blobEtag: existing.etag,
      anchoredAt: evidence.anchoredAt,
    );
    await _anchorWriter.insertAnchor(anchor);
    return AnchorRunResult(
      operatorId: summary.operatorId,
      chainDate: summary.chainDate,
      outcome: AnchorOutcome.recoveredCommitted,
      anchor: anchor,
      message:
          'recovery: existing immutable blob agrees with in-DB '
          'chain — inserted anchor row with original anchored_at '
          '${evidence.anchoredAt.toIso8601String()}',
    );
  }

  /// Reproduces the URI shape the Azure Blob client returns for a
  /// successful PUT (`<endpoint>/<container>/<blob>`). The recovery
  /// path does not have the live PUT response, so the URI is
  /// reconstructed from the deterministic blob name. Used only when
  /// the breadcrumb columns are populated on insert. Endpoint is not
  /// known at orchestrator scope so the URI is a relative path; the
  /// verifier compares ETags, not URI strings.
  String _blobUriFor({
    required String containerName,
    required String blobName,
  }) =>
      '$containerName/$blobName';

  bool _isBlobNotFound(AuditAnchorBlobUnavailable error) {
    final reason = error.reason.toLowerCase();
    return reason.contains('404') ||
        reason.contains('not found') ||
        reason.contains('not preloaded');
  }

  Future<AnchorRunResult> _anchorOne(
    AuditChainSummary summary, {
    required DateTime nowUtc,
  }) async {
    final rows = await _reader.readChainRows(
      operatorId: summary.operatorId,
      chainDate: summary.chainDate,
    );
    if (rows.isEmpty) {
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.empty,
        message: 'no rows in (operator_id, chain_date)',
      );
    }
    final violations = _hasher.verifyChain(rows);
    if (violations.isNotEmpty) {
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.chainHashMismatch,
        violations: violations,
        message: 'self-verification failed; refusing to anchor',
      );
    }
    final terminal = rows.last;
    final evidence = AnchorEvidence(
      schemaVersion: 1,
      operatorId: summary.operatorId,
      chainDate: summary.chainDate,
      terminalRowId: terminal.id,
      terminalRowHashHex: _hex(terminal.rowHash),
      rowCount: BigInt.from(rows.length),
      anchoredAt: nowUtc,
    );
    final bytes = _codec.encode(evidence);
    final blobName = anchorBlobName(
      operatorId: summary.operatorId,
      chainDate: summary.chainDate,
    );
    try {
      final write = await _blobClient.writeImmutable(
        containerName: _containerName,
        blobName: blobName,
        evidenceBytes: bytes,
      );
      final anchor = AuditChainAnchor(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        terminalRowHash: terminal.rowHash,
        terminalRowId: terminal.id,
        rowCount: BigInt.from(rows.length),
        blobUri: write.uri,
        blobEtag: write.etag,
        anchoredAt: nowUtc,
      );
      await _anchorWriter.insertAnchor(anchor);
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.anchored,
        anchor: anchor,
      );
    } on AuditAnchorBlobAlreadyAnchored catch (existing) {
      // The immutable blob already exists for this chain — almost
      // certainly a previous run wrote the blob and crashed before the
      // audit_chain_anchors INSERT committed. Validate the live
      // evidence against the current in-DB chain terminal; if it
      // matches, complete the anchor by inserting the missing row
      // with the blob's *original* anchored_at. If it does not match,
      // surface a chain-hash-mismatch result for runbook escalation
      // (the immutable blob disagrees with the current chain — this
      // is forensic-grade tampering or a real chain hash drift, never
      // routine recovery).
      final existingEvidence = _codec.decode(existing.evidenceBytes);
      final mismatch = _checkRecoveryEvidence(
        evidence: existingEvidence,
        terminal: terminal,
        rowCount: BigInt.from(rows.length),
        chainDate: summary.chainDate,
        operatorId: summary.operatorId,
      );
      if (mismatch != null) {
        return AnchorRunResult(
          operatorId: summary.operatorId,
          chainDate: summary.chainDate,
          outcome: AnchorOutcome.chainHashMismatch,
          message:
              'existing immutable blob disagrees with current in-DB '
              'chain — refusing to insert anchor row; $mismatch; '
              'see runbooks/audit_chain_verify_runbook.md',
        );
      }
      final anchor = AuditChainAnchor(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        terminalRowHash: terminal.rowHash,
        terminalRowId: terminal.id,
        rowCount: BigInt.from(rows.length),
        blobUri: existing.uri,
        blobEtag: existing.etag,
        anchoredAt: existingEvidence.anchoredAt,
      );
      await _anchorWriter.insertAnchor(anchor);
      return AnchorRunResult(
        operatorId: summary.operatorId,
        chainDate: summary.chainDate,
        outcome: AnchorOutcome.alreadyAnchored,
        anchor: anchor,
        message:
            'recovered: existing immutable blob anchored '
            '${existingEvidence.anchoredAt.toIso8601String()}',
      );
    }
  }

  /// Compares an existing-blob evidence envelope against the current
  /// in-DB chain terminal. Returns a single-line mismatch description
  /// for the first axis that disagrees, or `null` when every checked
  /// field matches. Used only on the recovery path
  /// ([AuditAnchorBlobAlreadyAnchored]) to decide between idempotent
  /// completion and forensic escalation.
  String? _checkRecoveryEvidence({
    required AnchorEvidence evidence,
    required AuditLogRow terminal,
    required BigInt rowCount,
    required DateTime chainDate,
    required String operatorId,
  }) {
    if (evidence.schemaVersion != 1) {
      return 'evidence schema_version=${evidence.schemaVersion} '
          '(expected 1)';
    }
    if (evidence.operatorId.toLowerCase() != operatorId.toLowerCase()) {
      return 'evidence operator_id=${evidence.operatorId} '
          '(expected $operatorId)';
    }
    if (!_dateEquals(evidence.chainDate, chainDate)) {
      return 'evidence chain_date='
          '${_formatChainDate(evidence.chainDate)} '
          '(expected ${_formatChainDate(chainDate)})';
    }
    if (evidence.terminalRowId != terminal.id) {
      return 'evidence terminal_row_id=${evidence.terminalRowId} '
          '(expected ${terminal.id})';
    }
    if (evidence.terminalRowHashHex != _hex(terminal.rowHash)) {
      return 'evidence terminal_row_hash_hex disagrees with current '
          'in-DB terminal row_hash';
    }
    if (evidence.rowCount != rowCount) {
      return 'evidence row_count=${evidence.rowCount} '
          '(expected $rowCount)';
    }
    return null;
  }

  /// Verifies one `(operator_id, chain_date)` chain against the DB
  /// row-by-row hash, the existing anchor row, and the Blob evidence.
  Future<VerifyRunResult> runVerify({
    required String operatorId,
    required DateTime chainDate,
  }) async {
    final rows = await _reader.readChainRows(
      operatorId: operatorId,
      chainDate: chainDate,
    );
    final violations = _hasher.verifyChain(rows);
    if (violations.isNotEmpty) {
      return VerifyRunResult(
        operatorId: operatorId,
        chainDate: chainDate,
        outcome: VerifyOutcome.chainHashMismatch,
        violations: violations,
        message: 'in-DB chain failed self-verification; escalate per runbook',
      );
    }
    final anchor = await _reader.readAnchor(
      operatorId: operatorId,
      chainDate: chainDate,
    );
    if (anchor == null) {
      // L9 rollforward path: before reporting anchorMissing, probe
      // the deterministic blob URL. A previous sweep run may have
      // written the immutable Blob but crashed before inserting the
      // audit_chain_anchors row. If the blob exists and the recovered
      // chain matches, insert the missing anchor row so this verify run
      // and all subsequent runs report ok instead of anchorMissing.
      final blobNameForRollforward = anchorBlobName(
        operatorId: operatorId,
        chainDate: chainDate,
      );
      AnchorBlobReadResult rollforwardRead;
      try {
        rollforwardRead = await _blobClient.readImmutable(
          containerName: _containerName,
          blobName: blobNameForRollforward,
        );
      } on AuditAnchorBlobUnavailable catch (error) {
        // Blob unreachable: could be a genuine 404 (never written) or a
        // transport failure. Either way, we report blobUnavailable so the
        // operator knows the anchor is missing AND the blob is not reachable
        // — distinct from a pure anchorMissing where the blob has not been
        // probed yet.
        return VerifyRunResult(
          operatorId: operatorId,
          chainDate: chainDate,
          outcome: VerifyOutcome.blobUnavailable,
          message:
              'no audit_chain_anchors row and blob probe failed '
              '(rollforward not possible): ${error.reason}',
        );
      }
      // Blob is reachable. Validate its evidence against the current
      // in-DB chain terminal. If it agrees → insert the missing anchor
      // row and continue verification as normal. If it disagrees →
      // report anchorMissing with an explicit "rollforward refused"
      // message so the runbook operator knows to escalate rather than
      // retry blindly.
      if (rows.isEmpty) {
        // Orphan blob with no in-DB chain rows. Refuse rollforward.
        return VerifyRunResult(
          operatorId: operatorId,
          chainDate: chainDate,
          outcome: VerifyOutcome.anchorMissing,
          message:
              'rollforward refused: no audit_chain_anchors row and '
              'in-DB chain is empty; an immutable blob exists at '
              '$blobNameForRollforward but there are no chain rows to '
              'verify it against; see runbooks/audit_chain_verify_runbook.md',
        );
      }
      final AnchorEvidence rollforwardEvidence;
      try {
        rollforwardEvidence = _codec.decode(rollforwardRead.bytes);
      } on FormatException catch (error) {
        return VerifyRunResult(
          operatorId: operatorId,
          chainDate: chainDate,
          outcome: VerifyOutcome.anchorMissing,
          message:
              'rollforward refused: no audit_chain_anchors row and '
              'blob at $blobNameForRollforward is not parseable '
              'evidence ($error); see runbooks/audit_chain_verify_runbook.md',
        );
      }
      final terminalForRollforward = rows.last;
      final rollforwardMismatch = _checkRecoveryEvidence(
        evidence: rollforwardEvidence,
        terminal: terminalForRollforward,
        rowCount: BigInt.from(rows.length),
        chainDate: chainDate,
        operatorId: operatorId,
      );
      if (rollforwardMismatch != null) {
        // Blob exists but disagrees with the chain. Refuse to insert.
        return VerifyRunResult(
          operatorId: operatorId,
          chainDate: chainDate,
          outcome: VerifyOutcome.anchorMissing,
          message:
              'rollforward refused: immutable blob at '
              '$blobNameForRollforward disagrees with the current '
              'in-DB chain — $rollforwardMismatch; '
              'see runbooks/audit_chain_verify_runbook.md',
        );
      }
      // Blob agrees. Insert the missing anchor row using the blob's
      // original anchored_at so the recovered row is forensically
      // faithful to the run that produced the evidence.
      final recoveredAnchor = AuditChainAnchor(
        operatorId: operatorId,
        chainDate: chainDate,
        terminalRowHash: terminalForRollforward.rowHash,
        terminalRowId: terminalForRollforward.id,
        rowCount: BigInt.from(rows.length),
        blobUri: _blobUriFor(
          containerName: _containerName,
          blobName: blobNameForRollforward,
        ),
        blobEtag: rollforwardRead.etag,
        anchoredAt: rollforwardEvidence.anchoredAt,
      );
      await _anchorWriter.insertAnchor(recoveredAnchor);
      // Fall through to the normal verify path using the recovered anchor.
      return VerifyRunResult(
        operatorId: operatorId,
        chainDate: chainDate,
        outcome: VerifyOutcome.ok,
        message:
            'rollforward committed: missing anchor row recovered from '
            'immutable blob at $blobNameForRollforward '
            '(original anchored_at '
            '${rollforwardEvidence.anchoredAt.toIso8601String()})',
      );
    }
    final terminal = rows.isNotEmpty ? rows.last : null;
    if (terminal == null ||
        !_byteEquals(anchor.terminalRowHash, terminal.rowHash)) {
      return VerifyRunResult(
        operatorId: operatorId,
        chainDate: chainDate,
        outcome: VerifyOutcome.anchorTerminalMismatch,
        message:
            'anchor terminal_row_hash does not match in-DB '
            'chain terminal hash',
      );
    }
    final blobName = anchorBlobName(
      operatorId: operatorId,
      chainDate: chainDate,
    );
    AnchorBlobReadResult read;
    try {
      read = await _blobClient.readImmutable(
        containerName: _containerName,
        blobName: blobName,
      );
    } on AuditAnchorBlobUnavailable catch (error) {
      return VerifyRunResult(
        operatorId: operatorId,
        chainDate: chainDate,
        outcome: VerifyOutcome.blobUnavailable,
        message: error.reason,
      );
    }
    if (read.etag != anchor.blobEtag) {
      return VerifyRunResult(
        operatorId: operatorId,
        chainDate: chainDate,
        outcome: VerifyOutcome.blobEvidenceMismatch,
        message: 'Blob ETag does not match anchor.blob_etag',
      );
    }
    final evidence = _codec.decode(read.bytes);
    final envelopeMismatch = _checkEvidenceEnvelope(
      evidence: evidence,
      requestedOperatorId: operatorId,
      requestedChainDate: chainDate,
      anchor: anchor,
    );
    if (envelopeMismatch != null) {
      return VerifyRunResult(
        operatorId: operatorId,
        chainDate: chainDate,
        outcome: VerifyOutcome.blobEvidenceMismatch,
        message: envelopeMismatch,
      );
    }
    return VerifyRunResult(
      operatorId: operatorId,
      chainDate: chainDate,
      outcome: VerifyOutcome.ok,
    );
  }

  /// Compares every field of the Blob evidence envelope against the
  /// caller's request and the in-DB anchor row. Returns a
  /// human-readable mismatch description for the first discrepancy
  /// found, or `null` when everything agrees.
  ///
  /// Why every field matters: a Blob body whose `terminal_row_hash`
  /// happens to match by accident (collision or stale evidence body)
  /// could still hide a misrouted anchor, a backdated chain date, a
  /// row-count discrepancy, or a schema-version drift. The runbook
  /// (`runbooks/audit_chain_verify_runbook.md`) documents triage for
  /// each axis; the verifier surfaces the specific axis through
  /// [VerifyRunResult.message] so the operator can match the runbook
  /// section without reading the body bytes.
  String? _checkEvidenceEnvelope({
    required AnchorEvidence evidence,
    required String requestedOperatorId,
    required DateTime requestedChainDate,
    required AuditChainAnchor anchor,
  }) {
    if (evidence.schemaVersion != 1) {
      return 'Blob evidence schema_version=${evidence.schemaVersion} '
          'is not the supported schema (expected 1)';
    }
    if (evidence.operatorId.toLowerCase() !=
        requestedOperatorId.toLowerCase()) {
      return 'Blob evidence operator_id (${evidence.operatorId}) does '
          'not match requested operator_id ($requestedOperatorId)';
    }
    if (evidence.operatorId.toLowerCase() != anchor.operatorId.toLowerCase()) {
      return 'Blob evidence operator_id (${evidence.operatorId}) does '
          'not match audit_chain_anchors.operator_id '
          '(${anchor.operatorId})';
    }
    if (!_dateEquals(evidence.chainDate, requestedChainDate)) {
      return 'Blob evidence chain_date '
          '(${_formatChainDate(evidence.chainDate)}) does not match '
          'requested chain_date '
          '(${_formatChainDate(requestedChainDate)})';
    }
    if (!_dateEquals(evidence.chainDate, anchor.chainDate)) {
      return 'Blob evidence chain_date '
          '(${_formatChainDate(evidence.chainDate)}) does not match '
          'audit_chain_anchors.chain_date '
          '(${_formatChainDate(anchor.chainDate)})';
    }
    if (evidence.terminalRowId != anchor.terminalRowId) {
      return 'Blob evidence terminal_row_id (${evidence.terminalRowId}) '
          'does not match audit_chain_anchors.terminal_row_id '
          '(${anchor.terminalRowId})';
    }
    if (evidence.terminalRowHashHex != _hex(anchor.terminalRowHash)) {
      return 'Blob evidence terminal_row_hash_hex disagrees with '
          'audit_chain_anchors.terminal_row_hash';
    }
    if (evidence.rowCount != anchor.rowCount) {
      return 'Blob evidence row_count (${evidence.rowCount}) does not '
          'match audit_chain_anchors.row_count (${anchor.rowCount})';
    }
    if (!evidence.anchoredAt.toUtc().isAtSameMomentAs(
      anchor.anchoredAt.toUtc(),
    )) {
      return 'Blob evidence anchored_at '
          '(${evidence.anchoredAt.toIso8601String()}) does not match '
          'audit_chain_anchors.anchored_at '
          '(${anchor.anchoredAt.toIso8601String()})';
    }
    return null;
  }
}

bool _dateEquals(DateTime a, DateTime b) {
  final aUtc = a.toUtc();
  final bUtc = b.toUtc();
  return aUtc.year == bUtc.year &&
      aUtc.month == bUtc.month &&
      aUtc.day == bUtc.day;
}

String _hex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
