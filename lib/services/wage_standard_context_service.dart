// Phase 7.55i.3 — Wage Standard Context Service.
//
// One repository-backed wage-source authority with integration-first
// precedence and a lightweight Settings-based fallback generator.
//
// Precedence waterfall:
//   1. laborDerivedFromActualDollars  — future Phase 8 labor integration
//   2. laborDerivedFromRatesAndHours  — future Phase 8 labor integration
//   3. appConfiguredGenerator         — restaurant-scoped role/rate setup
//   4. configFallback                 — MeridianConfig defaults
//   5. unavailable                    — no wage data at all
//
// For this prompt, labor-derived branches are clean seams only.
// Real current outputs are appConfiguredGenerator or configFallback.

import '../domain/models/active_target_profile.dart';
import '../domain/models/wage_role_row.dart';
import '../domain/models/wage_standard_context.dart';
import '../domain/models/wage_standard_source.dart';
import '../domain/services/target_cycle_active_target_profile_projector.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import '../data/app_defaults.dart'; // MeridianConfig for config fallback

class WageStandardContextService {
  WageStandardContextService._();
  static final WageStandardContextService instance =
      WageStandardContextService._();

  /// Resolves the current wage authority for a restaurant using the
  /// integration-first precedence waterfall.
  Future<WageStandardContext> resolve(String restaurantId) async {
    final now = DateTime.now().toIso8601String();

    // ── Step 1: labor-derived from actual dollars ─────────────────────────
    // Clean seam for Phase 8 labor adapters. Not available yet.

    // ── Step 2: labor-derived from rates and hours ────────────────────────
    // Clean seam for Phase 8 labor adapters. Not available yet.

    // ── Step 3: app-configured generator ─────────────────────────────────
    final rows = await SqliteWageRoleRowRepository.instance.getRows(
      restaurantId,
    );
    if (rows.isNotEmpty) {
      final fohRows =
          rows.where((r) => r.laborBucket == 'foh').toList();
      final bohRows =
          rows.where((r) => r.laborBucket == 'boh').toList();

      final fohWage = _weightedAvgRate(fohRows);
      final bohWage = _weightedAvgRate(bohRows);

      // Reference blended: all rows (foh + boh + manager)
      final blended = _weightedAvgRate(rows);

      // The generator must produce BOTH FOH and BOH standards to be
      // considered a complete app-configured source. Manager-only or
      // single-bucket setups degrade to configFallback so that
      // provenance and in-force standards stay honest.
      if (fohWage != null && bohWage != null) {
        return WageStandardContext(
          restaurantId: restaurantId,
          fohWage: fohWage,
          bohWage: bohWage,
          referenceBlendedWage: blended,
          source: WageStandardSource.appConfiguredGenerator,
          builtAt: now,
        );
      }

      // Incomplete generator — fall through to config fallback but
      // keep the reference blended wage from the rows that do exist.
    }

    // ── Step 4: config fallback ──────────────────────────────────────────
    return WageStandardContext(
      restaurantId: restaurantId,
      fohWage: MeridianConfig.fohWage,
      bohWage: MeridianConfig.bohWage,
      referenceBlendedWage: null,
      source: WageStandardSource.configFallback,
      builtAt: now,
    );
  }

  /// Convenience: resolves for the active restaurant.
  Future<WageStandardContext> resolveForActiveRestaurant() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();
    return resolve(restaurantId);
  }

  /// Syncs resolved wages into the current active target profile.
  ///
  /// Reads the current profile, resolves wage authority, and if the
  /// resolved wages differ from the profile, updates the profile's
  /// FOH/BOH wages and recomputes theoretical labor percentages.
  Future<void> syncWagesToActiveProfile() async {
    final restaurantId = await SqliteRestaurantScopeRepository.instance
        .getActiveRestaurantId();

    final wageCtx = await resolve(restaurantId);
    if (!wageCtx.isAvailable) return;

    final profile = await SqliteTargetProfileRepository.instance
        .getActiveTargetProfile(restaurantId);
    if (profile == null) return;

    final fohWage = wageCtx.fohWage ?? profile.fohWage;
    final bohWage = wageCtx.bohWage ?? profile.bohWage;

    // Skip if wages haven't changed
    if ((fohWage - profile.fohWage).abs() < 0.001 &&
        (bohWage - profile.bohWage).abs() < 0.001) {
      return;
    }

    // Recompute theoretical labor % with new wages
    final fohPct = (profile.targetCPLH > 0 && profile.targetPPA > 0)
        ? fohWage / (profile.targetCPLH * profile.targetPPA) * 100
        : 0.0;
    final bohPct =
        profile.targetSPLH > 0 ? bohWage / profile.targetSPLH * 100 : 0.0;

    final updated = ActiveTargetProfile(
      targetProfileId: profile.targetProfileId,
      restaurantId: profile.restaurantId,
      sourceType: profile.sourceType,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      fohWage: fohWage,
      bohWage: bohWage,
      opzFloorCPLH: profile.opzFloorCPLH,
      opzCeilingCPLH: profile.opzCeilingCPLH,
      theoreticalFohLaborPct: fohPct,
      theoreticalBohLaborPct: bohPct,
      theoreticalLaborPct: fohPct + bohPct,
      builtAt: DateTime.now().toIso8601String(),
    );

    await SqliteTargetProfileRepository.instance
        .upsertActiveTargetProfile(updated);
  }

  // ── Wage-aware bootstrap ────────────────────────────────────────────

  /// Loads or bootstraps the active target profile for [restaurantId],
  /// ensuring the persisted profile carries wages resolved through
  /// the wage-authority waterfall instead of ad hoc defaults.
  ///
  /// All service/notifier "profile missing" paths should call this
  /// instead of rebuilding from the bridge helper directly. Bootstrap
  /// order: prefer the active cycle when present, otherwise fall back
  /// to an honest config-default profile with resolved wages.
  Future<ActiveTargetProfile> loadOrBootstrapProfile(
      String restaurantId) async {
    final cycle = await SqliteTargetCycleRepository.instance
        .getActiveCycle(restaurantId);
    if (cycle != null) {
      final projected =
          TargetCycleActiveTargetProfileProjector.project(cycle);
      final existing = await SqliteTargetProfileRepository.instance
          .getActiveTargetProfile(restaurantId);
      if (existing == null ||
          !_matchesCycleProjection(existing, projected)) {
        await SqliteTargetProfileRepository.instance
            .upsertActiveTargetProfile(projected);
        return projected;
      }
      return existing;
    }

    final existing = await SqliteTargetProfileRepository.instance
        .getActiveTargetProfile(restaurantId);
    if (existing != null) return existing;

    final wageCtx = await resolve(restaurantId);
    final profile = ActiveTargetProfile.build(
      restaurantId: restaurantId,
      sourceType: 'system_baseline_insufficient',
      targetCPLH: MeridianConfig.targetCPLH,
      targetSPLH: MeridianConfig.targetSPLH,
      targetPPA: MeridianConfig.targetPPA,
      fohWage: wageCtx.fohWage ?? MeridianConfig.fohWage,
      bohWage: wageCtx.bohWage ?? MeridianConfig.bohWage,
      opzFloorCPLH: MeridianConfig.opzFloorCPLH,
      opzCeilingCPLH: MeridianConfig.opzCeilingCPLH,
    );
    await SqliteTargetProfileRepository.instance
        .upsertActiveTargetProfile(profile);
    return profile;
  }

  static bool _matchesCycleProjection(
    ActiveTargetProfile existing,
    ActiveTargetProfile projected,
  ) {
    bool same(double a, double b) => (a - b).abs() < 0.001;

    return existing.restaurantId == projected.restaurantId &&
        existing.sourceType == projected.sourceType &&
        same(existing.targetCPLH, projected.targetCPLH) &&
        same(existing.targetSPLH, projected.targetSPLH) &&
        same(existing.targetPPA, projected.targetPPA) &&
        same(existing.fohWage, projected.fohWage) &&
        same(existing.bohWage, projected.bohWage) &&
        same(existing.opzFloorCPLH, projected.opzFloorCPLH) &&
        same(existing.opzCeilingCPLH, projected.opzCeilingCPLH) &&
        same(existing.theoreticalFohLaborPct,
            projected.theoreticalFohLaborPct) &&
        same(existing.theoreticalBohLaborPct,
            projected.theoreticalBohLaborPct) &&
        same(existing.theoreticalLaborPct, projected.theoreticalLaborPct);
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  /// Weighted average hourly rate from a list of role rows.
  /// Returns null if no rows or total hours is zero.
  static double? _weightedAvgRate(List<WageRoleRow> rows) {
    if (rows.isEmpty) return null;
    final totalHours =
        rows.fold<double>(0, (s, r) => s + r.weightedHours);
    if (totalHours <= 0) return null;
    final totalDollars =
        rows.fold<double>(0, (s, r) => s + r.hourlyRate * r.weightedHours);
    return totalDollars / totalHours;
  }

  /// Summarizes a wage mix for the Settings whole-mix setup UX.
  ///
  /// Pure derivation over the provided rows. Does not hit the database
  /// or touch active profile state. The [resolve] / [syncWagesToActiveProfile]
  /// calls remain the canonical wage-authority seam — this helper only
  /// builds display-friendly totals for the Settings setup flow.
  ///
  /// Rules preserved from [resolve]:
  ///   - `hasCompleteFohBoh` is true only when at least one FOH row AND
  ///     at least one BOH row exist. That mirrors the rule that decides
  ///     whether the generator resolves as `appConfiguredGenerator` vs
  ///     degrading to `configFallback`.
  ///   - Manager rows are included in `totalHourlyCost` and
  ///     `totalWeightedHours` but do not make the mix "complete".
  static WageMixSetupSummary summarizeMix(List<WageRoleRow> rows) {
    final foh = rows.where((r) => r.laborBucket == 'foh').toList();
    final boh = rows.where((r) => r.laborBucket == 'boh').toList();
    final mgr = rows.where((r) => r.laborBucket == 'manager').toList();

    final totalHours =
        rows.fold<double>(0, (s, r) => s + r.weightedHours);
    final totalCost =
        rows.fold<double>(0, (s, r) => s + r.hourlyRate * r.weightedHours);

    return WageMixSetupSummary(
      fohRows: foh,
      bohRows: boh,
      managerRows: mgr,
      totalWeightedHours: totalHours,
      totalHourlyCost: totalCost,
      hasCompleteFohBoh: foh.isNotEmpty && boh.isNotEmpty,
    );
  }
}

/// Display-friendly summary of a wage mix, derived from the raw
/// [WageRoleRow] persistence. Used by the Settings whole-mix setup UX
/// to show computed totals without duplicating the derivation math.
///
/// This is not an authority contract. The canonical wage authority is
/// still resolved by [WageStandardContextService.resolve] and pushed
/// into the active profile by [WageStandardContextService.syncWagesToActiveProfile].
class WageMixSetupSummary {
  final List<WageRoleRow> fohRows;
  final List<WageRoleRow> bohRows;
  final List<WageRoleRow> managerRows;
  final double totalWeightedHours;
  final double totalHourlyCost;
  final bool hasCompleteFohBoh;

  const WageMixSetupSummary({
    required this.fohRows,
    required this.bohRows,
    required this.managerRows,
    required this.totalWeightedHours,
    required this.totalHourlyCost,
    required this.hasCompleteFohBoh,
  });

  bool get isEmpty =>
      fohRows.isEmpty && bohRows.isEmpty && managerRows.isEmpty;
}