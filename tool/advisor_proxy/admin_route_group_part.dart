// Forge & Flow advisor proxy — admin route group (part of advisor_proxy.dart).
//
// chore(advisor-proxy): pure size refactor. This part file holds a
// cohesive group of admin route handlers (corpus / debug-console /
// observability / feature-flags / graph-candidates) mechanically
// lifted out of `advisor_proxy.dart` so the monolith stays under the
// `kAdvisorProxyMaxLines` bleed-stop ceiling enforced by
// `tool/advisor_proxy_size_lint.dart`. It is a Dart `part` of the
// `advisor_proxy.dart` library: it shares that library's imports and
// private scope verbatim, so the move is behavior byte-identical —
// routing, request/response shapes, status codes, error handling,
// idempotency, RLS, auth, and SQL are all unchanged. No symbol was
// renamed; every helper reference resolves through the shared library
// scope exactly as before. New routes still belong in their own
// decomposed route files per the seam map, not here.

part of 'advisor_proxy.dart';

Future<void> _routeCorpusAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required CorpusAdminProxyGateway gateway,
  required String actorUserId,
  required String idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.corpus.$method:$actorUserId';

  if (method == 'GET' && path == adminCorpusVersionsPath) {
    final versions = await gateway.listVersions(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, <String, Object?>{'versions': versions});
    return;
  }

  if (method == 'GET' && path.startsWith(adminCorpusVersionsPrefix)) {
    final tail = _pathSuffix(path, adminCorpusVersionsPrefix);
    if (tail == null || tail.contains('/')) {
      _writeNotFound(response, request);
      return;
    }
    final bundle = await gateway.fetchVersion(
      actorUserId: actorUserId,
      versionId: tail,
      adminReason: '$reasonPrefix:fetch:$tail',
    );
    if (bundle == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_version',
        'message': 'corpus version not found',
      });
      return;
    }
    _writeJson(response, 200, bundle);
    return;
  }

  if (method == 'POST' &&
      (path == adminCorpusPreviewDiffPath || path == adminCorpusUploadPath)) {
    final fileName = _requireBodyString(body, 'file_name');
    final contentType = _requireBodyString(body, 'content_type');
    final base64 = _requireBodyString(body, 'content_base64');
    List<int> bytes;
    try {
      bytes = const Base64Decoder().convert(base64);
    } on FormatException {
      // A3.4: `Base64Decoder().convert` throws only `FormatException` on
      // malformed input — narrowest possible typing; `Error`s propagate
      // per C4.
      throw const _AdminInputError(
        statusCode: 400,
        code: 'invalid_content_base64',
        message: 'content_base64 is not a valid base64 payload',
      );
    }
    final result = await gateway.previewDiff(
      actorUserId: actorUserId,
      fileName: fileName,
      contentType: contentType,
      bytes: bytes,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:preview_diff:$fileName',
    );
    _writeJson(response, 200, result);
    return;
  }

  if (method == 'POST' && path == adminCorpusCommitPath) {
    final previewToken = _requireBodyString(body, 'preview_token');
    final summary = _optionalBodyString(body, 'summary') ?? '';
    final result = await gateway.commitVersion(
      actorUserId: actorUserId,
      previewToken: previewToken,
      summary: summary,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:commit:$previewToken',
    );
    _writeJson(response, 200, <String, Object?>{'version': result});
    return;
  }

  if (method == 'POST' && path == adminCorpusRollbackPath) {
    final targetVersionId = _requireBodyString(body, 'target_version_id');
    final summary = _optionalBodyString(body, 'summary') ?? '';
    final result = await gateway.rollbackVersion(
      actorUserId: actorUserId,
      targetVersionId: targetVersionId,
      summary: summary,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:rollback:$targetVersionId',
    );
    if (result == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_version',
        'message': 'rollback target version not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'version': result});
    return;
  }

  _writeNotFound(response, request);
}

bool _isAdminDebugPath(String path) {
  return path == adminDebugRequestsPath ||
      path == adminDebugRequestByIdPath ||
      path == adminDebugRequestByKeyPath ||
      path == adminDebugRequestsTailPath ||
      path == adminDebugFullContentOptInsPath ||
      path == adminDebugRelationshipHelpPath ||
      path == adminDebugAccountHelpPath;
}

bool _isAdminDebugOperation(String path, String method) {
  if (method != 'GET') return false;
  return _isAdminDebugPath(path);
}

Future<void> _routeDebugConsoleAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required DebugConsoleAdminProxyGateway gateway,
  required String actorUserId,
  required bool includeFullContent,
}) async {
  final params = request.uri.queryParameters;
  final repeatedLocationIds = _nonBlankStrings(
    request.uri.queryParametersAll['location_id'],
  );
  final scopedLocationIds = repeatedLocationIds.length > 1
      ? repeatedLocationIds
      : _commaSeparatedQueryList(params['location_ids']);
  final scopedLocationId = repeatedLocationIds.length > 1
      ? null
      : _nonBlankString(params['location_id']);
  final reasonPrefix = 'admin.debug.GET:$actorUserId';

  if (path == adminDebugRelationshipHelpPath ||
      path == adminDebugAccountHelpPath) {
    final allowedUsageClasses = path == adminDebugRelationshipHelpPath
        ? kDebugRelationshipHelpUsageClasses
        : kDebugAccountHelpUsageClasses;
    final supportUseCase = _nonBlankString(params['support_use_case']);
    if (supportUseCase != null &&
        !allowedUsageClasses.contains(supportUseCase)) {
      _writeJson(response, 400, <String, Object?>{
        'error': 'invalid_support_use_case',
        'message': 'support_use_case is not valid for this support-log tab',
        'allowed': allowedUsageClasses.toList(growable: false)..sort(),
      });
      return;
    }
    final limit = _clampedQueryInt(
      params['limit'],
      defaultValue: 100,
      min: 1,
      max: 100,
    );
    final rows = await _debugRowsBySupportHelpUsage(
      gateway: gateway,
      actorUserId: actorUserId,
      adminReason:
          '$reasonPrefix:${path == adminDebugRelationshipHelpPath ? 'relationship_help' : 'account_help'}',
      operatorId: _nonBlankString(params['operator_id']),
      locationId: scopedLocationId,
      locationIds: scopedLocationIds.isEmpty ? null : scopedLocationIds,
      allowedUsageClasses: allowedUsageClasses,
      supportUseCase: supportUseCase,
      status: _nonBlankString(params['status']),
      timeWindowSeconds: _optionalClampedQueryInt(
        params['time_window_seconds'],
        min: 1,
        max: 604800,
      ),
      searchText: _nonBlankString(params['q']),
      limit: limit,
      includeFullContent: includeFullContent,
    );
    _writeJson(response, 200, <String, Object?>{
      'requests': rows,
      'support_use_cases': allowedUsageClasses.toList(growable: false)..sort(),
    });
    return;
  }

  if (path == adminDebugRequestsPath) {
    final rows = await gateway.listRequests(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
      operatorId: _nonBlankString(params['operator_id']),
      locationId: scopedLocationId,
      locationIds: scopedLocationIds.isEmpty ? null : scopedLocationIds,
      usageClass: _nonBlankString(params['usage_class']),
      status: _nonBlankString(params['status']),
      timeWindowSeconds: _optionalClampedQueryInt(
        params['time_window_seconds'],
        min: 1,
        max: 604800,
      ),
      searchText: _nonBlankString(params['q']),
      limit: _clampedQueryInt(
        params['limit'],
        defaultValue: 100,
        min: 1,
        max: 100,
      ),
      includeFullContent: includeFullContent,
    );
    _writeJson(response, 200, <String, Object?>{'requests': rows});
    return;
  }

  if (path == adminDebugRequestsTailPath) {
    final rows = await gateway.tailRecent(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:tail',
      limit: _clampedQueryInt(
        params['limit'],
        defaultValue: 25,
        min: 1,
        max: 100,
      ),
      includeFullContent: includeFullContent,
    );
    _writeJson(response, 200, <String, Object?>{'requests': rows});
    return;
  }

  if (path == adminDebugRequestByIdPath) {
    final requestId = _requireQueryString(params, 'request_id');
    final row = await gateway.getByRequestId(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:by_id:$requestId',
      requestId: requestId,
      includeFullContent: includeFullContent,
    );
    if (row == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_request',
        'message': 'request_id was not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'request': row});
    return;
  }

  if (path == adminDebugRequestByKeyPath) {
    final idempotencyKey = _requireQueryString(params, 'idempotency_key');
    final row = await gateway.getByIdempotencyKey(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:by_key',
      idempotencyKey: idempotencyKey,
      includeFullContent: includeFullContent,
    );
    if (row == null) {
      _writeJson(response, 404, <String, Object?>{
        'error': 'unknown_request',
        'message': 'idempotency_key was not found',
      });
      return;
    }
    _writeJson(response, 200, <String, Object?>{'request': row});
    return;
  }

  if (path == adminDebugFullContentOptInsPath) {
    final rows = await gateway.listFullContentOptIns(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:opt_ins',
    );
    _writeJson(response, 200, <String, Object?>{'opt_ins': rows});
    return;
  }

  _writeNotFound(response, request);
}

Future<List<Map<String, Object?>>> _debugRowsBySupportHelpUsage({
  required DebugConsoleAdminProxyGateway gateway,
  required String actorUserId,
  required String adminReason,
  required String? operatorId,
  required String? locationId,
  required List<String>? locationIds,
  required Set<String> allowedUsageClasses,
  required String? supportUseCase,
  required String? status,
  required int? timeWindowSeconds,
  required String? searchText,
  required int limit,
  required bool includeFullContent,
}) async {
  final usageClasses = supportUseCase == null
      ? (allowedUsageClasses.toList(growable: false)..sort())
      : <String>[supportUseCase];
  final byRequestId = <String, Map<String, Object?>>{};
  for (final usageClass in usageClasses) {
    final rows = await gateway.listRequests(
      actorUserId: actorUserId,
      adminReason: '$adminReason:$usageClass',
      operatorId: operatorId,
      locationId: locationId,
      locationIds: locationIds,
      usageClass: usageClass,
      status: status,
      timeWindowSeconds: timeWindowSeconds,
      searchText: searchText,
      limit: limit,
      includeFullContent: includeFullContent,
    );
    for (final row in rows) {
      final requestId = row['request_id']?.toString();
      if (requestId == null || requestId.isEmpty) continue;
      byRequestId[requestId] = row;
    }
  }
  final merged = byRequestId.values.toList(growable: false)
    ..sort((a, b) {
      final bTime = _debugStartedAtSortValue(b);
      final aTime = _debugStartedAtSortValue(a);
      return bTime.compareTo(aTime);
    });
  return merged.length > limit ? merged.sublist(0, limit) : merged;
}

int _debugStartedAtSortValue(Map<String, Object?> row) {
  final raw = row['started_at'];
  if (raw is DateTime) return raw.toUtc().microsecondsSinceEpoch;
  if (raw is String) {
    return DateTime.tryParse(raw)?.toUtc().microsecondsSinceEpoch ?? 0;
  }
  return 0;
}

bool _isAdminObservabilityPath(String path) => path == adminObservabilityPath;

bool _isAdminObservabilityOperation(String path, String method) {
  return method == 'GET' && path == adminObservabilityPath;
}

Future<void> _routeObservabilityAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required ObservabilityAdminProxyGateway gateway,
  required String actorUserId,
}) async {
  if (path != adminObservabilityPath) {
    _writeNotFound(response, request);
    return;
  }
  final params = request.uri.queryParameters;
  final repeatedLocationIds = _nonBlankStrings(
    request.uri.queryParametersAll['location_id'],
  );
  final scopedLocationIds = repeatedLocationIds.length > 1
      ? repeatedLocationIds
      : _commaSeparatedQueryList(params['location_ids']);
  final scopedLocationId = repeatedLocationIds.length > 1
      ? null
      : _nonBlankString(params['location_id']);
  final limit = _clampedQueryInt(
    params['cost_telemetry_limit'],
    defaultValue: 100,
    min: 1,
    max: 100,
  );
  // `usage_logs` is a monthly rollup, so the only honest cost windows
  // are the current calendar month and the immediately preceding one.
  // `parseObservabilityMonth` maps `current`/`previous` to their enum
  // cases and clamps a missing or unrecognized value to `current` — an
  // unknown `month=` value can never widen the cost surfaces beyond one
  // honest month.
  final month = parseObservabilityMonth(params['month']);
  final payload = await gateway.fetch(
    actorUserId: actorUserId,
    adminReason: 'admin.observability.GET:$actorUserId:fetch',
    costTelemetryLimit: limit,
    queryClassFilter: _nonBlankString(params['query_class']),
    operatorId: _nonBlankString(params['operator_id']),
    locationId: scopedLocationId,
    locationIds: scopedLocationIds.isEmpty ? null : scopedLocationIds,
    month: month,
  );
  _writeJson(response, 200, payload);
}

bool _isAdminFeatureFlagsPath(String path) {
  return path == adminFeatureFlagsListPath ||
      path == adminFeatureFlagsTogglePath;
}

bool _isAdminFeatureFlagsOperation(String path, String method) {
  if (method == 'GET' && path == adminFeatureFlagsListPath) return true;
  if (method == 'POST' && path == adminFeatureFlagsTogglePath) return true;
  return false;
}

Future<void> _routeFeatureFlagsAdmin({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required FeatureFlagsAdminProxyGateway gateway,
  required String actorUserId,
  required String idempotencyKey,
  required Map<String, Object?> body,
  AdminRequestIdempotencyStore? idempotencyStore,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.feature_flags.$method:$actorUserId';

  if (method == 'GET' && path == adminFeatureFlagsListPath) {
    final params = request.uri.queryParameters;
    final flags = await gateway.listFlags(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
      operatorId: _nonBlankString(params['operator_id']),
      locationId: _nonBlankString(params['location_id']),
      locationIds: _commaSeparatedQueryList(params['location_ids']),
    );
    _writeJson(response, 200, <String, Object?>{'flags': flags});
    return;
  }

  if (method == 'POST' && path == adminFeatureFlagsTogglePath) {
    final flagId = _requireBodyString(body, 'flag_id');
    final enabledRaw = body['enabled'];
    if (enabledRaw is! bool) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'missing_enabled',
        message: 'enabled boolean is required',
      );
    }
    // HARD-B - optional operator-supplied rationale for the toggle.
    // Capped at 500 chars per the contract; longer values are
    // rejected at the route boundary so the audit row never carries
    // an unbounded blob. The check uses the raw body value (not
    // _nonBlankString) so a caller can explicitly pass an empty
    // string to mean "no rationale" without a 400.
    final reasonRaw = body['reason'];
    if (reasonRaw != null && reasonRaw is! String) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'invalid_reason',
        message: 'reason must be a string when present',
      );
    }
    if (reasonRaw is String && reasonRaw.length > 500) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'reason_too_long',
        message: 'reason must be 500 characters or fewer',
      );
    }
    final reason = reasonRaw is String ? reasonRaw.trim() : null;
    final reasonForAudit = reason == null || reason.isEmpty ? null : reason;

    // HARD-H idempotency wrap. When an idempotency store is wired the
    // route reserves the key + body hash, runs the gateway exactly
    // once, and returns the cached response on retry. When no store is
    // wired (older deploys / unit tests) the route degrades to the
    // legacy direct-delegate behavior — `_isAdminFeatureFlagsOperation`
    // already enforces the Idempotency-Key header is present, so the
    // observability story (every retry has a key in the audit
    // payload) is preserved. The body hash includes HARD-B's `reason`
    // (via the canonical sorted-key encoding in `_hashRequestBody`),
    // so a retry that changes the rationale is treated as a new
    // request body — matching the gateway-side
    // `FeatureFlagToggleIdempotencyCache` contract.
    const requestType = 'admin.feature_flags.toggle';
    final bodyHash = _hashRequestBody(body);

    if (idempotencyStore != null) {
      final cached = await idempotencyStore.lookup(
        idempotencyKey: idempotencyKey,
        requestType: requestType,
        requestBodyHash: bodyHash,
      );
      if (cached != null) {
        if (cached.responseStatus == null || cached.responsePayload == null) {
          _writeJson(response, 409, <String, Object?>{
            'error': 'idempotency_request_in_flight',
            'message': 'idempotent request is already in flight',
          });
          return;
        }
        _writeJson(response, cached.responseStatus!, cached.responsePayload!);
        return;
      }
      final reserved = await idempotencyStore.reserve(
        idempotencyKey: idempotencyKey,
        requestType: requestType,
        actorUserId: actorUserId,
        requestBodyHash: bodyHash,
      );
      if (!reserved) {
        // Lost the race — re-fetch and replay.
        final raceCached = await idempotencyStore.lookup(
          idempotencyKey: idempotencyKey,
          requestType: requestType,
          requestBodyHash: bodyHash,
        );
        if (raceCached != null &&
            raceCached.responseStatus != null &&
            raceCached.responsePayload != null) {
          _writeJson(
            response,
            raceCached.responseStatus!,
            raceCached.responsePayload!,
          );
          return;
        }
        _writeJson(response, 409, <String, Object?>{
          'error': 'idempotency_request_in_flight',
          'message': 'idempotent request is already in flight',
        });
        return;
      }
    }

    final result = await gateway.toggleFlag(
      actorUserId: actorUserId,
      flagId: flagId,
      enabled: enabledRaw,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:toggle:$flagId:$enabledRaw',
      reason: reasonForAudit,
    );
    if (result == null) {
      const statusCode = 404;
      final responsePayload = <String, Object?>{
        'error': 'unknown_flag',
        'message': 'feature flag not found',
      };
      if (idempotencyStore != null) {
        await idempotencyStore.completeReservation(
          idempotencyKey: idempotencyKey,
          responseStatus: statusCode,
          responsePayload: responsePayload,
        );
      }
      _writeJson(response, statusCode, responsePayload);
      return;
    }
    const statusCode = 200;
    final responsePayload = <String, Object?>{'flag': result};
    if (idempotencyStore != null) {
      await idempotencyStore.completeReservation(
        idempotencyKey: idempotencyKey,
        responseStatus: statusCode,
        responsePayload: responsePayload,
      );
    }
    _writeJson(response, statusCode, responsePayload);
    return;
  }

  _writeNotFound(response, request);
}

/// Canonicalize a JSON body so two POSTs with semantically identical
/// payloads (different key order, etc.) hash to the same value.
String _hashRequestBody(Map<String, Object?> body) {
  final sortedKeys = body.keys.toList()..sort();
  final canonical = <String, Object?>{
    for (final key in sortedKeys) key: body[key],
  };
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

/// HARD-H — Runs [compute] under cross-tenant admin idempotency dedup
/// against `public.admin_request_idempotency`. Mirrors the
/// reserve→run→complete envelope inlined inside `_routeFeatureFlagsAdmin`
/// so the operator/location, pricing, and integration admin routes get
/// the same Postgres-durable backstop without each handler having to
/// re-implement it.
///
/// Cases:
///   * [store] is null OR [idempotencyKey] is empty → run [compute] and
///     write its response without dedup. Preserves back-compat with
///     callers that don't (yet) wire a store + with the previously
///     header-optional admin routes.
///   * Cache hit, response complete → write the cached response.
///   * Cache hit, response in flight → 409 `idempotency_request_in_flight`.
///   * Reserve loses the race → look up again; replay or 409.
///   * Reserve succeeds → run [compute] exactly once; stamp response in
///     the ledger; write the response. If [compute] throws, the row
///     stays in flight (the dispatch-site catch translates the throw
///     into the appropriate HTTP envelope) — same Stripe-style retry
///     posture HARD-D / HARD-H ship for the toggle handler.
///
/// [AdminIdempotencyKeyConflict] thrown from `lookup` (different
/// `request_type` or differing `request_body_hash`) bubbles out so the
/// dispatch-site catch can translate it into the contract's 409 / 422
/// envelopes — same handling the toggle path uses.

/// CODE_HEALTH L4 — public test seam for [_runAdminIdempotent]. Lets
/// `test/tool/advisor_proxy/admin_idempotency_reclaim_test.dart` drive
/// the reserve → reclaim → re-reserve flow against an in-memory
/// `AdminRequestIdempotencyStore` fake without standing up the entire
/// route handler. Production code calls the private helper directly;
/// the public alias exists exclusively for tests.
Future<void> runAdminIdempotentForTesting({
  required HttpResponse response,
  required AdminRequestIdempotencyStore? store,
  required String idempotencyKey,
  required String requestType,
  required String? actorUserId,
  required Map<String, Object?> requestBody,
  required Future<({int statusCode, Map<String, Object?> payload})> Function()
  compute,
  DateTime Function()? clock,
}) {
  return _runAdminIdempotent(
    response: response,
    store: store,
    idempotencyKey: idempotencyKey,
    requestType: requestType,
    actorUserId: actorUserId,
    requestBody: requestBody,
    compute: compute,
    clock: clock,
  );
}

Future<void> _runAdminIdempotent({
  required HttpResponse response,
  required AdminRequestIdempotencyStore? store,
  required String idempotencyKey,
  required String requestType,
  required String? actorUserId,
  required Map<String, Object?> requestBody,
  required Future<({int statusCode, Map<String, Object?> payload})> Function()
  compute,
  DateTime Function()? clock,
}) async {
  if (store == null || idempotencyKey.isEmpty) {
    final result = await compute();
    _writeJson(response, result.statusCode, result.payload);
    return;
  }
  final now = (clock ?? () => DateTime.now().toUtc()).call();
  final bodyHash = _hashRequestBody(requestBody);
  final cached = await store.lookup(
    idempotencyKey: idempotencyKey,
    requestType: requestType,
    requestBodyHash: bodyHash,
  );
  if (cached != null) {
    if (cached.responseStatus == null || cached.responsePayload == null) {
      // CODE_HEALTH L4 — orphan reclaim. The pre-L4 helper returned
      // 409 here unconditionally, which meant a transient compute
      // failure between `reserve()` and `completeReservation()` (proxy
      // crash, network glitch, panic in the route body) pinned the
      // key to 409 forever — the Idempotency-Key was effectively
      // burned for any future retry.
      //
      // Reclaim predicate (matches the M1 migration + `pg_cron` sweep
      // exactly): the in-flight pair `(response_status IS NULL AND
      // completed_at IS NULL)` PLUS `expires_at < now()`. The HARD-H
      // table has NO `status` column — DO NOT check
      // `status='in_flight'`.
      final expiresAt = cached.expiresAt;
      if (expiresAt != null && expiresAt.isBefore(now)) {
        final reclaimed = await store.tryReclaimOrphan(
          idempotencyKey: idempotencyKey,
        );
        if (reclaimed) {
          // Row deleted; fall through to the normal reserve→compute
          // path below as if the key had never been used.
        } else {
          _writeJson(response, 409, <String, Object?>{
            'error': 'idempotency_request_in_flight',
            'message': 'idempotent request is already in flight',
          });
          return;
        }
      } else {
        _writeJson(response, 409, <String, Object?>{
          'error': 'idempotency_request_in_flight',
          'message': 'idempotent request is already in flight',
        });
        return;
      }
    } else {
      _writeJson(response, cached.responseStatus!, cached.responsePayload!);
      return;
    }
  }
  final reserved = await store.reserve(
    idempotencyKey: idempotencyKey,
    requestType: requestType,
    actorUserId: actorUserId,
    requestBodyHash: bodyHash,
  );
  if (!reserved) {
    final raceCached = await store.lookup(
      idempotencyKey: idempotencyKey,
      requestType: requestType,
      requestBodyHash: bodyHash,
    );
    if (raceCached != null &&
        raceCached.responseStatus != null &&
        raceCached.responsePayload != null) {
      _writeJson(
        response,
        raceCached.responseStatus!,
        raceCached.responsePayload!,
      );
      return;
    }
    _writeJson(response, 409, <String, Object?>{
      'error': 'idempotency_request_in_flight',
      'message': 'idempotent request is already in flight',
    });
    return;
  }
  final result = await compute();
  await store.completeReservation(
    idempotencyKey: idempotencyKey,
    responseStatus: result.statusCode,
    responsePayload: result.payload,
  );
  _writeJson(response, result.statusCode, result.payload);
}

/// Phase 11A.3b — Graphify candidate review route handler. Same shape
/// as [_routeCorpusAdmin]: GET → list, POST → commit-batch. The
/// commit-batch arm reads the operator/location target from the
/// request body (super_admin actors are cross-tenant, so the operator
/// the candidates land in is an explicit per-request choice) and
/// applies the corpus-manifest scope filter as defense-in-depth
/// before handing the decisions off to the
/// [GraphCandidatesProxyGateway] for repository persistence.
Future<void> _routeGraphCandidates({
  required HttpRequest request,
  required HttpResponse response,
  required String path,
  required GraphCandidatesProxyGateway gateway,
  required String actorUserId,
  required String idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final method = request.method;
  final reasonPrefix = 'admin.corpus.graph_candidates.$method:$actorUserId';

  if (method == 'GET' && path == adminCorpusGraphCandidatesPath) {
    final diff = await gateway.listGraphCandidates(
      actorUserId: actorUserId,
      adminReason: '$reasonPrefix:list',
    );
    _writeJson(response, 200, diff);
    return;
  }

  if (method == 'POST' && path == adminCorpusGraphCandidatesCommitPath) {
    final rawDecisions = body['decisions'];
    if (rawDecisions is! List) {
      throw const _AdminInputError(
        statusCode: 400,
        code: 'missing_decisions',
        message: 'decisions array is required',
      );
    }
    // F&F super_admin actors are cross-tenant — they don't carry an
    // operator_id in their JWT. The body must name the operator the
    // candidates land in so the gateway can build the [TenantContext]
    // for the [GraphRepository.commitBatch] call.
    final operatorId = _requireBodyString(body, 'target_operator_id');
    final locationId = _requireBodyString(body, 'target_location_id');
    final castDecisions = <Map<String, Object?>>[];
    for (var i = 0; i < rawDecisions.length; i++) {
      final entry = rawDecisions[i];
      if (entry is! Map) {
        throw _AdminInputError(
          statusCode: 400,
          code: 'invalid_decision_entry',
          message: 'decisions[$i] must be a JSON object',
        );
      }
      castDecisions.add(entry.cast<String, Object?>());
    }
    // Manifest scope filter (defense in depth). The importer already
    // dropped out-of-scope candidates when it wrote the JSONL, but the
    // wire body could carry a hand-crafted decision whose payload
    // points at a markdown source the manifest does not cover. Reject
    // before the gateway gets near the canonical-graph tables.
    await _enforceGraphCandidateSourceScope(castDecisions);
    final result = await gateway.commitBatch(
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      decisions: castDecisions,
      idempotencyKey: idempotencyKey,
      adminReason: '$reasonPrefix:commit_batch',
    );
    _writeJson(response, 200, result);
    return;
  }

  _writeNotFound(response, request);
}

/// Lazy cache of in-scope source-file identifiers (both `source_path`
/// and bare `file_name`) loaded from the corpus manifest. Populated on
/// first commit-batch call so the manifest YAML parse cost is paid
/// once per process instead of per request. Reset via
/// [resetGraphCandidatesManifestCache] from tests that need to swap
/// the manifest mid-process.
Set<String>? _graphCandidatesManifestCache;

/// Resets the lazy [CorpusManifest] cache used by the graph-candidate
/// commit-batch handler. Tests that swap the manifest YAML mid-process
/// (e.g. by writing a fixture file under a temp dir) call this between
/// scenarios so the next request re-reads the fresh manifest.
void resetGraphCandidatesManifestCache() {
  _graphCandidatesManifestCache = null;
}

/// Defense-in-depth manifest filter for graph-candidate commit
/// batches. The wire `ApprovalDecision` only carries an opaque
/// `candidate_id` (the server resolves the canonical payload from
/// the JSONL artifacts), so for `approve` / `reject` decisions there
/// is nothing for the route handler to filter — the importer already
/// dropped out-of-scope candidates when it wrote the JSONL.
///
/// The filter still has work to do on `edit` decisions: the admin
/// can swap in an `edited_payload` that names a `source_file` the
/// manifest does not cover, which would smuggle out-of-scope content
/// into canonical storage. Reject those with a typed
/// `source_out_of_scope` 403 before the gateway gets near
/// `graph_nodes` / `graph_edges`. Decisions without an
/// `edited_payload.source_file` are passed through.
Future<void> _enforceGraphCandidateSourceScope(
  List<Map<String, Object?>> decisions,
) async {
  Set<String>? scope;
  for (var i = 0; i < decisions.length; i++) {
    final decision = decisions[i];
    // Inspect both `edited_payload.source_file` (the edit-swap case)
    // and a top-level `payload.source_file` (defensive: if a future
    // wire shape inlines the candidate payload onto the decision,
    // we want the same filter to catch it).
    final candidateSources = <String>[];
    final editedPayload = decision['edited_payload'];
    if (editedPayload is Map) {
      final raw = editedPayload['source_file'];
      if (raw is String) candidateSources.add(raw);
    }
    final inlinedPayload = decision['payload'];
    if (inlinedPayload is Map) {
      final raw = inlinedPayload['source_file'];
      if (raw is String) candidateSources.add(raw);
    }
    for (final rawSource in candidateSources) {
      final trimmed = rawSource.trim();
      if (trimmed.isEmpty) continue;
      scope ??=
          _graphCandidatesManifestCache ??
          await _loadGraphCandidatesManifestScope();
      final normalized = trimmed.replaceAll(r'\', '/');
      if (scope.contains(normalized)) continue;
      final base = p.basename(normalized);
      if (scope.contains(base)) continue;
      throw _AdminInputError(
        statusCode: 403,
        code: 'source_out_of_scope',
        message:
            'decision $i references source_file "$rawSource" which is '
            'not in the corpus manifest',
      );
    }
  }
}

Future<Set<String>> _loadGraphCandidatesManifestScope() async {
  final manifestFile = File(defaultManifestPath);
  if (!manifestFile.existsSync()) {
    // No manifest on disk — fall through with an empty scope. The
    // route handler will reject EVERY decision that names a
    // source_file, which is the safe default for a misconfigured
    // deployment.
    final empty = <String>{};
    _graphCandidatesManifestCache = empty;
    return empty;
  }
  final manifest = await CorpusManifest.load(manifestFile);
  final scope = <String>{};
  for (final document in manifest.documents) {
    if (!document.isIncluded) continue;
    scope.add(document.sourcePath.replaceAll(r'\', '/'));
    scope.add(document.fileName);
  }
  _graphCandidatesManifestCache = scope;
  return scope;
}
