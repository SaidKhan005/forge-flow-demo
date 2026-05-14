// Wave 2 AC-1 - shared `actor_kind` label catalog unit tests.
//
// Pins:
//   * Every known wire enum string resolves to a plain-English label.
//   * Unknown enum strings fall through to the raw value (defensive
//     default — a freshly added enum must NOT crash the audit row).
//   * Null / blank / whitespace-only input resolves to a friendly
//     'Unknown actor' string.
//   * Lookups are case-insensitive (the catalog normalizes input).
//   * Labels never expose raw underscores so the UX writing standard
//     stays honored.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/auth/actor_kind_label_catalog.dart';

void main() {
  group('ActorKindLabelCatalog.byKind', () {
    test('declares a row for every actor_kind wire value the proxy '
        'emits or the SQL CHECK constraint allows', () {
      // The SQL CHECK in
      // db/migrations/202605071800_actor_kind_constraint_consolidation.sql
      // pins `('user', 'service')`. The proxy emitter widens to the
      // human-tier values listed below. Adding a new wire value
      // requires a matching catalog row.
      const expectedWireValues = <String>{
        'user',
        'team_member',
        'service',
        'service_principal',
        'forge_admin',
        'ff_support',
        'system',
      };
      expect(
        ActorKindLabelCatalog.byKind.keys.toSet(),
        equals(expectedWireValues),
      );
    });

    test('every catalog label is non-empty + free of raw underscores', () {
      for (final entry in ActorKindLabelCatalog.byKind.entries) {
        expect(entry.value, isNotEmpty,
            reason: 'actor_kind "${entry.key}" has an empty label');
        expect(
          entry.value,
          isNot(contains('_')),
          reason:
              'actor_kind "${entry.key}" label "${entry.value}" leaks an '
              'underscore - operator-facing labels must read as English',
        );
      }
    });
  });

  group('ActorKindLabelCatalog.labelFor', () {
    test('returns the Team member label for both user + team_member '
        '(the wire alias the operator-web enum uses)', () {
      expect(ActorKindLabelCatalog.labelFor('user'), 'Team member');
      expect(ActorKindLabelCatalog.labelFor('team_member'), 'Team member');
    });

    test('service and service_principal collapse to the same '
        '"Automated service" label', () {
      expect(ActorKindLabelCatalog.labelFor('service'), 'Automated service');
      expect(
        ActorKindLabelCatalog.labelFor('service_principal'),
        'Automated service',
      );
    });

    test('forge_admin resolves to the F&F admin label', () {
      expect(ActorKindLabelCatalog.labelFor('forge_admin'), 'F&F admin');
    });

    test('ff_support resolves to the F&F support label', () {
      expect(ActorKindLabelCatalog.labelFor('ff_support'), 'F&F support');
    });

    test('system resolves to the F&F platform label', () {
      expect(ActorKindLabelCatalog.labelFor('system'), 'F&F platform');
    });

    test('lookup is case-insensitive + trim-tolerant so a malformed '
        'wire value does not bypass the catalog', () {
      expect(ActorKindLabelCatalog.labelFor('FORGE_ADMIN'), 'F&F admin');
      expect(ActorKindLabelCatalog.labelFor(' user '), 'Team member');
      expect(ActorKindLabelCatalog.labelFor('Service'), 'Automated service');
    });

    test('null returns the friendly Unknown actor sentinel', () {
      expect(ActorKindLabelCatalog.labelFor(null), 'Unknown actor');
    });

    test('empty + whitespace-only inputs resolve to Unknown actor', () {
      expect(ActorKindLabelCatalog.labelFor(''), 'Unknown actor');
      expect(ActorKindLabelCatalog.labelFor('   '), 'Unknown actor');
    });

    test('unknown enum strings fall through to the trimmed raw value '
        'so a new wire enum does not crash the audit row', () {
      expect(
        ActorKindLabelCatalog.labelFor('new_kind_not_in_catalog'),
        'new_kind_not_in_catalog',
      );
      // Preserves the original casing on the fall-through return so
      // forensic inspection can still see the wire value verbatim.
      expect(ActorKindLabelCatalog.labelFor('NewKind'), 'NewKind');
    });
  });
}
