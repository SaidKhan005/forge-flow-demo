// Settings screen widget tests.
// ignore_for_file: curly_braces_in_flow_control_structures

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/data/schedule_plan_read_service.dart';
import 'package:forge_and_flow/data/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/data/wage_standard_context_service.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/models/wage_role_row.dart';
import 'package:forge_and_flow/domain/models/wage_standard_context.dart';
import 'package:forge_and_flow/domain/models/wage_standard_source.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_wage_role_row_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/screens/settings_screen.dart';

bool _includePrunedLabelGroups() => false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  group('Settings screen smoke', () {
    testWidgets('current status renders in the DATA STATUS section',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(
            importStatus: 'completed',
            timestamp: '2026-03-30T10:00:00',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('DATA STATUS'), findsOneWidget);
      expect(find.text('CURRENT'), findsOneWidget);
    });

    testWidgets('core Settings sections and mock replay anchors render',
        (tester) async {
      await _reseedDemoForWidgetTest(tester);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RestaurantScopeNotifier>(
              create: (_) => RestaurantScopeNotifier.fromRestaurant(
                const RestaurantLocation(
                  restaurantId: 'demo_restaurant_001',
                  displayName: 'Forge & Flow',
                  businessTimezone: 'America/St_Johns',
                  createdAt: '2026-03-30T10:00:00Z',
                  updatedAt: '2026-03-30T10:00:00Z',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        ),
      );
      await _pumpForAsync(tester);
      expect(find.text('MOCK REPLAY', skipOffstage: false), findsOneWidget);
      expect(find.text('DATA MANAGEMENT', skipOffstage: false), findsOneWidget);
      await _scrollToText(tester, 'TIMING AUTHORITY');

      expect(find.text('TIMING AUTHORITY', skipOffstage: false), findsOneWidget);
      expect(find.text('America/St_Johns'), findsOneWidget);
    });
  });

  if (_includePrunedLabelGroups()) group('Settings DATA STATUS section', () {
    testWidgets('shows CURRENT when status is current', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(
            importStatus: 'completed',
            timestamp: '2026-03-30T10:00:00',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('DATA STATUS'), findsOneWidget);
      expect(find.text('CURRENT'), findsOneWidget);
    });

    testWidgets('shows IMPORT FAILED when status is failedImport',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.failedImport(
            errorSummary: 'Connection timeout',
            timestamp: '2026-03-30T09:00:00',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('IMPORT FAILED'), findsOneWidget);
    });

    testWidgets('shows NO DATA when status is noData', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SettingsScreen(initialStatus: AppDataStatus.noData),
      ));
      await tester.pump();

      expect(find.text('NO DATA'), findsOneWidget);
    });

    testWidgets('shows HISTORICAL ONLY when status is historicalOnly',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: SettingsScreen(initialStatus: AppDataStatus.historicalOnly),
      ));
      await tester.pump();

      expect(find.text('HISTORICAL ONLY'), findsOneWidget);
    });

    testWidgets('shows STALE when status is stale', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.stale(
            timestamp: '2026-03-28T10:00:00',
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('STALE'), findsOneWidget);
    });

    testWidgets('Clear All Data description text is correct', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
        ),
      ));
      await tester.pump();
      await _scrollToText(tester, 'Clear All Data');

      expect(
        find.textContaining(
            'keeping restaurant scope and connector settings'),
        findsOneWidget,
      );
    });
  });

  // ── Section organization (7.55m.6) ──────────────────────────────────

  if (_includePrunedLabelGroups()) group('Settings section labels (7.55m.6)', () {
    testWidgets('shows MOCK REPLAY section label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await tester.pump();

      expect(find.text('MOCK REPLAY'), findsOneWidget);
    });

    testWidgets('shows DATA MANAGEMENT section label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await tester.pump();

      expect(find.text('DATA MANAGEMENT'), findsOneWidget);
    });
  });

  if (_includePrunedLabelGroups()) group('Settings timing authority section', () {
    testWidgets('shows persisted restaurant timing settings', (tester) async {
      await _reseedDemoForWidgetTest(tester);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<RestaurantScopeNotifier>(
              create: (_) => RestaurantScopeNotifier.fromRestaurant(
                const RestaurantLocation(
                  restaurantId: 'demo_restaurant_001',
                  displayName: 'Forge & Flow',
                  businessTimezone: 'America/St_Johns',
                  createdAt: '2026-03-30T10:00:00Z',
                  updatedAt: '2026-03-30T10:00:00Z',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            home: SettingsScreen(
              initialStatus: AppDataStatus.current(),
              initialMockDate: '2026-03-27',
            ),
          ),
        ),
      );
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'TIMING AUTHORITY');

      expect(find.text('TIMING AUTHORITY'), findsOneWidget);
      expect(find.text('America/St_Johns'), findsOneWidget);
      expect(find.text('Business Day Starts'), findsOneWidget);
      expect(find.text('Week Starts'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Dinner'), findsOneWidget);
      expect(find.text('Late Night'), findsOneWidget);
    });
  });

  // ── Mock replay controls ──────────────────────────────────────────────

  if (_includePrunedLabelGroups()) group('Settings mock replay controls', () {
    testWidgets('shows Mock Business Date label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await tester.pump();

      expect(find.text('Mock Business Date'), findsOneWidget);
    });

    testWidgets('shows formatted mock date when provided', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await tester.pump();

      expect(find.text('Fri, Mar 27, 2026'), findsOneWidget);
    });

    testWidgets('shows Reset Mock Scenario action', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await tester.pump();

      expect(find.text('Reset Mock Scenario'), findsOneWidget);
    });

    testWidgets('shows Advance Mock Day action', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await tester.pump();

      expect(find.text('Advance Mock Day'), findsOneWidget);
      expect(find.text('Move mock business date forward one day'),
          findsOneWidget);
    });
  });

  // ── Wage mix panel read-only shape (7.55p.5f1a) ──────────────────────

  group('Settings data alignment audit plan authority', () {
    testWidgets(
        'audit panel stays on the strict locked-plan path when the snapshot '
        'is missing', (tester) async {
      await _reseedDemoForWidgetTest(tester);

      await tester.runAsync(() async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('weekly_plan_snapshots');

        // Sanity: the live plan path still resolves, but the audit panel
        // must not use it as a competing authority path.
        final livePlan =
            await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
        expect(livePlan, isNotNull);
        expect(await db.query('weekly_plan_snapshots'), isEmpty);
      });

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Data Alignment Audit');

      await tester.tap(find.text('Data Alignment Audit'));
      await _pumpUntilFound(
        tester,
        find.text('SCHEDULE FORECAST', skipOffstage: false),
      );

      expect(find.textContaining('LIVE RESOLVED'), findsNothing);
      expect(find.text('SCHEDULE FORECAST', skipOffstage: false),
          findsOneWidget);
      expect(find.text('SCHEDULE PLAN', skipOffstage: false), findsOneWidget);
      expect(find.text('Not resolved', skipOffstage: false),
          findsAtLeastNWidgets(2));

      // 7.55r item 4 Tier 3: provenance section degrades honestly in the
      // no-snapshot state (does not fabricate a locked-week identity).
      expect(find.text('LOCKED WEEK PROVENANCE', skipOffstage: false),
          findsOneWidget);
      expect(find.text('No current-week snapshot resolved', skipOffstage: false),
          findsOneWidget);

      await tester.runAsync(() async {
        final db = await SqliteDatabase.instance.database;
        expect(await db.query('weekly_plan_snapshots'), isEmpty,
            reason:
                'expanding the audit panel must not auto-generate a locked '
                'snapshot through the live plan path');
      });
    });

    testWidgets(
        'audit panel exposes locked-week / target-cycle provenance rows '
        'when a snapshot exists', (tester) async {
      await _reseedDemoForWidgetTest(tester);

      // Prime a locked weekly plan via the auto-generating read path so
      // the audit panel has a snapshot to read from. Uses the same
      // authority seam a production first-render would take.
      await tester.runAsync(() async {
        await SchedulePlanReadService.instance.getCurrentLockedWeeklyPlan();
      });

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Data Alignment Audit');

      await tester.tap(find.text('Data Alignment Audit'));
      await _pumpUntilFound(
        tester,
        find.text('LOCKED WEEK PROVENANCE', skipOffstage: false),
      );

      expect(find.text('LOCKED WEEK PROVENANCE', skipOffstage: false),
          findsOneWidget);
      // Labels rendered by the provenance rows. Asserting the labels
      // rather than the resolved values keeps the test robust to seed
      // timing drift.
      expect(find.text('WEEK KEY', skipOffstage: false), findsOneWidget);
      expect(find.text('WEEK SPAN', skipOffstage: false), findsOneWidget);
      expect(find.text('SNAPSHOT ID', skipOffstage: false), findsOneWidget);
      expect(find.text('TARGET CYCLE ID', skipOffstage: false), findsOneWidget);
      expect(find.text('EFFECTIVE WINDOW', skipOffstage: false), findsOneWidget);
      expect(find.text('CALIBRATION WINDOW', skipOffstage: false),
          findsOneWidget);
    });

    // ── 7.56c.1 — grouped audit-check sections render ───────────────────
    //
    // The audit panel now exposes Plan + Benchmark coverage in grouped
    // sections (live actuals / benchmark authority / benchmark runtime
    // / locked plan ↔ projection / plan runtime). This smoke covers
    // header + group titles for the populated-snapshot path so the
    // grouped audit is wired through the read service end to end.

    testWidgets(
        'audit panel renders 7.56c.1 grouped audit-check sections '
        'with summary lines', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      await tester.runAsync(() async {
        await SchedulePlanReadService.instance.getCurrentLockedWeeklyPlan();
      });

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Data Alignment Audit');

      await tester.tap(find.text('Data Alignment Audit'));
      await _pumpUntilFound(
        tester,
        find.textContaining('AUDIT CHECKS —', skipOffstage: false),
      );

      // Overall AUDIT CHECKS header is present with a summary line.
      expect(find.textContaining('AUDIT CHECKS —', skipOffstage: false),
          findsOneWidget);

      // Each canonical group title is rendered with an aligned/drifted/
      // unavailable summary suffix.
      expect(
        find.textContaining('LIVE / ACTUAL PROVENANCE', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('BENCHMARK AUTHORITY', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('BENCHMARK -> RUNTIME', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining(
            'LOCKED PLAN <-> PROJECTION',
            skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('PLAN -> RUNTIME', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets(
        'audit panel grouped sections degrade to unavailable when no '
        'snapshot exists', (tester) async {
      await _reseedDemoForWidgetTest(tester);

      await tester.runAsync(() async {
        final db = await SqliteDatabase.instance.database;
        await db.delete('weekly_plan_snapshots');
      });

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Data Alignment Audit');

      await tester.tap(find.text('Data Alignment Audit'));
      await _pumpUntilFound(
        tester,
        find.textContaining('AUDIT CHECKS —', skipOffstage: false),
      );

      // Group titles still render even when the snapshot path is empty.
      expect(
        find.textContaining(
            'LOCKED PLAN <-> PROJECTION',
            skipOffstage: false),
        findsOneWidget,
      );

      // Confirms the panel degrades honestly: the no-snapshot path
      // surfaces unavailable counts somewhere in the AUDIT CHECKS area
      // rather than silently dropping the sections.
      expect(
        find.textContaining('unavailable', skipOffstage: false),
        findsAtLeastNWidgets(1),
      );
    });
  });

  group('Settings wage mix panel (7.55p.5f1a)', () {
    testWidgets(
        'panel is a read-only summary + single Edit Wage Mix action',
        (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      // Wage panel content is now in view.
      expect(find.text('MIX SUMMARY'), findsWidgets);

      // Grouped read-only bucket headers are rendered as their own row;
      // role count lives in a count pill beside each header.
      expect(find.text('FRONT OF HOUSE'), findsOneWidget);
      expect(find.text('BACK OF HOUSE'), findsOneWidget);
      expect(find.text('MANAGEMENT'), findsOneWidget);

      // The panel exposes exactly one whole-mix edit action.
      expect(find.text('Edit Wage Mix'), findsOneWidget);

      // The per-bucket add buttons from the intermediate 7.55p.5f1
      // implementation are gone from the Settings panel. Editing now
      // happens only inside the editor.
      expect(find.text('Add FOH role'), findsNothing);
      expect(find.text('Add BOH role'), findsNothing);
      expect(find.text('Add Management role'), findsNothing);

      // Older flat-list affordances from before 7.55p.5f1 remain absent.
      expect(find.text('Add Role'), findsNothing);
      expect(find.text('FALLBACK ROLES'), findsNothing);
    });

    testWidgets('empty mix shows Config Default warning on the panel',
        (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      expect(
        find.textContaining('No roles configured'),
        findsOneWidget,
      );
      expect(find.text('Config Default'), findsOneWidget);
    });
  });

  // ── Whole-mix editor real save path (7.55p.5f1a) ─────────────────────
  //
  // These tests drive the actual UI: tap `Edit Wage Mix`, fill inline
  // rows, tap Save, and assert persistence + profile sync. They
  // replace the earlier repo-seeded shape tests.

  group('Whole-mix editor real save path (7.55p.5f1a)', () {
    testWidgets(
        'complete FOH+BOH mix entered through the editor persists and '
        'updates ActiveTargetProfile wages', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);
      // Pre-sync so the profile starts with config defaults.
      await _syncWagesToActiveProfile(tester);

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      // Open the whole-mix editor.
      await tester.tap(find.text('Edit Wage Mix'));
      await _pumpUntilFound(tester, find.text('Add FOH role'));

      // Editor route is live.
      expect(find.text('Edit Wage Mix'), findsWidgets);
      expect(find.text('Add FOH role'), findsOneWidget);
      expect(find.text('Add BOH role'), findsOneWidget);

      // Add one FOH row inline.
      await tester.tap(find.text('Add FOH role'));
      await _pumpForAsync(tester);

      // The newly added FOH row exposes three fields (role, rate,
      // hours). Fill them in via real text entry.
      var fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), 'Server');
      await tester.enterText(fields.at(1), '17.50');
      await tester.enterText(fields.at(2), '30');
      await _pumpForAsync(tester);

      // Add one BOH row inline.
      await tester.tap(find.text('Add BOH role'));
      await _pumpForAsync(tester);

      fields = find.byType(TextField);
      expect(fields, findsNWidgets(6));
      await tester.enterText(fields.at(3), 'Line Cook');
      await tester.enterText(fields.at(4), '22.75');
      await tester.enterText(fields.at(5), '35');
      await _pumpForAsync(tester);

      // Save the whole mix in one pass.
      await tester.tap(find.text('Save Wage Mix'));
      await _pumpForDbAsync(tester);

      // Persistence proof: two rows are in SQLite.
      final rows = await _getWageRows(tester, restaurantId);
      expect(rows.length, 2);
      final foh = rows.firstWhere((r) => r.laborBucket == 'foh');
      final boh = rows.firstWhere((r) => r.laborBucket == 'boh');
      expect(foh.roleName, 'Server');
      expect(foh.hourlyRate, closeTo(17.50, 0.01));
      expect(foh.weightedHours, closeTo(30, 0.01));
      expect(boh.roleName, 'Line Cook');
      expect(boh.hourlyRate, closeTo(22.75, 0.01));
      expect(boh.weightedHours, closeTo(35, 0.01));

      // Resolution proof: the authority waterfall resolves as
      // App Configured (not config fallback).
      final ctx = await _resolveWageContext(tester, restaurantId);
      expect(ctx.source, WageStandardSource.appConfiguredGenerator);
      expect(ctx.fohWage, closeTo(17.50, 0.01));
      expect(ctx.bohWage, closeTo(22.75, 0.01));

      // Sync proof: the ActiveTargetProfile fields that Benchmark,
      // Variance WTD, Variance Full Week, and Shift read from now
      // carry the edited wages and the wage-derived theoretical
      // percentages.
      final profile = await _getActiveTargetProfile(tester, restaurantId);
      expect(profile, isNotNull);
      expect(profile!.fohWage, closeTo(17.50, 0.01));
      expect(profile.bohWage, closeTo(22.75, 0.01));
      final expectedFoh =
          17.50 / (profile.targetCPLH * profile.targetPPA) * 100;
      final expectedBoh = 22.75 / profile.targetSPLH * 100;
      expect(profile.theoreticalFohLaborPct, closeTo(expectedFoh, 0.01));
      expect(profile.theoreticalBohLaborPct, closeTo(expectedBoh, 0.01));
      expect(profile.theoreticalLaborPct,
          closeTo(expectedFoh + expectedBoh, 0.01));
    });

    testWidgets(
        'manager-only mix entered through the editor stays honest: '
        'saves the row but authority remains Config Default',
        (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);
      await _syncWagesToActiveProfile(tester);

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      // Open editor.
      await tester.tap(find.text('Edit Wage Mix'));
      await _pumpUntilFound(tester, find.text('Add Management role'));

      // The Management bucket sits at the bottom of the editor — scroll
      // its add button into view before tapping so it isn't blocked by
      // the pinned Save Wage Mix bar.
      await tester.ensureVisible(find.text('Add Management role'));
      await _pumpForAsync(tester);

      // Add one Management row only — deliberately incomplete.
      await tester.tap(find.text('Add Management role'));
      await _pumpForAsync(tester);

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(3));
      await tester.enterText(fields.at(0), 'GM');
      await tester.enterText(fields.at(1), '30');
      await tester.enterText(fields.at(2), '40');
      await _pumpForAsync(tester);

      // Editor shows the honest "will fall back" warning.
      expect(
        find.textContaining('Will fall back to Config Default'),
        findsOneWidget,
      );

      await tester.tap(find.text('Save Wage Mix'));
      await _pumpForDbAsync(tester);

      // Persistence proof: manager row is saved.
      final rows = await _getWageRows(tester, restaurantId);
      expect(rows.length, 1);
      expect(rows.first.laborBucket, 'manager');
      expect(rows.first.hourlyRate, closeTo(30, 0.01));

      // Honesty proof: authority still resolves as Config Default,
      // and the profile does NOT carry the $30 manager rate as FOH or
      // BOH wages.
      final ctx = await _resolveWageContext(tester, restaurantId);
      expect(ctx.source, WageStandardSource.configFallback);

      final profile = await _getActiveTargetProfile(tester, restaurantId);
      expect(profile, isNotNull);
      expect(profile!.fohWage, lessThan(30.0));
      expect(profile.bohWage, lessThan(30.0));

      // Settings panel shows the incomplete warning band.
      await _scrollToText(tester, 'Edit Wage Mix');
      expect(
        find.textContaining('one FOH role AND one BOH role'),
        findsOneWidget,
      );
      expect(find.text('Config Default'), findsOneWidget);
      expect(find.text('App Configured'), findsNothing);
    });

    testWidgets(
        'removing an existing row in the editor deletes it on save '
        'and degrades authority honestly', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);
      // Seed a complete mix first.
      await tester.runAsync(() async {
        await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
          restaurantId: restaurantId,
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 16.00,
          weightedHours: 30,
        ));
        await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
          restaurantId: restaurantId,
          roleName: 'Line Cook',
          laborBucket: 'boh',
          hourlyRate: 20.00,
          weightedHours: 35,
        ));
      });
      await _syncWagesToActiveProfile(tester);

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      await tester.tap(find.text('Edit Wage Mix'));
      await _pumpUntilFound(tester, find.text('Add FOH role'));

      // Editor should show both seeded rows (6 TextFields — 3 per row).
      expect(find.byType(TextField), findsNWidgets(6));

      // Remove the BOH row via its trash-style icon.
      final removeButtons = find.byTooltip('Remove role');
      expect(removeButtons, findsNWidgets(2));
      await tester.tap(removeButtons.at(1));
      await _pumpForAsync(tester);

      // Only the FOH row's fields remain.
      expect(find.byType(TextField), findsNWidgets(3));

      await tester.tap(find.text('Save Wage Mix'));
      await _pumpForDbAsync(tester);

      // Persistence proof: the removed BOH row is gone.
      final rows = await _getWageRows(tester, restaurantId);
      expect(rows.length, 1);
      expect(rows.first.laborBucket, 'foh');

      // Authority proof: FOH-only mix degrades to configFallback.
      final ctx = await _resolveWageContext(tester, restaurantId);
      expect(ctx.source, WageStandardSource.configFallback);
    });

    testWidgets(
        'clearing an existing row field drops the stale persisted row on save',
        (tester) async {
      await _reseedDemoForWidgetTest(tester);
      final restaurantId = await _getActiveRestaurantId(tester);
      await _deleteAllWageRows(tester, restaurantId);
      await tester.runAsync(() async {
        await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
          restaurantId: restaurantId,
          roleName: 'Server',
          laborBucket: 'foh',
          hourlyRate: 16.00,
          weightedHours: 30,
        ));
        await SqliteWageRoleRowRepository.instance.upsertRow(WageRoleRow(
          restaurantId: restaurantId,
          roleName: 'Line Cook',
          laborBucket: 'boh',
          hourlyRate: 20.00,
          weightedHours: 35,
        ));
      });
      await _syncWagesToActiveProfile(tester);

      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);
      await _scrollToText(tester, 'Edit Wage Mix');

      await tester.tap(find.text('Edit Wage Mix'));
      await _pumpUntilFound(tester, find.text('Add FOH role'));

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(6));

      // Clear the persisted BOH role name to make that draft invalid.
      await tester.enterText(fields.at(3), '');
      await _pumpForAsync(tester);

      await tester.tap(find.text('Save Wage Mix'));
      await _pumpForDbAsync(tester);

      // The stale BOH row should be deleted instead of silently preserved.
      final rows = await _getWageRows(tester, restaurantId);
      expect(rows.length, 1);
      expect(rows.first.laborBucket, 'foh');
      expect(rows.first.roleName, 'Server');

      final ctx = await _resolveWageContext(tester, restaurantId);
      expect(ctx.source, WageStandardSource.configFallback);
    });
  });

  // ── 7.55q.9 — Reset Target Cycle (Admin) tile renders + opens dialog ──

  group('Settings 7.55q.9 admin reset tile', () {
    if (_includePrunedLabelGroups()) testWidgets('Reset Target Cycle (Admin) tile renders with admin '
        'description', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);

      // Settings screen is long — match offstage and use the file's
      // established scroll helper so suite ordering doesn't make the
      // assertion flaky.
      expect(
        find.text('Reset Target Cycle (Admin)', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining(
            'Clears manager override + rebuilds the active 60-day',
            skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('tapping Reset Target Cycle (Admin) opens a confirm '
        'dialog with Cancel + Reset actions', (tester) async {
      await _reseedDemoForWidgetTest(tester);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          initialStatus: AppDataStatus.current(),
          initialMockDate: '2026-03-27',
        ),
      ));
      await _pumpForAsync(tester);

      // Use the file's established scroll helper to bring the tile
      // on-stage before tapping (Settings is taller than the test
      // viewport).
      await _scrollToText(tester, 'Reset Target Cycle (Admin)');
      final resetRow = find.ancestor(
        of: find.text('Reset Target Cycle (Admin)'),
        matching: find.byType(InkWell),
      );
      await tester.ensureVisible(resetRow.first);
      await _pumpForAsync(tester);
      await tester.tap(resetRow.first);
      await _pumpForAsync(tester);

      expect(find.text('Reset target cycle?'), findsOneWidget);
      expect(
        find.textContaining(
            'Clears the persisted manager override and the active'),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsAtLeastNWidgets(1));
      expect(find.text('Reset'), findsOneWidget);

      // Cancel exits the dialog without acting.
      await tester.tap(find.text('Cancel'));
      await _pumpForAsync(tester);
      expect(find.text('Reset target cycle?'), findsNothing);
    });
  });
}

/// Helper: pump repeatedly to let async DB work + animations settle
/// without risking `pumpAndSettle` deadlock on a Provider-heavy
/// screen.
Future<void> _pumpForAsync(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    });
  }
}

Future<void> _pumpForDbAsync(WidgetTester tester) async {
  await tester.runAsync(() async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await _pumpForAsync(tester);
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxTicks = 20,
}) async {
  for (var i = 0; i < maxTicks; i++) {
    if (finder.evaluate().isNotEmpty) return;
    await _pumpForAsync(tester);
  }
}

Future<void> _scrollToText(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text, skipOffstage: false),
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await _pumpForAsync(tester);
}

Future<void> _reseedDemoForWidgetTest(WidgetTester tester) async {
  await tester.runAsync(() async {
    await SqliteDatabase.instance.reseedDemo();
  });
}

Future<String> _getActiveRestaurantId(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    return SqliteRestaurantScopeRepository.instance.getActiveRestaurantId();
  }))!;
}

Future<void> _deleteAllWageRows(
  WidgetTester tester,
  String restaurantId,
) async {
  await tester.runAsync(() async {
    await SqliteWageRoleRowRepository.instance.deleteAll(restaurantId);
  });
}

Future<void> _syncWagesToActiveProfile(WidgetTester tester) async {
  await tester.runAsync(() async {
    await WageStandardContextService.instance.syncWagesToActiveProfile();
  });
}

Future<List<WageRoleRow>> _getWageRows(
  WidgetTester tester,
  String restaurantId,
) async {
  return (await tester.runAsync(() async {
    return SqliteWageRoleRowRepository.instance.getRows(restaurantId);
  }))!;
}

Future<WageStandardContext> _resolveWageContext(
  WidgetTester tester,
  String restaurantId,
) async {
  return (await tester.runAsync(() async {
    return WageStandardContextService.instance.resolve(restaurantId);
  }))!;
}

Future<ActiveTargetProfile?> _getActiveTargetProfile(
  WidgetTester tester,
  String restaurantId,
) async {
  return (await tester.runAsync<ActiveTargetProfile?>(() async {
    return SqliteTargetProfileRepository.instance
        .getActiveTargetProfile(restaurantId);
  }))!;
}
