// GENERATED VERBATIM TRAINING CONTENT — regenerate, do not hand-edit bodies.
//
// Source: docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md
// Body text is word-for-word from the source Markdown. Headings become
// chapter/card titles; markdown syntax markers are formatting, not words,
// and are omitted. Generated for the 2026-07-11 training-bubble slice.

import '../company_handbook_content.dart';
import 'barrio_training_doc.dart';

const BarrioTrainingDoc kTrainingJimTaylor = BarrioTrainingDoc(
  id: 'jim_taylor_labor_model',
  title: 'How the Metrics Actually Work',
  sourcePath: 'docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md',
  chapters: [
    HandbookChapter(
      id: 'jim_taylor_labor_model_c0',
      title: 'How the Metrics Actually Work',
      subtitle: '1 card',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c0_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'How the Metrics Actually Work',
          body: 'Jim Taylor - Benchmark Sixty - Study Notes\n'
              '\n'
              'These notes build from zero. Every chapter builds on the last. '
              'By the end you can look at any shift\'s numbers and know '
              'exactly what story they are telling - and what to do about it. '
              'Sources are marked: Book = Bold Operations (2024) LinkedIn = '
              'Jim\'s LinkedIn posts.\n'
              '\n'
              'Part 1 - Labor\n'
              '\n'
              'Part 2 - Food Cost (coming soon)\n'
              '\n'
              '- 13 Dollar Contribution vs Food Cost % Food Cost\n'
              '\n'
              '- 14 Menu Engineering Stars & Plowhorses\n'
              '\n'
              '- 15 Theoretical vs Actual Food Cost Variance\n'
              '\n'
              'Bold Operations (c) 2024 Jim Taylor - benchmarksixty.com '
              'LinkedIn posts 2024-2025',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c0_u0.webp',
              caption: 'Diagram: How the Metrics Actually Work',
              afterParagraph: -1,
            ),
          ],
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c1',
      title: 'Chapter 01: The Foundation',
      subtitle: '5 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c1_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 01: The Foundation',
          body: 'The four raw inputs everything is built from\n'
              '\n'
              'Before any metric makes sense you need to know the four '
              'building blocks. Everything Jim teaches is assembled from '
              'these.',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c1_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Cover - one guest served',
          body: 'A table of 4 = 4 covers. Jim uses covers not tables because a '
              'table of 2 and a table of 6 are completely different amounts '
              'of work. Covers are honest. Tables aren\'t.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c1_u1.webp',
              caption: 'Diagram: Cover - one guest served',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c1_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Labor Hour - one person working one hour',
          body: '3 servers on a 6-hour shift = 18 labor hours. Every person, '
              'every hour, adds to the total.\n'
              '\n'
              'Example: Counting labor hours - Saturday dinner\n'
              '\n'
              '- 3 servers x 6 hrs = 18 hrs\n'
              '\n'
              '- 2 runners x 5 hrs = 10 hrs\n'
              '\n'
              '- 1 host x 6 hrs = 6 hrs\n'
              '\n'
              '- 1 manager x 8 hrs = 8 hrs\n'
              '\n'
              'Answer: Total labor hours: 42 hours\n'
              '\n'
              '---',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c1_u2.webp',
              caption: 'Diagram: Labor Hour - one person working one hour',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c1_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'PPA - Per Person Average (average spend per guest)',
          body: 'Formula\n'
              '\n'
              'PPA = Total Sales / Total Covers\n'
              '\n'
              'Example: PPA - Saturday dinner\n'
              '\n'
              '- Sales: \$14,440 Covers: 380\n'
              '\n'
              'Answer: PPA = \$14,440 / 380 = \$38.00 per guest\n'
              '\n'
              '> Takeaway > > If PPA drops from \$38 to \$30, revenue drops '
              '\$3,040 on the same 380 guests - without a single fewer person '
              'walking in. That \$8 is what the team failed to upsell, or what '
              'a rushed experience caused guests not to order.\n'
              '\n'
              '---',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c1_u3.webp',
              caption: 'Diagram: PPA - Per Person Average (average spend per guest)',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c1_u4',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Wage Mix - blended average hourly rate across all roles',
          body: 'Example: Calculating blended wage mix - full team, upscale '
              'casual\n'
              '\n'
              'FOH\n'
              '\n'
              '- 4 servers @ \$16.00/hr = \$64.00\n'
              '\n'
              '- 2 runners @ \$16.00/hr = \$32.00\n'
              '\n'
              '- 1 host @ \$16.00/hr = \$16.00\n'
              '\n'
              '- 1 bartender @ \$16.00/hr = \$16.00\n'
              '\n'
              'BOH\n'
              '\n'
              '- 3 line cooks @ \$20.00/hr = \$60.00\n'
              '\n'
              '- 2 prep cooks @ \$17.50/hr = \$35.00\n'
              '\n'
              '- 2 dishwashers @ \$16.50/hr = \$33.00\n'
              '\n'
              'Management\n'
              '\n'
              '- 1 manager @ \$26.00/hr = \$26.00\n'
              '\n'
              '- Total hourly cost: \$282.00 / 16 people\n'
              '\n'
              'Answer: Blended wage mix: \$17.62/hr\n'
              '\n'
              '> Takeaway > > This single number - \$17.62 - is what goes into '
              'the labor % formula as "wage." Every role, every pay rate, '
              'collapsed into one blended average. Call in a \$26 manager to '
              'cover a \$16 server shift and that number moves. Add a line '
              'cook shift at \$20 instead of a dishwasher at \$16.50 and that '
              'number moves. Labor % moves with it - without a single cover '
              'or hour changing.',
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c2',
      title: 'Chapter 02: Labor % - What It Is and Why It Lies',
      subtitle: '4 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c2_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 02: Labor % - What It Is and Why It Lies',
          body: 'The most tracked number in restaurants and the most '
              'misunderstood\n'
              '\n'
              '> Source: Bold Operations, Chapter Three Book > > '
              '"Surprisingly, although several restaurants measure units of '
              'productivity, and almost all of them measure labor costs, few '
              'actually understand the importance of understanding how the '
              'two work together."',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c2_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What it calculates',
          body: 'Labor % is a ratio. For every \$100 of revenue, how many '
              'dollars went to paying the team? That is all it does. It does '
              'not tell you if the team worked hard, if the schedule was '
              'right, or if the operation was well run. It just shows you two '
              'dollar amounts as a ratio.\n'
              '\n'
              'Formula: Step 1 - Basic formula\n'
              '\n'
              'Labor % = Total Labor Cost / Total Sales x 100\n'
              '\n'
              '\$20,400 labor / \$68,000 sales = 30%\n'
              '\n'
              'Formula: Step 2 - Expand both sides\n'
              '\n'
              'Labor Cost \$ = Hours x Wage\n'
              '\n'
              'Total Sales = Covers x PPA\n'
              '\n'
              'Labor % = (Hours x Wage) / (Covers x PPA)',
          runIndex: 1,
          runLength: 2,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c2_u1.webp',
              caption: 'Diagram: What it calculates',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c2_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What it calculates (cont.)',
          body: 'Now you can see what is actually inside the number. Four '
              'variables. Look at who controls each one:\n'
              '\n'
              'Input | Who controls it\n'
              '\n'
              'Hours worked | The manager - scheduling decision\n'
              '\n'
              'Wage mix | Market rates and corporate pay bands\n'
              '\n'
              'Covers | The guests - whether they walk in\n'
              '\n'
              'PPA | The guests - what they choose to order\n'
              '\n'
              '> Warning > > A manager directly controls one of the four '
              'variables that produce labor %. Yet operators hold managers '
              'accountable for the output of all four. This is why good '
              'managers get blamed for numbers that were never in their '
              'hands.',
          runIndex: 2,
          runLength: 2,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c2_u2.webp',
              caption: 'Diagram: What it calculates',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c2_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why cutting labor % rarely fixes labor %',
          body: 'Example: The math of why cuts backfire\n'
              '\n'
              'Starting position\n'
              '\n'
              '- Sales: \$68,000 Labor: \$20,400 Labor %: 30%\n'
              '\n'
              '- Owner says: cut to 28%. That means cutting \$1,360 in labor.\n'
              '\n'
              'Manager cuts 40 hours x \$19/hr = \$760 saved\n'
              '\n'
              '- New labor cost: \$19,640\n'
              '\n'
              '- Fewer staff -> service slows -> check-backs stop\n'
              '\n'
              '- Guests skip second drinks and desserts -> PPA drops\n'
              '\n'
              '- Some regulars don\'t return -> covers drop next week\n'
              '\n'
              '- Sales fall to: \$62,000\n'
              '\n'
              'Answer: New labor %: \$19,640 / \$62,000 = 31.7% - went UP\n'
              '\n'
              '> Takeaway > > The cut saved \$760. It lost \$6,000 in sales. '
              'The ratio got worse. Absolute profit got worse. The manager '
              'followed instructions and is now being blamed for 31.7%. This '
              'is the death spiral.\n'
              '\n'
              '> Source: LinkedIn > > "Labor % is a scoreboard. Not a '
              'strategy. You can\'t schedule your way out of weak '
              'productivity. You can\'t cut your way to a better system."',
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c3',
      title: 'Chapter 03: The 4 Inputs',
      subtitle: '3 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c3_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 03: The 4 Inputs',
          body: 'Change any one of these and labor % moves - even if nothing '
              'else changes\n'
              '\n'
              '> Source: LinkedIn > > "What actually drives labor spend: '
              'guest count, average spend, hours worked, wage mix. Change the '
              'inputs, the output follows. Keep staring at the percentage, '
              'and you\'ll keep getting the same results."',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c3_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Change one input - watch labor % move',
          body: 'Base case: a real full-service restaurant week. 400 covers - '
              '\$42 PPA - 280 hours - \$19 wage = \$5,320 labor / \$16,800 sales '
              '= 31.7%. Change one input at a time:\n'
              '\n'
              'Input | Change | Labor \$ | Sales \$ | Labor % | Direction\n'
              '\n'
              'Covers<br>Manager cannot control | 400 -> 500 | \$5,320 | '
              '\$21,000 | 25.3% down | More guests, same cost\n'
              '\n'
              '400 -> 300 | \$5,320 | \$12,600 | 42.2% up | Fewer guests, same '
              'cost\n'
              '\n'
              'PPA<br>Manager cannot control | \$42 -> \$52 | \$5,320 | \$20,800 '
              '| 25.6% down | Guests spent more\n'
              '\n'
              '\$42 -> \$32 | \$5,320 | \$12,800 | 41.6% up | Guests spent less\n'
              '\n'
              'Hours<br>Manager controls this | 280 -> 330 | \$6,270 | \$16,800 '
              '| 37.3% up | More hours, sales unchanged\n'
              '\n'
              '280 -> 230 | \$4,370 | \$16,800 | 26.0% down | Fewer hours - but '
              'does service hold?\n'
              '\n'
              'Wage Mix<br>Set by market/corporate | \$19 -> \$23 | \$6,440 | '
              '\$16,800 | 38.3% up | Higher blended wage\n'
              '\n'
              '\$19 -> \$16 | \$4,480 | \$16,800 | 26.7% down | Lower blended '
              'wage',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c3_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Change one input - watch labor % move (cont.)',
          body: '> Key: What this table exposes > > Three of the four inputs - '
              'covers, PPA, wage - are largely outside a manager\'s control on '
              'any given shift. They can move labor % by 10+ percentage '
              'points through no action or fault of the manager. This is '
              'Jim\'s core argument: you cannot evaluate a manager against a '
              'number they barely control.',
          runIndex: 2,
          runLength: 2,
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c4',
      title: 'Chapter 04: CPLH - Covers Per Labor Hour',
      subtitle: '6 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c4_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 04: CPLH - Covers Per Labor Hour',
          body: 'What it measures, what it reveals, why Jim calls it the best '
              'FOH metric\n'
              '\n'
              '> Source: Bold Operations, p.62 and p.66 Book > > "Covers per '
              'labor hour - measures how many people are required to serve '
              'the number of guests visiting the restaurant... CPLH is the '
              'best metric to be used in the front of the house."\n'
              '\n'
              'Formula: CPLH Formula\n'
              '\n'
              'CPLH = Total Covers / Total Labor Hours\n'
              '\n'
              'Higher CPLH = more guests per hour of labor = more productive\n'
              '\n'
              'Lower CPLH = fewer guests per hour = overstaffed or slow\n'
              '\n'
              'Example: Calculating CPLH - Friday dinner shift\n'
              '\n'
              '- Covers served: 380\n'
              '\n'
              '- FOH hours: 5 servers x 6hrs + 2 runners x 5hrs + 1 host x '
              '6hrs = 46 hrs\n'
              '\n'
              'Answer: CPLH = 380 / 46 = 8.26 covers per labor hour\n'
              '\n'
              '> Takeaway > > 8.26 means each FOH labor hour served just over '
              '8 guests. Whether that is good depends on the concept and your '
              'OPZ (Chapter 10). For upscale casual, 8+ likely means the team '
              'is stretched - see the OPZ ceiling.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c4_u0.webp',
              caption: 'Diagram: Chapter 04: CPLH - Covers Per Labor Hour',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c4_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why CPLH is a better manager metric than labor %',
          body: 'CPLH strips out money entirely. It only asks: how many guests '
              'did the team serve per hour of work? That removes the '
              'distortion from PPA (what guests ordered) and wage mix (what '
              'the market pays) - two things the manager cannot control. Same '
              'covers, same hours, same team - watch what happens when PPA '
              'shifts.\n'
              '\n'
              'Example: Same manager, same schedule - labor % swings, CPLH '
              'holds\n'
              '\n'
              'Week A - guests engaged fully - 800 covers - 515 total hrs - '
              '\$17.62 blended wage\n'
              '\n'
              '- CPLH: 800 / 160 FOH hrs = 5.0\n'
              '\n'
              '- Labor \$: 515 x \$17.62 = \$9,074\n'
              '\n'
              '- PPA: \$42 (guests ordered drinks, appetizers, desserts)\n'
              '\n'
              '- Sales: 800 x \$42 = \$33,600\n'
              '\n'
              'Answer: Labor %: \$9,074 / \$33,600 = 27.0%\n'
              '\n'
              '---\n'
              '\n'
              'Week B - same covers, same hours, same team - guests pulled '
              'back on spend\n'
              '\n'
              '- CPLH: 800 / 160 FOH hrs = 5.0 <- identical\n'
              '\n'
              '- Labor \$: 515 x \$17.62 = \$9,074 <- identical\n'
              '\n'
              '- PPA: \$31 (guests skipped second drinks and desserts)\n'
              '\n'
              '- Sales: 800 x \$31 = \$24,800 <- \$8,800 less revenue, same '
              'guest count',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c4_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why CPLH is a better manager metric than labor % (cont.)',
          body: 'Answer: Labor %: \$9,074 / \$24,800 = 36.6% <- jumped 9.6 points\n'
              '\n'
              '> Takeaway > > CPLH held at 5.0 both weeks. The manager '
              'scheduled identically, deployed identically, served the same '
              'number of guests. Labor % jumped 9.6 points because guests '
              'chose to spend less. If you evaluate this manager on labor %, '
              'Week B is a crisis. CPLH tells the truth: nothing changed on '
              'the operations side. The metric moved because of what guests '
              'decided to order.\n'
              '\n'
              '> Source: LinkedIn > > "Covers per labor hour tells you if '
              'scheduling was right. Labor % tells you if guests showed up '
              'and spent money. One measures management. One measures the '
              'business."',
          runIndex: 2,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c4_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'CPLH ranges by concept type',
          body: 'Concept | Typical CPLH | Why\n'
              '\n'
              'Fine Dining | 2.0 - 3.5 | Long stays, many service touches, '
              'low turns\n'
              '\n'
              'Casual / Upscale Casual | 3.5 - 6.0 | Balanced volume and '
              'service\n'
              '\n'
              'High Volume Casual | 5.0 - 8.0 | Faster turns, simpler service\n'
              '\n'
              'Fast Casual / Counter | 8.0 - 15.0+ | Minimal table service, '
              'high throughput\n'
              '\n'
              'No universal correct CPLH. Your target comes from your OPZ '
              'data - Chapter 10.',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c4_u4',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What a 0.63 CPLH gap costs in real life',
          body: '> Source: LinkedIn > > "Two restaurants. Same brand. Same '
              'volume. Same wage rate. Location A: 4.99 guests per labor '
              'hour, \$19 PPA. Location B: 4.36 guests per labor hour, \$17 '
              'PPA. That\'s it. That\'s the whole story. One location is simply '
              'more productive. Not because of who\'s running it. Because of '
              'how it\'s being run."\n'
              '\n'
              'Example: Same wage - two different operations - 5-point labor '
              'gap\n'
              '\n'
              'Location A - more productive\n'
              '\n'
              '- CPLH: 4.99 PPA: \$19 Labor: 19.7%\n'
              '\n'
              'Location B - less productive\n'
              '\n'
              '- CPLH: 4.36 PPA: \$17 Labor: 24.6%\n'
              '\n'
              'Answer: Gap: 5 labor points. Same brand. Same wage. Same '
              'market.\n'
              '\n'
              '> Takeaway > > The gap is entirely explained by two CPLH/PPA '
              'differences. Location B serves 0.63 fewer covers per labor '
              'hour and each guest spends \$2 less. No wage advantage exists - '
              'the entire 5-point labor gap is a productivity and service '
              'execution gap. Jim\'s math: a 5% improvement in productivity '
              'across both locations equals roughly \$6K per week - \$300K+ '
              'annualized.',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c4_u5',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What a 0.63 CPLH gap costs in real life (cont.)',
          body: '> Callout > > Labor % is a scoreboard. Not a strategy. '
              'Location B\'s 24.6% isn\'t a wage problem. It is not a staffing '
              'problem. It is a productivity problem. CPLH names it. Labor % '
              'never could.',
          runIndex: 2,
          runLength: 2,
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c5',
      title: 'Chapter 05: CPLH In Action',
      subtitle: '7 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c5_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 05: CPLH In Action',
          body: 'How it is used to schedule - and what it reveals that labor % '
              'cannot',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c5_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Point 1 - Why scheduling to revenue fails',
          body: 'Most managers look at last Friday\'s \$18,000 in sales and '
              'schedule enough staff to handle \$18,000. Jim says this is the '
              'wrong input. Revenue tells you nothing about how many people '
              'are walking in. The same \$18,000 comes from two completely '
              'different nights:\n'
              '\n'
              'Example: Same revenue - two completely different staffing '
              'needs\n'
              '\n'
              'Night A - 450 guests at \$40 PPA = \$18,000\n'
              '\n'
              '- At 5.0 CPLH: 450 / 5.0 = 90 FOH hours needed\n'
              '\n'
              'Night B - 300 guests at \$60 PPA = \$18,000\n'
              '\n'
              '- At 5.0 CPLH: 300 / 5.0 = 60 FOH hours needed\n'
              '\n'
              'Answer: Same \$18,000. One needs 90 hours. One needs 60 hours.\n'
              '\n'
              '> Takeaway > > If you scheduled 75 hours to a \$18,000 revenue '
              'target - Night A is 15 hours short, team overwhelmed, service '
              'breaks. Night B is 15 hours over, team idle, labor bleeds. '
              'Revenue gave the wrong answer both times. Cover count gives '
              'the right answer every time.',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c5_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Point 1 - Why scheduling to revenue fails (cont.)',
          body: '> Key: The correct scheduling formula > > Required Hours = '
              'Expected Covers / Target CPLH > > Forecast your covers from '
              'historical same-day data. Apply your CPLH target. That gives '
              'you the hours to schedule. Build the shift from those hours - '
              'not from a revenue guess.\n'
              '\n'
              '> Source: LinkedIn > > "Stop scheduling to revenue. You\'re '
              'wasting time on something you can\'t control. Schedule to guest '
              'count instead. You don\'t control what guests order. You '
              'control how many people you put on the floor. And you can '
              'forecast how many guests walk through the door. That\'s it."\n'
              '\n'
              '---',
          runIndex: 2,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c5_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Point 2 - Same 28%, two completely different operations',
          body: '> Source: LinkedIn - verbatim LinkedIn > > "Two restaurants. '
              'Same labor %. Restaurant A: 28% labor. Overstaffed by 40 '
              'hours. Covers came in hot and saved them. Got lucky. '
              'Restaurant B: 28% labor. Scheduled perfectly to demand. Covers '
              'came in exactly as expected. Executed smoothly. Same number. '
              'Completely different operations. Labor % can\'t tell you the '
              'difference."\n'
              '\n'
              'These are two separate restaurants. Same brand. Same week. '
              'Both landed at 28% by the end of it. But they got there by '
              'completely different paths - because one applied Point 1 and '
              'one didn\'t.\n'
              '\n'
              'Restaurant A did not schedule to covers with CPLH. They '
              'carried too many hours all week without grounding them in a '
              'cover forecast. That overstaffing is the direct cause of their '
              'problem. Restaurant B did exactly what Point 1 describes - '
              'they forecasted their covers from history, applied their CPLH '
              'target, and scheduled the right hours. When their forecast '
              'came in accurately, the model held.',
          runIndex: 1,
          runLength: 4,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c5_u4',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Point 2 - Same 28%, two completely different operations (cont.)',
          body: 'B\'s 480 covers was not a surprise to them. It was the plan - '
              'their history told them to expect 480 that week. A\'s 480 was '
              'the lucky accident that rescued a bloated schedule.\n'
              '\n'
              'Here is the math underneath each one. Read the CPLH number at '
              'the end of each - that is the only number that reveals which '
              'operation is in control.\n'
              '\n'
              'Example: Restaurant A - 28% labor, overstaffed, saved by a hot '
              'cover week\n'
              '\n'
              'How the week was built - forecasted 400 covers, kept too many '
              'staff on\n'
              '\n'
              '- Cover forecast: 400 for the week\n'
              '\n'
              '- Should have scheduled: 400 / 5.0 CPLH = 80 FOH hours\n'
              '\n'
              '- Actually kept on: 120 FOH hours - 40 hours overstaffed all '
              'week\n'
              '\n'
              '- Total hours: 283 Wage: \$19/hr Labor \$: 283 x \$19 = \$5,377\n'
              '\n'
              'What happened - 480 covers walked in, not 400\n'
              '\n'
              '- Actual covers: 480 (a hot week - 80 more guests than '
              'expected)\n'
              '\n'
              '- PPA: \$40 Sales: 480 x \$40 = \$19,200',
          runIndex: 2,
          runLength: 4,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c5_u5',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Point 2 - Same 28%, two completely different operations (cont.)',
          body: 'Answer: Labor %: \$5,377 / \$19,200 = 28.0%\n'
              '\n'
              'Now check CPLH\n'
              '\n'
              '- FOH CPLH: 480 covers / 120 FOH hrs = 4.0 - below the 5.0 OPZ '
              'target\n'
              '\n'
              '- Too many people on the floor all week. Labor was bleeding. '
              'Covers rescued it.\n'
              '\n'
              '> Takeaway > > The 28% was luck. The 40 extra hours that were '
              'kept on all week should have pushed labor % to 33.6% - that is '
              'what the number would have been if only 400 covers had come in '
              'as forecast: \$5,377 / (400 x \$40 = \$16,000) = 33.6%. The 80 '
              'extra guests inflated the sales denominator and made the '
              'number look fine. Next week when it\'s a normal week, this '
              'restaurant is at 33-34%.\n'
              '\n'
              'Example: Restaurant B - 28% labor, scheduled to demand, earned '
              'it\n'
              '\n'
              'How the week was built - forecasted 480 covers, scheduled '
              'correctly\n'
              '\n'
              '- Cover forecast: 480 for the week\n'
              '\n'
              '- Scheduled: 480 / 5.0 CPLH = 96 FOH hours - right number',
          runIndex: 3,
          runLength: 4,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c5_u6',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Point 2 - Same 28%, two completely different operations (cont.)',
          body: '- Total hours: 283 Wage: \$19/hr Labor \$: 283 x \$19 = \$5,377\n'
              '\n'
              'What happened - 480 covers, exactly as forecast\n'
              '\n'
              '- Actual covers: 480 (exactly as planned)\n'
              '\n'
              '- PPA: \$40 Sales: 480 x \$40 = \$19,200\n'
              '\n'
              'Answer: Labor %: \$5,377 / \$19,200 = 28.0%\n'
              '\n'
              'Now check CPLH\n'
              '\n'
              '- FOH CPLH: 480 covers / 96 FOH hrs = 5.0 - exactly on target\n'
              '\n'
              '- Right number of people all week. Team productive. Service '
              'consistent.\n'
              '\n'
              '> Takeaway > > The 28% was designed. Same model next week '
              'gives the same result. If the cover forecast is off, CPLH '
              'shows it during the week - not on the P&L a month later. This '
              'operation is in control.\n'
              '\n'
              '> Callout > > Both: 28.0%. Same hours. Same labor \$. Same '
              'sales. Same week. Labor % sees two identical restaurants. CPLH '
              'sees 4.0 vs 5.0 - one team overstaffed and bailed out by lucky '
              'volume, one team right on target. One number was luck. One was '
              'design.',
          runIndex: 4,
          runLength: 4,
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c6',
      title: 'Chapter 06: SPLH - Sales Per Labor Hour',
      subtitle: '2 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c6_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 06: SPLH - Sales Per Labor Hour',
          body: 'Revenue generated per hour of labor - Jim\'s best BOH metric\n'
              '\n'
              '> Source: Bold Operations, p.62 and p.66 Book > > "Sales per '
              'labor hour - measures how much revenue is generated for each '
              'hour of work... SPLH is the best metric to be used in the back '
              'of the house."\n'
              '\n'
              'Formula: SPLH Formula\n'
              '\n'
              'SPLH = Total Sales / Total Labor Hours\n'
              '\n'
              '\$22,400 sales / 88 BOH hours = \$254.55 SPLH\n'
              '\n'
              'Every BOH labor hour generated \$254.55 in revenue.\n'
              '\n'
              'Example: Calculating SPLH - Saturday dinner BOH\n'
              '\n'
              '- Total sales: \$22,400\n'
              '\n'
              '- Total BOH hrs: 88 hours (line cooks, prep, dishwashers)\n'
              '\n'
              'Answer: SPLH = \$22,400 / 88 = \$254.55 per BOH labor hour\n'
              '\n'
              '> Takeaway > > Every BOH labor hour this Saturday produced '
              '\$254.55 in revenue. Track this across weeks and you will see '
              'which shifts the kitchen is fully productive vs which ones '
              'drag. A drop in SPLH with consistent covers means the kitchen '
              'is taking longer per ticket, remakes are climbing, or BOH was '
              'overstaffed for the volume.',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c6_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why SPLH belongs in the kitchen',
          body: 'The kitchen produces food, not covers. A single order can feed '
              '1 person or 6. CPLH is harder to apply to BOH because ticket '
              'complexity varies. SPLH is cleaner for the kitchen - every '
              'station\'s output ultimately converts to sales, so revenue per '
              'hour is the right lens.\n'
              '\n'
              '> Key: The rule from the book > > CPLH for FOH. SPLH for BOH. '
              'They are measuring the same concept - productivity per labor '
              'hour - applied to the part of the operation that makes most '
              'sense for each metric. Book p.66',
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c7',
      title: 'Chapter 07: CPLH and SPLH Together',
      subtitle: '2 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c7_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 07: CPLH and SPLH Together',
          body: 'Reading both metrics at the same time - they tell different '
              'parts of the same story\n'
              '\n'
              '> Source: Bold Operations, p.65 Book > > "They are often '
              'spoken about independently from other areas of the business, '
              'however opportunities are often missed when they are left on '
              'their own."\n'
              '\n'
              'When CPLH and SPLH move in different directions, something '
              'specific happened. Here are the four combinations:\n'
              '\n'
              'CPLH | SPLH | What the data is saying | What to investigate\n'
              '\n'
              'On target | On target | Everything working. Right covers, '
              'right spend. | Document this shift. Replicate it.\n'
              '\n'
              'On target | Below target | Right cover count, guests spent '
              'less than expected. | PPA dropped. Upselling issue or rushed '
              'service.\n'
              '\n'
              'Below target | On target | Fewer covers but each guest spent '
              'more. | Volume problem, not an execution problem. Fix the '
              'forecast.\n'
              '\n'
              'Below target | Below target | Fewer covers AND less spend. | '
              'Check external cause first - weather, event nearby, day of '
              'week anomaly.\n'
              '\n'
              'Example: Reading both metrics - Wednesday dinner',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c7_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 07: CPLH and SPLH Together (cont.)',
          body: '- Target CPLH: 5.0 Actual CPLH: 4.1 <- below\n'
              '\n'
              '- Target SPLH: \$200 Actual SPLH: \$218 <- above\n'
              '\n'
              'Answer: Fewer covers than expected. But each guest who came in '
              'spent more than usual.\n'
              '\n'
              '> Takeaway > > This is not a team performance problem. SPLH '
              'above target means the team executed well - every guest who '
              'came in was served properly and spent generously. CPLH below '
              'target means the restaurant was slightly overstaffed for the '
              'actual volume. The fix is in the forecast, not on the floor. '
              'The team had a good night.',
          runIndex: 2,
          runLength: 2,
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c8',
      title: 'Chapter 08: Theoretical Labor',
      subtitle: '4 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c8_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 08: Theoretical Labor',
          body: 'What your labor should cost - calculated from your actual '
              'inputs, not borrowed from anywhere\n'
              '\n'
              '> Source: LinkedIn > > "Theoretical labor cost = (Hours x Avg '
              'Wage) / (Covers x Avg Spend). That\'s the number your manager '
              'should be measured against. Not a guess. Not a benchmark. Not '
              'last year."',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c8_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What it is',
          body: 'Theoretical labor is the answer to: if everything went '
              'perfectly - right hours scheduled, right team deployed, at '
              'your actual wage rates and actual PPA - what would labor % be? '
              'This is your floor. The minimum achievable without '
              'compromising service.',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c8_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why it matters - the walk-in tears story',
          body: '> Source: LinkedIn > > "Their labor was running 31%. Target '
              'was 27%. On paper, they were failing. But here\'s what nobody '
              'looked at: their average wage was \$21/hour. The location '
              'across town? \$18/hour. Same brand. Same target. Completely '
              'different math."\n'
              '\n'
              'Example: Proving the manager was right - full calculation\n'
              '\n'
              'Both locations - shared inputs\n'
              '\n'
              '- 200 covers - \$45 PPA - 126 total labor hours\n'
              '\n'
              '- Sales: 200 x \$45 = \$9,000\n'
              '\n'
              '- FOH hours (~40% of total): 50 hrs -> FOH CPLH: 200 / 50 = '
              '4.0 check\n'
              '\n'
              '---\n'
              '\n'
              'Her location - \$21/hr wages\n'
              '\n'
              '- Theoretical labor \$: 126 x \$21 = \$2,646\n'
              '\n'
              '- Theoretical labor %: \$2,646 / \$9,000 = 29.4%\n'
              '\n'
              '- She was running 31%. Variance: 31 - 29.4 = 1.6 points\n'
              '\n'
              '> Takeaway > > 1.6 points. Fixable. But the corporate target '
              'was 27% - a number that sat 2.4 points below her mathematical '
              'floor. She could not hit 27%. The math made it impossible. She '
              'was being evaluated against a target that was never achievable '
              'at her wage rate.',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c8_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why it matters - the walk-in tears story (cont.)',
          body: '---\n'
              '\n'
              'The other manager - \$18/hr wages, same everything else\n'
              '\n'
              '- Theoretical labor \$: 126 x \$18 = \$2,268\n'
              '\n'
              '- Theoretical labor %: \$2,268 / \$9,000 = 25.2%\n'
              '\n'
              '- He was running 28%. Variance: 28 - 25.2 = 2.8 points\n'
              '\n'
              '> Takeaway > > 2.8 points - nearly twice her gap. But his '
              'floor sat 1.8 points below the 27% corporate target. He had '
              'room. She didn\'t. He was being celebrated. She was in tears in '
              'the walk-in. Same company. Same target. Completely different '
              'math.\n'
              '\n'
              '> Callout > > Theoretical labor shows you what is actually '
              'possible. Without it you are evaluating people against a '
              'number that was never built for their reality.\n'
              '\n'
              'Now you know what theoretical labor is and why it matters. The '
              'question is: how do you build the data to calculate it for '
              'your restaurant? That is what Chapter 09 covers.',
          runIndex: 2,
          runLength: 2,
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c9',
      title: 'Chapter 09: The 60-Day Tracking Discipline',
      subtitle: '10 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 09: The 60-Day Tracking Discipline',
          body: 'How to build the data foundation that makes your theoretical '
              'labor target real\n'
              '\n'
              '> Key: The goal > > - Acquire your restaurant\'s realistic '
              'weekly labor percentage target > - Acquire your target CPLH '
              'and SPLH for your team and your concept > > This is done '
              'without changing anything operationally yet, and without '
              'optimizing for anything yet. You are observing. You are '
              'building a picture of what your operation actually is.',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What you track - across dayparts, every shift',
          body: 'Over 60 days you track five numbers across every daypart - '
              'lunch, dinner, late night:\n'
              '\n'
              'FOH metrics\n'
              '\n'
              '- Covers - how many guests per daypart\n'
              '\n'
              '- PPA - what each guest spent\n'
              '\n'
              '- CPLH - covers per FOH labor hour\n'
              '\n'
              'BOH metrics\n'
              '\n'
              '- SPLH - sales per BOH labor hour\n'
              '\n'
              'Whole team - FOH + BOH + Management\n'
              '\n'
              '- Blended Wage - your actual wage mix across every role, every '
              'shift\n'
              '\n'
              '> Key: Why dayparts and not just daily totals > > Lunch and '
              'dinner are different businesses. A strong dinner can mask a '
              'bleeding lunch every day of the week and your daily total will '
              'look fine. Tracking by daypart gives you the resolution to see '
              'which shift is consistently off target. That is what makes '
              'your targets precise - and what makes variance actionable '
              'later in Chapter 10.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c9_u1.webp',
              caption: 'Diagram: What you track - across dayparts, every shift',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What you are looking for',
          body: 'Over those 60 days you are analyzing when BOH and FOH were '
              'performing their best on the floor. The key indicator is when '
              'three things are high together: CPLH, SPLH, and PPA. On the '
              'floor you already know what that shift feels like - good '
              'pacing, clean ticket times, table touches happening, plates '
              'cleared, floor looking sharp. Guests are engaged. The team is '
              'moving but not scrambling. On paper, that shift shows up as '
              'high CPLH, high SPLH, high PPA all at once. Those are the days '
              'you build your targets from.\n'
              '\n'
              'Example: Reading your 60-day data - what a strong shift looks '
              'like\n'
              '\n'
              'The pattern you are identifying\n'
              '\n'
              '- CPLH is high - FOH is productive, right number of people for '
              'the covers\n'
              '\n'
              '- SPLH is high - BOH is producing efficiently, kitchen not '
              'backed up or overstaffed\n'
              '\n'
              '- PPA is high - guests are being attended to, upsells are '
              'happening, service is not rushed\n'
              '\n'
              'Answer: When all three are high together - that is your team '
              'at their best',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What you are looking for (cont.)',
          body: '> Takeaway > > You are not looking for your best single day. '
              'You are looking for the range where your team was consistently '
              'comfortable and productive. From that range you set your '
              'target CPLH and target SPLH. These become the inputs that '
              'build your theoretical labor %.',
          runIndex: 2,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u4',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why 60 days - the replication problem',
          body: '> Source: LinkedIn > > "I reviewed 300 days of data for a '
              'client last week. On their best days, they were hitting 5.28 '
              'guests per labor hour, \$103 SPLH, \$19.67 average check, and '
              '17.73% labor. On their worst days? 3.51 guests per labor hour. '
              '\$67 SPLH. 33% labor. Same building. Same team. The gap between '
              'best and worst cost them \$11,300 in less than a month. But '
              'here\'s the part that should worry you: they didn\'t know why '
              'Wednesday worked. They just knew it did. That means it was an '
              'accident. And you can\'t build a business on accidents."\n'
              '\n'
              '60 days is not arbitrary. It is the minimum before your data '
              'stops being a collection of accidents and starts being a '
              'pattern you can trust. Two good Wednesdays do not give you a '
              'CPLH target - they give you a false floor. You need enough '
              'days to see both ends of what your operation actually does, '
              'not just what it does when everything goes right.',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u5',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Why 60 days - the replication problem (cont.)',
          body: '> Warning > > A CPLH target built from too few days is just '
              'your best Wednesday disguised as a standard. Track long enough '
              'to see the full range. Your target lives somewhere inside it.',
          runIndex: 2,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u6',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'How it assembles into your theoretical labor %',
          body: 'Once you have 60 days of data and have identified your target '
              'CPLH and SPLH, here is how those numbers build your '
              'theoretical labor %.\n'
              '\n'
              'Example: Step 0 - Convert your 60-day totals into a weekly '
              'forecast\n'
              '\n'
              '- 60-day total covers: 10,286\n'
              '\n'
              '- Weeks in 60 days: 60 / 7 = 8.57 weeks\n'
              '\n'
              '- Average weekly covers: 10,286 / 8.57 = 1,200 covers per week\n'
              '\n'
              '> Takeaway > > That 1,200 is your forecasted covers input. It '
              'is not a guess - it is your own operation averaged across 60 '
              'days of real trading. Every other input - PPA, CPLH, SPLH, '
              'Blended Wage - is already an average and feeds directly into '
              'the formula below.\n'
              '\n'
              'Your FOH inputs\n'
              '\n'
              'Forecasted Covers -> 1,200 (10,286 / 8.57 weeks)\n'
              '\n'
              'Target CPLH -> 4.5 (from your best sustainable daypart range)\n'
              '\n'
              'PPA -> \$42 (your 60-day average spend per guest)\n'
              '\n'
              'FOH Wage -> \$16.50/hr (servers, runners, host, FOH managers)\n'
              '\n'
              'Your BOH inputs',
          runIndex: 1,
          runLength: 3,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c9_u6.webp',
              caption: 'Diagram: How it assembles into your theoretical labor %',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u7',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'How it assembles into your theoretical labor % (cont.)',
          body: 'Target SPLH -> \$180 (from your best sustainable daypart range)\n'
              '\n'
              'BOH Wage -> \$21.35/hr (line cooks, prep, dishwashers, BOH '
              'managers)\n'
              '\n'
              'Step 1: Required FOH Hours\n'
              '\n'
              'Forecasted Covers / Target CPLH\n'
              '\n'
              '1,200 / 4.5 = 267 FOH hours\n'
              '\n'
              'Step 2: Required BOH Hours\n'
              '\n'
              'Forecasted Sales / Target SPLH (Forecasted Sales = Covers x '
              'PPA)\n'
              '\n'
              '(1,200 x \$42 PPA = \$50,400) / \$180 SPLH = 280 BOH hours\n'
              '\n'
              'Step 3: Theoretical Labor \$ - FOH and BOH separately\n'
              '\n'
              'FOH Hours x FOH Wage + BOH Hours x BOH Wage\n'
              '\n'
              '267 x \$16.50 = \$4,405 (FOH)\n'
              '\n'
              '280 x \$21.35 = \$5,978 (BOH)\n'
              '\n'
              'Total theoretical labor \$: \$4,405 + \$5,978 = \$10,383',
          runIndex: 2,
          runLength: 3,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c9_u7.webp',
              caption: 'Diagram: How it assembles into your theoretical labor %',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u8',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'How it assembles into your theoretical labor % (cont.)',
          body: 'Step 4: Theoretical Labor % - FOH, BOH, and Total\n'
              '\n'
              'FOH Labor \$ / Forecasted Sales - BOH Labor \$ / Forecasted '
              'Sales\n'
              '\n'
              'FOH: \$4,405 / \$50,400 = 8.7%\n'
              '\n'
              'BOH: \$5,978 / \$50,400 = 11.9%\n'
              '\n'
              'Total: 8.7 + 11.9 = 20.6%\n'
              '\n'
              '> Takeaway > > 20.6% is your floor - 8.7% FOH and 11.9% BOH. '
              'Built from your covers, your PPA, your target CPLH, your '
              'target SPLH, your FOH and BOH wages. Not borrowed from a '
              'benchmark. Not copied from another location. Built from 60 '
              'days of your own operation. When variance appears you know '
              'immediately which side of the house to look at first.',
          runIndex: 3,
          runLength: 3,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c9_u8.webp',
              caption: 'Diagram: How it assembles into your theoretical labor %',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c9_u9',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What this looks like tracked across 60 days',
          body: 'Below is what the two tracking spreadsheets look like after 60 '
              'days of shift data - one for CPLH by daypart, one for SPLH by '
              'daypart. These are the sheets you are building during the '
              'discipline period. The patterns in them are what your targets '
              'come from.\n'
              '\n'
              'Screenshot Placeholder\n'
              '\n'
              'Insert: CPLH Tracking Spreadsheet (Excel) Daily covers, FOH '
              'hours, CPLH per shift by daypart - 60 days. OPZ band '
              'highlighted. Target line at 4.5.\n'
              '\n'
              'Insert: SPLH Tracking Spreadsheet (Excel) Daily sales, BOH '
              'hours, SPLH per shift by daypart - 60 days. Target SPLH line. '
              'PPA column alongside.',
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c10',
      title: 'Chapter 10: Variance - The Gap',
      subtitle: '11 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 10: Variance - The Gap',
          body: 'Manage the variance, not the %. The weekly labor calculation '
              'that shows you exactly where the hours went.\n'
              '\n'
              '> Source: LinkedIn > > "If you want to make more profit. '
              'Manage the variance. Not the %."',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The three-part model',
          body: 'Jim\'s framing is precise. There are three things to know about '
              'your labor. Most operators only track one. That\'s the problem.\n'
              '\n'
              'Formula: Jim Taylor - LinkedIn\n'
              '\n'
              'Theoretical = What should happen\n'
              '\n'
              'Actual = What actually happened\n'
              '\n'
              'The Gap = Management opportunity\n'
              '\n'
              'Variance = Actual Labor % - Theoretical Labor %\n'
              '\n'
              '0 points -> Perfect. Hours matched the model exactly.\n'
              '\n'
              '+1 to 2 pts -> Small. Normal variation. Watch it weekly.\n'
              '\n'
              '+3 to 5 pts -> Meaningful. Find the cause this week.\n'
              '\n'
              '+5 pts+ -> Large. Significant money leaving the building.',
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'What a 4-point gap actually costs',
          body: '> Source: LinkedIn > > "If theoretical labor is 15% and actual '
              'is 19%, that 4-point gap isn\'t a wage problem. It\'s a '
              'productivity management gap."\n'
              '\n'
              'Example: Jim\'s example - translated to dollars\n'
              '\n'
              '- Sales: \$50,000 this week\n'
              '\n'
              '- Theoretical labor (15%): \$50,000 x 0.15 = \$7,500\n'
              '\n'
              '- Actual labor (19%): \$50,000 x 0.19 = \$9,500\n'
              '\n'
              'Answer: Gap: \$2,000 this week - \$104,000 annualised\n'
              '\n'
              '> Takeaway > > \$104,000 a year. No new staff hired. No wage '
              'increases. Just the gap between what the model required and '
              'what actually got scheduled and deployed. That is a '
              'productivity management gap - not a cost problem. The fix is '
              'operational, not financial.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c10_u2.webp',
              caption: 'Diagram: What a 4-point gap actually costs',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Full weekly variance - built from Chapter 09',
          body: 'This is the same restaurant from Chapter 09. The theoretical '
              'baseline was built from real inputs. Now the week is over and '
              'the actuals are in. Here is how you run the calculation.\n'
              '\n'
              'Theoretical baseline (Chapter 09)\n'
              '\n'
              'Covers: 1,200\n'
              '\n'
              'CPLH target: 4.5\n'
              '\n'
              'SPLH target: \$180\n'
              '\n'
              'PPA: \$42\n'
              '\n'
              'FOH hours: 267 - FOH wage: \$16.50\n'
              '\n'
              'BOH hours: 280 - BOH wage: \$21.35\n'
              '\n'
              'FOH labor \$: 267 x \$16.50 = \$4,405\n'
              '\n'
              'BOH labor \$: 280 x \$21.35 = \$5,978\n'
              '\n'
              'Total labor \$: \$10,383\n'
              '\n'
              'Sales: 1,200 x \$42 = \$50,400\n'
              '\n'
              'FOH floor: 8.7% - BOH floor: 11.9% - Total: 20.6%\n'
              '\n'
              'What actually happened\n'
              '\n'
              'Covers: 1,140 -60\n'
              '\n'
              'CPLH actual: 1,140 / 280 = 4.07\n'
              '\n'
              'SPLH actual: \$47,880 / 290 = \$165.10\n'
              '\n'
              'PPA: \$42 held\n'
              '\n'
              'FOH hours: 280 model needed 253\n'
              '\n'
              'BOH hours: 290 +10 overtime\n'
              '\n'
              'FOH labor \$: 280 x \$16.50 = \$4,620\n'
              '\n'
              'BOH labor \$: 290 x \$21.35 = \$6,192',
          runIndex: 1,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u4',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Full weekly variance - built from Chapter 09 (cont.)',
          body: 'Total labor \$: \$10,812\n'
              '\n'
              'Sales: 1,140 x \$42 = \$47,880\n'
              '\n'
              'FOH: 9.7% up 1.0 - BOH: 12.9% up 1.0 - Total: 22.6% up 2.0 pts\n'
              '\n'
              '> Takeaway > > 2.0 points on \$47,880 = \$958 above the floor '
              'this week. Annualised: \$49,816. The split tells you '
              'immediately: both FOH and BOH drifted equally - a cover '
              'shortfall hit both sides. Now the question is: which of the '
              'five levers moved, and why?',
          runIndex: 2,
          runLength: 2,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u5',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The diagnostic - tracing which input moved',
          body: 'Variance tells you something went wrong. The five levers below '
              'tell you exactly what. Each moves labor % in a specific '
              'direction for a specific reason. Each has a different fix. FOH '
              'and BOH are shown separately so you know immediately which '
              'side of the house to look at. All numbers use the same '
              '1,200-cover baseline from Chapter 09.\n'
              '\n'
              'Covers - affects both FOH and BOH\n'
              '\n'
              'Covers up: 1,200 -> 1,320 guests\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After\n'
              '\n'
              'FOH 7.9% - BOH 10.8% - Total 18.7% down 1.9 pts\n'
              '\n'
              'Note: More guests than forecast, same hours. Both sides '
              'improve as the sales denominator grows. If consistent, '
              'recalibrate the forecast upward.\n'
              '\n'
              'Covers down: 1,200 -> 1,080 guests\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After\n'
              '\n'
              'FOH 9.7% - BOH 13.2% - Total 22.9% up 2.3 pts\n'
              '\n'
              'Note: Hours didn\'t flex with volume. Both sides drift. '
              'Forecast or scheduling gap. Track covers mid-week and cut '
              'hours in real time.',
          runIndex: 1,
          runLength: 6,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u6',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The diagnostic - tracing which input moved (cont.)',
          body: 'PPA - affects both FOH and BOH\n'
              '\n'
              'PPA up: \$42 -> \$46 per guest\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After\n'
              '\n'
              'FOH 7.9% - BOH 10.8% - Total 18.7% down 1.9 pts\n'
              '\n'
              'Note: Team executed well. Upsells happened, guests were '
              'attended to, service wasn\'t rushed. The OPZ working as '
              'designed.\n'
              '\n'
              'PPA down: \$42 -> \$38 per guest\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After\n'
              '\n'
              'FOH 9.6% - BOH 13.2% - Total 22.8% up 2.2 pts\n'
              '\n'
              'Note: Check if the team was overstretched - upsells die above '
              'the OPZ ceiling. Guests felt rushed. FOH problem showing up '
              'across both sides.\n'
              '\n'
              'CPLH - FOH productivity - FOH labor % moves - BOH unchanged\n'
              '\n'
              'CPLH up: 4.5 -> 5.2 covers per hour\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After - 231 FOH hrs x \$16.50 = \$3,812\n'
              '\n'
              'FOH 7.6% - BOH 11.9% - Total 19.5% down 1.1 pts',
          runIndex: 2,
          runLength: 6,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u7',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The diagnostic - tracing which input moved (cont.)',
          body: 'Note: FOH more productive per hour. Schedule was right for the '
              'volume. Document this shift and replicate it.\n'
              '\n'
              'CPLH down: 4.5 -> 3.8 covers per hour\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After - 316 FOH hrs x \$16.50 = \$5,214\n'
              '\n'
              'FOH 10.3% - BOH 11.9% - Total 22.2% up 1.6 pts\n'
              '\n'
              'Note: FOH overstaffed for actual volume. Hours weren\'t built '
              'from covers. Fix the schedule, not the team. BOH unaffected.\n'
              '\n'
              'SPLH - BOH productivity - BOH labor % moves - FOH unchanged\n'
              '\n'
              'SPLH up: \$180 -> \$200 per BOH hour\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After - 252 BOH hrs x \$21.35 = \$5,380\n'
              '\n'
              'FOH 8.7% - BOH 10.7% - Total 19.4% down 1.2 pts\n'
              '\n'
              'Note: BOH producing more per hour. Kitchen efficient, ticket '
              'times clean. FOH unaffected.\n'
              '\n'
              'SPLH down: \$180 -> \$155 per BOH hour\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%',
          runIndex: 3,
          runLength: 6,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u8',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The diagnostic - tracing which input moved (cont.)',
          body: 'After - 325 BOH hrs x \$21.35 = \$6,939\n'
              '\n'
              'FOH 8.7% - BOH 13.8% - Total 22.5% up 1.9 pts\n'
              '\n'
              'Note: BOH underproducing per hour. Ticket times slow, kitchen '
              'complexity, or overstaffed. FOH unaffected - this is a kitchen '
              'problem.\n'
              '\n'
              'FOH Wage - FOH labor % moves - BOH unchanged\n'
              '\n'
              'FOH Wage up: \$16.50 -> \$18.50/hr (overtime)\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After - 267 hrs x \$18.50 = \$4,940\n'
              '\n'
              'FOH 9.8% - BOH 11.9% - Total 21.7% up 1.1 pts\n'
              '\n'
              'Note: FOH overtime or wrong role covering a shift. Same hours, '
              'higher cost. Smarter FOH deployment. BOH unaffected.\n'
              '\n'
              'FOH Wage down: \$16.50 -> \$15.00/hr (favorable mix)\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After - 267 hrs x \$15.00 = \$4,005\n'
              '\n'
              'FOH 7.9% - BOH 11.9% - Total 19.8% down 0.8 pts\n'
              '\n'
              'Note: Right FOH roles on right shifts. Note the deployment '
              'pattern and replicate it.',
          runIndex: 4,
          runLength: 6,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u9',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The diagnostic - tracing which input moved (cont.)',
          body: 'BOH Wage - BOH labor % moves - FOH unchanged\n'
              '\n'
              'BOH Wage up: \$21.35 -> \$23.50/hr (overtime)\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After - 280 hrs x \$23.50 = \$6,580\n'
              '\n'
              'FOH 8.7% - BOH 13.1% - Total 21.8% up 1.2 pts\n'
              '\n'
              'Note: BOH overtime or kitchen manager covering a line '
              'position. Same hours, higher cost. Smarter BOH deployment. FOH '
              'unaffected.\n'
              '\n'
              'BOH Wage down: \$21.35 -> \$19.50/hr (favorable mix)\n'
              '\n'
              'Before\n'
              '\n'
              'FOH 8.7% - BOH 11.9% - Total 20.6%\n'
              '\n'
              'After - 280 hrs x \$19.50 = \$5,460\n'
              '\n'
              'FOH 8.7% - BOH 10.8% - Total 19.5% down 1.1 pts\n'
              '\n'
              'Note: Right BOH roles on right shifts. Note the kitchen '
              'deployment pattern and replicate it.\n'
              '\n'
              '> Callout > > Variance tells you something went wrong. The '
              'levers tell you exactly what. The FOH/BOH split tells you '
              'exactly where. Fix the specific input that moved.\n'
              '\n'
              '> Source: LinkedIn > > "If you\'ve never calculated your '
              'theoretical labor cost before, you\'re not alone. Most '
              'operators haven\'t. But once you see the gap, you can\'t unsee '
              'it."',
          runIndex: 5,
          runLength: 6,
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c10_u10',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The diagnostic - tracing which input moved (cont.)',
          body: '> Key: Part 2 - Food Cost (coming) > > Jim applies the exact '
              'same framework to food cost - theoretical vs actual COGS, '
              'recipe costing, contribution margin, menu engineering. The '
              'logic is identical. The foundation work is different. Part 2 '
              'covers that system in full. > > Master the labor model first. '
              'Once you can read a shift\'s numbers in 90 seconds, the food '
              'cost layer drops in on top of a model that already works.',
          runIndex: 6,
          runLength: 6,
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c11',
      title: 'Chapter 11: The Optimal Productivity Zone',
      subtitle: '3 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c11_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 11: The Optimal Productivity Zone',
          body: 'The floor and the ceiling - why going above it costs you as '
              'much as going below\n'
              '\n'
              '> Source: LinkedIn > > "This is what I call the Optimal '
              'Productivity Zone. The balance where your team produces more '
              'without being overloaded. Too few people? Team burns out. '
              'Service suffers. Turnover spikes. Average spend drops. Too '
              'many people? Payroll bleeds. Staff gets bored. Margins '
              'disappear."\n'
              '\n'
              'Below OPZ - too many staff\n'
              '\n'
              '- Servers standing around between tables\n'
              '\n'
              '- Hours paid, covers not being produced\n'
              '\n'
              '- CPLH low - labor bleeds\n'
              '\n'
              '- Staff bored and complacent\n'
              '\n'
              'Above OPZ - too few staff\n'
              '\n'
              '- Servers running 8 tables instead of 5\n'
              '\n'
              '- Check-backs stop - upsells die\n'
              '\n'
              '- PPA drops - guests not prompted to order more\n'
              '\n'
              '- Best people burn out and quit\n'
              '\n'
              '> Good > > Inside the OPZ: team is busy but not overwhelmed. '
              'Service is smooth. Upsells happen. Guests feel attended to. '
              'CPLH is at target. Labor % lands where the model predicts. '
              'This is the only zone where profit is consistently designed.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c11_u0.webp',
              caption: 'Diagram: Chapter 11: The Optimal Productivity Zone',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c11_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Jim\'s real data - one restaurant tracked for 30 days',
          body: '> Source: LinkedIn > > "Target: 7 covers per labor hour. When '
              'productivity dropped to 5.3 CPLH -> labor cost hit 8.2%. When '
              'productivity rose to 7.5 CPLH -> labor cost dropped to 6.8%. '
              'Productivity swung from 5.3 to 8.0 CPLH. That\'s a 51% swing."\n'
              '\n'
              'CPLH | FOH Labor % | Zone | What was happening\n'
              '\n'
              '5.3 | 8.2% | Below OPZ | Overstaffed. Too many hours for the '
              'covers.\n'
              '\n'
              '6.5 | 7.4% | OPZ check | Good. Team busy, service holding.\n'
              '\n'
              '7.0 | 7.1% | OPZ check | Optimal. Right balance.\n'
              '\n'
              '7.5 | 6.8% | OPZ check | Strong. Approaching ceiling.\n'
              '\n'
              '8.0 | 6.6% | Ceiling | Team stressed. Service complaints '
              'rising.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c11_u1.webp',
              caption: 'Diagram: Jim\'s real data - one restaurant tracked for 30 days',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c11_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'The counterintuitive result - add staff, drop labor %',
          body: '> Source: LinkedIn > > "The fix was counterintuitive: add '
              'people back. Intentionally. Labor climbed to 28%. Then dropped '
              'back to 25% on its own, because a properly staffed team '
              'actually had time to sell, serve, and stay. +\$400K in annual '
              'revenue. Turnover cut in half."\n'
              '\n'
              'How adding staff drops labor %: when the team is properly '
              'staffed, upsells happen, PPA rises, revenue grows. Labor cost '
              'is slightly higher but the sales denominator grows faster. The '
              'ratio improves. That is the OPZ working as designed.',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c11_u2.webp',
              caption: 'Diagram: The counterintuitive result - add staff, drop labor %',
              afterParagraph: -1,
            ),
          ],
        ),
      ],
    ),
    HandbookChapter(
      id: 'jim_taylor_labor_model_c12',
      title: 'Chapter 12: Reading the Full Story',
      subtitle: '6 cards',
      iconCodePoint: 0xe865,
      units: [
        HandbookUnit(
          id: 'jim_taylor_labor_model_c12_u0',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Chapter 12: Reading the Full Story',
          body: 'Every metric, every formula, and the 90-second post-shift read',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c12_u0.webp',
              caption: 'Diagram: Chapter 12: Reading the Full Story',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c12_u1',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'How the metrics chain together',
          body: 'Step 1: Count covers, sales, and labor hours every shift - by '
              'daypart\n'
              '\n'
              'Raw inputs. Lunch, dinner, late night tracked separately. '
              'Everything else is built from these.\n'
              '\n'
              'Step 2: Calculate CPLH (FOH) and SPLH (BOH) after every shift\n'
              '\n'
              'CPLH = Covers / FOH Hours. SPLH = Sales / BOH Hours. Your two '
              'productivity reads, every daypart, every shift.\n'
              '\n'
              'Step 3: Track for 60 days - identify your sustainable range\n'
              '\n'
              'Look for when CPLH, SPLH, and PPA are all high together. That '
              'is your team at their best. That range sets your targets. Not '
              'a benchmark. Not last year. Your own 60 days.\n'
              '\n'
              'Step 4: Convert your 60-day cover total into a weekly forecast\n'
              '\n'
              'Total covers / (60 / 7) = weekly average. That number, with '
              'your target CPLH, SPLH, PPA, and blended wage, builds your '
              'theoretical labor %.\n'
              '\n'
              'Step 5: Track variance weekly\n'
              '\n'
              'Actual % - Theoretical %. If it moved, one of the five levers '
              'moved with it. Go to the lever cards in Chapter 10. Find the '
              'specific input. Fix that thing only.',
          runIndex: 1,
          runLength: 2,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c12_u1.webp',
              caption: 'Diagram: How the metrics chain together',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c12_u2',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'How the metrics chain together (cont.)',
          body: 'Step 6: Find and defend your OPZ\n'
              '\n'
              'From your 60 days of CPLH data, identify the range where labor '
              '% declines and service holds. Below it you are bleeding hours. '
              'Above it you are burning your team. Stay inside it.',
          runIndex: 2,
          runLength: 2,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c12_u2.webp',
              caption: 'Diagram: How the metrics chain together',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c12_u3',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'All formulas',
          body: 'Formula: Every Formula in Sequence\n'
              '\n'
              'PPA = Total Sales / Total Covers\n'
              '\n'
              'CPLH = Total Covers / FOH Labor Hours\n'
              '\n'
              'SPLH = Total Sales / BOH Labor Hours\n'
              '\n'
              'Weekly Covers = 60-Day Cover Total / (60 / 7)\n'
              '\n'
              'Required FOH Hours = Forecasted Covers / Target CPLH\n'
              '\n'
              'Required BOH Hours = Forecasted Sales / Target SPLH\n'
              '\n'
              'FOH Theoretical Labor \$ = Required FOH Hours x FOH Wage\n'
              '\n'
              'BOH Theoretical Labor \$ = Required BOH Hours x BOH Wage\n'
              '\n'
              'Total Theoretical Labor \$= FOH Labor \$ + BOH Labor \$\n'
              '\n'
              'FOH Theoretical Labor % = FOH Labor \$ / Forecasted Sales\n'
              '\n'
              'BOH Theoretical Labor % = BOH Labor \$ / Forecasted Sales\n'
              '\n'
              'Labor % = (Hours x Wage) / (Covers x PPA)\n'
              '\n'
              'Variance = Actual Labor % - Theoretical Labor %',
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c12_u3.webp',
              caption: 'Diagram: All formulas',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c12_u4',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Reading a shift in 90 seconds',
          body: '1. Pull covers, sales, and labor hours from POS - by daypart.\n'
              '\n'
              '2. Calculate CPLH. Inside your OPZ? Above it or below it?\n'
              '\n'
              '3. Calculate SPLH. Is BOH producing at target? Is PPA where '
              'you expected?\n'
              '\n'
              '4. Compare to theoretical. What is the variance?\n'
              '\n'
              '5. If CPLH inside OPZ, SPLH on target, variance tight -> '
              'benchmark shift. Write down what made it work. That is a '
              'replicable day.\n'
              '\n'
              '6. If variance exists -> go to the lever cards in Chapter 10. '
              'Identify which input moved. Fix that specific thing. Not '
              '"labor." The input.\n'
              '\n'
              '> Key: The final thought - from the book > > "We introduced '
              'the concept of \'employee workload\' to the restaurant industry, '
              'drawing inspiration from professional sports\' approach to '
              'athlete management. By carefully monitoring and managing '
              'employee workload, we sought to create a more sustainable and '
              'productive work environment." - Jim Taylor, Bold Operations '
              'p.7 Book > > Every metric here exists in service of one goal: '
              'making sure the people on your floor are working hard enough '
              'to be productive, but not so hard that they break. That is the '
              'OPZ. That is the whole framework.',
          runIndex: 1,
          runLength: 2,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c12_u4.webp',
              caption: 'Diagram: Reading a shift in 90 seconds',
              afterParagraph: -1,
            ),
          ],
        ),
        HandbookUnit(
          id: 'jim_taylor_labor_model_c12_u5',
          type: HandbookUnitType.explainer,
          badgeHint: 'READ',
          title: 'Reading a shift in 90 seconds (cont.)',
          body: 'Tags: Covers, Labor Hours, PPA, Wage Mix, CPLH - FOH, SPLH - '
              'BOH, 60-Day Tracking Discipline, Required FOH Hours, Required '
              'BOH Hours, Theoretical Labor, Variance, OPZ',
          runIndex: 2,
          runLength: 2,
          images: [
            HandbookUnitImage(
              assetPath: 'assets/internal/barrio/training/jim_taylor_labor_model_diagrams/jim_taylor_labor_model_c12_u5.webp',
              caption: 'Diagram: Reading a shift in 90 seconds',
              afterParagraph: -1,
            ),
          ],
        ),
      ],
    ),
  ],
);
