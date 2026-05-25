// Phase 11A.2 - Pricing tier admin value objects.
//
// Carries the operator + usage_caps shape the admin pricing screen
// needs to render and edit. Mirrors the `usage_caps` Postgres columns
// from `db/migrations/202604250005_advisor_cloud_foundation.sql` plus
// the optional `staff_id` / `workflow_id` axes added by
// `db/migrations/202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql`.
// `created_by` / `updated_by` carry actor user IDs for audit; the
// admin proxy stamps them on every mutation.
//
// Tier templates (Pilot / Starter / Premium / Elite / Pro / Enterprise)
// match the locked tier model in
// `docs/phases/phase_11a/phase_11a_decision_register.md` Pricing Tier
// Model section. Concrete USD caps in each template come from the
// gross-margin sanity check in the same section; F&F admin can edit
// any cap row inline after applying a template.

import 'package:flutter/foundation.dart';

/// Snapshot of one operator's billing posture: subscription tier on
/// `operators.subscription_tier`, plus every `usage_caps` row for the
/// operator (across all locations / staff / workflows / usage classes).
@immutable
class PricingOperatorBundle {
  const PricingOperatorBundle({
    required this.operatorId,
    required this.businessName,
    required this.subscriptionTier,
    required this.preferredCurrency,
    required this.primaryLocationId,
    this.primaryLocationName,
    required this.suspended,
    required this.caps,
  });

  final String operatorId;
  final String businessName;
  final String subscriptionTier;
  final String preferredCurrency;
  final String? primaryLocationId;
  final String? primaryLocationName;
  final bool suspended;
  final List<UsageCapRow> caps;

  static PricingOperatorBundle fromJson(Map<String, Object?> json) {
    final operator = (json['operator'] as Map).cast<String, Object?>();
    final caps = (json['caps'] as List?) ?? const [];
    return PricingOperatorBundle(
      operatorId: operator['operator_id']! as String,
      businessName: operator['business_name']! as String,
      subscriptionTier: operator['subscription_tier']! as String,
      preferredCurrency: operator['preferred_currency']! as String,
      primaryLocationId: operator['primary_location_id'] as String?,
      primaryLocationName: operator['primary_location_name'] as String?,
      suspended: (operator['suspended'] as bool?) ?? false,
      caps: <UsageCapRow>[
        for (final c in caps)
          UsageCapRow.fromJson((c as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// One `usage_caps` row. `staffId` / `workflowId` are nullable per the
/// 9.0Σ.g add-columns migration; NULL = the cap applies across all
/// staff / workflows for the (operator, location, usage_class) tuple.
@immutable
class UsageCapRow {
  const UsageCapRow({
    required this.capId,
    required this.operatorId,
    required this.locationId,
    required this.usageClass,
    required this.monthlyCapUsd,
    required this.perInvocationCapUsd,
    required this.staffId,
    required this.workflowId,
    required this.createdBy,
    required this.updatedBy,
    required this.createdAt,
    required this.updatedAt,
  });

  /// `cap_id` surrogate from 9.0Σ.g, or null on rows written before
  /// the constraint flip lands. The screen keys edits off
  /// `(operator_id, location_id, usage_class, staff_id, workflow_id)`
  /// so a missing `cap_id` is non-fatal.
  final String? capId;
  final String operatorId;
  final String locationId;
  final String usageClass;
  final double monthlyCapUsd;
  final double perInvocationCapUsd;
  final String? staffId;
  final String? workflowId;
  final String? createdBy;
  final String? updatedBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  static UsageCapRow fromJson(Map<String, Object?> json) {
    return UsageCapRow(
      capId: json['cap_id'] as String?,
      operatorId: json['operator_id']! as String,
      locationId: json['location_id']! as String,
      usageClass: json['usage_class']! as String,
      monthlyCapUsd: _asDouble(json['monthly_cap_usd']),
      perInvocationCapUsd: _asDouble(json['per_invocation_cap_usd']),
      staffId: json['staff_id'] as String?,
      workflowId: json['workflow_id'] as String?,
      createdBy: json['created_by'] as String?,
      updatedBy: json['updated_by'] as String?,
      createdAt: DateTime.parse(json['created_at']! as String),
      updatedAt: DateTime.parse(json['updated_at']! as String),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    if (capId != null) 'cap_id': capId,
    'operator_id': operatorId,
    'location_id': locationId,
    'usage_class': usageClass,
    'monthly_cap_usd': monthlyCapUsd,
    'per_invocation_cap_usd': perInvocationCapUsd,
    'staff_id': staffId,
    'workflow_id': workflowId,
    'created_by': createdBy,
    'updated_by': updatedBy,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}

/// Patch the operator's subscription tier. Goes to
/// `PATCH /v1/admin/pricing/operators/{id}`.
@immutable
class OperatorTierPatchCommand {
  const OperatorTierPatchCommand({
    required this.operatorId,
    required this.subscriptionTier,
    required this.idempotencyKey,
  });

  final String operatorId;
  final String subscriptionTier;

  /// Per-action idempotency key. The proxy stores it in
  /// `admin_request_idempotency` so a retried PATCH collapses to one
  /// tier mutation + one audit row.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'subscription_tier': subscriptionTier,
  };
}

/// Inline edit of one `usage_caps` row. Goes to
/// `PUT /v1/admin/pricing/usage-caps`. The proxy upserts on the
/// `(operator_id, location_id, usage_class, staff_id, workflow_id)`
/// logical key, so both create and update flow through the same
/// command.
@immutable
class UsageCapUpsertCommand {
  const UsageCapUpsertCommand({
    required this.operatorId,
    required this.locationId,
    required this.usageClass,
    required this.monthlyCapUsd,
    required this.perInvocationCapUsd,
    required this.idempotencyKey,
    this.staffId,
    this.workflowId,
  });

  final String operatorId;
  final String locationId;
  final String usageClass;
  final double monthlyCapUsd;
  final double perInvocationCapUsd;
  final String? staffId;
  final String? workflowId;

  /// Per-action idempotency key. The proxy stores it in
  /// `admin_request_idempotency` so a retried PUT collapses to one
  /// upsert + one audit row.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'location_id': locationId,
    'usage_class': usageClass,
    'monthly_cap_usd': monthlyCapUsd,
    'per_invocation_cap_usd': perInvocationCapUsd,
    'staff_id': staffId,
    'workflow_id': workflowId,
  };
}

/// Delete one `usage_caps` row. Goes to
/// `DELETE /v1/admin/pricing/usage-caps`. The proxy deletes by the
/// surrogate [capId] when present, otherwise by the same
/// `(operator_id, location_id, usage_class, staff_id, workflow_id)`
/// logical key the upsert uses.
@immutable
class UsageCapDeleteCommand {
  const UsageCapDeleteCommand({
    required this.operatorId,
    required this.locationId,
    required this.usageClass,
    required this.idempotencyKey,
    this.staffId,
    this.workflowId,
    this.capId,
  });

  final String operatorId;
  final String locationId;
  final String usageClass;
  final String? staffId;
  final String? workflowId;
  final String? capId;

  /// Per-action idempotency key. The proxy stores it in
  /// `admin_request_idempotency` so a retried DELETE collapses to one
  /// delete + one audit row.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'operator_id': operatorId,
    'location_id': locationId,
    'usage_class': usageClass,
    if (staffId != null) 'staff_id': staffId,
    if (workflowId != null) 'workflow_id': workflowId,
    if (capId != null) 'cap_id': capId,
  };
}

/// Month-to-date spend for one operator, keyed by
/// `(location_id, usage_class)`. Read from
/// `GET /v1/admin/pricing/operators/{id}/spend-summary`; the figures
/// reuse the same `usage_logs` SUM(cost_usd)-for-month grain the cap
/// enforcement path uses, so they line up with the cap on each bar.
@immutable
class OperatorSpendSummary {
  const OperatorSpendSummary({required this.byLocationAndClass});

  /// `'<location_id>::<usage_class>' -> month-to-date spend USD`.
  final Map<String, double> byLocationAndClass;

  static String keyFor(String locationId, String usageClass) =>
      '$locationId::$usageClass';

  /// Spend for one `(location, usage_class)` pair, or null when the
  /// summary has no row for it (honest empty, not a phantom $0).
  double? spendFor(String locationId, String usageClass) =>
      byLocationAndClass[keyFor(locationId, usageClass)];

  static OperatorSpendSummary fromJson(Map<String, Object?> json) {
    final spend = (json['spend'] as List?) ?? const [];
    final map = <String, double>{};
    for (final entry in spend) {
      final row = (entry as Map).cast<String, Object?>();
      final locationId = row['location_id'] as String?;
      final usageClass = row['usage_class'] as String?;
      if (locationId == null || usageClass == null) continue;
      map[keyFor(locationId, usageClass)] = _asDouble(row['spend_usd']);
    }
    return OperatorSpendSummary(byLocationAndClass: map);
  }
}

/// Apply a tier template: update `operators.subscription_tier` and
/// upsert each cap row from the template under one admin reason. Goes
/// to `POST /v1/admin/pricing/operators/{id}/apply-template`.
@immutable
class ApplyTierTemplateCommand {
  const ApplyTierTemplateCommand({
    required this.operatorId,
    required this.tierKey,
    required this.idempotencyKey,
  });

  final String operatorId;
  final String tierKey;

  /// Per-action idempotency key. The proxy stores it in
  /// `admin_request_idempotency` so a retried POST collapses to one
  /// template apply + one audit row.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{'tier_key': tierKey};
}

/// One pre-defined cap row inside a tier template.
@immutable
class PricingTierTemplateCap {
  const PricingTierTemplateCap({
    required this.usageClass,
    required this.monthlyCapUsd,
    required this.perInvocationCapUsd,
    this.staffId,
    this.workflowId,
  });

  final String usageClass;
  final double monthlyCapUsd;
  final double perInvocationCapUsd;
  final String? staffId;
  final String? workflowId;
}

/// Locked tier templates from the decision register Pricing Tier
/// Model section. Pilot / Starter / Premium / Elite / Pro come with
/// concrete USD caps; Enterprise is custom (no template caps), so the
/// admin builds the rows by hand after assigning the tier.
@immutable
class PricingTierTemplate {
  const PricingTierTemplate({
    required this.tierKey,
    required this.displayName,
    required this.summary,
    required this.subscriptionTier,
    required this.caps,
  });

  /// Stable key the proxy / DB recognise. Mirrors
  /// `operators.subscription_tier` values.
  final String tierKey;
  final String displayName;
  final String summary;

  /// Value written to `operators.subscription_tier` when the template
  /// is applied. Same as [tierKey] for the launch templates; carried
  /// separately so future migrations can rename one without breaking
  /// the other.
  final String subscriptionTier;

  /// Pre-defined cap rows. Empty for Enterprise (custom contract).
  final List<PricingTierTemplateCap> caps;
}

/// Locked tier-template catalog (decision register 2026-04-26).
/// Order is the side-by-side layout used by the screen's "apply
/// template" picker.
const List<PricingTierTemplate> kPricingTierTemplates = <PricingTierTemplate>[
  PricingTierTemplate(
    tierKey: 'pilot',
    displayName: 'Pilot',
    summary: 'Pay-as-you-go. \$0/mo + per-query metering, capped at \$50/mo.',
    subscriptionTier: 'pilot',
    caps: <PricingTierTemplateCap>[
      PricingTierTemplateCap(
        usageClass: 'advisor_qa',
        monthlyCapUsd: 50.0,
        perInvocationCapUsd: 0.10,
      ),
    ],
  ),
  PricingTierTemplate(
    tierKey: 'starter',
    displayName: 'Starter',
    summary: '\$250/mo. Manager surfaces only; Haiku for advisor.',
    subscriptionTier: 'starter',
    caps: <PricingTierTemplateCap>[
      PricingTierTemplateCap(
        usageClass: 'advisor_qa',
        monthlyCapUsd: 50.0,
        perInvocationCapUsd: 0.10,
      ),
    ],
  ),
  PricingTierTemplate(
    tierKey: 'premium',
    displayName: 'Premium',
    summary: '\$250 + \$5/seat. Adds LMS + scoreboard; Sonnet for advisor.',
    subscriptionTier: 'premium',
    caps: <PricingTierTemplateCap>[
      PricingTierTemplateCap(
        usageClass: 'advisor_qa',
        monthlyCapUsd: 200.0,
        perInvocationCapUsd: 0.20,
      ),
    ],
  ),
  PricingTierTemplate(
    tierKey: 'elite',
    displayName: 'Elite',
    summary: '\$250 + \$10/\$5 seat. Adds staff coach + SOPs.',
    subscriptionTier: 'elite',
    caps: <PricingTierTemplateCap>[
      PricingTierTemplateCap(
        usageClass: 'advisor_qa',
        monthlyCapUsd: 400.0,
        perInvocationCapUsd: 0.20,
      ),
      PricingTierTemplateCap(
        usageClass: 'coach_qa',
        monthlyCapUsd: 300.0,
        perInvocationCapUsd: 0.20,
      ),
    ],
  ),
  PricingTierTemplate(
    tierKey: 'pro',
    displayName: 'Pro',
    summary:
        '\$500 + \$15/\$8 seat. Adds workflow catalog with run allowances.',
    subscriptionTier: 'pro',
    caps: <PricingTierTemplateCap>[
      PricingTierTemplateCap(
        usageClass: 'advisor_qa',
        monthlyCapUsd: 600.0,
        perInvocationCapUsd: 0.20,
      ),
      PricingTierTemplateCap(
        usageClass: 'coach_qa',
        monthlyCapUsd: 400.0,
        perInvocationCapUsd: 0.20,
      ),
      PricingTierTemplateCap(
        usageClass: 'workflow_pl',
        monthlyCapUsd: 500.0,
        perInvocationCapUsd: 5.0,
      ),
      PricingTierTemplateCap(
        usageClass: 'workflow_schedule',
        monthlyCapUsd: 300.0,
        perInvocationCapUsd: 5.0,
      ),
    ],
  ),
  PricingTierTemplate(
    tierKey: 'enterprise',
    displayName: 'Enterprise',
    summary: 'Custom contract. Caps configured per agreement.',
    subscriptionTier: 'enterprise',
    caps: <PricingTierTemplateCap>[],
  ),
];

/// Read-only presentation metadata for one plan in the laddered plan
/// map. The concrete USD caps + the canonical plan keys/names stay in
/// [kPricingTierTemplates] (the proxy-recognised source of truth); this
/// table layers the human-facing price line, per-seat line, "what it
/// adds" summary, margin estimate, and onboarding range from the
/// reconciled pricing model in
/// `docs/phases/phase_11a/phase_11a_decision_register.md`
/// ("Reconciled pricing model (2026-05-24)") and the operator-approved
/// mockup `docs/_mockups/admin_plans_and_limits_redesign.html`.
///
/// As of Phase 3 these constants are the OFFLINE / DEMO FALLBACK for the
/// editable server catalog (`pricing_plan_catalog`, read via
/// `GET /v1/admin/pricing/plans`). The screen prefers the live catalog
/// and falls back to these values when the call fails or in offline demo
/// mode (see [buildFallbackPlanCatalog]). They are NOT deleted — they
/// keep the plan map painting without a backend.
@immutable
class PricingPlanPresentation {
  const PricingPlanPresentation({
    required this.tierKey,
    required this.monthlyUsd,
    required this.priceLine,
    required this.seatLine,
    required this.includes,
    required this.marginEstimate,
    required this.onboardingRange,
    required this.ladderFraction,
  });

  /// Matches [PricingTierTemplate.tierKey].
  final String tierKey;

  /// Headline monthly price in USD, or null for a custom contract
  /// (Enterprise) so the map renders "Custom" instead of a number.
  final double? monthlyUsd;

  /// One-line price summary as the operator should read it
  /// (e.g. `$250/mo plus $5/seat`). Plain English, no em dash.
  final String priceLine;

  /// Per-seat / onboarding-context line shown under the price.
  final String seatLine;

  /// "What it adds" relative to the plan below it.
  final String includes;

  /// Margin estimate copy from the gross-margin sanity check.
  final String marginEstimate;

  /// Onboarding fee range copy.
  final String onboardingRange;

  /// 0 to 1 fill used to draw the laddered accent bar in the plan map.
  final double ladderFraction;
}

/// Laddered plan presentation, lowest to highest. Order mirrors
/// [kPricingTierTemplates]. Values are the reconciled 2026-05-24 model.
const List<PricingPlanPresentation> kPricingPlanPresentations =
    <PricingPlanPresentation>[
      PricingPlanPresentation(
        tierKey: 'pilot',
        monthlyUsd: 0,
        priceLine: 'Free preview on sample data',
        seatLine: 'No seat fee. Self-serve onboarding.',
        includes:
            'KPI dashboard on sample data plus the AI advisor. '
            'Connect real data to go live.',
        marginEstimate: 'Free trial',
        onboardingRange: r'$0 (self-serve)',
        ladderFraction: 0.28,
      ),
      PricingPlanPresentation(
        tierKey: 'starter',
        monthlyUsd: 250,
        priceLine: r'$250/mo',
        seatLine: 'No seat fee.',
        includes: 'KPI dashboard, reporting, and the manager chatbot.',
        marginEstimate: 'About 95% margin',
        onboardingRange: r'$500 to $1,000',
        ladderFraction: 0.42,
      ),
      PricingPlanPresentation(
        tierKey: 'premium',
        monthlyUsd: 250,
        priceLine: r'$250/mo plus $5/seat',
        seatLine: r'$5/seat first 20, then $3.',
        includes: 'Everything in Starter, plus the LMS and scoreboard.',
        marginEstimate: 'About 93% margin',
        onboardingRange: r'$750 to $2,000',
        ladderFraction: 0.56,
      ),
      PricingPlanPresentation(
        tierKey: 'elite',
        monthlyUsd: 250,
        priceLine: r'$250/mo plus $10/$5 seat',
        seatLine: r'$10/seat first 20, then $5.',
        includes: 'Everything in Premium, plus staff coaching and SOPs.',
        marginEstimate: 'About 78% margin',
        onboardingRange: r'$1,500 to $3,500',
        ladderFraction: 0.7,
      ),
      PricingPlanPresentation(
        tierKey: 'pro',
        monthlyUsd: 500,
        priceLine: r'$500/mo plus $15/$8 seat',
        seatLine: r'$15/seat first 20, then $8. Includes 100 workflow runs.',
        includes: 'Everything in Elite, plus the workflow catalog.',
        marginEstimate: 'About 75% margin',
        onboardingRange: r'$2,500 to $5,000',
        ladderFraction: 0.84,
      ),
      PricingPlanPresentation(
        tierKey: 'enterprise',
        monthlyUsd: null,
        priceLine: 'Custom contract',
        seatLine: 'Per-contract seats and SLA.',
        includes: 'Everything in Pro, plus custom workflows and SLA.',
        marginEstimate: '80% or more margin',
        onboardingRange: 'Custom',
        ladderFraction: 1.0,
      ),
    ];

/// Resolve plan presentation by [tierKey]; null for unknown keys.
PricingPlanPresentation? findPricingPlanPresentation(String tierKey) {
  final normalized = tierKey.trim().toLowerCase();
  for (final p in kPricingPlanPresentations) {
    if (p.tierKey == normalized) return p;
  }
  return null;
}

/// The set of tier keys that the proxy will accept on
/// `apply-template`. Used for client + server validation.
final Set<String> kPricingTierTemplateKeys = <String>{
  for (final t in kPricingTierTemplates) t.tierKey,
};

/// Resolve a template by its [tierKey]; returns null for unknown keys.
PricingTierTemplate? findPricingTierTemplate(String tierKey) {
  for (final t in kPricingTierTemplates) {
    if (t.tierKey == tierKey) return t;
  }
  return null;
}

/// Phase 3 — one editable row from the server `pricing_plan_catalog`
/// table (`db/migrations/202605241100_plans_and_limits_phase3_pricing_plan_catalog.sql`).
///
/// This is the live, admin-editable source of plan pricing. The screen
/// reads the catalog via `GET /v1/admin/pricing/plans` and falls back to
/// the hard-coded [kPricingPlanPresentations] when the call fails or in
/// offline demo mode, so the plan map always paints. Nullable money
/// fields mirror the catalog columns: Enterprise has a null
/// `monthlyUsd` (custom contract); plans with no per-seat fee have null
/// seat fields; the self-serve / custom plans have null onboarding
/// bounds.
@immutable
class PricingPlanCatalogEntry {
  const PricingPlanCatalogEntry({
    required this.tierKey,
    required this.monthlyUsd,
    required this.firstNSeats,
    required this.firstSeatUsd,
    required this.additionalSeatUsd,
    required this.onboardingMinUsd,
    required this.onboardingMaxUsd,
    this.updatedAt,
    this.updatedBy,
  });

  /// Matches [PricingTierTemplate.tierKey] / the catalog primary key.
  final String tierKey;

  /// Headline monthly fee in USD, or null for a custom-contract plan
  /// (Enterprise).
  final double? monthlyUsd;

  /// Size of the first per-seat pricing band (e.g. 20), or null when the
  /// plan has no per-seat fee.
  final int? firstNSeats;

  /// Per-seat USD price inside / past the first band; null when the plan
  /// has no per-seat fee.
  final double? firstSeatUsd;
  final double? additionalSeatUsd;

  /// Onboarding fee range in USD; null for the self-serve and custom
  /// plans.
  final double? onboardingMinUsd;
  final double? onboardingMaxUsd;

  /// UTC instant of the last edit + the actor who made it. Null on a
  /// fallback entry projected from the hard-coded presentations.
  final DateTime? updatedAt;
  final String? updatedBy;

  static PricingPlanCatalogEntry fromJson(Map<String, Object?> json) {
    final updatedAtRaw = json['updated_at'] as String?;
    return PricingPlanCatalogEntry(
      tierKey: json['tier_key']! as String,
      monthlyUsd: _asNullableDouble(json['monthly_usd']),
      firstNSeats: _asNullableInt(json['first_n_seats']),
      firstSeatUsd: _asNullableDouble(json['first_seat_usd']),
      additionalSeatUsd: _asNullableDouble(json['additional_seat_usd']),
      onboardingMinUsd: _asNullableDouble(json['onboarding_min_usd']),
      onboardingMaxUsd: _asNullableDouble(json['onboarding_max_usd']),
      updatedAt: (updatedAtRaw == null || updatedAtRaw.isEmpty)
          ? null
          : DateTime.parse(updatedAtRaw),
      updatedBy: json['updated_by'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'tier_key': tierKey,
    'monthly_usd': monthlyUsd,
    'first_n_seats': firstNSeats,
    'first_seat_usd': firstSeatUsd,
    'additional_seat_usd': additionalSeatUsd,
    'onboarding_min_usd': onboardingMinUsd,
    'onboarding_max_usd': onboardingMaxUsd,
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
    if (updatedBy != null) 'updated_by': updatedBy,
  };

  /// Project a hard-coded [PricingPlanPresentation] into a catalog entry
  /// for the offline / demo fallback. Only the headline monthly price is
  /// carried verbatim; the per-seat ramp + onboarding bounds are sourced
  /// from [kPricingTierTemplates]-adjacent constants below so the demo
  /// editor shows the same numbers the server seed holds.
  factory PricingPlanCatalogEntry.fromPresentation(
    PricingPlanPresentation presentation,
  ) {
    final seed = _kPlanPricingSeed[presentation.tierKey];
    return PricingPlanCatalogEntry(
      tierKey: presentation.tierKey,
      monthlyUsd: presentation.monthlyUsd,
      firstNSeats: seed?.firstNSeats,
      firstSeatUsd: seed?.firstSeatUsd,
      additionalSeatUsd: seed?.additionalSeatUsd,
      onboardingMinUsd: seed?.onboardingMinUsd,
      onboardingMaxUsd: seed?.onboardingMaxUsd,
    );
  }
}

/// Edit one plan's pricing fields. Goes to
/// `PATCH /v1/admin/pricing/plans/{tier_key}`. Only the editable money /
/// band fields travel; `tier_key` is the path segment, not a body field.
@immutable
class PricingPlanPricingUpdateCommand {
  const PricingPlanPricingUpdateCommand({
    required this.tierKey,
    required this.monthlyUsd,
    required this.firstNSeats,
    required this.firstSeatUsd,
    required this.additionalSeatUsd,
    required this.onboardingMinUsd,
    required this.onboardingMaxUsd,
    required this.idempotencyKey,
  });

  final String tierKey;
  final double? monthlyUsd;
  final int? firstNSeats;
  final double? firstSeatUsd;
  final double? additionalSeatUsd;
  final double? onboardingMinUsd;
  final double? onboardingMaxUsd;

  /// Per-action idempotency key. The proxy stores it in
  /// `admin_request_idempotency` so a retried PATCH collapses to one
  /// pricing mutation + one audit row.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'monthly_usd': monthlyUsd,
    'first_n_seats': firstNSeats,
    'first_seat_usd': firstSeatUsd,
    'additional_seat_usd': additionalSeatUsd,
    'onboarding_min_usd': onboardingMinUsd,
    'onboarding_max_usd': onboardingMaxUsd,
  };
}

/// Per-plan per-seat + onboarding seed values, mirroring the catalog
/// migration's seed (`202605241100_...`) and the reconciled pricing
/// model. Used only to build the offline/demo fallback catalog so the
/// in-memory gateway + the screen's fallback path show the same numbers
/// the server holds. The headline monthly price stays sourced from
/// [kPricingPlanPresentations]; this table carries the fields the
/// presentations do not.
class _PlanPricingSeed {
  const _PlanPricingSeed({
    this.firstNSeats,
    this.firstSeatUsd,
    this.additionalSeatUsd,
    this.onboardingMinUsd,
    this.onboardingMaxUsd,
  });

  final int? firstNSeats;
  final double? firstSeatUsd;
  final double? additionalSeatUsd;
  final double? onboardingMinUsd;
  final double? onboardingMaxUsd;
}

const Map<String, _PlanPricingSeed> _kPlanPricingSeed =
    <String, _PlanPricingSeed>{
      'pilot': _PlanPricingSeed(onboardingMinUsd: 0, onboardingMaxUsd: 0),
      'starter': _PlanPricingSeed(
        onboardingMinUsd: 500,
        onboardingMaxUsd: 1000,
      ),
      'premium': _PlanPricingSeed(
        firstNSeats: 20,
        firstSeatUsd: 5,
        additionalSeatUsd: 3,
        onboardingMinUsd: 750,
        onboardingMaxUsd: 2000,
      ),
      'elite': _PlanPricingSeed(
        firstNSeats: 20,
        firstSeatUsd: 10,
        additionalSeatUsd: 5,
        onboardingMinUsd: 1500,
        onboardingMaxUsd: 3500,
      ),
      'pro': _PlanPricingSeed(
        firstNSeats: 20,
        firstSeatUsd: 15,
        additionalSeatUsd: 8,
        onboardingMinUsd: 2500,
        onboardingMaxUsd: 5000,
      ),
      'enterprise': _PlanPricingSeed(),
    };

/// Build the full offline/demo fallback catalog from the hard-coded
/// presentations + the per-seat/onboarding seed. The in-memory gateway
/// seeds from this so demo mode edits plan pricing without a backend,
/// and the screen falls back to it when `GET /v1/admin/pricing/plans`
/// fails.
List<PricingPlanCatalogEntry> buildFallbackPlanCatalog() =>
    <PricingPlanCatalogEntry>[
      for (final p in kPricingPlanPresentations)
        PricingPlanCatalogEntry.fromPresentation(p),
    ];

// ---------------------------------------------------------------------------
// Phase 5a — feature entitlements (which features each plan includes).
// ---------------------------------------------------------------------------

/// Plain-English display names for each feature slug, used by the admin
/// matrix editor so the operator reads "Learning (LMS)" not the raw
/// `lms` key. Mirrors the slug set seeded by
/// `db/migrations/202605241700_plans_and_limits_phase5a_feature_entitlements.sql`.
///
/// `advisor` covers the AI advisor / manager chatbot (there is no
/// separate "chatbots" product concept — Starter's "manager chatbot" IS
/// the advisor surface). Order is the display order in the matrix
/// (advisor first, then the features each higher plan layers on).
const Map<String, String> kFeatureSlugCatalog = <String, String>{
  'advisor': 'AI advisor',
  'lms': 'Learning (LMS)',
  'scoreboard': 'Scoreboard',
  'staff_coach': 'Staff coaching',
  'sops': 'Standard operating procedures',
  'workflows': 'Workflow catalog',
};

/// The known feature slugs in display order. Used by the screen to draw
/// the matrix columns and by the in-memory gateway / client validation to
/// reject an unknown slug.
final List<String> kFeatureSlugOrder = kFeatureSlugCatalog.keys.toList(
  growable: false,
);

/// The set of feature slugs the proxy + gateway accept. Mirrors
/// [kFeatureSlugCatalog]'s keys.
final Set<String> kFeatureSlugKeys = kFeatureSlugCatalog.keys.toSet();

/// Resolve a feature slug to its plain-English display name; falls back to
/// the raw slug for an unknown key so the UI never renders blank.
String featureSlugDisplayName(String slug) => kFeatureSlugCatalog[slug] ?? slug;

/// One editable row from the server `feature_entitlements` table
/// (`db/migrations/202605241700_plans_and_limits_phase5a_feature_entitlements.sql`):
/// whether one plan ([tierKey]) includes one feature ([featureSlug]).
///
/// This is the live, admin-editable source of the per-plan feature matrix.
/// The screen reads it via `GET /v1/admin/pricing/entitlements` and falls
/// back to [buildDefaultFeatureEntitlements] when the call fails or in
/// offline demo mode, so the matrix always paints.
@immutable
class FeatureEntitlementEntry {
  const FeatureEntitlementEntry({
    required this.tierKey,
    required this.featureSlug,
    required this.enabled,
    this.updatedAt,
    this.updatedBy,
  });

  /// Matches [PricingTierTemplate.tierKey] / the catalog primary key.
  final String tierKey;

  /// Matches a key in [kFeatureSlugCatalog].
  final String featureSlug;

  /// Whether the plan includes the feature.
  final bool enabled;

  /// UTC instant of the last toggle + the actor who made it. Null on a
  /// default entry projected from [buildDefaultFeatureEntitlements].
  final DateTime? updatedAt;
  final String? updatedBy;

  FeatureEntitlementEntry copyWith({bool? enabled}) => FeatureEntitlementEntry(
    tierKey: tierKey,
    featureSlug: featureSlug,
    enabled: enabled ?? this.enabled,
    updatedAt: updatedAt,
    updatedBy: updatedBy,
  );

  static FeatureEntitlementEntry fromJson(Map<String, Object?> json) {
    final updatedAtRaw = json['updated_at'] as String?;
    return FeatureEntitlementEntry(
      tierKey: json['tier_key']! as String,
      featureSlug: json['feature_slug']! as String,
      enabled: _asBool(json['enabled']),
      updatedAt: (updatedAtRaw == null || updatedAtRaw.isEmpty)
          ? null
          : DateTime.parse(updatedAtRaw),
      updatedBy: json['updated_by'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'tier_key': tierKey,
    'feature_slug': featureSlug,
    'enabled': enabled,
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
    if (updatedBy != null) 'updated_by': updatedBy,
  };
}

/// Toggle one plan/feature pair. Goes to
/// `PATCH /v1/admin/pricing/entitlements/{tier_key}/{feature_slug}`. The
/// keys are path segments; only `enabled` travels in the body.
@immutable
class FeatureEntitlementUpdateCommand {
  const FeatureEntitlementUpdateCommand({
    required this.tierKey,
    required this.featureSlug,
    required this.enabled,
    required this.idempotencyKey,
  });

  final String tierKey;
  final String featureSlug;
  final bool enabled;

  /// Per-action idempotency key. The proxy stores it in
  /// `admin_request_idempotency` so a retried PATCH collapses to one
  /// toggle + one audit row.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{'enabled': enabled};
}

/// The cumulative-ladder DEFAULT matrix, mirroring the migration seed in
/// `202605241700_plans_and_limits_phase5a_feature_entitlements.sql`. Each
/// plan includes everything below it. Used by the in-memory gateway so the
/// demo walkthrough edits the matrix offline, and by the screen as the
/// fallback when `GET /v1/admin/pricing/entitlements` is unavailable.
///
/// A pair NOT in this map is `enabled: false` (the feature is not included
/// in that plan by default).
List<FeatureEntitlementEntry> buildDefaultFeatureEntitlements() {
  // Lowest tier at which each feature turns on, cumulative up the ladder.
  // Index into [kPricingPlanPresentations] (Pilot=0 .. Enterprise=5).
  const minTierIndexBySlug = <String, int>{
    'advisor': 0, // Pilot (free preview) + every paid tier.
    'lms': 2, // Premium and up.
    'scoreboard': 2, // Premium and up.
    'staff_coach': 3, // Elite and up.
    'sops': 3, // Elite and up.
    'workflows': 4, // Pro and up.
  };
  final entries = <FeatureEntitlementEntry>[];
  for (
    var tierIndex = 0;
    tierIndex < kPricingPlanPresentations.length;
    tierIndex++
  ) {
    final tierKey = kPricingPlanPresentations[tierIndex].tierKey;
    for (final slug in kFeatureSlugOrder) {
      final minIndex = minTierIndexBySlug[slug] ?? 0;
      entries.add(
        FeatureEntitlementEntry(
          tierKey: tierKey,
          featureSlug: slug,
          enabled: tierIndex >= minIndex,
        ),
      );
    }
  }
  return entries;
}

// ---------------------------------------------------------------------------
// Plans and limits V1 - hierarchy-scoped custom contracts.
// ---------------------------------------------------------------------------

/// Scope selected in the admin hierarchy tree for scoped commercial terms.
enum ScopedPricingContractScopeType {
  business('business'),
  orgUnit('org_unit'),
  location('location');

  const ScopedPricingContractScopeType(this.wireValue);

  final String wireValue;

  static ScopedPricingContractScopeType fromWireValue(String raw) {
    for (final value in ScopedPricingContractScopeType.values) {
      if (value.wireValue == raw) return value;
    }
    throw ArgumentError.value(raw, 'scope_type', 'unknown scoped contract');
  }
}

/// Whether the selected hierarchy node has its own override, inherits one,
/// or falls through to the global plan catalog.
enum ScopedPricingContractOverrideStatus {
  setHere('set_here'),
  inherited('inherited'),
  catalogDefault('catalog_default');

  const ScopedPricingContractOverrideStatus(this.wireValue);

  final String wireValue;

  static ScopedPricingContractOverrideStatus fromWireValue(String raw) {
    for (final value in ScopedPricingContractOverrideStatus.values) {
      if (value.wireValue == raw) return value;
    }
    throw ArgumentError.value(raw, 'override_status', 'unknown status');
  }
}

/// Kind of source that supplied the effective commercial terms.
enum ScopedPricingContractInheritedSourceType {
  scopedOverride('scoped_override'),
  catalogDefault('catalog_default');

  const ScopedPricingContractInheritedSourceType(this.wireValue);

  final String wireValue;

  static ScopedPricingContractInheritedSourceType fromWireValue(String raw) {
    for (final value in ScopedPricingContractInheritedSourceType.values) {
      if (value.wireValue == raw) return value;
    }
    throw ArgumentError.value(
      raw,
      'source_type',
      'unknown scoped contract source',
    );
  }
}

/// Business, org-unit, or location node used by the scoped-contract resolver.
@immutable
class ScopedPricingContractScope {
  const ScopedPricingContractScope({
    required this.operatorId,
    required this.scopeType,
    this.orgUnitId,
    this.locationId,
    this.displayName,
  });

  final String operatorId;
  final ScopedPricingContractScopeType scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String? displayName;

  static ScopedPricingContractScope fromJson(Map<String, Object?> json) {
    return ScopedPricingContractScope(
      operatorId: json['operator_id']! as String,
      scopeType: ScopedPricingContractScopeType.fromWireValue(
        json['scope_type']! as String,
      ),
      orgUnitId: json['org_unit_id'] as String?,
      locationId: json['location_id'] as String?,
      displayName: json['display_name'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...toRequestJson(),
    if (displayName != null && displayName!.isNotEmpty)
      'display_name': displayName,
  };

  /// Request/query shape. Labels stay response-only so writes carry only IDs.
  Map<String, Object?> toRequestJson() => <String, Object?>{
    'operator_id': operatorId,
    'scope_type': scopeType.wireValue,
    if (orgUnitId != null && orgUnitId!.isNotEmpty) 'org_unit_id': orgUnitId,
    if (locationId != null && locationId!.isNotEmpty) 'location_id': locationId,
  };

  Map<String, String> toQueryParameters() => <String, String>{
    'operator_id': operatorId,
    'scope_type': scopeType.wireValue,
    if (orgUnitId != null && orgUnitId!.isNotEmpty) 'org_unit_id': orgUnitId!,
    if (locationId != null && locationId!.isNotEmpty)
      'location_id': locationId!,
  };
}

/// The effective scoped commercial terms after hierarchy inheritance.
@immutable
class ScopedPricingContractValue {
  const ScopedPricingContractValue({
    required this.tierKey,
    this.monthlyUsd,
    this.firstNSeats,
    this.firstSeatUsd,
    this.additionalSeatUsd,
    this.onboardingMinUsd,
    this.onboardingMaxUsd,
    this.advisorCapMonthlyUsd,
    this.billingOwnerOrgUnitId,
    this.effectiveFrom,
    this.effectiveUntil,
    this.contractLabel,
    this.internalNote,
    this.updatedAt,
    this.updatedBy,
  });

  final String tierKey;
  final double? monthlyUsd;
  final int? firstNSeats;
  final double? firstSeatUsd;
  final double? additionalSeatUsd;
  final double? onboardingMinUsd;
  final double? onboardingMaxUsd;
  final double? advisorCapMonthlyUsd;
  final String? billingOwnerOrgUnitId;
  final DateTime? effectiveFrom;
  final DateTime? effectiveUntil;
  final String? contractLabel;
  final String? internalNote;
  final DateTime? updatedAt;
  final String? updatedBy;

  ScopedPricingContractValue withAuditStamp({
    required DateTime updatedAt,
    required String? updatedBy,
  }) {
    return ScopedPricingContractValue(
      tierKey: tierKey,
      monthlyUsd: monthlyUsd,
      firstNSeats: firstNSeats,
      firstSeatUsd: firstSeatUsd,
      additionalSeatUsd: additionalSeatUsd,
      onboardingMinUsd: onboardingMinUsd,
      onboardingMaxUsd: onboardingMaxUsd,
      advisorCapMonthlyUsd: advisorCapMonthlyUsd,
      billingOwnerOrgUnitId: billingOwnerOrgUnitId,
      effectiveFrom: effectiveFrom,
      effectiveUntil: effectiveUntil,
      contractLabel: contractLabel,
      internalNote: internalNote,
      updatedAt: updatedAt,
      updatedBy: updatedBy,
    );
  }

  static ScopedPricingContractValue fromJson(Map<String, Object?> json) {
    return ScopedPricingContractValue(
      tierKey: json['tier_key']! as String,
      monthlyUsd: _asNullableDouble(json['monthly_usd']),
      firstNSeats: _asNullableInt(json['first_n_seats']),
      firstSeatUsd: _asNullableDouble(json['first_seat_usd']),
      additionalSeatUsd: _asNullableDouble(json['additional_seat_usd']),
      onboardingMinUsd: _asNullableDouble(json['onboarding_min_usd']),
      onboardingMaxUsd: _asNullableDouble(json['onboarding_max_usd']),
      advisorCapMonthlyUsd: _asNullableDouble(
        json['advisor_cap_monthly_usd'] ??
            json['advisor_spend_cap_monthly_usd'],
      ),
      billingOwnerOrgUnitId: json['billing_owner_org_unit_id'] as String?,
      effectiveFrom: _asNullableDateTime(json['effective_from']),
      effectiveUntil: _asNullableDateTime(json['effective_until']),
      contractLabel: json['contract_label'] as String?,
      internalNote: json['internal_note'] as String?,
      updatedAt: _asNullableDateTime(json['updated_at']),
      updatedBy: json['updated_by'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...toRequestJson(),
    if (updatedAt != null) 'updated_at': updatedAt!.toUtc().toIso8601String(),
    if (updatedBy != null) 'updated_by': updatedBy,
  };

  /// Write shape. Audit metadata is response-only.
  Map<String, Object?> toRequestJson() => <String, Object?>{
    'tier_key': tierKey,
    'monthly_usd': monthlyUsd,
    'first_n_seats': firstNSeats,
    'first_seat_usd': firstSeatUsd,
    'additional_seat_usd': additionalSeatUsd,
    'onboarding_min_usd': onboardingMinUsd,
    'onboarding_max_usd': onboardingMaxUsd,
    'advisor_cap_monthly_usd': advisorCapMonthlyUsd,
    'billing_owner_org_unit_id': billingOwnerOrgUnitId,
    'effective_from': effectiveFrom?.toUtc().toIso8601String(),
    'effective_until': effectiveUntil?.toUtc().toIso8601String(),
    'contract_label': contractLabel,
    'internal_note': internalNote,
  };
}

/// Source that supplied the effective value: a scoped override or the
/// global catalog default.
@immutable
class ScopedPricingContractInheritedSource {
  const ScopedPricingContractInheritedSource({
    required this.sourceType,
    this.scope,
    this.overrideId,
    this.displayName,
    this.tierKey,
  });

  final ScopedPricingContractInheritedSourceType sourceType;
  final ScopedPricingContractScope? scope;
  final String? overrideId;
  final String? displayName;
  final String? tierKey;

  static ScopedPricingContractInheritedSource fromJson(
    Map<String, Object?> json,
  ) {
    final sourceTypeRaw = json['source_type'] as String?;
    final scopeRaw = json['scope'];
    final scope = scopeRaw is Map
        ? ScopedPricingContractScope.fromJson(scopeRaw.cast<String, Object?>())
        : (json['scope_type'] == null
              ? null
              : ScopedPricingContractScope.fromJson(json));
    return ScopedPricingContractInheritedSource(
      sourceType: sourceTypeRaw == null
          ? (scope == null
                ? ScopedPricingContractInheritedSourceType.catalogDefault
                : ScopedPricingContractInheritedSourceType.scopedOverride)
          : ScopedPricingContractInheritedSourceType.fromWireValue(
              sourceTypeRaw,
            ),
      scope: scope,
      overrideId:
          json['override_id'] as String? ??
          json['contract_override_id'] as String?,
      displayName: json['display_name'] as String?,
      tierKey: json['tier_key'] as String?,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'source_type': sourceType.wireValue,
    if (scope != null) 'scope': scope!.toJson(),
    if (overrideId != null) 'override_id': overrideId,
    if (displayName != null) 'display_name': displayName,
    if (tierKey != null) 'tier_key': tierKey,
  };
}

/// The hierarchy node that a save or clear action will mutate.
@immutable
class ScopedPricingContractMutationTarget {
  const ScopedPricingContractMutationTarget({
    required this.scope,
    this.existingOverrideId,
    this.canSave = true,
    this.canDelete = false,
  });

  final ScopedPricingContractScope scope;
  final String? existingOverrideId;
  final bool canSave;
  final bool canDelete;

  static ScopedPricingContractMutationTarget fromJson(
    Map<String, Object?> json,
  ) {
    final scopeRaw = json['scope'];
    final scope = scopeRaw is Map
        ? ScopedPricingContractScope.fromJson(scopeRaw.cast<String, Object?>())
        : ScopedPricingContractScope.fromJson(json);
    return ScopedPricingContractMutationTarget(
      scope: scope,
      existingOverrideId:
          json['existing_override_id'] as String? ??
          json['override_id'] as String? ??
          json['contract_override_id'] as String?,
      canSave: _asBool(json['can_save'] ?? true),
      canDelete: _asBool(json['can_delete'] ?? false),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'scope': scope.toJson(),
    'existing_override_id': existingOverrideId,
    'can_save': canSave,
    'can_delete': canDelete,
  };
}

/// Effective resolver response for the Businesses tab scoped contract panel.
@immutable
class ScopedPricingContractEffectiveResponse {
  const ScopedPricingContractEffectiveResponse({
    required this.selectedScope,
    required this.overrideStatus,
    required this.inheritedSource,
    required this.effectiveValue,
    required this.mutationTarget,
  });

  final ScopedPricingContractScope selectedScope;
  final ScopedPricingContractOverrideStatus overrideStatus;
  final ScopedPricingContractInheritedSource inheritedSource;
  final ScopedPricingContractValue effectiveValue;
  final ScopedPricingContractMutationTarget mutationTarget;

  static ScopedPricingContractEffectiveResponse fromEnvelope(
    Map<String, Object?> json,
  ) {
    final nested =
        json['effective_contract'] ??
        json['effective'] ??
        json['contract'] ??
        json['scoped_contract'];
    if (nested is Map) {
      return fromJson(nested.cast<String, Object?>());
    }
    return fromJson(json);
  }

  static ScopedPricingContractEffectiveResponse fromJson(
    Map<String, Object?> json,
  ) {
    final selectedScope = ScopedPricingContractScope.fromJson(
      (json['selected_scope'] as Map).cast<String, Object?>(),
    );
    final effectiveRaw =
        json['effective_value'] ?? json['effective_contract_value'];
    final inheritedRaw = json['inherited_source'];
    return ScopedPricingContractEffectiveResponse(
      selectedScope: selectedScope,
      overrideStatus: ScopedPricingContractOverrideStatus.fromWireValue(
        json['override_status']! as String,
      ),
      inheritedSource: inheritedRaw is Map
          ? ScopedPricingContractInheritedSource.fromJson(
              inheritedRaw.cast<String, Object?>(),
            )
          : const ScopedPricingContractInheritedSource(
              sourceType:
                  ScopedPricingContractInheritedSourceType.catalogDefault,
              displayName: 'Global plan catalog',
            ),
      effectiveValue: ScopedPricingContractValue.fromJson(
        (effectiveRaw as Map).cast<String, Object?>(),
      ),
      mutationTarget: json['mutation_target'] is Map
          ? ScopedPricingContractMutationTarget.fromJson(
              (json['mutation_target'] as Map).cast<String, Object?>(),
            )
          : ScopedPricingContractMutationTarget(scope: selectedScope),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'selected_scope': selectedScope.toJson(),
    'override_status': overrideStatus.wireValue,
    'inherited_source': inheritedSource.toJson(),
    'effective_value': effectiveValue.toJson(),
    'mutation_target': mutationTarget.toJson(),
  };
}

/// Seed/read model for one persisted scoped override.
@immutable
class ScopedPricingContractOverride {
  const ScopedPricingContractOverride({
    required this.id,
    required this.scope,
    required this.value,
  });

  final String id;
  final ScopedPricingContractScope scope;
  final ScopedPricingContractValue value;

  static ScopedPricingContractOverride fromJson(Map<String, Object?> json) {
    final scopeRaw = json['scope'];
    final valueRaw = json['value'];
    return ScopedPricingContractOverride(
      id: json['id']! as String,
      scope: scopeRaw is Map
          ? ScopedPricingContractScope.fromJson(
              scopeRaw.cast<String, Object?>(),
            )
          : ScopedPricingContractScope.fromJson(json),
      value: valueRaw is Map
          ? ScopedPricingContractValue.fromJson(
              valueRaw.cast<String, Object?>(),
            )
          : ScopedPricingContractValue.fromJson(json),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'scope': scope.toJson(),
    'value': value.toJson(),
  };
}

/// Save or replace a scoped custom contract. Goes to
/// `PUT /v1/admin/pricing/scoped-contracts`.
@immutable
class ScopedPricingContractSaveCommand {
  const ScopedPricingContractSaveCommand({
    required this.targetScope,
    required this.value,
    required this.adminReason,
    required this.idempotencyKey,
    this.contractOverrideId,
  });

  final ScopedPricingContractScope targetScope;
  final ScopedPricingContractValue value;
  final String adminReason;
  final String idempotencyKey;
  final String? contractOverrideId;

  Map<String, Object?> toJson() => <String, Object?>{
    ...targetScope.toRequestJson(),
    if (contractOverrideId != null) 'id': contractOverrideId,
    ...value.toRequestJson(),
    'admin_reason': adminReason,
  };
}

/// Clear one scoped custom contract. Goes to
/// `DELETE /v1/admin/pricing/scoped-contracts/{id}`.
@immutable
class ScopedPricingContractDeleteCommand {
  const ScopedPricingContractDeleteCommand({
    required this.contractOverrideId,
    required this.selectedScope,
    required this.adminReason,
    required this.idempotencyKey,
  });

  final String contractOverrideId;
  final ScopedPricingContractScope selectedScope;
  final String adminReason;
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    ...selectedScope.toRequestJson(),
    'admin_reason': adminReason,
  };
}

bool _asBool(Object? raw) {
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    final lower = raw.toLowerCase();
    return raw == 't' || lower == 'true';
  }
  return false;
}

double _asDouble(Object? raw) {
  if (raw == null) return 0;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw) ?? 0;
  return 0;
}

/// Parse a JSON money/number field that may be a genuine SQL NULL.
/// Numeric columns can arrive as `num` (driver) or `String` (jsonb text);
/// a missing/blank value stays null so the UI renders the honest empty
/// sentinel rather than a phantom $0.
double? _asNullableDouble(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  if (raw is String) {
    if (raw.isEmpty) return null;
    return double.tryParse(raw);
  }
  return null;
}

int? _asNullableInt(Object? raw) {
  if (raw == null) return null;
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) {
    if (raw.isEmpty) return null;
    return int.tryParse(raw);
  }
  return null;
}

DateTime? _asNullableDateTime(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is String) {
    if (raw.isEmpty) return null;
    return DateTime.parse(raw);
  }
  return null;
}
