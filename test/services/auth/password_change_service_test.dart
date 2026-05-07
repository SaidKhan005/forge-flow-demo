// CODE_HEALTH L10 — PasswordChangeService HIBP-after-shape order.
//
// Pins the ordering fix: shape validation runs FIRST so an
// obviously-invalid candidate (empty, too short, control chars,
// edge whitespace) returns immediately without burning the HIBP
// HTTP roundtrip OR the history-check DB call. Beyond saving the
// outbound HTTP cost, the early return defends the HIBP rate
// budget against a brute-force attacker who fires malformed
// candidates.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/password_policy.dart';
import 'package:forge_and_flow/services/auth/hibp_pwned_password_screener.dart';
import 'package:forge_and_flow/services/auth/password_change_service.dart';
import 'package:forge_and_flow/services/auth/password_history_check.dart';

void main() {
  group('PasswordChangeService.evaluate ordering (CODE_HEALTH L10)', () {
    test('empty candidate -> shape rejection without HIBP roundtrip', () async {
      final hibp = _CountingHibpFetcher();
      final history = _CountingHistoryCheck();
      final svc = _service(hibp: hibp, history: history);

      final outcome = await svc.evaluate(userId: 'u', candidate: '');

      expect(outcome.allowed, isFalse);
      expect(
        outcome.rejections,
        contains(PasswordChangeRejection.violatesPolicy),
      );
      expect(outcome.violations, contains(PasswordViolation.tooShort));
      // The HIBP HTTP fetch was NOT invoked.
      expect(hibp.calls, equals(0));
      // The history check was NOT invoked.
      expect(history.calls, equals(0));
    });

    test(
      '3-char candidate -> shape rejection without HIBP roundtrip',
      () async {
        final hibp = _CountingHibpFetcher();
        final history = _CountingHistoryCheck();
        final svc = _service(hibp: hibp, history: history);

        final outcome = await svc.evaluate(userId: 'u', candidate: 'abc');

        expect(outcome.allowed, isFalse);
        expect(
          outcome.rejections,
          contains(PasswordChangeRejection.violatesPolicy),
        );
        expect(hibp.calls, equals(0));
        expect(history.calls, equals(0));
      },
    );

    test('control-char candidate -> shape rejection without HIBP', () async {
      final hibp = _CountingHibpFetcher();
      final history = _CountingHistoryCheck();
      final svc = _service(hibp: hibp, history: history);

      final outcome = await svc.evaluate(
        userId: 'u',
        // 8 chars but contains a tab (control char).
        candidate: 'pa\tssword',
      );

      expect(outcome.allowed, isFalse);
      expect(
        outcome.rejections,
        contains(PasswordChangeRejection.violatesPolicy),
      );
      expect(
        outcome.violations,
        contains(PasswordViolation.containsControlChars),
      );
      expect(hibp.calls, equals(0));
      expect(history.calls, equals(0));
    });

    test('shape-valid candidate flows through to HIBP THEN history', () async {
      final hibp = _CountingHibpFetcher();
      final history = _CountingHistoryCheck();
      final svc = _service(hibp: hibp, history: history);

      final outcome = await svc.evaluate(
        userId: 'u',
        candidate: 'correct horse battery staple',
      );

      expect(outcome.allowed, isTrue);
      expect(hibp.calls, equals(1));
      expect(history.calls, equals(1));
    });

    test('shape-valid + pwned -> rejected, HIBP called, history still '
        'consulted', () async {
      final hibp = _CountingHibpFetcher(
        pwnedCandidates: const <String>{'P@ssword1234'},
      );
      final history = _CountingHistoryCheck();
      final svc = _service(hibp: hibp, history: history);

      final outcome = await svc.evaluate(
        userId: 'u',
        candidate: 'P@ssword1234',
      );

      expect(outcome.allowed, isFalse);
      expect(
        outcome.rejections,
        contains(PasswordChangeRejection.pwnedInBreach),
      );
      expect(hibp.calls, equals(1));
      expect(history.calls, equals(1));
    });

    test('shape-valid + history reuse -> rejected, history called', () async {
      final hibp = _CountingHibpFetcher();
      final history = _CountingHistoryCheck(reused: true);
      final svc = _service(hibp: hibp, history: history);

      final outcome = await svc.evaluate(
        userId: 'u',
        candidate: 'fresh-shape-password',
      );

      expect(outcome.allowed, isFalse);
      expect(
        outcome.rejections,
        contains(PasswordChangeRejection.reusedFromHistory),
      );
      expect(hibp.calls, equals(1));
      expect(history.calls, equals(1));
    });

    test('leading-space candidate -> shape rejection without HIBP', () async {
      final hibp = _CountingHibpFetcher();
      final history = _CountingHistoryCheck();
      final svc = _service(hibp: hibp, history: history);

      final outcome = await svc.evaluate(
        userId: 'u',
        candidate: ' has-leading-space',
      );

      expect(outcome.allowed, isFalse);
      expect(
        outcome.violations,
        contains(PasswordViolation.containsLeadingOrTrailingSpace),
      );
      expect(hibp.calls, equals(0));
      expect(history.calls, equals(0));
    });
  });
}

PasswordChangeService _service({
  required _CountingHibpFetcher hibp,
  required _CountingHistoryCheck history,
  bool failClosedOnHibpUnavailable = false,
}) {
  return PasswordChangeService(
    hibpScreener: HibpPwnedPasswordScreener(fetcher: hibp),
    historyCheck: history,
    failClosedOnHibpUnavailable: failClosedOnHibpUnavailable,
  );
}

/// Counts every HIBP fetch + optionally reports specific candidates
/// as pwned by injecting their SHA-1 suffixes into the response body.
class _CountingHibpFetcher implements HibpRangeFetcher {
  _CountingHibpFetcher({Set<String>? pwnedCandidates})
    : _pwnedCandidates = pwnedCandidates ?? const <String>{};

  final Set<String> _pwnedCandidates;
  int calls = 0;

  @override
  Future<String> fetchRange(String hexPrefix) async {
    calls += 1;
    final lines = <String>[];
    for (final candidate in _pwnedCandidates) {
      final hash = sha1
          .convert(utf8.encode(candidate))
          .toString()
          .toUpperCase();
      if (hash.startsWith(hexPrefix)) {
        lines.add('${hash.substring(5)}:42');
      }
    }
    if (lines.isEmpty) {
      // A non-matching line so the screener returns notPwned rather
      // than seeing an empty body.
      lines.add('0000000000000000000000000000000000000:1');
    }
    return lines.join('\r\n');
  }
}

class _CountingHistoryCheck implements PasswordHistoryCheck {
  _CountingHistoryCheck({this.reused = false});

  final bool reused;
  int calls = 0;

  @override
  Future<bool> isReusedPassword({
    required String userId,
    required String candidate,
  }) async {
    calls += 1;
    return reused;
  }
}
