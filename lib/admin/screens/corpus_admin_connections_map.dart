// C2-map — the focusable connection Map for the corpus admin Connections
// tab.
//
// Replaces the C2 "coming soon" Map placeholder with the approved
// preview's focusable node-link diagram (preview lines 360-399). The map
// reads the SAME [GraphCandidateDiff] the clarity lists already use: it
// adds NO new gateway/proxy/data and fabricates nothing. Every edge it
// draws is a real candidate edge; every verb is C2's plain-English
// relationship reading ([corpusRelationshipVerb]); every line colour is
// C2's clarity bucketing ([corpusConnectionClarity]) mapped to the
// theme's positive / warning / muted tokens.
//
// Layout (honest, no graph-layout package): the focused topic sits on
// the left; its directly-connected topics stack on the right; one line
// per edge connects them. Lines are styled by clarity:
//   * clear        -> solid line
//   * worth-check  -> dashed line
//   * not-sure     -> dotted line
// matching the preview's legend. The diagram is drawn with a single
// [CustomPaint] (edges + node boxes) sized to the node count, so it
// scales down to an honest empty state when the focus topic has no links
// and shows an honest "No connections to map yet." card when there is no
// graph data at all.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_human_labels.dart';
import '../models/corpus_admin_models.dart';
import 'corpus_admin_chunk_view.dart' show corpusTopicKindIcon;
import 'corpus_admin_connections_view.dart'
    show
        CorpusConnectionClarity,
        corpusConnectionClarity,
        corpusConnectionNodeKind,
        corpusConnectionNodeName,
        corpusRelationshipVerb;

/// Clarity accent colour for a map edge. REUSES C2's exact clarity ->
/// theme-token mapping (clear = positive, worth-checking = warning,
/// not-sure = muted) so the map and the lists never disagree. Public so
/// the map's legend + painter + tests can all read the same source.
Color corpusMapClarityColor(CorpusConnectionClarity clarity) {
  switch (clarity) {
    case CorpusConnectionClarity.clear:
      return AppColors.positive;
    case CorpusConnectionClarity.check:
      return AppColors.warning;
    case CorpusConnectionClarity.unsure:
      return AppColors.textMuted;
  }
}

/// One resolved edge in the focused map: the connected (non-focused)
/// topic name, the plain-English verb, and the clarity bucket. The
/// [outbound] flag records whether the focused topic is the FROM side
/// (so the arrow/sentence read in the natural direction).
@immutable
class CorpusMapEdge {
  const CorpusMapEdge({
    required this.otherName,
    required this.otherKind,
    required this.verb,
    required this.clarity,
    required this.outbound,
  });

  final String otherName;

  /// Kind of the connected (non-focused) topic, so the map node can lead
  /// with the same per-kind icon the topic list + connection flow use.
  final AdminCorpusTopicKind otherKind;
  final String verb;
  final CorpusConnectionClarity clarity;
  final bool outbound;

  @override
  bool operator ==(Object other) =>
      other is CorpusMapEdge &&
      other.otherName == otherName &&
      other.otherKind == otherKind &&
      other.verb == verb &&
      other.clarity == clarity &&
      other.outbound == outbound;

  @override
  int get hashCode => Object.hash(otherName, otherKind, verb, clarity, outbound);
}

/// Pure model of the focused map: the centred topic, the distinct list of
/// focusable topics, the edges touching the focus, and the honest total.
///
/// Kept free of widgets/I/O so the focus selection + edge resolution is
/// unit-testable. The view layer ([CorpusConnectionsMap]) renders it.
@immutable
class CorpusMapModel {
  const CorpusMapModel({
    required this.topics,
    required this.focus,
    required this.focusKind,
    required this.edges,
    required this.totalEdges,
  });

  /// Distinct topic names that appear as an endpoint on at least one
  /// edge candidate, sorted for a stable dropdown order.
  final List<String> topics;

  /// The currently-centred topic, or null when there are no topics.
  final String? focus;

  /// Kind of the focused topic, so the centre node leads with the same
  /// per-kind icon the rest of the screen uses. Defaults to Document when
  /// the producer recorded no type for it.
  final AdminCorpusTopicKind focusKind;

  /// The edges directly connected to [focus] (deduped by other-topic +
  /// verb so a repeated pair does not draw twice).
  final List<CorpusMapEdge> edges;

  /// Honest count of ALL edge candidates in the diff (the "of M" in the
  /// caption), independent of which topic is focused.
  final int totalEdges;

  bool get hasGraph => topics.isNotEmpty;

  /// Builds the model from the raw diff for a chosen [focusTopic] (null =
  /// default to the first topic). Only EDGE candidates contribute links;
  /// single-node candidates carry no relationship to map.
  factory CorpusMapModel.fromDiff(
    GraphCandidateDiff diff, {
    String? focusTopic,
  }) {
    final allEdges = <GraphCandidate>[
      ...diff.extracted,
      ...diff.inferred,
      ...diff.ambiguous,
    ].where((c) => c.kind == GraphCandidateKind.edge).toList(growable: false);

    // Distinct topic names across both endpoints, plus a best-effort kind
    // per topic read from the producer's recorded node types (the same
    // signal the connection flow uses). A topic with no recorded type
    // reads as a Document; nothing is fabricated.
    final topicSet = <String>{};
    final topicKinds = <String, AdminCorpusTopicKind>{};
    void note(String name, String? rawType) {
      if (name == 'this topic') return;
      topicSet.add(name);
      if (!topicKinds.containsKey(name) && rawType != null) {
        topicKinds[name] = corpusConnectionNodeKind(rawType);
      }
    }

    for (final c in allEdges) {
      note(
        corpusConnectionNodeName(c.fromNodeKey),
        c.payload['from_node_type'] as String?,
      );
      note(
        corpusConnectionNodeName(c.toNodeKey),
        c.payload['to_node_type'] as String?,
      );
    }
    final topics = topicSet.toList()..sort();
    AdminCorpusTopicKind kindOf(String name) =>
        topicKinds[name] ?? AdminCorpusTopicKind.document;

    if (topics.isEmpty) {
      return const CorpusMapModel(
        topics: <String>[],
        focus: null,
        focusKind: AdminCorpusTopicKind.document,
        edges: <CorpusMapEdge>[],
        totalEdges: 0,
      );
    }

    // Resolve the focus: honour the caller's choice when it is still a
    // valid topic, otherwise centre on the first.
    final focus = (focusTopic != null && topics.contains(focusTopic))
        ? focusTopic
        : topics.first;

    // Edges touching the focus, deduped by (other topic, verb, direction).
    final seen = <String>{};
    final edges = <CorpusMapEdge>[];
    for (final c in allEdges) {
      final from = corpusConnectionNodeName(c.fromNodeKey);
      final to = corpusConnectionNodeName(c.toNodeKey);
      final outbound = from == focus;
      final inbound = to == focus;
      if (!outbound && !inbound) continue;
      final other = outbound ? to : from;
      if (other == 'this topic' || other == focus) continue;
      final verb = corpusRelationshipVerb(c.candidateType);
      final clarity = corpusConnectionClarity(c);
      final dedupe = '$other|$verb|$outbound|${clarity.name}';
      if (!seen.add(dedupe)) continue;
      edges.add(
        CorpusMapEdge(
          otherName: other,
          otherKind: kindOf(other),
          verb: verb,
          clarity: clarity,
          outbound: outbound,
        ),
      );
    }

    return CorpusMapModel(
      topics: topics,
      focus: focus,
      focusKind: kindOf(focus),
      edges: edges,
      totalEdges: allEdges.length,
    );
  }
}

/// C2-map: the focusable Map card. A "Focus on:" dropdown over the
/// distinct topics, a node-link diagram centred on the focused topic, an
/// honest caption, and a clarity legend. Reads only the passed-in
/// [diff] (no gateway). Local UI state = the focused topic only.
class CorpusConnectionsMap extends StatefulWidget {
  const CorpusConnectionsMap({super.key, required this.diff});

  /// The same connections diff the clarity lists render. The map draws
  /// only real edge candidates from it.
  final GraphCandidateDiff diff;

  @override
  State<CorpusConnectionsMap> createState() => _CorpusConnectionsMapState();
}

class _CorpusConnectionsMapState extends State<CorpusConnectionsMap> {
  String? _focus;

  @override
  Widget build(BuildContext context) {
    final model = CorpusMapModel.fromDiff(widget.diff, focusTopic: _focus);

    // Honest empty state: no edge candidates means nothing to map. We do
    // NOT draw a fabricated diagram.
    if (!model.hasGraph) {
      return OperatorWebPanel(
        key: const Key('admin_corpus_connections_map'),
        title: AdminKnowledgeBaseCopy.connectionsMapTitle,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.hub_outlined, size: 18, color: AppColors.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                AdminKnowledgeBaseCopy.connectionsMapEmpty,
                key: const Key('admin_corpus_connections_map_empty'),
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      );
    }

    final focus = model.focus!;
    return OperatorWebPanel(
      key: const Key('admin_corpus_connections_map'),
      title: AdminKnowledgeBaseCopy.connectionsMapTitle,
      trailing: _FocusDropdown(
        topics: model.topics,
        focus: focus,
        onChanged: (value) {
          if (value != null && value != _focus) {
            setState(() => _focus = value);
          }
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _MapDiagram(focus: focus, edges: model.edges),
          const SizedBox(height: 12),
          Text(
            AdminKnowledgeBaseCopy.connectionsMapCaption(
              model.edges.length,
              model.totalEdges,
              focus,
            ),
            key: const Key('admin_corpus_connections_map_caption'),
            style: AppTextStyles.body12(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          const _MapLegend(),
        ],
      ),
    );
  }
}

/// C2-map: the "Focus on:" dropdown. Lists every distinct topic so the
/// operator can centre the diagram on any of them.
class _FocusDropdown extends StatelessWidget {
  const _FocusDropdown({
    required this.topics,
    required this.focus,
    required this.onChanged,
  });

  final List<String> topics;
  final String focus;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          AdminKnowledgeBaseCopy.connectionsMapFocusLabel,
          style: AppTextStyles.body12(color: AppColors.textMuted),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.backgroundSurface,
              border: Border.all(color: AppColors.borderSubtle, width: 1),
              borderRadius: BorderRadius.circular(AppRadius.small),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                key: const Key('admin_corpus_connections_map_focus'),
                value: focus,
                isDense: true,
                isExpanded: true,
                borderRadius: BorderRadius.circular(AppRadius.small),
                icon: const Icon(
                  Icons.expand_more_outlined,
                  size: 18,
                  color: AppColors.textMuted,
                ),
                style: AppTextStyles.body13(color: AppColors.textPrimary),
                dropdownColor: AppColors.backgroundSurface,
                items: <DropdownMenuItem<String>>[
                  for (final topic in topics)
                    DropdownMenuItem<String>(
                      value: topic,
                      child: Text(topic, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// C2-map: the node-link diagram. The focused topic box sits on the left;
/// the connected topic boxes stack down the right; one clarity-styled
/// line per edge joins them with its verb label. Drawn as a single
/// [CustomPaint] so the layout stays simple + honest and never pulls a
/// graph-layout package. When the focus has no edges the painter renders
/// just the focused box plus an honest "no links" note.
class _MapDiagram extends StatelessWidget {
  const _MapDiagram({required this.focus, required this.edges});

  final String focus;
  final List<CorpusMapEdge> edges;

  @override
  Widget build(BuildContext context) {
    // Height grows with the connected-node count so rows never overlap;
    // a comfortable per-row band with a sensible floor.
    const double rowHeight = 64;
    const double minHeight = 150;
    final height = edges.isEmpty
        ? minHeight
        : (edges.length * rowHeight + 40).clamp(minHeight, 520).toDouble();

    return Container(
      key: const Key('admin_corpus_connections_map_diagram'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(
          color: AppColors.borderSubtle.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, height);
            return CustomPaint(
              size: size,
              painter: _MapPainter(
                focus: focus,
                edges: edges,
                // Resolve the text styles in the widget tree so the
                // painter draws the same fonts the rest of the screen
                // uses (google_fonts resolves lazily otherwise).
                nodeStyle: AppTextStyles.mono11(color: AppColors.textPrimary),
                verbStyleFor: (clarity) => AppTextStyles.mono8(
                  color: corpusMapClarityColor(clarity),
                ),
                emptyStyle: AppTextStyles.body12(
                  color: AppColors.textSecondary,
                ),
                emptyNote: AdminKnowledgeBaseCopy.connectionsMapNoLinks(focus),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Paints the focused node, the connected nodes, and the clarity-styled
/// connector lines + verb labels. Pure drawing: all data is resolved
/// before it gets here.
class _MapPainter extends CustomPainter {
  _MapPainter({
    required this.focus,
    required this.edges,
    required this.nodeStyle,
    required this.verbStyleFor,
    required this.emptyStyle,
    required this.emptyNote,
  });

  final String focus;
  final List<CorpusMapEdge> edges;
  final TextStyle nodeStyle;
  final TextStyle Function(CorpusConnectionClarity clarity) verbStyleFor;
  final TextStyle emptyStyle;
  final String emptyNote;

  static const double _nodeWidth = 150;
  static const double _nodeHeight = 40;
  static const double _radius = 11;

  @override
  void paint(Canvas canvas, Size size) {
    final focusCenter = Offset(_nodeWidth / 2 + 4, size.height / 2);

    // Connected node centres: stacked down the right edge.
    final rightX = size.width - _nodeWidth / 2 - 4;
    final centers = <Offset>[];
    if (edges.isNotEmpty) {
      final slot = size.height / edges.length;
      for (var i = 0; i < edges.length; i++) {
        centers.add(Offset(rightX, slot * (i + 0.5)));
      }
    }

    // 1) Draw the connector lines first so node boxes sit on top.
    for (var i = 0; i < edges.length; i++) {
      final edge = edges[i];
      final color = corpusMapClarityColor(edge.clarity);
      final start = Offset(
        focusCenter.dx + _nodeWidth / 2,
        focusCenter.dy,
      );
      final end = Offset(centers[i].dx - _nodeWidth / 2, centers[i].dy);
      _drawClarityLine(canvas, start, end, color, edge.clarity);
      _drawArrowHead(canvas, start, end, color, edge.outbound);

      // Verb label near the line midpoint, nudged above the line.
      final mid = Offset(
        (start.dx + end.dx) / 2,
        (start.dy + end.dy) / 2 - 10,
      );
      _drawText(
        canvas,
        edge.verb,
        mid,
        verbStyleFor(edge.clarity),
        maxWidth: (end.dx - start.dx).abs(),
        center: true,
      );
    }

    // 2) The focused node box.
    _drawNodeBox(
      canvas,
      focusCenter,
      focus,
      fill: AppColors.backgroundMid,
      border: AppColors.borderSubtle,
    );

    // 3) Connected node boxes, tinted by clarity.
    for (var i = 0; i < edges.length; i++) {
      final edge = edges[i];
      final color = corpusMapClarityColor(edge.clarity);
      _drawNodeBox(
        canvas,
        centers[i],
        edge.otherName,
        fill: color.withValues(alpha: 0.12),
        border: color,
      );
    }

    // Honest "no links" note when the focus topic stands alone.
    if (edges.isEmpty) {
      _drawText(
        canvas,
        emptyNote,
        Offset(focusCenter.dx + _nodeWidth / 2 + 16, focusCenter.dy - 8),
        emptyStyle,
        maxWidth: size.width - (_nodeWidth + 28),
        center: false,
      );
    }
  }

  void _drawClarityLine(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color,
    CorpusConnectionClarity clarity,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    switch (clarity) {
      case CorpusConnectionClarity.clear:
        // Solid.
        canvas.drawLine(start, end, paint);
        break;
      case CorpusConnectionClarity.check:
        // Dashed (long dashes).
        _drawDashed(canvas, start, end, paint, dash: 6, gap: 5);
        break;
      case CorpusConnectionClarity.unsure:
        // Dotted (short dots).
        _drawDashed(canvas, start, end, paint, dash: 2, gap: 5);
        break;
    }
  }

  void _drawDashed(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    final total = (end - start).distance;
    if (total <= 0) return;
    final dir = (end - start) / total;
    var drawn = 0.0;
    while (drawn < total) {
      final segEnd = (drawn + dash).clamp(0.0, total);
      canvas.drawLine(
        start + dir * drawn,
        start + dir * segEnd,
        paint,
      );
      drawn += dash + gap;
    }
  }

  void _drawArrowHead(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color,
    bool outbound,
  ) {
    // Point the head at the connected node for an outbound edge, back at
    // the focus for an inbound edge.
    final tip = outbound ? end : start;
    final from = outbound ? start : end;
    final total = (tip - from).distance;
    if (total <= 0) return;
    final dir = (tip - from) / total;
    final normal = Offset(-dir.dy, dir.dx);
    const double len = 9;
    const double half = 4;
    final base = tip - dir * len;
    final p1 = base + normal * half;
    final p2 = base - normal * half;
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  void _drawNodeBox(
    Canvas canvas,
    Offset center,
    String label, {
    required Color fill,
    required Color border,
  }) {
    final rect = Rect.fromCenter(
      center: center,
      width: _nodeWidth,
      height: _nodeHeight,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(_radius));
    canvas.drawRRect(rrect, Paint()..color = fill);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    _drawText(
      canvas,
      label,
      center,
      nodeStyle,
      maxWidth: _nodeWidth - 14,
      center: true,
      verticalCenter: true,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset anchor,
    TextStyle style, {
    required double maxWidth,
    required bool center,
    bool verticalCenter = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '...',
      textAlign: center ? TextAlign.center : TextAlign.left,
    )..layout(maxWidth: maxWidth < 0 ? 0 : maxWidth);
    final dx = center ? anchor.dx - tp.width / 2 : anchor.dx;
    final dy = verticalCenter ? anchor.dy - tp.height / 2 : anchor.dy;
    tp.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(covariant _MapPainter old) =>
      old.focus != focus || old.edges != edges;
}

/// C2-map: the clarity legend (Clear / Worth checking / Not sure), each
/// shown with the line style the diagram uses for that clarity.
class _MapLegend extends StatelessWidget {
  const _MapLegend();

  @override
  Widget build(BuildContext context) {
    return Wrap(
      key: const Key('admin_corpus_connections_map_legend'),
      spacing: 18,
      runSpacing: 8,
      children: <Widget>[
        _LegendItem(
          clarity: CorpusConnectionClarity.clear,
          label: AdminKnowledgeBaseCopy.connectionsClarityClear,
        ),
        _LegendItem(
          clarity: CorpusConnectionClarity.check,
          label: AdminKnowledgeBaseCopy.connectionsClarityCheck,
        ),
        _LegendItem(
          clarity: CorpusConnectionClarity.unsure,
          label: AdminKnowledgeBaseCopy.connectionsClarityUnsure,
        ),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.clarity, required this.label});

  final CorpusConnectionClarity clarity;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = corpusMapClarityColor(clarity);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 28,
          height: 8,
          child: CustomPaint(
            painter: _LegendLinePainter(color: color, clarity: clarity),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: AppTextStyles.mono8(color: color)),
      ],
    );
  }
}

/// Draws a short sample of the same clarity line style the diagram uses.
class _LegendLinePainter extends CustomPainter {
  _LegendLinePainter({required this.color, required this.clarity});

  final Color color;
  final CorpusConnectionClarity clarity;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    final start = Offset(0, y);
    final end = Offset(size.width, y);
    switch (clarity) {
      case CorpusConnectionClarity.clear:
        canvas.drawLine(start, end, paint);
        break;
      case CorpusConnectionClarity.check:
        _dash(canvas, start, end, paint, dash: 6, gap: 5);
        break;
      case CorpusConnectionClarity.unsure:
        _dash(canvas, start, end, paint, dash: 2, gap: 5);
        break;
    }
  }

  void _dash(
    Canvas canvas,
    Offset start,
    Offset end,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    final total = (end - start).distance;
    final dir = (end - start) / total;
    var drawn = 0.0;
    while (drawn < total) {
      final segEnd = (drawn + dash).clamp(0.0, total);
      canvas.drawLine(start + dir * drawn, start + dir * segEnd, paint);
      drawn += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _LegendLinePainter old) =>
      old.color != color || old.clarity != clarity;
}
