// Phase 11A.2 - Pricing tier admin gateway.
//
// Translates the pricing screen's commands into proxy
// `/v1/admin/pricing/*` HTTP calls. The admin Flutter client never
// holds a Postgres connection string and never reaches the database
// directly - every read/write flows through the F&F admin proxy.
//
// Two implementations ship in this slice:
//
//   * [HttpPricingTierAdminGateway] - production. GET/PATCH/PUT/POST
//     against the proxy with the signed-in admin's bearer token. The
//     bearer source is injected so production can hand it the
//     Firebase ID token stream while tests can pin a fixed value.
//
//   * [InMemoryPricingTierAdminGateway] - demo + widget tests. Mutates
//     an in-memory collection so the admin screen can run end-to-end
//     in `kDemoMode` without a backend.
//
// Payload shapes mirror the proxy contract documented in
// `tool/advisor_proxy/advisor_proxy.dart` 11A.2 route handlers.

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/pricing_tier_admin_models.dart';
import 'admin_http_timeout.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef PricingAdminBearerTokenProvider = Future<String> Function();

/// Top-level error type for gateway calls. Carries an HTTP-style
/// status code + machine-readable error code so the screen can branch
/// on `permission_denied` / `validation_failed` / `unknown_tier_template`
/// without parsing `message`.
class PricingTierAdminGatewayError implements Exception {
  const PricingTierAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'PricingTierAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class PricingTierAdminGateway {
  Future<List<PricingOperatorBundle>> listOperators();

  Future<PricingOperatorBundle> updateOperatorTier(
    OperatorTierPatchCommand command,
  );

  Future<UsageCapRow> upsertUsageCap(UsageCapUpsertCommand command);

  Future<PricingOperatorBundle> applyTierTemplate(
    ApplyTierTemplateCommand command,
  );

  /// Delete one usage cap. Phase 2 delete-a-limit affordance.
  Future<void> deleteUsageCap(UsageCapDeleteCommand command);

  /// Month-to-date spend per `(location, usage_class)` for one operator
  /// (Phase 2 live spend-vs-cap figures).
  Future<OperatorSpendSummary> fetchSpendSummary(String operatorId);

  /// Phase 3 — read the editable plan-pricing catalog
  /// (`GET /v1/admin/pricing/plans`). One entry per plan. The screen's
  /// plan map prefers this over the hard-coded presentations.
  Future<List<PricingPlanCatalogEntry>> listPlanCatalog();

  /// Phase 3 — edit one plan's pricing fields
  /// (`PATCH /v1/admin/pricing/plans/{tier_key}`). Returns the updated
  /// catalog row.
  Future<PricingPlanCatalogEntry> updatePlanPricing(
    PricingPlanPricingUpdateCommand command,
  );
}

class HttpPricingTierAdminGateway implements PricingTierAdminGateway {
  HttpPricingTierAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`). The
  /// gateway resolves `/v1/admin/pricing/*` against this.
  final Uri baseUri;
  final PricingAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String operatorsPath = '/v1/admin/pricing/operators';
  static const String operatorsPrefix = '$operatorsPath/';
  static const String usageCapsPath = '/v1/admin/pricing/usage-caps';
  static const String plansPath = '/v1/admin/pricing/plans';
  static const String plansPrefix = '$plansPath/';

  // Idempotency key generation lives in the screen layer
  // (`_PricingTierAdminScreenState._nextIdempotencyKey`) so a single
  // minted key flows through both the dialog → command → gateway path
  // and the action handler. Keeping the minter here too would double-
  // mint keys for the same user action.

  @override
  Future<List<PricingOperatorBundle>> listOperators() async {
    final body = await _send(method: 'GET', path: operatorsPath);
    final list = (body['operators'] as List?) ?? const [];
    return <PricingOperatorBundle>[
      for (final entry in list)
        PricingOperatorBundle.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<PricingOperatorBundle> updateOperatorTier(
    OperatorTierPatchCommand command,
  ) async {
    final body = await _send(
      method: 'PATCH',
      path: '$operatorsPrefix${Uri.encodeComponent(command.operatorId)}',
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return PricingOperatorBundle.fromJson(body);
  }

  @override
  Future<UsageCapRow> upsertUsageCap(UsageCapUpsertCommand command) async {
    final body = await _send(
      method: 'PUT',
      path: usageCapsPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return UsageCapRow.fromJson((body['cap'] as Map).cast<String, Object?>());
  }

  @override
  Future<PricingOperatorBundle> applyTierTemplate(
    ApplyTierTemplateCommand command,
  ) async {
    final body = await _send(
      method: 'POST',
      path:
          '$operatorsPrefix${Uri.encodeComponent(command.operatorId)}/apply-template',
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return PricingOperatorBundle.fromJson(body);
  }

  @override
  Future<void> deleteUsageCap(UsageCapDeleteCommand command) async {
    await _send(
      method: 'DELETE',
      path: usageCapsPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
  }

  @override
  Future<OperatorSpendSummary> fetchSpendSummary(String operatorId) async {
    final body = await _send(
      method: 'GET',
      path: '$operatorsPrefix${Uri.encodeComponent(operatorId)}/spend-summary',
    );
    return OperatorSpendSummary.fromJson(body);
  }

  @override
  Future<List<PricingPlanCatalogEntry>> listPlanCatalog() async {
    final body = await _send(method: 'GET', path: plansPath);
    final list = (body['plans'] as List?) ?? const [];
    return <PricingPlanCatalogEntry>[
      for (final entry in list)
        PricingPlanCatalogEntry.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<PricingPlanCatalogEntry> updatePlanPricing(
    PricingPlanPricingUpdateCommand command,
  ) async {
    final body = await _send(
      method: 'PATCH',
      path: '$plansPrefix${Uri.encodeComponent(command.tierKey)}',
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return PricingPlanCatalogEntry.fromJson(
      (body['plan'] as Map).cast<String, Object?>(),
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw PricingTierAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message: 'admin pricing proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        parsed = decoded.cast<String, Object?>();
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    throw PricingTierAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin pricing proxy returned an error',
    );
  }
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Persists nothing across runs - every construction starts from
/// [seed]. Validation rules mirror the proxy:
///
///   * `subscription_tier` must be one of the locked template keys.
///   * `monthly_cap_usd` / `per_invocation_cap_usd` must be >= 0.
///   * `usage_class` must be non-blank.
///   * `apply-template` rejects an unknown `tier_key`.
class InMemoryPricingTierAdminGateway implements PricingTierAdminGateway {
  InMemoryPricingTierAdminGateway({
    Iterable<PricingOperatorBundle> seed = const <PricingOperatorBundle>[],
    DateTime Function()? now,
    String Function()? idGenerator,
    String? actorUserId,
    Iterable<PricingPlanCatalogEntry>? planCatalogSeed,
  }) : _now = now ?? DateTime.now,
       _idGenerator = idGenerator ?? _randomId,
       _actorUserId = actorUserId,
       _bundles = <String, _MutableBundle>{
         for (final bundle in seed)
           bundle.operatorId: _MutableBundle.from(bundle),
       },
       // Demo mode edits plan pricing offline: seed the catalog from the
       // hard-coded fallback (which mirrors the server migration seed) and
       // mutate it in place. Callers can override with a custom seed.
       _planCatalog = <String, PricingPlanCatalogEntry>{
         for (final entry in (planCatalogSeed ?? buildFallbackPlanCatalog()))
           entry.tierKey: entry,
       };

  final DateTime Function() _now;
  final String Function() _idGenerator;
  final String? _actorUserId;
  final Map<String, _MutableBundle> _bundles;
  final Map<String, PricingPlanCatalogEntry> _planCatalog;

  /// Per-key cache so a retried mutation on the in-memory gateway
  /// returns the prior result instead of mutating again - mirrors the
  /// proxy's `admin_request_idempotency` backstop.
  final Map<String, Object> _idempotentResults = <String, Object>{};

  @override
  Future<List<PricingOperatorBundle>> listOperators() async {
    final list = _bundles.values.map((b) => b.toBundle()).toList()
      ..sort(
        (a, b) => a.businessName.toLowerCase().compareTo(
          b.businessName.toLowerCase(),
        ),
      );
    return list;
  }

  @override
  Future<PricingOperatorBundle> updateOperatorTier(
    OperatorTierPatchCommand command,
  ) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is PricingOperatorBundle) return cached;
    _validateTierKey(command.subscriptionTier);
    final bundle = _bundleOrThrow(command.operatorId);
    bundle.subscriptionTier = command.subscriptionTier;
    final result = bundle.toBundle();
    _idempotentResults[command.idempotencyKey] = result;
    return result;
  }

  @override
  Future<UsageCapRow> upsertUsageCap(UsageCapUpsertCommand command) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is UsageCapRow) return cached;
    _validateUsageClass(command.usageClass);
    _validateNonNegative(command.monthlyCapUsd, field: 'monthly_cap_usd');
    _validateNonNegative(
      command.perInvocationCapUsd,
      field: 'per_invocation_cap_usd',
    );
    final bundle = _bundleOrThrow(command.operatorId);
    final ts = _now().toUtc();
    final existingIndex = bundle.caps.indexWhere(
      (c) =>
          c.locationId == command.locationId &&
          c.usageClass == command.usageClass &&
          c.staffId == command.staffId &&
          c.workflowId == command.workflowId,
    );
    final UsageCapRow row;
    if (existingIndex >= 0) {
      final prior = bundle.caps[existingIndex];
      row = UsageCapRow(
        capId: prior.capId,
        operatorId: prior.operatorId,
        locationId: prior.locationId,
        usageClass: prior.usageClass,
        monthlyCapUsd: command.monthlyCapUsd,
        perInvocationCapUsd: command.perInvocationCapUsd,
        staffId: prior.staffId,
        workflowId: prior.workflowId,
        createdBy: prior.createdBy,
        updatedBy: _actorUserId ?? prior.updatedBy,
        createdAt: prior.createdAt,
        updatedAt: ts,
      );
      bundle.caps[existingIndex] = row;
    } else {
      row = UsageCapRow(
        capId: _idGenerator(),
        operatorId: command.operatorId,
        locationId: command.locationId,
        usageClass: command.usageClass,
        monthlyCapUsd: command.monthlyCapUsd,
        perInvocationCapUsd: command.perInvocationCapUsd,
        staffId: command.staffId,
        workflowId: command.workflowId,
        createdBy: _actorUserId,
        updatedBy: _actorUserId,
        createdAt: ts,
        updatedAt: ts,
      );
      bundle.caps.add(row);
    }
    _idempotentResults[command.idempotencyKey] = row;
    return row;
  }

  @override
  Future<PricingOperatorBundle> applyTierTemplate(
    ApplyTierTemplateCommand command,
  ) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is PricingOperatorBundle) return cached;
    final template = findPricingTierTemplate(command.tierKey);
    if (template == null) {
      throw PricingTierAdminGatewayError(
        statusCode: 400,
        errorCode: 'unknown_tier_template',
        message:
            'tier_key "${command.tierKey}" is not a known pricing template',
      );
    }
    final bundle = _bundleOrThrow(command.operatorId);
    bundle.subscriptionTier = template.subscriptionTier;
    final primaryLocation = bundle.primaryLocationId;
    if (primaryLocation == null) {
      throw const PricingTierAdminGatewayError(
        statusCode: 400,
        errorCode: 'no_primary_location',
        message:
            'operator must have a primary_location_id before a tier template can be applied',
      );
    }
    final ts = _now().toUtc();
    for (final cap in template.caps) {
      // Each cap upsert gets a derived idempotency key so re-running
      // the apply doesn't re-cache as a cap. The outer apply key is
      // the primary cache slot.
      await upsertUsageCap(
        UsageCapUpsertCommand(
          operatorId: bundle.operatorId,
          locationId: primaryLocation,
          usageClass: cap.usageClass,
          monthlyCapUsd: cap.monthlyCapUsd,
          perInvocationCapUsd: cap.perInvocationCapUsd,
          staffId: cap.staffId,
          workflowId: cap.workflowId,
          idempotencyKey:
              '${command.idempotencyKey}:cap:${cap.usageClass}:'
              '${cap.staffId ?? "_"}:${cap.workflowId ?? "_"}',
        ),
      );
    }
    // Touch updatedAt indirectly: nothing else to do; the upserts
    // above already set it.
    if (template.caps.isEmpty) {
      // Enterprise: tier change without cap rewrites still needs a
      // visible audit timestamp on the operator bundle.
      bundle.updatedAt = ts;
    }
    final result = bundle.toBundle();
    _idempotentResults[command.idempotencyKey] = result;
    return result;
  }

  @override
  Future<void> deleteUsageCap(UsageCapDeleteCommand command) async {
    if (_idempotentResults.containsKey(command.idempotencyKey)) return;
    final bundle = _bundleOrThrow(command.operatorId);
    final before = bundle.caps.length;
    bundle.caps.removeWhere((c) {
      if (command.capId != null) return c.capId == command.capId;
      return c.locationId == command.locationId &&
          c.usageClass == command.usageClass &&
          c.staffId == command.staffId &&
          c.workflowId == command.workflowId;
    });
    if (bundle.caps.length == before) {
      throw const PricingTierAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_usage_cap',
        message: 'no matching usage limit to delete',
      );
    }
    // Sentinel so a retried delete under the same key is a no-op.
    _idempotentResults[command.idempotencyKey] = const _DeletedSentinel();
  }

  @override
  Future<OperatorSpendSummary> fetchSpendSummary(String operatorId) async {
    // The demo gateway has no `usage_logs`; month-to-date spend is not
    // modeled here. Return an empty summary so the screen FALLS BACK to
    // the observability envelope for demo spend figures (HP#2: demo
    // mode keeps working without a live spend-summary endpoint).
    _bundleOrThrow(operatorId);
    return const OperatorSpendSummary(byLocationAndClass: <String, double>{});
  }

  @override
  Future<List<PricingPlanCatalogEntry>> listPlanCatalog() async {
    // Return the six plans in the canonical ladder order
    // (kPricingPlanPresentations order) so the screen renders
    // deterministically, regardless of map iteration order.
    return <PricingPlanCatalogEntry>[
      for (final p in kPricingPlanPresentations)
        if (_planCatalog[p.tierKey] != null) _planCatalog[p.tierKey]!,
    ];
  }

  @override
  Future<PricingPlanCatalogEntry> updatePlanPricing(
    PricingPlanPricingUpdateCommand command,
  ) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached is PricingPlanCatalogEntry) return cached;
    _validatePlanTierKey(command.tierKey);
    _validateNullableNonNegative(command.monthlyUsd, field: 'monthly_usd');
    _validateNullableNonNegativeInt(
      command.firstNSeats,
      field: 'first_n_seats',
    );
    _validateNullableNonNegative(command.firstSeatUsd, field: 'first_seat_usd');
    _validateNullableNonNegative(
      command.additionalSeatUsd,
      field: 'additional_seat_usd',
    );
    _validateNullableNonNegative(
      command.onboardingMinUsd,
      field: 'onboarding_min_usd',
    );
    _validateNullableNonNegative(
      command.onboardingMaxUsd,
      field: 'onboarding_max_usd',
    );
    final updated = PricingPlanCatalogEntry(
      tierKey: command.tierKey,
      monthlyUsd: command.monthlyUsd,
      firstNSeats: command.firstNSeats,
      firstSeatUsd: command.firstSeatUsd,
      additionalSeatUsd: command.additionalSeatUsd,
      onboardingMinUsd: command.onboardingMinUsd,
      onboardingMaxUsd: command.onboardingMaxUsd,
      updatedAt: _now().toUtc(),
      updatedBy: _actorUserId,
    );
    _planCatalog[command.tierKey] = updated;
    _idempotentResults[command.idempotencyKey] = updated;
    return updated;
  }

  _MutableBundle _bundleOrThrow(String operatorId) {
    final bundle = _bundles[operatorId];
    if (bundle == null) {
      throw const PricingTierAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_operator',
        message: 'operator not found',
      );
    }
    return bundle;
  }

  static void _validateTierKey(String tierKey) {
    if (!kPricingTierTemplateKeys.contains(tierKey)) {
      throw PricingTierAdminGatewayError(
        statusCode: 400,
        errorCode: 'unknown_subscription_tier',
        message:
            'subscription_tier must be one of: ${kPricingTierTemplateKeys.join(', ')}',
      );
    }
  }

  static void _validateUsageClass(String usageClass) {
    if (usageClass.trim().isEmpty) {
      throw const PricingTierAdminGatewayError(
        statusCode: 400,
        errorCode: 'missing_usage_class',
        message: 'usage_class is required',
      );
    }
  }

  static void _validateNonNegative(double value, {required String field}) {
    if (value < 0 || value.isNaN || value.isInfinite) {
      throw PricingTierAdminGatewayError(
        statusCode: 400,
        errorCode: 'invalid_$field',
        message: '$field must be a non-negative finite number',
      );
    }
  }

  static void _validatePlanTierKey(String tierKey) {
    if (!kPricingTierTemplateKeys.contains(tierKey)) {
      throw PricingTierAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_plan',
        message:
            'tier_key must be one of: ${kPricingTierTemplateKeys.join(', ')}',
      );
    }
  }

  /// A null money field is allowed (genuine SQL NULL: e.g. Enterprise has
  /// no monthly price, no-seat plans have null seat fees); a present value
  /// must be a non-negative finite number.
  static void _validateNullableNonNegative(
    double? value, {
    required String field,
  }) {
    if (value == null) return;
    _validateNonNegative(value, field: field);
  }

  static void _validateNullableNonNegativeInt(
    int? value, {
    required String field,
  }) {
    if (value == null) return;
    if (value < 0) {
      throw PricingTierAdminGatewayError(
        statusCode: 400,
        errorCode: 'invalid_$field',
        message: '$field must be a non-negative integer',
      );
    }
  }

  static int _idCounter = 0;
  static String _randomId() {
    _idCounter += 1;
    final hex = _idCounter.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-8000-$hex';
  }
}

/// Cache marker for a completed in-memory delete so a retried
/// [InMemoryPricingTierAdminGateway.deleteUsageCap] under the same
/// idempotency key is a no-op (mirrors the proxy's idempotent DELETE).
class _DeletedSentinel {
  const _DeletedSentinel();
}

class _MutableBundle {
  _MutableBundle({
    required this.operatorId,
    required this.businessName,
    required this.subscriptionTier,
    required this.preferredCurrency,
    required this.primaryLocationId,
    required this.primaryLocationName,
    required this.suspended,
    required List<UsageCapRow> caps,
    required this.updatedAt,
  }) : caps = List<UsageCapRow>.from(caps);

  factory _MutableBundle.from(PricingOperatorBundle bundle) {
    return _MutableBundle(
      operatorId: bundle.operatorId,
      businessName: bundle.businessName,
      subscriptionTier: bundle.subscriptionTier,
      preferredCurrency: bundle.preferredCurrency,
      primaryLocationId: bundle.primaryLocationId,
      primaryLocationName: bundle.primaryLocationName,
      suspended: bundle.suspended,
      caps: bundle.caps,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  final String operatorId;
  final String businessName;
  String subscriptionTier;
  final String preferredCurrency;
  final String? primaryLocationId;
  final String? primaryLocationName;
  final bool suspended;
  final List<UsageCapRow> caps;
  DateTime updatedAt;

  PricingOperatorBundle toBundle() => PricingOperatorBundle(
    operatorId: operatorId,
    businessName: businessName,
    subscriptionTier: subscriptionTier,
    preferredCurrency: preferredCurrency,
    primaryLocationId: primaryLocationId,
    primaryLocationName: primaryLocationName,
    suspended: suspended,
    caps: List<UsageCapRow>.unmodifiable(caps),
  );
}
