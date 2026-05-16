// GAP A4 — unit tests for the shared org-unit depth-cap rule.
//
// The boundary is the highest-risk detail: a parent at the maximum
// level (6) must be blocked; a parent one below (5) must be allowed
// because its child lands exactly at the cap. These tests pin that
// boundary against the proxy guard at
// lib/infrastructure/persistence/postgres/repositories/
//   org_units_repository.dart:241 (`if (parentDepth >= maxDepth)`).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/hierarchy/org_unit_depth_rule.dart';

void main() {
  group('OrgUnitDepthRule cap constant', () {
    test('maxDepth mirrors the DB CHECK and the proxy guard (6)', () {
      expect(kOrgUnitMaxDepth, 6);
      expect(OrgUnitDepthRule.maxDepth, 6);
    });

    test('depth-cap copy is plain English with no error code', () {
      expect(kOrgUnitMaxDepth, OrgUnitDepthRule.maxDepth);
      expect(OrgUnitDepthRule.depthCapMessage, kOrgUnitDepthCapMessage);
      expect(
        OrgUnitDepthRule.depthCapMessage,
        contains('deepest level we allow'),
      );
      // No raw schema vocabulary / no error codes leak into copy.
      expect(OrgUnitDepthRule.depthCapMessage.contains('_'), isFalse);
      expect(
        OrgUnitDepthRule.depthCapMessage.toLowerCase().contains('error'),
        isFalse,
      );
    });
  });

  group('canAddChild boundary (mirrors org_units_repository.dart:241)', () {
    test('parent at level 5 (one below cap) is allowed', () {
      expect(OrgUnitDepthRule.canAddChild(5), isTrue);
    });

    test('parent at level 6 (the cap) is blocked', () {
      expect(OrgUnitDepthRule.canAddChild(6), isFalse);
    });

    test('parent deeper than the cap stays blocked', () {
      expect(OrgUnitDepthRule.canAddChild(7), isFalse);
      expect(OrgUnitDepthRule.canAddChild(99), isFalse);
    });

    test('shallow parents (levels 1-4) are allowed', () {
      for (var depth = 0; depth <= 4; depth++) {
        expect(
          OrgUnitDepthRule.canAddChild(depth),
          isTrue,
          reason: 'depth $depth must allow a child',
        );
      }
    });
  });

  group('depthFromPath (matches Postgres nlevel)', () {
    test('empty / blank path is level 0', () {
      expect(OrgUnitDepthRule.depthFromPath(''), 0);
      expect(OrgUnitDepthRule.depthFromPath('   '), 0);
    });

    test('single-label root path is level 1', () {
      expect(OrgUnitDepthRule.depthFromPath('demo_bistro'), 1);
    });

    test('"a.b.c" is level 3', () {
      expect(OrgUnitDepthRule.depthFromPath('a.b.c'), 3);
    });

    test('real fixture path "demo_bistro.east_region.metro_district" '
        'is level 3', () {
      expect(
        OrgUnitDepthRule.depthFromPath(
          'demo_bistro.east_region.metro_district',
        ),
        3,
      );
    });

    test('stray leading/trailing dots do not over-count', () {
      expect(OrgUnitDepthRule.depthFromPath('.a.b.'), 2);
      expect(OrgUnitDepthRule.depthFromPath('a..b'), 2);
    });

    test('a 6-label path is exactly at the cap and blocks a 7th level', () {
      const sixDeep = 'l1.l2.l3.l4.l5.l6';
      final depth = OrgUnitDepthRule.depthFromPath(sixDeep);
      expect(depth, 6);
      expect(OrgUnitDepthRule.canAddChild(depth), isFalse);
    });

    test('a 5-label path allows one more level (child lands at 6)', () {
      const fiveDeep = 'l1.l2.l3.l4.l5';
      final depth = OrgUnitDepthRule.depthFromPath(fiveDeep);
      expect(depth, 5);
      expect(OrgUnitDepthRule.canAddChild(depth), isTrue);
    });
  });

  group('depthFromChain (admin path — no ltree available)', () {
    test('root with no parent is level 1', () {
      expect(
        OrgUnitDepthRule.depthFromChain('root', (_) => null),
        1,
      );
    });

    test('three-deep chain is level 3', () {
      const parents = <String, String?>{
        'c': 'b',
        'b': 'a',
        'a': null,
      };
      expect(
        OrgUnitDepthRule.depthFromChain('c', (id) => parents[id]),
        3,
      );
    });

    test('boundary: a chain at level 6 blocks a child; level 5 allows', () {
      const sixChain = <String, String?>{
        'n6': 'n5',
        'n5': 'n4',
        'n4': 'n3',
        'n3': 'n2',
        'n2': 'n1',
        'n1': null,
      };
      final d6 = OrgUnitDepthRule.depthFromChain(
        'n6',
        (id) => sixChain[id],
      );
      expect(d6, 6);
      expect(OrgUnitDepthRule.canAddChild(d6), isFalse);

      final d5 = OrgUnitDepthRule.depthFromChain(
        'n5',
        (id) => sixChain[id],
      );
      expect(d5, 5);
      expect(OrgUnitDepthRule.canAddChild(d5), isTrue);
    });

    test('cycle in the parent links does not loop forever', () {
      // Corrupt data: a -> b -> a. The walk must terminate and
      // return the count seen before the repeat.
      const cyclic = <String, String?>{
        'a': 'b',
        'b': 'a',
      };
      final depth = OrgUnitDepthRule.depthFromChain(
        'a',
        (id) => cyclic[id],
      );
      expect(depth, 2);
    });

    test('self-cycle terminates at level 1', () {
      final depth = OrgUnitDepthRule.depthFromChain(
        'x',
        (_) => 'x',
      );
      expect(depth, 1);
    });
  });
}
