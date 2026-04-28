// Phase 9.9 - Role-permission matrix editor controller.
//
// Pure logic backing the dense matrix editor:
//
//   rows = permission keys (grouped by category)
//   columns = roles
//   cells = allow / deny / inherit (no explicit rule)
//
// "Diff vs seeded baseline" tracks every cell that differs from the
// initial state the editor was loaded with. The proxy uses the diff
// to write a single `role_audit_log` row capturing the
// before/after JSONB payload for every mutation that hits Save.
//
// The controller is plain Dart with no Flutter dependency — Phase
// 9.9's optional UI consumes it through a ChangeNotifier wrapper or
// a Provider; tests interact with it directly.

import '../../auth/permission_effect.dart';

enum MatrixCellState {
  /// No `role_permissions` row for this (role, key); the resolver
  /// treats it as deny (default deny).
  inherit,

  /// Explicit allow.
  allow,

  /// Explicit deny — wins over allow at resolution time per the
  /// 9.6 algorithm.
  deny;

  PermissionEffect? toEffect() {
    switch (this) {
      case MatrixCellState.inherit:
        return null;
      case MatrixCellState.allow:
        return PermissionEffect.allow;
      case MatrixCellState.deny:
        return PermissionEffect.deny;
    }
  }

  static MatrixCellState fromEffect(PermissionEffect? effect) {
    if (effect == null) return MatrixCellState.inherit;
    return effect == PermissionEffect.allow
        ? MatrixCellState.allow
        : MatrixCellState.deny;
  }
}

class MatrixCellChange {
  const MatrixCellChange({
    required this.roleId,
    required this.permissionKey,
    required this.from,
    required this.to,
  });

  final String roleId;
  final String permissionKey;
  final MatrixCellState from;
  final MatrixCellState to;
}

class RolePermissionMatrixController {
  RolePermissionMatrixController({
    required Map<String, Map<String, PermissionEffect>> baseline,
  }) : _baseline = baseline.map(
         (roleId, perKey) => MapEntry(
           roleId,
           Map<String, PermissionEffect>.unmodifiable(perKey),
         ),
       ),
       _current = baseline.map(
         (roleId, perKey) => MapEntry(
           roleId,
           Map<String, PermissionEffect>.from(perKey),
         ),
       );

  final Map<String, Map<String, PermissionEffect>> _baseline;
  final Map<String, Map<String, PermissionEffect>> _current;

  /// Returns the current cell state for [roleId] x [permissionKey].
  MatrixCellState cell(String roleId, String permissionKey) {
    final per = _current[roleId];
    if (per == null) return MatrixCellState.inherit;
    return MatrixCellState.fromEffect(per[permissionKey]);
  }

  /// Sets the cell to [state]. Inherit removes the row; allow / deny
  /// upserts it.
  void setCell({
    required String roleId,
    required String permissionKey,
    required MatrixCellState state,
  }) {
    final per = _current.putIfAbsent(roleId, () => <String, PermissionEffect>{});
    final effect = state.toEffect();
    if (effect == null) {
      per.remove(permissionKey);
    } else {
      per[permissionKey] = effect;
    }
  }

  /// Cycles the cell through inherit → allow → deny → inherit.
  void toggleCell({required String roleId, required String permissionKey}) {
    final next = switch (cell(roleId, permissionKey)) {
      MatrixCellState.inherit => MatrixCellState.allow,
      MatrixCellState.allow => MatrixCellState.deny,
      MatrixCellState.deny => MatrixCellState.inherit,
    };
    setCell(roleId: roleId, permissionKey: permissionKey, state: next);
  }

  /// Resets every cell back to the loaded baseline.
  void revertAll() {
    _current.clear();
    for (final entry in _baseline.entries) {
      _current[entry.key] = Map<String, PermissionEffect>.from(entry.value);
    }
  }

  /// Returns true iff any cell differs from the baseline.
  bool get isDirty => diff().isNotEmpty;

  /// Computes the per-cell diff vs the loaded baseline. Empty list
  /// means clean. The proxy emits the diff as the
  /// `role_audit_log.change_payload` JSONB.
  List<MatrixCellChange> diff() {
    final changes = <MatrixCellChange>[];
    final allRoles = <String>{..._baseline.keys, ..._current.keys};
    for (final roleId in allRoles) {
      final base = _baseline[roleId] ?? const <String, PermissionEffect>{};
      final cur = _current[roleId] ?? const <String, PermissionEffect>{};
      final allKeys = <String>{...base.keys, ...cur.keys};
      for (final key in allKeys) {
        final from = MatrixCellState.fromEffect(base[key]);
        final to = MatrixCellState.fromEffect(cur[key]);
        if (from != to) {
          changes.add(
            MatrixCellChange(
              roleId: roleId,
              permissionKey: key,
              from: from,
              to: to,
            ),
          );
        }
      }
    }
    // Stable ordering for deterministic audit payloads + tests.
    changes.sort((a, b) {
      final byRole = a.roleId.compareTo(b.roleId);
      if (byRole != 0) return byRole;
      return a.permissionKey.compareTo(b.permissionKey);
    });
    return changes;
  }

  /// Diff serialized as the JSONB shape `role_audit_log.change_payload`
  /// expects.
  Map<String, Object?> diffPayload() {
    final changes = diff();
    return <String, Object?>{
      'change_count': changes.length,
      'changes': <Map<String, Object?>>[
        for (final change in changes)
          <String, Object?>{
            'role_id': change.roleId,
            'permission_key': change.permissionKey,
            'from': change.from.name,
            'to': change.to.name,
          },
      ],
    };
  }
}
