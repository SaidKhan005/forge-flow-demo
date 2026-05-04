// Phase 11A.2 — Pricing tier admin value objects.
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

double _asDouble(Object? raw) {
  if (raw == null) return 0;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw) ?? 0;
  return 0;
}
