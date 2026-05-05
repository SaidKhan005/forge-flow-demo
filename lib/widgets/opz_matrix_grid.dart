// Phase 7.58 depth wave, slice 10.5.6.
//
// 3x3 visual grid that lives inside the OPZ tile on the Shift Dashboard
// whole-day view. Rows are CPLH OPZ position (above-ceiling / in-OPZ /
// below-floor). Columns are SPLH movement (low / on / high). The active
// cell is painted in the brand sunset color; the other eight render as a
// dim middot. When SPLH input is missing (BOH not punched in), the grid
// renders nine dim cells with no active marker so the operator sees the
// shape without a phantom claim.
//
// Authority:
//   docs/contracts/phase_7_58_primary_driver_contract.md "Depth Surfaces"
//   docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md ch. 7
//   docs/Knowledge_graph_docs/Bold By Design.md ch. 9

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// CPLH band relative to the OPZ floor and ceiling.
enum OpzCplhBand {
  /// Actual CPLH is above the OPZ ceiling. Over-productive, kitchen
  /// running thin.
  aboveCeiling,

  /// Actual CPLH sits inside the operating zone.
  inOpz,

  /// Actual CPLH is below the OPZ floor. Under-productive, too many
  /// labor hours for the volume.
  belowFloor,
}

/// SPLH movement vs target.
enum OpzSplhBand {
  /// SPLH below the on-target tolerance band.
  low,

  /// SPLH inside the on-target tolerance band.
  onTarget,

  /// SPLH above the on-target tolerance band.
  high,
}

/// 3x3 CPLH x SPLH matrix shown inside the Shift Dashboard OPZ tile.
///
/// Rows map [OpzCplhBand] in display order: aboveCeiling -> inOpz ->
/// belowFloor. Columns map [OpzSplhBand]: low -> onTarget -> high. The
/// active cell is the intersection of the current bands. When [splh]
/// is null the grid renders fully dim with no active marker.
class OpzMatrixGrid extends StatelessWidget {
  const OpzMatrixGrid({
    super.key,
    required this.cplh,
    required this.splh,
  });

  final OpzCplhBand cplh;
  final OpzSplhBand? splh;

  static const List<OpzCplhBand> _rowOrder = <OpzCplhBand>[
    OpzCplhBand.aboveCeiling,
    OpzCplhBand.inOpz,
    OpzCplhBand.belowFloor,
  ];

  static const List<OpzSplhBand> _colOrder = <OpzSplhBand>[
    OpzSplhBand.low,
    OpzSplhBand.onTarget,
    OpzSplhBand.high,
  ];

  static const Map<OpzCplhBand, String> _rowLabel = <OpzCplhBand, String>{
    OpzCplhBand.aboveCeiling: 'OVER',
    OpzCplhBand.inOpz: 'OPZ',
    OpzCplhBand.belowFloor: 'UNDER',
  };

  static const Map<OpzSplhBand, String> _colLabel = <OpzSplhBand, String>{
    OpzSplhBand.low: 'LOW',
    OpzSplhBand.onTarget: 'ON',
    OpzSplhBand.high: 'HIGH',
  };

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'CPLH x SPLH',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              const SizedBox(width: 56),
              for (final OpzSplhBand col in _colOrder)
                Expanded(
                  child: Center(
                    child: Text(
                      'SPLH ${_colLabel[col]}',
                      key: Key('opz_matrix_col_${col.name}'),
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (final OpzCplhBand row in _rowOrder)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  SizedBox(
                    width: 56,
                    child: Text(
                      'CPLH ${_rowLabel[row]}',
                      key: Key('opz_matrix_row_${row.name}'),
                      style:
                          AppTextStyles.mono10(color: AppColors.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final OpzSplhBand col in _colOrder)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: _Cell(
                          row: row,
                          col: col,
                          active:
                              splh != null && row == cplh && col == splh,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.row,
    required this.col,
    required this.active,
  });

  final OpzCplhBand row;
  final OpzSplhBand col;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('opz_matrix_cell_${row.name}_${col.name}'
          '${active ? '_active' : ''}'),
      height: 22,
      decoration: BoxDecoration(
        color: active
            ? AppColors.sunset
            : AppColors.shimmer.withValues(alpha: 0.6),
        border: Border.all(
          color: active
              ? AppColors.sunsetDark
              : AppColors.borderSubtle.withValues(alpha: 0.6),
          width: active ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(2),
      ),
      alignment: Alignment.center,
      child: active
          ? const SizedBox.shrink()
          : Text(
              '·',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
    );
  }
}
