// Regression coverage for ops-debt.demo-fallback-hardening — the
// fix for the Hard Promise #2 violation in `lib/main_admin.dart`
// (CLAUDE.md: "kDemoMode is a writer-side switch; same tables, same
// reads, same UI either way"). The pre-fix admin entrypoint had 11
// gateway resolvers that silently returned `null` when
// `ADMIN_PROXY_BASE_URI` was unset/malformed. The chained-null pattern
// in `Future<void> main()` then propagated those nulls into
// `AdminConsoleServicesScope`, and `admin_routes.dart` quietly fell
// back to the in-memory `_default*DemoGateway` fixtures. A typo in a
// deployed Cloud Run env var could therefore serve seeded demo data
// from a live `--allow-unauthenticated` admin console.
//
// These tests are source-text assertions over `lib/main_admin.dart`
// (same harness pattern used by `data_accuracy_live_wiring_test.dart`).
// They guarantee:
//   * every gateway resolver routes through `_requireAdminProxyBaseUri`
//     so a missing/malformed URI hard-fails at startup,
//   * the demo-mode branch (`_kAdminDemoAuth == true`) still returns
//     null so `admin_routes.dart` can wire the explicit
//     `_default*DemoGateway` fixtures (the demo gateway is no longer a
//     silent fallback — it is the explicit demo branch),
//   * a startup banner enumerates each gateway's transport
//     (`live HTTP` vs `demo seed`) so Cloud Run logs make the binding
//     obvious,
//   * production directories no longer import `lib/dev/`.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('main_admin demo-fallback hardening', () {
    late String source;

    setUpAll(() {
      source = File('lib/main_admin.dart').readAsStringSync();
    });

    test(
      'every admin gateway resolver hard-fails on missing/malformed URI '
      'via _requireAdminProxyBaseUri',
      () {
        // The shared helper centralises the "fail-closed when
        // ADMIN_PROXY_BASE_URI is unset/malformed" behaviour. Each of
        // the 12 resolvers must call it exactly once so a typo cannot
        // sneak through any single surface.
        const resolvers = <String>[
          '_resolveOperatorLocationGateway',
          '_resolvePricingTierAdminGateway',
          '_resolveDataAccuracyAdminGateway',
          '_resolveCorpusAdminGateway',
          '_resolveIntegrationAdminGateway',
          '_resolveHealthAdminGateway',
          '_resolveObservabilityAdminGateway',
          '_resolveFeatureFlagsAdminGateway',
          '_resolveDebugConsoleAdminGateway',
          '_resolveMembersAdminGateway',
          '_resolveRolesHierarchySessionsAdminGateway',
          '_resolveAuditedSupportActionsAdminGateway',
        ];

        for (final resolver in resolvers) {
          final fnBlock = _resolverBody(source, resolver);
          expect(
            fnBlock,
            isNot(isEmpty),
            reason: '$resolver definition must be locatable',
          );
          // Every resolver function body must reference
          // _requireAdminProxyBaseUri so the missing/malformed URI
          // case throws StateError instead of returning null.
          expect(
            fnBlock,
            contains('_requireAdminProxyBaseUri('),
            reason:
                '$resolver must route through _requireAdminProxyBaseUri so '
                'a missing/malformed ADMIN_PROXY_BASE_URI hard-fails at '
                'startup (Hard Promise #2)',
          );
          // No resolver may return null on a missing URI in live mode.
          // The legacy `if (rawBaseUri.isEmpty) return null;` shape and
          // its sibling `if (!baseUri.hasScheme || ...) return null;`
          // are explicitly forbidden.
          expect(
            fnBlock,
            isNot(contains('rawBaseUri.isEmpty) return null')),
            reason:
                '$resolver must not silently return null on missing URI '
                '(was the Hard Promise #2 violation)',
          );
          expect(
            fnBlock,
            isNot(contains('!baseUri.hasScheme || !baseUri.hasAuthority) '
                'return null')),
            reason:
                '$resolver must not silently return null on malformed URI '
                '(was the Hard Promise #2 violation)',
          );
        }
      },
    );

    test(
      '_requireAdminProxyBaseUri throws StateError naming the env var '
      'and the gateway',
      () {
        final helperBody = _functionBodyAfter(
          source,
          source.indexOf('Uri _requireAdminProxyBaseUri('),
        );
        expect(helperBody, contains('throw StateError'));
        // Mentions the env var so the on-call grepping logs after a
        // bad deploy lands directly on the line that names the
        // missing variable.
        expect(helperBody, contains('ADMIN_PROXY_BASE_URI'));
        // Mentions ADMIN_DEMO_AUTH so the message tells the operator
        // exactly which dart-define unblocks the demo path.
        expect(helperBody, contains('ADMIN_DEMO_AUTH'));
        // Carries the Hard Promise reference so the message is
        // self-documenting from a Cloud Run log line.
        expect(helperBody, contains('Hard Promise #2'));
      },
    );

    test(
      'every admin gateway resolver short-circuits to null when '
      'ADMIN_DEMO_AUTH is true (the demo branch is explicit, not a '
      'silent fallback)',
      () {
        const resolvers = <String>[
          '_resolveOperatorLocationGateway',
          '_resolvePricingTierAdminGateway',
          '_resolveDataAccuracyAdminGateway',
          '_resolveCorpusAdminGateway',
          '_resolveIntegrationAdminGateway',
          '_resolveHealthAdminGateway',
          '_resolveObservabilityAdminGateway',
          '_resolveFeatureFlagsAdminGateway',
          '_resolveDebugConsoleAdminGateway',
          '_resolveMembersAdminGateway',
          '_resolveRolesHierarchySessionsAdminGateway',
          '_resolveAuditedSupportActionsAdminGateway',
        ];
        for (final resolver in resolvers) {
          final fnBlock = _resolverBody(source, resolver);
          // The demo-mode branch must be the FIRST statement in every
          // resolver: `if (_kAdminDemoAuth) return null;`. Any check
          // run before that branch could trigger a StateError on a
          // missing live-mode env var even when the operator is just
          // running a demo walkthrough.
          expect(
            fnBlock,
            matches(
              RegExp(
                r'\{\s*if \(_kAdminDemoAuth\) return null;',
                multiLine: true,
              ),
            ),
            reason:
                '$resolver must short-circuit to null when '
                '_kAdminDemoAuth is true so the kDemoMode walkthrough '
                'reaches the explicit _default*DemoGateway in '
                'admin_routes.dart instead of throwing',
          );
        }
      },
    );

    test('startup banner enumerates every gateway transport', () {
      // The banner is the on-call's at-a-glance audit. It must:
      //   * exist as `_logAdminGatewayBindings`,
      //   * be invoked from `main()`,
      //   * label modes "live HTTP" and "demo seed" so the log line
      //     answers "is this serving real or seeded data?" without
      //     interpretation.
      expect(source, contains('_logAdminGatewayBindings'));
      expect(source, contains("'live HTTP'"));
      expect(source, contains("'demo seed'"));
      expect(source, contains('admin gateway bindings'));
      // Banner emits via debugPrint so Cloud Run captures it on
      // stdout — same channel as every other Flutter Web INFO log.
      final bannerBody = _functionBodyAfter(
        source,
        source.indexOf('void _logAdminGatewayBindings('),
      );
      expect(bannerBody, contains('debugPrint('));
    });

    test(
      'live admin entrypoint exposes _requireAdminProxyBaseUri to tests '
      'via @visibleForTesting',
      () {
        // The visible-for-testing seam lets unit tests assert the
        // live-mode hard-fail without spinning up Firebase. Every other
        // hardening test in this file is source-text — this one
        // guarantees future tests can call the helper directly.
        expect(source, contains('@visibleForTesting'));
        expect(source, contains('requireAdminProxyBaseUriForTest'));
      },
    );
  });

  group('production paths must not import lib/dev/', () {
    // The four files below were the last lib/dev/ imports outside
    // lib/main*.dart and lib/dev/ itself. Keep them locked.
    const productionFiles = <String>[
      'lib/services/shift_data_source.dart',
      'lib/screens/baseline_tracker.dart',
      'lib/screens/schedule_builder.dart',
      'lib/infrastructure/persistence/sqlite/sqlite_database.dart',
    ];

    for (final path in productionFiles) {
      test('$path does not import lib/dev/', () {
        final src = File(path).readAsStringSync();
        // Match `import '../dev/...';`, `import '../../dev/...';`,
        // `import '../../../dev/...';`, and absolute
        // `import 'package:.../dev/...';`.
        final relativeImport = RegExp(
          r'''import\s+['"](?:\.\./)+dev/[^'"]+['"]''',
        );
        final packageImport = RegExp(
          r'''import\s+['"]package:[^'"/]+/dev/[^'"]+['"]''',
        );
        expect(
          relativeImport.hasMatch(src),
          isFalse,
          reason: '$path must not import lib/dev/ via a relative path',
        );
        expect(
          packageImport.hasMatch(src),
          isFalse,
          reason: '$path must not import lib/dev/ via a package: path',
        );
      });
    }

    test(
      'no file under lib/services/, lib/screens/, lib/infrastructure/ '
      'imports lib/dev/',
      () {
        const roots = <String>[
          'lib/services',
          'lib/screens',
          'lib/infrastructure',
        ];
        final relativeImport = RegExp(
          r'''import\s+['"](?:\.\./)+dev/[^'"]+['"]''',
        );
        final packageImport = RegExp(
          r'''import\s+['"]package:[^'"/]+/dev/[^'"]+['"]''',
        );
        final offenders = <String>[];
        for (final root in roots) {
          final dir = Directory(root);
          if (!dir.existsSync()) continue;
          for (final entity in dir.listSync(recursive: true)) {
            if (entity is! File || !entity.path.endsWith('.dart')) {
              continue;
            }
            final src = entity.readAsStringSync();
            if (relativeImport.hasMatch(src) ||
                packageImport.hasMatch(src)) {
              offenders.add(entity.path);
            }
          }
        }
        expect(
          offenders,
          isEmpty,
          reason:
              'production files must not import lib/dev/ — offenders: '
              '${offenders.join(', ')}',
        );
      },
    );
  });
}

/// Returns the substring starting at `fnStart` and running to the end
/// of the function body's closing `}`, balancing braces. Used to scope
/// a containment check to a single function.
String _functionBodyAfter(String src, int fnStart) {
  if (fnStart < 0) return '';
  final braceStart = src.indexOf('{', fnStart);
  if (braceStart == -1) return '';
  var depth = 0;
  for (var i = braceStart; i < src.length; i++) {
    final ch = src[i];
    if (ch == '{') {
      depth++;
    } else if (ch == '}') {
      depth--;
      if (depth == 0) {
        return src.substring(braceStart, i + 1);
      }
    }
  }
  return src.substring(braceStart);
}

/// Locates the function-definition site for the named resolver
/// (`Gateway? _resolveX(...)` or `Gateway _resolveX(...)`) and returns
/// its body. The first occurrence of `_resolveX(` in the source is the
/// CALL site inside `main()`, not the definition — this helper skips
/// past those by walking backwards from each candidate to confirm the
/// preceding non-whitespace token is a `(` boundary belonging to the
/// definition's parameter list (not a call argument). Concretely we
/// find the resolver name preceded by either a generic-arg-style
/// `Gateway?` token or `Gateway` token: that is, the resolver name on
/// a line where the previous-line ends in `(` (multi-line definitions)
/// or the same line carries the return type. Falls back to scanning
/// for the unique signature pattern shared by all resolvers (the
/// `_kAdminDemoAuth` short-circuit on the first body line).
String _resolverBody(String src, String resolver) {
  // All resolver definitions return either `T?` or `T` and live at the
  // top level of the file. The return-type token has no leading
  // whitespace on its own line, while the resolver name appears on the
  // SAME line for `_resolveCorpusAdminGateway` /
  // `_resolveHealthAdminGateway` (return type + name + `(` on one
  // line) and on a NEW line for the others (return type on its own
  // line, then name + `(` on the next). The robust signal is: the
  // function definition is followed by the body opener pattern
  // `\) {\s*if \(_kAdminDemoAuth\) return null;`, while a call site
  // is followed by `(...);`. Find every occurrence of the resolver
  // name and return the first one whose immediate continuation is the
  // definition's body.
  var searchFrom = 0;
  while (true) {
    final idx = src.indexOf(resolver, searchFrom);
    if (idx == -1) return '';
    // Find the matching closing `)` for the parameter list / call.
    final openParen = src.indexOf('(', idx);
    if (openParen == -1) return '';
    var depth = 0;
    var closeParen = -1;
    for (var i = openParen; i < src.length; i++) {
      final ch = src[i];
      if (ch == '(') {
        depth++;
      } else if (ch == ')') {
        depth--;
        if (depth == 0) {
          closeParen = i;
          break;
        }
      }
    }
    if (closeParen == -1) return '';
    // Look at the next non-whitespace character after `)`. The
    // definition is followed by `{`, the call by `;` or `,` or `)`
    // (chained args).
    var j = closeParen + 1;
    while (j < src.length &&
        (src[j] == ' ' || src[j] == '\n' || src[j] == '\r' ||
            src[j] == '\t')) {
      j++;
    }
    if (j < src.length && src[j] == '{') {
      return _functionBodyAfter(src, j);
    }
    searchFrom = idx + resolver.length;
  }
}
