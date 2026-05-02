// Phase 11A.4c — tests for the per-lane KMS dispatcher.
//
// Acceptance:
//   * Flag OFF → write goes to the stub delegate; the real delegate
//     is not touched.
//   * Flag ON  → write goes to the real delegate; the stub is not
//     touched.
//   * Per-lane gating: the same router can route one lane to real
//     and another to stub on the same call site.
//   * `KmsWriteFailure` raised by the chosen delegate propagates
//     unchanged (the router does not catch it).
//   * The `plaintext` argument is forwarded verbatim — no masking,
//     trimming, or other mutation by the router.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_lane_router.dart';
import 'package:forge_and_flow/infrastructure/kms/kms_provider.dart';

void main() {
  group('KmsLaneRouter.writeSecret', () {
    test('flag OFF → stub serves; real is not called', () async {
      final stub = _RecordingKmsProvider(label: 'stub');
      final real = _RecordingKmsProvider(label: 'real');
      final router = KmsLaneRouter(
        stub: stub,
        real: real,
        flagLookup: (_) async => false,
      );

      final result = await router.writeSecret(
        logicalKeyKind: 'anthropic',
        plaintext: 'sk-ant-1234567890',
      );

      expect(stub.calls, hasLength(1));
      expect(real.calls, isEmpty);
      expect(result.secretName, startsWith('kms://recorded/stub/'));
    });

    test('flag ON → real serves; stub is not called', () async {
      final stub = _RecordingKmsProvider(label: 'stub');
      final real = _RecordingKmsProvider(label: 'real');
      final router = KmsLaneRouter(
        stub: stub,
        real: real,
        flagLookup: (_) async => true,
      );

      final result = await router.writeSecret(
        logicalKeyKind: 'anthropic',
        plaintext: 'sk-ant-1234567890',
      );

      expect(real.calls, hasLength(1));
      expect(stub.calls, isEmpty);
      expect(result.secretName, startsWith('kms://recorded/real/'));
    });

    test(
      'per-lane gating: anthropic → real, voyage → stub on the same '
      'router instance',
      () async {
        final stub = _RecordingKmsProvider(label: 'stub');
        final real = _RecordingKmsProvider(label: 'real');
        final router = KmsLaneRouter(
          stub: stub,
          real: real,
          flagLookup: (kind) async => kind == 'anthropic',
        );

        await router.writeSecret(
          logicalKeyKind: 'anthropic',
          plaintext: 'sk-ant-1234567890',
        );
        await router.writeSecret(
          logicalKeyKind: 'voyage',
          plaintext: 'pa-voyage-9876543210',
        );

        expect(real.calls, hasLength(1));
        expect(real.calls.single.kind, 'anthropic');
        expect(stub.calls, hasLength(1));
        expect(stub.calls.single.kind, 'voyage');
      },
    );

    test(
      'failure on the chosen provider propagates unchanged — the '
      'router does not catch KmsWriteFailure',
      () async {
        final stub = _RecordingKmsProvider(label: 'stub');
        final real = _RecordingKmsProvider(
          label: 'real',
          throwOnNextWrite: const KmsWriteFailure('boom'),
        );
        final router = KmsLaneRouter(
          stub: stub,
          real: real,
          flagLookup: (_) async => true,
        );

        await expectLater(
          () => router.writeSecret(
            logicalKeyKind: 'anthropic',
            plaintext: 'sk-ant-1234567890',
          ),
          throwsA(
            isA<KmsWriteFailure>().having(
              (KmsWriteFailure e) => e.message,
              'message',
              'boom',
            ),
          ),
        );
        expect(stub.calls, isEmpty);
      },
    );

    test('plaintext is forwarded verbatim to the chosen delegate', () async {
      const plaintext = '  sk-ant-WITH-padding-and-Mixed-Case-1234  ';
      final stub = _RecordingKmsProvider(label: 'stub');
      final real = _RecordingKmsProvider(label: 'real');
      final router = KmsLaneRouter(
        stub: stub,
        real: real,
        flagLookup: (_) async => true,
      );

      await router.writeSecret(
        logicalKeyKind: 'anthropic',
        plaintext: plaintext,
      );

      expect(real.calls.single.plaintext, plaintext);
    });
  });
}

/// Captures every `writeSecret` call so tests can assert who was
/// chosen + what they received. Returns a deterministic
/// `kms://recorded/<label>/<n>` pointer keyed off the label so the
/// caller can tell apart whose result they got back.
class _RecordingKmsProvider implements KmsProvider {
  _RecordingKmsProvider({required this.label, this.throwOnNextWrite});

  final String label;
  KmsWriteFailure? throwOnNextWrite;
  final List<_RecordedWrite> calls = <_RecordedWrite>[];

  @override
  Future<KmsWriteResult> writeSecret({
    required String logicalKeyKind,
    required String plaintext,
  }) async {
    if (throwOnNextWrite != null) {
      final failure = throwOnNextWrite!;
      throwOnNextWrite = null;
      throw failure;
    }
    calls.add(_RecordedWrite(kind: logicalKeyKind, plaintext: plaintext));
    final ordinal = calls.length;
    return KmsWriteResult(
      secretName: 'kms://recorded/$label/$ordinal',
      maskedDisplay: '***',
    );
  }
}

class _RecordedWrite {
  const _RecordedWrite({required this.kind, required this.plaintext});

  final String kind;
  final String plaintext;
}
