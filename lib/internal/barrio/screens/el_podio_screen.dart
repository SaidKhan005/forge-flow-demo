import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../content/el_podio_demo_data.dart';
import '../widgets/barrio_destination_scaffold.dart';

/// El Podio — the Barrio Legado scoreboard.
///
/// Premium glassmorphic podium for top 3 performers plus a ranked list
/// for remaining entries. Scores are Phase-9-ready: the [PodioEntry] model
/// includes userId for future auth-scoped persistence.
///
/// Negative scores are presented in a muted (not shaming) style.
class ElPodioScreen extends StatefulWidget {
  const ElPodioScreen({super.key});

  @override
  State<ElPodioScreen> createState() => _ElPodioScreenState();
}

class _ElPodioScreenState extends State<ElPodioScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFD4AF37);
  static const _silver = Color(0xFFC0C0C0);
  static const _bronze = Color(0xFFCD7F32);

  late final AnimationController _entranceCtrl;
  late final Animation<double> _entranceFade;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..forward();
    _entranceFade = CurvedAnimation(
      parent: _entranceCtrl,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = List<PodioEntry>.from(podioDemo)
      ..sort((a, b) => b.score.compareTo(a.score));

    final top3 = entries.take(3).toList();
    final rest = entries.skip(3).toList();

    return Scaffold(
      backgroundColor: BarrioColors.shellDeep,
      appBar: barrioAppBar(
        context: context,
        title: 'El Podio',
        accentColor: _gold,
      ),
      body: _ElPodioPremiumBackground(
        child: SafeArea(
          child: FadeTransition(
            opacity: _entranceFade,
            child: Column(
              children: [
                const SizedBox(height: 16),
                // Podium section
                if (top3.length >= 3)
                  _PodiumSection(
                    first: top3[0],
                    second: top3[1],
                    third: top3[2],
                    entranceCtrl: _entranceCtrl,
                  ),
                const SizedBox(height: 20),
                // Gold gradient divider
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Container(
                    height: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          _gold.withValues(alpha: 0.4),
                          _gold.withValues(alpha: 0.4),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.3, 0.7, 1.0],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // Ranked list
                if (rest.isNotEmpty)
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 4),
                      itemCount: rest.length,
                      itemBuilder: (context, index) {
                        final rank = index + 4; // top 3 already shown
                        return _StaggeredTileEntry(
                          index: index,
                          child: _RankTile(
                            entry: rest[index],
                            rank: rank,
                          ),
                        );
                      },
                    ),
                  )
                else
                  const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Podium section — top 3 with varied heights and medal colors
// ---------------------------------------------------------------------------

class _PodiumSection extends StatelessWidget {
  final PodioEntry first;
  final PodioEntry second;
  final PodioEntry third;
  final AnimationController entranceCtrl;

  const _PodiumSection({
    required this.first,
    required this.second,
    required this.third,
    required this.entranceCtrl,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 2nd place — silver
          Expanded(
            child: _PodiumColumn(
              entry: second,
              rank: 2,
              medalColor: _ElPodioScreenState._silver,
              podiumHeight: 100,
              avatarSize: 52,
              entranceCtrl: entranceCtrl,
              entranceDelay: 0.15,
            ),
          ),
          const SizedBox(width: 8),
          // 1st place — gold + crown
          Expanded(
            child: _PodiumColumn(
              entry: first,
              rank: 1,
              medalColor: _ElPodioScreenState._gold,
              podiumHeight: 130,
              avatarSize: 64,
              showCrown: true,
              entranceCtrl: entranceCtrl,
              entranceDelay: 0.0,
            ),
          ),
          const SizedBox(width: 8),
          // 3rd place — bronze
          Expanded(
            child: _PodiumColumn(
              entry: third,
              rank: 3,
              medalColor: _ElPodioScreenState._bronze,
              podiumHeight: 80,
              avatarSize: 52,
              entranceCtrl: entranceCtrl,
              entranceDelay: 0.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _PodiumColumn extends StatelessWidget {
  final PodioEntry entry;
  final int rank;
  final Color medalColor;
  final double podiumHeight;
  final double avatarSize;
  final bool showCrown;
  final AnimationController entranceCtrl;
  final double entranceDelay;

  const _PodiumColumn({
    required this.entry,
    required this.rank,
    required this.medalColor,
    required this.podiumHeight,
    required this.avatarSize,
    this.showCrown = false,
    required this.entranceCtrl,
    required this.entranceDelay,
  });

  @override
  Widget build(BuildContext context) {
    final slideUp = CurvedAnimation(
      parent: entranceCtrl,
      curve: Interval(entranceDelay, entranceDelay + 0.5,
          curve: Curves.easeOutCubic),
    );
    final crownScale = CurvedAnimation(
      parent: entranceCtrl,
      curve: Interval(entranceDelay + 0.4, entranceDelay + 0.7,
          curve: Curves.elasticOut),
    );

    return AnimatedBuilder(
      animation: slideUp,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, 30 * (1 - slideUp.value)),
          child: Opacity(
            opacity: slideUp.value,
            child: child,
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Crown for #1
          if (showCrown)
            ScaleTransition(
              scale: crownScale,
              child: Icon(
                Icons.workspace_premium,
                color: medalColor,
                size: 28,
              ),
            )
          else
            const SizedBox(height: 28),

          const SizedBox(height: 4),

          // Avatar
          Container(
            width: avatarSize,
            height: avatarSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: entry.avatarColor.withValues(alpha: 0.20),
              border: Border.all(
                color: medalColor.withValues(alpha: 0.60),
                width: 2.5,
              ),
              boxShadow: [
                // Inner medal glow
                BoxShadow(
                  color: medalColor.withValues(alpha: 0.25),
                  blurRadius: 18,
                  spreadRadius: 0,
                ),
                // Outer ambient
                BoxShadow(
                  color: medalColor.withValues(alpha: 0.10),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Center(
              child: Text(
                entry.initials,
                style: GoogleFonts.ibmPlexMono(
                  fontSize: avatarSize * 0.3,
                  fontWeight: FontWeight.w700,
                  color: entry.avatarColor,
                ),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Name
          Text(
            entry.displayName,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.playfairDisplay(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: BarrioColors.textPrimary,
            ),
          ),

          const SizedBox(height: 2),

          // Score
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '${entry.score}',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: rank == 1 ? 20 : 16,
                  fontWeight: FontWeight.w700,
                  color: medalColor,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                'pts',
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: medalColor.withValues(alpha: 0.5),
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),

          // Weekly change
          Text(
            entry.weeklyChange >= 0
                ? '+${entry.weeklyChange} this week'
                : '${entry.weeklyChange} this week',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              color: entry.weeklyChange >= 0
                  ? const Color(0xFF2ECC71).withValues(alpha: 0.7)
                  : BarrioColors.textMuted.withValues(alpha: 0.5),
              letterSpacing: 0.2,
            ),
          ),

          const SizedBox(height: 8),

          // Podium base — glass with specular highlight
          Container(
            height: podiumHeight,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(12)),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  medalColor.withValues(alpha: 0.22),
                  medalColor.withValues(alpha: 0.08),
                  medalColor.withValues(alpha: 0.04),
                ],
                stops: const [0.0, 0.4, 1.0],
              ),
              border: Border(
                top: BorderSide(
                  color: medalColor.withValues(alpha: 0.45),
                  width: 1.5,
                ),
                left: BorderSide(
                  color: medalColor.withValues(alpha: 0.18),
                  width: 0.5,
                ),
                right: BorderSide(
                  color: medalColor.withValues(alpha: 0.18),
                  width: 0.5,
                ),
              ),
            ),
            child: Stack(
              children: [
                // Specular highlight — top-left light catch
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          center: const Alignment(-0.6, -0.9),
                          radius: 0.8,
                          colors: [
                            Colors.white.withValues(alpha: 0.06),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Center(
                  child: Text(
                    '#$rank',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: medalColor.withValues(alpha: 0.20),
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

// ---------------------------------------------------------------------------
// Rank tile — for entries #4 and beyond
// ---------------------------------------------------------------------------

class _RankTile extends StatelessWidget {
  final PodioEntry entry;
  final int rank;

  const _RankTile({required this.entry, required this.rank});

  @override
  Widget build(BuildContext context) {
    final isNegative = entry.score < 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xF2FFFFFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isNegative
              ? const Color(0x1A16243B)
              : entry.avatarColor.withValues(alpha: 0.30),
        ),
        boxShadow: [
          // Inner accent glow
          BoxShadow(
            color: entry.avatarColor.withValues(alpha: isNegative ? 0.04 : 0.08),
            blurRadius: 16,
            spreadRadius: -4,
          ),
          // Outer soft lift (navy-tinted, light UI)
          const BoxShadow(
            color: Color(0x1416243B),
            blurRadius: 20,
            spreadRadius: -4,
          ),
        ],
      ),
      child: Stack(
        children: [
          // Specular highlight
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.7, -0.8),
                    radius: 0.8,
                    colors: [
                      Colors.white.withValues(alpha: 0.06),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
        children: [
          // Rank number
          SizedBox(
            width: 28,
            child: Text(
              '#$rank',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: isNegative
                    ? BarrioColors.textMuted.withValues(alpha: 0.4)
                    : BarrioColors.tealDeep.withValues(alpha: 0.8),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Avatar
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: entry.avatarColor.withValues(alpha: isNegative ? 0.12 : 0.20),
              border: Border.all(
                color: entry.avatarColor.withValues(alpha: isNegative ? 0.15 : 0.35),
              ),
            ),
            child: Center(
              child: Text(
                entry.initials,
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: entry.avatarColor
                      .withValues(alpha: isNegative ? 0.5 : 1.0),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Name + weekly change
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.displayName,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: isNegative
                        ? BarrioColors.textMuted
                        : BarrioColors.textPrimary,
                  ),
                ),
                Text(
                  entry.weeklyChange >= 0
                      ? '+${entry.weeklyChange} this week'
                      : '${entry.weeklyChange} this week',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11,
                    color: entry.weeklyChange >= 0
                        ? const Color(0xFF2ECC71).withValues(alpha: 0.6)
                        : BarrioColors.textMuted.withValues(alpha: 0.4),
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),

          // Score
          Text(
            '${entry.score}',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: isNegative
                  ? BarrioColors.textMuted.withValues(alpha: 0.45)
                  : BarrioColors.textPrimary,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            'pts',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              color: BarrioColors.textMuted.withValues(alpha: 0.4),
              letterSpacing: 0.3,
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

// ---------------------------------------------------------------------------
// Staggered tile entry animation
// ---------------------------------------------------------------------------

class _StaggeredTileEntry extends StatefulWidget {
  final int index;
  final Widget child;
  const _StaggeredTileEntry({required this.index, required this.child});

  @override
  State<_StaggeredTileEntry> createState() => _StaggeredTileEntryState();
}

class _StaggeredTileEntryState extends State<_StaggeredTileEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.08),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: 500 + 80 * widget.index), () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

// ---------------------------------------------------------------------------
// Premium background — gold accent bloom
// ---------------------------------------------------------------------------

class _ElPodioPremiumBackground extends StatelessWidget {
  final Widget child;
  const _ElPodioPremiumBackground({required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: Full-bleed photo (reuse home background)
        Positioned.fill(
          child: Image.asset(
            'assets/internal/barrio/home_bg.webp',
            fit: BoxFit.cover,
            alignment: const Alignment(0.0, -0.4),
            errorBuilder: (_, __, ___) => const ColoredBox(
              color: BarrioColors.shellDeep,
            ),
          ),
        ),

        // Layer 2: Heavy cream veil for text legibility over photo
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.15, 0.4, 0.7, 0.9, 1.0],
                  colors: [
                    BarrioColors.shellDeep.withValues(alpha: 0.92),
                    BarrioColors.shellDeep.withValues(alpha: 0.85),
                    BarrioColors.shellDeep.withValues(alpha: 0.80),
                    BarrioColors.shellDeep.withValues(alpha: 0.85),
                    BarrioColors.shellDeep.withValues(alpha: 0.92),
                    BarrioColors.shellDeep.withValues(alpha: 0.96),
                  ],
                ),
              ),
            ),
          ),
        ),

        // Layer 3: Gold accent bloom — top center
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(0.0, -0.85),
                  radius: 1.05,
                  colors: [
                    _ElPodioScreenState._gold.withValues(alpha: 0.16),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),

        // Layer 4: Navy bloom — bottom
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.85, 0.95),
                  radius: 0.75,
                  colors: [
                    Color(0x1A1A2456),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),

        // Layer 5: Edge vignette
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.1,
                  colors: [
                    Colors.transparent,
                    BarrioColors.shellDeep.withValues(alpha: 0.35),
                  ],
                ),
              ),
            ),
          ),
        ),

        child,
      ],
    );
  }
}
