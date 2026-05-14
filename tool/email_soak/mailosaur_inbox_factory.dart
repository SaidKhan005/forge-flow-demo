// Wave 2 Q-2a — per-test Mailosaur inbox derivation.
//
// Each scenario gets a unique loopback inbox so parallel orchestrator
// runs against the same Mailosaur server do NOT collide.
//
// Inbox address shape:
//
//   <prefix>-<scenario>-<run_id_hash>@<server>.mailosaur.net
//
// where:
//   * <prefix> defaults to `q2a-soak` (overridable via
//     `MAILOSAUR_INBOX_PREFIX`).
//   * <scenario> is the slugified `EmailSoakScenario.scenarioId`.
//   * <run_id_hash> is a short hash of the orchestrator's run id so
//     two parallel runs produce different addresses but a re-run with
//     the same run id reuses the same address (idempotent).
//
// Mailosaur accepts any subdomain prefix under the server's
// `<server_id>.mailosaur.net` zone; the wildcard MX routes every
// address to the server's inbox. This is the documented per-test
// inbox pattern.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Derive the per-scenario Mailosaur inbox address.
///
/// [inboxPrefix] is the operator-configured prefix
/// (`MAILOSAUR_INBOX_PREFIX`, default `q2a-soak`). [scenarioId] is
/// the scenario's stable id. [runId] is the orchestrator's run id —
/// hashed to keep the address short. [serverId] is the Mailosaur
/// server identifier.
String deriveMailosaurInbox({
  required String inboxPrefix,
  required String scenarioId,
  required String runId,
  required String serverId,
}) {
  final scenario = _slug(scenarioId);
  final runHash = _shortHash(runId);
  final local = '$inboxPrefix-$scenario-$runHash';
  return '$local@$serverId.mailosaur.net';
}

/// Slugify an arbitrary scenario id into a safe local-part fragment.
String _slug(String raw) {
  final lower = raw.toLowerCase();
  final out = StringBuffer();
  for (var i = 0; i < lower.length; i++) {
    final ch = lower.codeUnitAt(i);
    final isLower = ch >= 0x61 && ch <= 0x7a;
    final isDigit = ch >= 0x30 && ch <= 0x39;
    if (isLower || isDigit) {
      out.writeCharCode(ch);
    } else if (ch == 0x2d || ch == 0x5f) {
      out.writeCharCode(0x2d); // collapse `_` and `-` to `-`
    }
    // every other character is dropped (no hyphen runs).
  }
  return out.toString();
}

/// 6-char hex hash of [runId] so the inbox address stays compact
/// while still being unique per orchestrator run.
String _shortHash(String runId) {
  final digest = sha256.convert(utf8.encode(runId)).bytes;
  final hex = StringBuffer();
  for (var i = 0; i < 3; i++) {
    final b = digest[i];
    hex.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return hex.toString();
}
