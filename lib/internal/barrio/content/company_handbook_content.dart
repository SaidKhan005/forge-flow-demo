// Typed content model and data for the Company Handbook.
//
// All content here is translated from the Barrio Legado handbook PDF
// into native structured data. This is NOT a document viewer -- it is
// an interactive learning surface built from source material.
//
// The content model follows the Barrio blueprint teaching loop:
//   situation -> decision -> outcome -> explanation -> action

// ---------------------------------------------------------------------------
// Content model types
// ---------------------------------------------------------------------------

/// The kind of learning unit inside a handbook chapter.
enum HandbookUnitType {
  /// An explainer card that teaches a concept.
  explainer,

  /// A decision-based interaction: situation + options + feedback.
  decision,

  /// A checkpoint/quiz that tests understanding.
  checkpoint,
}

/// A single option inside a decision or checkpoint unit.
class HandbookOption {
  final String label;
  final bool isCorrect;
  final String feedback;

  const HandbookOption({
    required this.label,
    required this.isCorrect,
    required this.feedback,
  });
}

/// A content picture carried from a training source document, rendered
/// inline inside a unit's body at its source position.
class HandbookUnitImage {
  /// Bundled asset path, e.g.
  /// 'assets/internal/barrio/training/coffee_training/01.webp'.
  final String assetPath;

  /// Literal caption from the source document, when one exists. Never
  /// invented; null renders no caption.
  final String? caption;

  /// 0-based index of the blank-line-separated paragraph in [HandbookUnit.body]
  /// after which this image renders. -1 renders the image before the first
  /// paragraph.
  final int afterParagraph;

  const HandbookUnitImage({
    required this.assetPath,
    this.caption,
    required this.afterParagraph,
  });
}

/// A single learning unit inside a handbook chapter.
///
/// Can be an explainer, a decision prompt, or a checkpoint quiz.
class HandbookUnit {
  final String id;
  final HandbookUnitType type;

  /// Title shown at the top of the card.
  final String title;

  /// Body text for explainer cards, or the situation prompt for
  /// decision/checkpoint cards.
  final String body;

  /// Available options for decision and checkpoint units.
  /// Empty for explainer units.
  final List<HandbookOption> options;

  /// Short contextual label for the card badge (e.g. 'HISTORY' instead of
  /// the generic 'LEARN'). Falls back to the type-based default when null.
  final String? badgeHint;

  /// Content pictures rendered inside the body at their source positions.
  /// Empty for units without pictures (the default; rendering is unchanged).
  final List<HandbookUnitImage> images;

  /// 1-based position of this card inside its source-section run. A long
  /// source section split across N cards yields runIndex 1..N in reading
  /// order; an unsplit card is a run of one (the default). Honest
  /// arithmetic only: no invented sub-titles. Lets a card badge show
  /// 'K of N' instead of a bare '(cont.)' tail.
  final int runIndex;

  /// Total cards in this card's source-section run. 1 (the default) when
  /// the source section fit on a single card.
  final int runLength;

  const HandbookUnit({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.options = const [],
    this.badgeHint,
    this.images = const [],
    this.runIndex = 1,
    this.runLength = 1,
  });
}

/// Photo vs. diagram classification for a unit's images.
///
/// House-style diagram pictograms (full-coverage pass 2026-07-30, so every
/// reading card carries a visual) all carry a 'Diagram: ' caption. They are
/// teaching visuals shown ONLY in the reading card body: never as a browse-row
/// thumbnail, A-Z index photo, photo-grid tile, or flashcard front, where a
/// real photograph of the actual dish/term is what earns recognition (Metric
/// Honesty: a pictogram is not a photo of the thing). These helpers let the
/// photo-only surfaces skip diagrams while the reading card keeps rendering
/// every image in order.
extension HandbookUnitPhotos on HandbookUnit {
  /// Whether an image is a house-style diagram pictogram (vs. a photograph).
  static bool isDiagram(HandbookUnitImage image) =>
      image.caption?.startsWith('Diagram: ') ?? false;

  /// The unit's real photographs, in source order (diagrams excluded).
  Iterable<HandbookUnitImage> get photos => images.where((i) => !isDiagram(i));

  /// The first real photograph, or null when the unit has only diagrams
  /// (or no images at all).
  HandbookUnitImage? get firstPhoto {
    for (final image in images) {
      if (!isDiagram(image)) return image;
    }
    return null;
  }
}

/// A chapter in the handbook, containing multiple learning units.
class HandbookChapter {
  final String id;
  final String title;
  final String subtitle;
  final int iconCodePoint;
  final List<HandbookUnit> units;

  /// Optional part grouping for long manuals: the name of the part this
  /// chapter belongs to. Presentation metadata only (the chapter rail
  /// and doc header render parts as separators); null (the default) for
  /// manuals without part grouping. Part names never change body words.
  final String? partTitle;

  /// 1-based index of [partTitle] among the manual's parts. Null when the
  /// manual has no part grouping.
  final int? partIndex;

  /// Total number of parts in the manual's grouping. Null when the manual
  /// has no part grouping.
  final int? partCount;

  const HandbookChapter({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.iconCodePoint,
    required this.units,
    this.partTitle,
    this.partIndex,
    this.partCount,
  });
}

// ---------------------------------------------------------------------------
// Handbook content data -- translated from source PDF
// ---------------------------------------------------------------------------

/// All handbook chapters.
///
/// The first two chapters are fully built with real source content.
/// Additional chapters are scaffolded lightly for future prompts.
const List<HandbookChapter> handbookChapters = [
  _chapterWelcome,
  _chapterEmploymentEssentials,
  _chapterWorkplacePolicies,
  _chapterConductAndTeamwork,
  _chapterHealthAndSafety,
];

// ---- Chapter 1: Welcome to Barrio ----------------------------------------

const _chapterWelcome = HandbookChapter(
  id: 'welcome',
  title: 'Welcome to Barrio',
  subtitle: 'Our story, mission, and values',
  iconCodePoint: 0xe533, // Icons.restaurant_menu
  units: [
    HandbookUnit(
      id: 'welcome_concept',
      type: HandbookUnitType.explainer,
      title: 'Our Concept',
      badgeHint: 'DISCOVER',
      body: 'Barrio Legado celebrates culinary heritage and community spirit. '
          'The name is a tribute to Raymond\'s, a groundbreaking restaurant '
          'that set the standard for exceptional hospitality in St. John\'s.\n\n'
          'We invite you on a culinary journey across Latin America, where '
          'every dish tells a story and every bite awakens the senses. Light '
          'wood and soft grey tones create a soothing backdrop, while vibrant '
          'turquoise accents and lush greenery infuse the space with energy.',
    ),
    HandbookUnit(
      id: 'welcome_history',
      type: HandbookUnitType.explainer,
      title: 'The History of 95 Water Street',
      badgeHint: 'HISTORY',
      body: 'Constructed in 1915 and opened in 1916, our building was '
          'originally The Commercial Cable Company Building -- a vital hub '
          'for Newfoundland\'s telecommunications.\n\n'
          'In 1987 it was designated a registered heritage structure. This '
          'Classical Revival masterpiece, designed by architect William F. '
          'Butler, is one of the few classical buildings still standing in '
          'the heart of the city.',
    ),
    HandbookUnit(
      id: 'welcome_raymonds',
      type: HandbookUnitType.explainer,
      title: 'Raymond\'s Legacy',
      badgeHint: 'LEGACY',
      body: 'Raymond\'s was a culinary gem at 95 Water Street, operated by '
          'chef Jeremy Charles and sommelier Jeremy Bonia. Named Canada\'s '
          'Best New Restaurant by EnRoute magazine in 2012, it reached #4 on '
          'Canada\'s 100 Best in 2015.\n\n'
          'Their farm-to-table philosophy showcased the best of Atlantic '
          'Canada. At Barrio Legado, we carry this legacy forward with our '
          'own fresh and vibrant Latin American touch.',
    ),
    HandbookUnit(
      id: 'welcome_mission',
      type: HandbookUnitType.explainer,
      title: 'Our Mission',
      badgeHint: 'MISSION',
      body: '"Creating unforgettable experiences where every interaction '
          'forges lasting connections."\n\n'
          'Hospitality is more than a transaction -- it\'s about the '
          'connections we build and the emotions we share. We add thoughtful '
          'surprises that transform a regular meal into an extraordinary '
          'experience.',
    ),
    HandbookUnit(
      id: 'welcome_values_decision',
      type: HandbookUnitType.decision,
      title: 'Living Our Values',
      badgeHint: 'DECIDE',
      body: 'A guest mentions it\'s their anniversary but didn\'t make a '
          'special request. As a team member, what best reflects our mission '
          'of forging lasting connections?',
      options: [
        HandbookOption(
          label: 'Acknowledge it verbally and move on',
          isCorrect: false,
          feedback: 'A kind gesture, but our mission calls for going beyond '
              'words to create unforgettable moments.',
        ),
        HandbookOption(
          label: 'Let them enjoy their meal without interruption',
          isCorrect: false,
          feedback: 'Respecting space matters, but a small thoughtful touch '
              'is what separates good service from unforgettable hospitality.',
        ),
        HandbookOption(
          label: 'Surprise them with a small dessert and a warm note',
          isCorrect: true,
          feedback: 'This reflects our core value of adding thoughtful '
              'surprises that transform a regular meal into an extraordinary '
              'experience.',
        ),
      ],
    ),
    HandbookUnit(
      id: 'welcome_checkpoint',
      type: HandbookUnitType.checkpoint,
      title: 'Check Your Knowledge',
      badgeHint: 'CHECK',
      body: 'What was the original purpose of the building at 95 Water '
          'Street when it opened in 1916?',
      options: [
        HandbookOption(
          label: 'A telegraph and telecommunications office',
          isCorrect: true,
          feedback: 'Correct! It was The Commercial Cable Company Building, '
              'serving as a hub for Newfoundland\'s telecommunications.',
        ),
        HandbookOption(
          label: 'A fine dining restaurant',
          isCorrect: false,
          feedback: 'Raymond\'s didn\'t open until 2011. The building started '
              'as a telecommunications hub in 1916.',
        ),
        HandbookOption(
          label: 'A trade school',
          isCorrect: false,
          feedback: 'The Brother T.I. Murphy Centre came later. The building '
              'was originally a telecommunications office.',
        ),
      ],
    ),
  ],
);

// ---- Chapter 2: Employment Essentials ------------------------------------

const _chapterEmploymentEssentials = HandbookChapter(
  id: 'employment_essentials',
  title: 'Employment Essentials',
  subtitle: 'Scheduling, attendance, and compensation',
  iconCodePoint: 0xe556, // Icons.schedule
  units: [
    HandbookUnit(
      id: 'emp_welcome',
      type: HandbookUnitType.explainer,
      title: 'Welcome to the Team',
      badgeHint: 'WELCOME',
      body: 'Welcome to the Barrio familia! Our leadership team is '
          'comprised of passionate individuals committed to blending '
          'heartfelt service with modern technology.\n\n'
          'We believe open communication is the cornerstone of a thriving '
          'workplace. Our Open Door Policy encourages you to bring forward '
          'questions, innovative ideas, or any concerns at any time.',
    ),
    HandbookUnit(
      id: 'emp_scheduling',
      type: HandbookUnitType.explainer,
      title: 'Scheduling & Availability',
      badgeHint: 'SCHEDULE',
      body: 'Schedules are posted weekly, no later than Thursday evening '
          'for the following week, through the Push Operations App.\n\n'
          'Your availability should reflect your other commitments rather '
          'than personal shift preferences. Time off requests must be '
          'submitted by Monday of the previous week. Vacation requests '
          'require at least two weeks notice.',
    ),
    HandbookUnit(
      id: 'emp_attendance',
      type: HandbookUnitType.explainer,
      title: 'Attendance & Punctuality',
      badgeHint: 'ATTEND',
      body: 'Be prepared to start your shift at least 5 minutes before '
          'your scheduled time -- in uniform, with tools ready and personal '
          'belongings stored.\n\n'
          'If you are running late, reach out to the manager on duty as soon '
          'as possible. We maintain a zero-tolerance policy for no-shows. '
          'If you are feeling unwell, call your manager at least three hours '
          'before your shift.',
    ),
    HandbookUnit(
      id: 'emp_compensation',
      type: HandbookUnitType.explainer,
      title: 'Compensation & Benefits',
      badgeHint: 'PAY',
      body: 'Pay is deposited every Thursday via direct deposit. Overtime '
          'is paid at 1.5x minimum wage for hours beyond 40 in a week '
          '(Monday to Sunday).\n\n'
          'Staff receive 50% off a regular-priced meal during their break '
          'period, and 20% off food on days off for themselves and a guest.\n\n'
          'Gratuities discussions should remain private and never happen '
          'within earshot of guests.',
    ),
    HandbookUnit(
      id: 'emp_scheduling_decision',
      type: HandbookUnitType.decision,
      title: 'Schedule Scenario',
      badgeHint: 'DECIDE',
      body: 'You realize you have a conflict with next week\'s schedule '
          'after it was already posted. What is the correct first step?',
      options: [
        HandbookOption(
          label: 'Text a coworker to cover it informally',
          isCorrect: false,
          feedback: 'Informal swaps bypass the system. All changes must be '
              'submitted through Push Operations and approved by a manager.',
        ),
        HandbookOption(
          label: 'Submit a shift switch through Push Operations',
          isCorrect: true,
          feedback: 'Correct! All shift changes must go through Push '
              'Operations. You remain responsible until the change is '
              'approved by a manager.',
        ),
        HandbookOption(
          label: 'Just skip the shift since you updated your availability',
          isCorrect: false,
          feedback: 'Availability reflects commitments, not preferences. '
              'You are responsible for every scheduled shift until a change '
              'is formally approved.',
        ),
      ],
    ),
    HandbookUnit(
      id: 'emp_sick_decision',
      type: HandbookUnitType.decision,
      title: 'Calling In Sick',
      badgeHint: 'DECIDE',
      body: 'You wake up feeling unwell 4 hours before your shift. '
          'What should you do?',
      options: [
        HandbookOption(
          label: 'Call your manager on duty directly',
          isCorrect: true,
          feedback: 'Correct! Call at least 3 hours before your shift. '
              'Direct communication is required -- no voicemails, emails, '
              'or text messages.',
        ),
        HandbookOption(
          label: 'Send a text message to your manager',
          isCorrect: false,
          feedback: 'Text messages are not acceptable for calling in sick. '
              'You must call the manager on duty directly.',
        ),
        HandbookOption(
          label: 'Wait to see if you feel better closer to the shift',
          isCorrect: false,
          feedback: 'You need to give at least 3 hours notice. Waiting '
              'reduces the time management has to arrange coverage.',
        ),
      ],
    ),
    HandbookUnit(
      id: 'emp_checkpoint',
      type: HandbookUnitType.checkpoint,
      title: 'Check Your Knowledge',
      badgeHint: 'CHECK',
      body: 'How early should you be ready to start before your '
          'scheduled shift time?',
      options: [
        HandbookOption(
          label: 'Exactly on time',
          isCorrect: false,
          feedback: 'On time means you still need to get ready. The policy '
              'asks you to be prepared 5 minutes early.',
        ),
        HandbookOption(
          label: 'At least 5 minutes',
          isCorrect: true,
          feedback: 'Correct! Be in uniform with tools ready and belongings '
              'stored at least 5 minutes before your scheduled start.',
        ),
        HandbookOption(
          label: 'At least 15 minutes',
          isCorrect: false,
          feedback: '15 minutes is more than required. The policy is at '
              'least 5 minutes early.',
        ),
      ],
    ),
  ],
);

// ---- Chapter 3: Workplace Policies ---------------------------------------

const _chapterWorkplacePolicies = HandbookChapter(
  id: 'workplace_policies',
  title: 'Workplace Policies',
  subtitle: 'Phone, devices, breaks, and service standards',
  iconCodePoint: 0xe4d9, // Icons.policy
  units: [
    HandbookUnit(
      id: 'wp_phone',
      type: HandbookUnitType.explainer,
      title: 'Answering the Phone',
      badgeHint: 'PHONE',
      body: 'Greet callers warmly: "Good Afternoon/Evening, Barrio Legado. '
          'This is [Your First Name], how may I assist you today?"\n\n'
          'If you are unsure about the answer, ask if you can place them on '
          'hold while you connect them with someone who can help.',
    ),
    HandbookUnit(
      id: 'wp_cellphones',
      type: HandbookUnitType.explainer,
      title: 'Cell Phone Policy',
      badgeHint: 'DEVICES',
      body: 'Cell phone usage is prohibited on the floor or on the line. '
          'Guests should never see you using your phone -- it detracts from '
          'their experience and can create food safety concerns.\n\n'
          'Managers and supervisors may use phones strictly for work-related '
          'purposes. If you have a special circumstance, discuss it with '
          'management.',
    ),
    HandbookUnit(
      id: 'wp_breaks',
      type: HandbookUnitType.explainer,
      title: 'Breaks',
      badgeHint: 'BREAKS',
      body: 'Staff working 5+ consecutive hours are entitled to a 30-minute '
          'unpaid break. Arrange breaks with your Manager on Duty -- they '
          'should not be taken during peak service hours.\n\n'
          'Clock out during your break. Staff are not permitted to order '
          'food within the first 3 hours of their shift and must be on '
          'break to consume a meal.',
    ),
    HandbookUnit(
      id: 'wp_phone_decision',
      type: HandbookUnitType.decision,
      title: 'Phone Scenario',
      badgeHint: 'DECIDE',
      body: 'A guest calls and asks a question you don\'t know the answer '
          'to. What do you do?',
      options: [
        HandbookOption(
          label: 'Give your best guess to be helpful',
          isCorrect: false,
          feedback: 'Guessing can lead to misinformation. It is better to '
              'connect them with someone who knows.',
        ),
        HandbookOption(
          label: 'Ask them to call back later',
          isCorrect: false,
          feedback: 'Asking a guest to call back risks losing them. Find '
              'help while they are on the line.',
        ),
        HandbookOption(
          label: 'Ask to place them on hold and find the right person',
          isCorrect: true,
          feedback: 'Correct! Ask politely if you can place them on hold, '
              'then connect them with someone who can help.',
        ),
      ],
    ),
    HandbookUnit(
      id: 'wp_checkpoint',
      type: HandbookUnitType.checkpoint,
      title: 'Check Your Knowledge',
      badgeHint: 'CHECK',
      body: 'When are staff permitted to order food during a shift?',
      options: [
        HandbookOption(
          label: 'After the first 3 hours, and only while on break',
          isCorrect: true,
          feedback: 'Correct! No food orders in the first 3 hours, and you '
              'must be on break to consume a meal.',
        ),
        HandbookOption(
          label: 'Any time during a slow period',
          isCorrect: false,
          feedback: 'The 3-hour rule and break requirement apply regardless '
              'of how busy it is.',
        ),
        HandbookOption(
          label: 'Only before the shift starts',
          isCorrect: false,
          feedback: 'The policy allows ordering after 3 hours while on '
              'break, not only before the shift.',
        ),
      ],
    ),
  ],
);

// ---- Chapter 4: Conduct & Teamwork --------------------------------------

const _chapterConductAndTeamwork = HandbookChapter(
  id: 'conduct_teamwork',
  title: 'Conduct & Teamwork',
  subtitle: 'Standards, appearance, and working together',
  iconCodePoint: 0xea21, // Icons.groups
  units: [
    HandbookUnit(
      id: 'ct_code',
      type: HandbookUnitType.explainer,
      title: 'Code of Conduct',
      badgeHint: 'CONDUCT',
      body: 'Barrio Legado fosters an environment of mutual respect and '
          'courtesy. Our Code of Conduct outlines the behaviors and practices '
          'expected of every team member, and violations can lead to '
          'disciplinary action including termination.\n\n'
          'We maintain zero tolerance for theft, harassment, violence, '
          'intoxication at work, insubordination, and safety violations. '
          'These standards exist to protect everyone in our familia.',
    ),
    HandbookUnit(
      id: 'ct_behaviour',
      type: HandbookUnitType.explainer,
      title: 'Employee Behaviour',
      badgeHint: 'STANDARDS',
      body: 'Professional conduct is expected at all times, both on and off '
          'the floor. You represent the Barrio Legado brand in every '
          'interaction, so carry yourself with pride and intention.\n\n'
          'Treat all guests and coworkers with dignity and respect. The way '
          'you conduct yourself directly shapes the guest experience and the '
          'culture of our team.',
    ),
    HandbookUnit(
      id: 'ct_teamwork',
      type: HandbookUnitType.explainer,
      title: 'Teamwork',
      badgeHint: 'TEAMWORK',
      body: '"That is not my job" has no place in hospitality. Flexibility '
          'and cooperation are the foundation of efficient service at Barrio '
          'Legado. Each team member should be ready to take on any reasonable '
          'task to keep operations running smoothly.\n\n'
          'Anticipate your teammates\' needs and step in to help before being '
          'asked. When the team wins, everyone wins.',
    ),
    HandbookUnit(
      id: 'ct_communication',
      type: HandbookUnitType.explainer,
      title: 'Communication',
      badgeHint: 'COMMS',
      body: 'Brand success is built on relationships, and every interaction '
          '-- whether with guests, teammates, or management -- matters. Open '
          'and honest communication is the standard at Barrio Legado.\n\n'
          'Consistency across all touchpoints strengthens the brand. Whether '
          'you are greeting a guest, briefing the team, or resolving a '
          'concern, communicate with clarity and respect.',
    ),
    HandbookUnit(
      id: 'ct_appearance',
      type: HandbookUnitType.explainer,
      title: 'Personal Appearance',
      badgeHint: 'UNIFORM',
      body: 'Dress, grooming, and personal cleanliness standards contribute '
          'to team morale and our business image. Management reserves the '
          'right to send home any employee not properly dressed or groomed.\n\n'
          'Servers wear a Barrio Legado branded dress shirt with dark pants. '
          'Fragrances must be light so as not to overpower wine aromas. Nails '
          'should be neat and trimmed, facial hair well-groomed, and hair '
          'clean and styled.',
    ),
    HandbookUnit(
      id: 'ct_social_media',
      type: HandbookUnitType.explainer,
      title: 'Social Media Policy',
      badgeHint: 'SOCIAL',
      body: 'Exercise sound judgment when posting on social media, both '
          'during and outside work hours. Communications that are insulting, '
          'demeaning, or offensive to Barrio Legado will not be tolerated.\n\n'
          'Remember that your online activities reflect upon the organization. '
          'Protect the brand\'s reputation in every post, comment, and share.',
    ),
    HandbookUnit(
      id: 'ct_decision',
      type: HandbookUnitType.decision,
      title: 'Teamwork Scenario',
      badgeHint: 'DECIDE',
      body: 'During a busy Friday dinner rush, you notice a coworker is '
          'falling behind on their section and tables are waiting. What do '
          'you do?',
      options: [
        HandbookOption(
          label: 'Focus on your own section -- it is their responsibility',
          isCorrect: false,
          feedback: '"That is not my job" has no place in hospitality. '
              'Flexibility and cooperation are key to efficient service.',
        ),
        HandbookOption(
          label: 'Step in and help with their tables without being asked',
          isCorrect: true,
          feedback: 'Correct! Anticipating teammates\' needs and stepping in '
              'to help is exactly what teamwork at Barrio Legado looks like.',
        ),
        HandbookOption(
          label: 'Tell a manager so they can deal with it',
          isCorrect: false,
          feedback: 'Escalating without helping first misses the point. The '
              'team should support each other directly during a rush.',
        ),
      ],
    ),
    HandbookUnit(
      id: 'ct_checkpoint',
      type: HandbookUnitType.checkpoint,
      title: 'Check Your Knowledge',
      badgeHint: 'CHECK',
      body: 'Why must fragrances be kept light at Barrio Legado?',
      options: [
        HandbookOption(
          label: 'To avoid triggering guest allergies',
          isCorrect: false,
          feedback: 'Allergies are a concern, but the primary reason is '
              'related to the dining experience itself.',
        ),
        HandbookOption(
          label: 'Because management prefers a neutral scent',
          isCorrect: false,
          feedback: 'It is not a personal preference. There is a specific '
              'operational reason tied to our service.',
        ),
        HandbookOption(
          label: 'So they do not overpower wine aromas for guests',
          isCorrect: true,
          feedback: 'Correct! Strong fragrances can interfere with guests\' '
              'ability to enjoy the wine experience, which is central to '
              'our service.',
        ),
      ],
    ),
  ],
);

// ---- Chapter 5: Health & Safety ------------------------------------------

const _chapterHealthAndSafety = HandbookChapter(
  id: 'health_safety',
  title: 'Health & Safety',
  subtitle: 'Your safety, rights, and emergency procedures',
  iconCodePoint: 0xe305, // Icons.health_and_safety
  units: [
    HandbookUnit(
      id: 'hs_statement',
      type: HandbookUnitType.explainer,
      title: 'Health & Safety Statement',
      badgeHint: 'SAFETY',
      body: 'Barrio Legado is committed to a robust safety program that '
          'safeguards the well-being of staff, protects property, and ensures '
          'the public is shielded from workplace accidents.\n\n'
          'Everyone shares the responsibility to create a safe workspace. '
          'Make reasonable efforts to protect your own health and safety, '
          'cooperate with your employer and coworkers, and always use required '
          'PPE and safety devices.',
    ),
    HandbookUnit(
      id: 'hs_rights',
      type: HandbookUnitType.explainer,
      title: 'Employee Rights',
      badgeHint: 'RIGHTS',
      body: 'You have three fundamental rights under health and safety law: '
          'the right to know about hazards, the right to participate in H&S '
          'decisions, and the right to refuse unsafe work.\n\n'
          'To refuse unsafe work, follow the three-step procedure: first '
          'report the concern to your supervisor, then the OHS committee '
          'investigates, and if unresolved, the OHS Division steps in. You '
          'must never carry out work where imminent danger exists.',
    ),
    HandbookUnit(
      id: 'hs_emergency',
      type: HandbookUnitType.explainer,
      title: 'Emergency Procedures',
      badgeHint: 'EMERGENCY',
      body: 'Know your evacuation routes, exit signs, and the location of '
          'your muster station before an emergency happens. The fire alarm '
          'system, emergency lighting, and portable fire extinguishers are '
          'inspected regularly to ensure readiness.\n\n'
          'The kitchen is equipped with a fire suppression system. In any '
          'emergency, follow established procedures, stay calm, and account '
          'for all team members at the muster station.',
    ),
    HandbookUnit(
      id: 'hs_food_safety',
      type: HandbookUnitType.explainer,
      title: 'Food Safety',
      badgeHint: 'FOOD',
      body: 'Food safety at Barrio Legado centers on three pillars: '
          'temperature control, cross-contamination prevention, and proper '
          'food handling techniques.\n\n'
          'Always monitor holding temperatures, keep raw and cooked items '
          'separated, and follow handwashing protocols. These practices '
          'protect our guests and uphold the standards our brand is built on.',
    ),
    HandbookUnit(
      id: 'hs_whmis',
      type: HandbookUnitType.explainer,
      title: 'WHMIS',
      badgeHint: 'WHMIS',
      body: 'WHMIS -- the Workplace Hazardous Materials Information System '
          '-- teaches you to recognize hazardous materials through supplier '
          'labels, workplace labels, and standardized pictograms.\n\n'
          'Every hazardous product must have a Safety Data Sheet (SDS) '
          'available. Learn the hazard groups and classes, understand how '
          'chemicals can enter and harm the body, and never use a product '
          'without reading its label first.',
    ),
    HandbookUnit(
      id: 'hs_harassment',
      type: HandbookUnitType.explainer,
      title: 'Harassment Prevention',
      badgeHint: 'POLICY',
      body: 'Barrio Legado is committed to a workplace free from harassment. '
          'Our policy clearly defines prohibited conduct and outlines the '
          'complaint procedure, which includes confidentiality protections '
          'and a strict non-retaliation commitment.\n\n'
          'Managers are responsible for maintaining a respectful environment, '
          'and every employee is responsible for reporting concerns. All '
          'complaints are investigated and corrective action is taken.',
    ),
    HandbookUnit(
      id: 'hs_violence',
      type: HandbookUnitType.explainer,
      title: 'Violence Prevention',
      badgeHint: 'PREVENT',
      body: 'Our violence prevention policy covers prohibited conduct, '
          'domestic violence awareness, and complaint procedures. Any form of '
          'violence or threat of violence in the workplace is taken seriously '
          'and addressed immediately.\n\n'
          'If you witness or experience a violent incident, follow the '
          'complaint procedure and report it to management. Your safety and '
          'the safety of your coworkers is the top priority.',
    ),
    HandbookUnit(
      id: 'hs_decision',
      type: HandbookUnitType.decision,
      title: 'Safety Scenario',
      badgeHint: 'DECIDE',
      body: 'You notice a coworker handling cleaning chemicals without the '
          'required gloves. What should you do?',
      options: [
        HandbookOption(
          label: 'Remind them to put on gloves and report the hazard',
          isCorrect: true,
          feedback: 'Correct! Everyone is responsible for safety. Remind '
              'your coworker directly and report the hazard so it is '
              'documented and addressed.',
        ),
        HandbookOption(
          label: 'Ignore it -- they probably know what they are doing',
          isCorrect: false,
          feedback: 'Ignoring a safety violation puts your coworker at risk. '
              'You have a responsibility to speak up and report hazards '
              'immediately.',
        ),
        HandbookOption(
          label: 'Wait until after the shift and mention it casually',
          isCorrect: false,
          feedback: 'Waiting creates unnecessary exposure to harm. Safety '
              'concerns must be addressed immediately, not after the fact.',
        ),
      ],
    ),
    HandbookUnit(
      id: 'hs_checkpoint',
      type: HandbookUnitType.checkpoint,
      title: 'Check Your Knowledge',
      badgeHint: 'CHECK',
      body: 'What are the three fundamental employee rights under health '
          'and safety law?',
      options: [
        HandbookOption(
          label: 'Right to breaks, right to overtime pay, right to vacation',
          isCorrect: false,
          feedback: 'Those are employment rights, not health and safety '
              'rights. The three H&S rights focus on hazard awareness, '
              'participation, and refusal of unsafe work.',
        ),
        HandbookOption(
          label: 'Right to know, right to participate, right to refuse '
              'unsafe work',
          isCorrect: true,
          feedback: 'Correct! These three rights ensure you can identify '
              'hazards, have a voice in safety decisions, and refuse work '
              'that poses imminent danger.',
        ),
        HandbookOption(
          label: 'Right to PPE, right to first aid, right to compensation',
          isCorrect: false,
          feedback: 'While PPE and first aid are important, the three '
              'fundamental rights are: right to know, right to participate, '
              'and right to refuse unsafe work.',
        ),
      ],
    ),
  ],
);
