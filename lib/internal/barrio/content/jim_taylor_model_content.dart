// Typed content model and data for the Jim Taylor Labor Model.
//
// All content here is translated from the Jim Taylor deep-dive HTML
// into native structured data. This is a professional, book-like,
// scenario-driven learning surface for managers and admins.
//
// Source: docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md
// (originally docs/internal/barrio/jim_taylor_labor_model_deep_dive.html;
// converted to founder-authored Markdown April 2026)
// Original: Jim Taylor / Benchmark Sixty / Bold Operations (2024)

// ---------------------------------------------------------------------------
// Content model
// ---------------------------------------------------------------------------

enum JtUnitType { concept, scenario, checkpoint }

class JtOption {
  final String label;
  final bool isCorrect;
  final String feedback;
  const JtOption({
    required this.label,
    required this.isCorrect,
    required this.feedback,
  });
}

class JtUnit {
  final String id;
  final JtUnitType type;
  final String title;
  final String body;
  final List<JtOption> options;
  final String? badgeHint;
  const JtUnit({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.options = const [],
    this.badgeHint,
  });
}

class JtModule {
  final String id;
  final String title;
  final String subtitle;
  final int iconCodePoint;
  final List<JtUnit> units;
  const JtModule({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.iconCodePoint,
    required this.units,
  });
}

// ---------------------------------------------------------------------------
// Content data -- translated from source HTML
// ---------------------------------------------------------------------------

const List<JtModule> jtModules = [
  _moduleFoundation,
  _moduleLaborPercent,
  _moduleCplh,
  _moduleSplhAndOPZ,
];

// ---- Module 1: The Foundation --------------------------------------------

const _moduleFoundation = JtModule(
  id: 'foundation',
  title: 'The Foundation',
  subtitle: 'Covers, hours, PPA, and wage mix',
  iconCodePoint: 0xe2c9, // Icons.foundation
  units: [
    JtUnit(
      id: 'fd_covers',
      type: JtUnitType.concept,
      badgeHint: 'COVERS',
      title: 'Cover -- One Guest Served',
      body: 'A table of 4 = 4 covers. Jim uses covers, not tables, because '
          'a table of 2 and a table of 6 are completely different amounts '
          'of work. Covers are honest. Tables are not.',
    ),
    JtUnit(
      id: 'fd_labor_hour',
      type: JtUnitType.concept,
      badgeHint: 'HOURS',
      title: 'Labor Hour',
      body: 'One person working one hour. 3 servers on a 6-hour shift = '
          '18 labor hours. Every person, every hour, adds to the total.\n\n'
          'Example:\n'
          '  3 servers x 6 hrs = 18 hrs\n'
          '  2 runners x 5 hrs = 10 hrs\n'
          '  1 host x 6 hrs = 6 hrs\n'
          '  1 manager x 8 hrs = 8 hrs\n'
          '  Total: 42 labor hours',
    ),
    JtUnit(
      id: 'fd_ppa',
      type: JtUnitType.concept,
      badgeHint: 'PPA',
      title: 'PPA -- Per Person Average',
      body: 'PPA = Total Sales / Total Covers\n\n'
          'Example: \$14,440 sales / 380 covers = \$38.00 per guest.\n\n'
          'If PPA drops from \$38 to \$30, revenue drops \$3,040 on the '
          'same 380 guests -- without a single fewer person walking in. '
          'That \$8 gap is what the team failed to upsell, or what a '
          'rushed experience caused guests not to order.',
    ),
    JtUnit(
      id: 'fd_wage_mix',
      type: JtUnitType.concept,
      badgeHint: 'WAGE MIX',
      title: 'Wage Mix',
      body: 'The blended average hourly rate across all roles. Every role '
          'and every pay rate collapsed into one number.\n\n'
          'Call in a \$26 manager to cover a \$16 server shift and the '
          'wage mix moves. Add a line cook at \$20 instead of a '
          'dishwasher at \$16.50 and it moves. Labor % moves with it -- '
          'without a single cover or hour changing.',
    ),
    JtUnit(
      id: 'fd_scenario',
      type: JtUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'Foundation Scenario',
      body: 'Your Friday shift served 380 covers with 46 FOH labor hours. '
          'PPA was \$38.00. A manager calls in sick, so you cover their '
          'shift yourself at \$26/hr instead of a server at \$16/hr. '
          'What happens to labor %?',
      options: [
        JtOption(
          label: 'It stays the same -- same number of people worked',
          isCorrect: false,
          feedback: 'The headcount is the same, but the wage mix increased. '
              'Higher blended wage means higher labor cost and higher '
              'labor %.',
        ),
        JtOption(
          label: 'It goes down -- a manager is more efficient',
          isCorrect: false,
          feedback: 'Efficiency does not change the wage mix calculation. '
              'The blended rate went up, so labor % goes up.',
        ),
        JtOption(
          label: 'It goes up -- higher wage mix increases labor cost',
          isCorrect: true,
          feedback: 'Correct! The wage mix moved up because a \$26/hr '
              'person replaced a \$16/hr person. Same hours, same covers, '
              'but higher labor cost.',
        ),
      ],
    ),
    JtUnit(
      id: 'fd_checkpoint',
      type: JtUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'Which of the four building blocks does a manager directly '
          'control on any given shift?',
      options: [
        JtOption(
          label: 'Hours worked (scheduling)',
          isCorrect: true,
          feedback: 'Correct! Hours worked is the one input a manager '
              'directly controls through scheduling decisions.',
        ),
        JtOption(
          label: 'Covers (guest count)',
          isCorrect: false,
          feedback: 'Guests decide whether they walk in. The manager '
              'cannot directly control cover count.',
        ),
        JtOption(
          label: 'PPA (average guest spend)',
          isCorrect: false,
          feedback: 'Guests decide what they order. The team can influence '
              'PPA through upselling, but the manager does not control it.',
        ),
      ],
    ),
  ],
);

// ---- Module 2: Labor % ---------------------------------------------------

const _moduleLaborPercent = JtModule(
  id: 'labor_percent',
  title: 'Labor %',
  subtitle: 'What it is and why it lies',
  iconCodePoint: 0xf0547, // Icons.percent
  units: [
    JtUnit(
      id: 'lp_formula',
      type: JtUnitType.concept,
      badgeHint: 'FORMULA',
      title: 'The Formula',
      body: 'Labor % = Total Labor Cost / Total Sales x 100\n\n'
          'Expand both sides:\n'
          '  Labor Cost = Hours x Wage\n'
          '  Total Sales = Covers x PPA\n\n'
          'So: Labor % = (Hours x Wage) / (Covers x PPA)\n\n'
          'Four variables. A manager directly controls one of them (hours). '
          'Yet operators hold managers accountable for the output of all four.',
    ),
    JtUnit(
      id: 'lp_death_spiral',
      type: JtUnitType.concept,
      badgeHint: 'SPIRAL',
      title: 'The Death Spiral',
      body: 'Starting position: \$68,000 sales, \$20,400 labor = 30%.\n\n'
          'Owner says cut to 28%. Manager cuts 40 hours (\$760 saved).\n'
          'Fewer staff -> service slows -> check-backs stop.\n'
          'Guests skip second drinks and desserts -> PPA drops.\n'
          'Some regulars leave -> covers drop.\n'
          'Sales fall to \$62,000.\n\n'
          'New labor %: \$19,640 / \$62,000 = 31.7% -- went UP.\n\n'
          'The cut saved \$760 but lost \$6,000 in sales. The manager '
          'followed instructions and is now blamed for 31.7%.',
    ),
    JtUnit(
      id: 'lp_quote',
      type: JtUnitType.concept,
      badgeHint: 'INSIGHT',
      title: 'Jim Taylor on Labor %',
      body: '"Labor % is a scoreboard. Not a strategy. You can\'t schedule '
          'your way out of weak productivity. You can\'t cut your way to a '
          'better system."\n\n'
          'Three of the four inputs -- covers, PPA, wage -- are largely '
          'outside a manager\'s control. They can move labor % by 10+ '
          'percentage points through no action or fault of the manager.',
    ),
    JtUnit(
      id: 'lp_scenario',
      type: JtUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'Labor % Scenario',
      body: 'Your restaurant ran 30% labor last week. The owner asks you '
          'to cut hours to bring it to 28%. Based on what you have learned, '
          'what is the risk?',
      options: [
        JtOption(
          label: 'No risk -- cutting hours always reduces labor %',
          isCorrect: false,
          feedback: 'Cutting hours can trigger the death spiral. Fewer '
              'staff means worse service, lower PPA, and potentially '
              'fewer returning guests.',
        ),
        JtOption(
          label: 'The death spiral -- service drops, sales drop, ratio worsens',
          isCorrect: true,
          feedback: 'Correct! Cutting hours to chase a ratio can destroy '
              'the guest experience and actually push labor % higher. '
              'You need to look at CPLH to see if scheduling was truly '
              'the problem.',
        ),
        JtOption(
          label: 'Only a risk if you cut too many hours at once',
          isCorrect: false,
          feedback: 'The size of the cut matters, but the core issue is '
              'using labor % as a strategy instead of a scoreboard.',
        ),
      ],
    ),
    JtUnit(
      id: 'lp_checkpoint',
      type: JtUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'A manager scheduled the same team both weeks. Covers were '
          'identical. But labor % jumped from 27% to 36.6%. What changed?',
      options: [
        JtOption(
          label: 'The manager over-scheduled in Week B',
          isCorrect: false,
          feedback: 'Same team, same hours. Scheduling was identical.',
        ),
        JtOption(
          label: 'Wage rates increased between weeks',
          isCorrect: false,
          feedback: 'Wage mix was the same both weeks. The change came '
              'from PPA (guest spending), not wages.',
        ),
        JtOption(
          label: 'Guests spent less -- PPA dropped',
          isCorrect: true,
          feedback: 'Correct! PPA dropped from \$42 to \$31. Same covers, '
              'same hours, same team. Labor % moved because of what '
              'guests decided to order, not because of anything the '
              'manager did.',
        ),
      ],
    ),
  ],
);

// ---- Module 3: CPLH (scaffolded with real content) -----------------------

const _moduleCplh = JtModule(
  id: 'cplh',
  title: 'CPLH',
  subtitle: 'Covers per labor hour -- the FOH metric',
  iconCodePoint: 0xe59f, // Icons.show_chart
  units: [
    JtUnit(
      id: 'cplh_formula',
      type: JtUnitType.concept,
      badgeHint: 'FORMULA',
      title: 'CPLH Formula',
      body: 'CPLH = Total Covers / Total FOH Labor Hours\n\n'
          'Higher CPLH = more guests per hour = more productive.\n'
          'Lower CPLH = fewer guests per hour = overstaffed or slow.\n\n'
          'Example: 380 covers / 46 FOH hrs = 8.26 CPLH.\n'
          'Each FOH labor hour served about 8 guests.',
    ),
    JtUnit(
      id: 'cplh_why_better',
      type: JtUnitType.concept,
      badgeHint: 'COMPARE',
      title: 'Why CPLH Beats Labor %',
      body: 'CPLH strips out money entirely. It only asks: how many guests '
          'did the team serve per hour of work?\n\n'
          'This removes distortion from PPA (what guests ordered) and '
          'wage mix (what the market pays) -- two things the manager '
          'cannot control.\n\n'
          '"Covers per labor hour tells you if scheduling was right. '
          'Labor % tells you if guests showed up and spent money. One '
          'measures management. One measures the business."',
    ),
    JtUnit(
      id: 'cplh_ranges',
      type: JtUnitType.concept,
      badgeHint: 'RANGES',
      title: 'CPLH by Concept Type',
      body: 'Typical CPLH ranges:\n\n'
          '  Fine Dining: 2.0 - 3.5\n'
          '  Casual / Upscale Casual: 3.5 - 6.0\n'
          '  High Volume Casual: 5.0 - 8.0\n'
          '  Fast Casual / Counter: 8.0 - 15.0+\n\n'
          'Barrio Legado is upscale casual, so a healthy CPLH range is '
          'roughly 3.5 to 6.0.',
    ),
    JtUnit(
      id: 'cplh_scenario',
      type: JtUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'CPLH Scenario',
      body: 'Two weeks had identical CPLH of 5.0. But labor % jumped from '
          '27% to 36.6% in Week B. As a manager, should you change your '
          'scheduling?',
      options: [
        JtOption(
          label: 'No -- CPLH shows scheduling was correct both weeks',
          isCorrect: true,
          feedback: 'Correct! CPLH held steady at 5.0. The labor % move '
              'was caused by guests spending less (PPA drop), not by '
              'a scheduling problem.',
        ),
        JtOption(
          label: 'Yes -- labor % went up so I need fewer staff',
          isCorrect: false,
          feedback: 'CPLH was identical both weeks. Scheduling was right. '
              'The change came from PPA, not staffing.',
        ),
        JtOption(
          label: 'Check labor % instead -- it gives a fuller picture',
          isCorrect: false,
          feedback: 'Labor % includes PPA and wage mix, which the manager '
              'cannot control. CPLH isolates the scheduling decision and '
              'is the cleaner metric for evaluating staffing.',
        ),
      ],
    ),
    JtUnit(
      id: 'cplh_checkpoint',
      type: JtUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'Why does Jim call CPLH the best FOH metric?',
      options: [
        JtOption(
          label: 'It includes wage and sales data for a complete picture',
          isCorrect: false,
          feedback: 'CPLH deliberately excludes money. That is its strength.',
        ),
        JtOption(
          label: 'It measures only what the manager controls -- guests per hour',
          isCorrect: true,
          feedback: 'Correct! CPLH removes the distortion of PPA and wage '
              'mix, leaving only the staffing decision the manager owns.',
        ),
        JtOption(
          label: 'It is the easiest number to calculate',
          isCorrect: false,
          feedback: 'Ease of calculation is not the reason. CPLH isolates '
              'the manager\'s scheduling decision from factors they '
              'cannot control.',
        ),
      ],
    ),
  ],
);

// ---- Module 4: SPLH & OPZ ------------------------------------------------

const _moduleSplhAndOPZ = JtModule(
  id: 'splh_opz',
  title: 'SPLH & OPZ',
  subtitle: 'Back-of-house metric and the optimal zone',
  iconCodePoint: 0xe5e0, // Icons.speed
  units: [
    JtUnit(
      id: 'splh_formula',
      type: JtUnitType.concept,
      badgeHint: 'FORMULA',
      title: 'SPLH -- Sales Per Labor Hour',
      body: 'SPLH = Total Sales / Total BOH Labor Hours\n\n'
          'Higher SPLH means each BOH hour generates more revenue. '
          'Lower SPLH means the kitchen is overstaffed or volume is '
          'low.\n\n'
          'SPLH is the BOH counterpart to CPLH. While CPLH measures '
          'FOH productivity in covers, SPLH measures BOH productivity '
          'in dollars.',
    ),
    JtUnit(
      id: 'splh_together',
      type: JtUnitType.concept,
      badgeHint: 'TOGETHER',
      title: 'CPLH and SPLH Together',
      body: 'When CPLH and SPLH move in different directions, something '
          'specific happened. Four combinations:\n\n'
          '- Both on target: everything working. Document and replicate.\n'
          '- CPLH on target, SPLH below: right cover count but guests '
          'spent less. PPA dropped -- upselling issue or rushed service.\n'
          '- CPLH below, SPLH on target: fewer covers but each guest '
          'spent more. Volume problem, not execution.\n'
          '- Both below: fewer covers AND less spend. Check external '
          'cause first -- weather, event nearby, day of week anomaly.',
    ),
    JtUnit(
      id: 'splh_theoretical',
      type: JtUnitType.concept,
      badgeHint: 'TARGET',
      title: 'Theoretical Labor',
      body: '"Theoretical labor cost = (Hours x Avg Wage) / (Covers x '
          'Avg Spend). That is the number your manager should be measured '
          'against. Not a guess. Not a benchmark. Not last year."\n\n'
          'The walk-in tears story: two managers, same brand, same 27% '
          'target. One ran 31% with a \$21/hr wage -- her theoretical '
          'floor was 29.4%. She could never hit 27%. The other ran 28% '
          'with \$18/hr wages -- his floor was 25.2%. He had room. She '
          'did not. Same company, completely different math.',
    ),
    JtUnit(
      id: 'splh_tracking',
      type: JtUnitType.concept,
      badgeHint: '60 DAYS',
      title: 'The 60-Day Tracking Discipline',
      body: 'Over 60 days, track five numbers across every daypart '
          '(lunch, dinner, late night):\n\n'
          '- Covers\n- PPA\n- CPLH\n- SPLH\n- Blended Wage\n\n'
          'You are looking for when CPLH, SPLH, and PPA are all high '
          'together -- that is your team at their best. On the floor, '
          'that shift shows good pacing, clean ticket times, table '
          'touches happening, and the team moving without scrambling.\n\n'
          'From that range you set your target CPLH and target SPLH.',
    ),
    JtUnit(
      id: 'splh_variance',
      type: JtUnitType.concept,
      badgeHint: 'VARIANCE',
      title: 'Variance -- The Gap',
      body: 'Variance = Actual labor % minus Theoretical labor %.\n\n'
          'If variance is small (1-2 points), scheduling is close to '
          'optimal. If variance is large, dig into which input drifted.\n\n'
          'Variance tells you what to fix. Labor % alone tells you '
          'nothing actionable. A manager running 31% against a 29.4% '
          'floor has a 1.6 point gap -- fixable. A manager running 28% '
          'against a 25.2% floor has a 2.8 point gap -- worse, even '
          'though 28% looks better than 31%.',
    ),
    JtUnit(
      id: 'splh_opz_concept',
      type: JtUnitType.concept,
      badgeHint: 'OPZ',
      title: 'The Optimal Productivity Zone',
      body: 'The OPZ is the range where the team is productive AND '
          'guests are well served.\n\n'
          'Below the zone = understaffed. Service suffers, tables wait, '
          'check-backs stop, and guests spend less.\n\n'
          'Above the zone = overstaffed. Labor cost rises without '
          'improving service. Extra bodies add cost but not value.\n\n'
          'The sweet spot is where CPLH and SPLH are both in their '
          'target ranges simultaneously. That is your OPZ.',
    ),
    JtUnit(
      id: 'splh_scenario',
      type: JtUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'SPLH Scenario',
      body: 'Last week CPLH was on target at 5.0 but SPLH came in '
          'below target. Labor % went up. What happened?',
      options: [
        JtOption(
          label: 'The kitchen was overstaffed -- cut BOH hours',
          isCorrect: false,
          feedback: 'SPLH below target does not automatically mean '
              'overstaffing. When CPLH is on target, the issue is '
              'more likely on the revenue side.',
        ),
        JtOption(
          label: 'PPA dropped -- guests spent less than expected',
          isCorrect: true,
          feedback: 'Correct! CPLH on target means the right number of '
              'covers came in. SPLH below target means sales per hour '
              'fell -- PPA dropped, likely an upselling or service '
              'pacing issue.',
        ),
        JtOption(
          label: 'Too many servers were scheduled for FOH',
          isCorrect: false,
          feedback: 'CPLH was on target, which means FOH staffing was '
              'correct. The problem is in BOH revenue per hour, not '
              'FOH headcount.',
        ),
      ],
    ),
    JtUnit(
      id: 'splh_checkpoint',
      type: JtUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'What does the Optimal Productivity Zone represent?',
      options: [
        JtOption(
          label: 'The range where CPLH and SPLH are both in target '
              'and guests are well served',
          isCorrect: true,
          feedback: 'Correct! The OPZ is where the team is productive '
              'and guests are well served -- both metrics in range '
              'simultaneously.',
        ),
        JtOption(
          label: 'The lowest possible labor % the restaurant can achieve',
          isCorrect: false,
          feedback: 'The OPZ is not about minimizing labor %. It is '
              'the balance point where productivity and service quality '
              'meet.',
        ),
        JtOption(
          label: 'The maximum number of covers a shift can handle',
          isCorrect: false,
          feedback: 'Cover capacity matters, but the OPZ is about the '
              'intersection of CPLH and SPLH targets, not a single '
              'number.',
        ),
      ],
    ),
  ],
);
