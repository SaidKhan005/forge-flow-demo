// Typed content model and data for the Interview Playbook.
//
// All content here is translated from the Barrio Legado interview
// playbook PDF into native structured data. This is a guided,
// visual, step-by-step learning surface for managers and supervisors.
//
// Source: docs/internal/barrio/interview_playbook.pdf

// ---------------------------------------------------------------------------
// Content model
// ---------------------------------------------------------------------------

enum PlaybookUnitType { guide, scenario, checkpoint }

class PlaybookOption {
  final String label;
  final bool isCorrect;
  final String feedback;
  const PlaybookOption({
    required this.label,
    required this.isCorrect,
    required this.feedback,
  });
}

class PlaybookUnit {
  final String id;
  final PlaybookUnitType type;
  final String title;
  final String body;
  final List<PlaybookOption> options;
  final String? badgeHint;
  const PlaybookUnit({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.options = const [],
    this.badgeHint,
  });
}

class PlaybookSection {
  final String id;
  final String title;
  final String subtitle;
  final int iconCodePoint;
  final List<PlaybookUnit> units;
  const PlaybookSection({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.iconCodePoint,
    required this.units,
  });
}

// ---------------------------------------------------------------------------
// Content data -- translated from source PDF
// ---------------------------------------------------------------------------

const List<PlaybookSection> playbookSections = [
  _sectionHiringPrinciples,
  _sectionHiringFlow,
  _sectionGreenRedFlags,
  _sectionPositionQuestions,
];

// ---- Section 1: Hiring Principles ----------------------------------------

const _sectionHiringPrinciples = PlaybookSection(
  id: 'hiring_principles',
  title: 'Hiring Principles',
  subtitle: 'Building the dream team with intention',
  iconCodePoint: 0xf06be, // Icons.handshake
  units: [
    PlaybookUnit(
      id: 'hp_intro',
      type: PlaybookUnitType.guide,
      badgeHint: 'PRINCIPLES',
      title: 'Hire With Intention',
      body: 'At Barrio Legado, the real challenges in recruitment stem from '
          'unclear expectations and hasty decisions, not a shortage of '
          'candidates.\n\n'
          'We are not just looking for someone with a shiny resume. We want '
          'people who resonate with our core values, enhance our culture, '
          'and are eager to grow alongside us.',
    ),
    PlaybookUnit(
      id: 'hp_what_to_look_for',
      type: PlaybookUnitType.guide,
      badgeHint: 'QUALITIES',
      title: 'What to Look For',
      body: 'Look for long-term potential, not just current skillset:\n\n'
          '- Curiosity, humility, and eagerness to grow -- skills can be '
          'taught, willingness cannot\n'
          '- Composure under pressure -- change exposes character\n'
          '- Coachability -- ability to accept and act on feedback\n'
          '- Warmth and positive demeanor',
    ),
    PlaybookUnit(
      id: 'hp_interview_principles',
      type: PlaybookUnitType.guide,
      badgeHint: 'TECHNIQUE',
      title: 'Interview Principles',
      body: '- Be fully present and actively listen\n'
          '- Ask follow-up questions for deeper insight\n'
          '- Do not follow a script -- let it flow naturally\n'
          '- Have different people conduct different stages to minimize bias\n'
          '- Use the same set of questions to evaluate candidates fairly\n'
          '- Encourage genuine conversation\n'
          '- Explain position expectations clearly\n'
          '- Take detailed notes\n'
          '- Allow silences to observe composure',
    ),
    PlaybookUnit(
      id: 'hp_scenario',
      type: PlaybookUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'Interview Scenario',
      body: 'A candidate gives polished, rehearsed-sounding answers to every '
          'question. They sound great on paper. What is the best next step?',
      options: [
        PlaybookOption(
          label: 'Ask follow-up questions to dig deeper into specifics',
          isCorrect: true,
          feedback: 'Correct! Follow-up questions reveal whether a candidate '
              'has real experience or just polished delivery. Look for '
              'ownership over actions and specific stories.',
        ),
        PlaybookOption(
          label: 'Accept the answers -- they clearly prepared well',
          isCorrect: false,
          feedback: 'Rehearsed answers can mask real character. The playbook '
              'says to look for real, specific stories and genuine emotion.',
        ),
        PlaybookOption(
          label: 'End the interview early -- rehearsed answers are a red flag',
          isCorrect: false,
          feedback: 'Some candidates prepare thoroughly. Use follow-ups to '
              'determine whether the depth is real before deciding.',
        ),
      ],
    ),
    PlaybookUnit(
      id: 'hp_checkpoint',
      type: PlaybookUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'According to the playbook, what matters more when evaluating '
          'a candidate?',
      options: [
        PlaybookOption(
          label: 'Their current skillset and experience',
          isCorrect: false,
          feedback: 'Skills can be taught. The playbook emphasizes looking '
              'for curiosity, resilience, coachability, and mindset.',
        ),
        PlaybookOption(
          label: 'Years of restaurant experience',
          isCorrect: false,
          feedback: 'Experience helps, but the playbook prioritizes mindset, '
              'coachability, and cultural alignment over tenure.',
        ),
        PlaybookOption(
          label: 'Signs of long-term potential and mindset',
          isCorrect: true,
          feedback: 'Correct! The playbook says to "recognize the signals '
              'of long-term potential, not just their current skillset."',
        ),
      ],
    ),
  ],
);

// ---- Section 2: The Hiring Flow ------------------------------------------

const _sectionHiringFlow = PlaybookSection(
  id: 'hiring_flow',
  title: 'The Hiring Flow',
  subtitle: 'Stage-by-stage evaluation process',
  iconCodePoint: 0xe2b9, // Icons.format_list_numbered
  units: [
    PlaybookUnit(
      id: 'hf_overview',
      type: PlaybookUnitType.guide,
      badgeHint: 'STAGES',
      title: 'Five Stages of Evaluation',
      body: 'The hiring flow uses a variety of contact methods to spotlight '
          'different traits at each stage:\n\n'
          '1. Resume Review -- evaluate experience, job history frequency, '
          'teamwork activities, and presentation\n'
          '2. Pre-Screen -- quick call or professional email; evaluate '
          'professionalism, tone, and curiosity\n'
          '3. Interview -- conversation-driven; evaluate core values, '
          'emotional intelligence, and composure\n'
          '4. Optional Second Interview -- position-based; evaluate '
          'problem-solving, initiative, and team chemistry\n'
          '5. Decision -- use the red/green flag method; evaluate long-term '
          'value, mindset, and alignment',
    ),
    PlaybookUnit(
      id: 'hf_prescreen',
      type: PlaybookUnitType.guide,
      badgeHint: 'PRE-SCREEN',
      title: 'Pre-Screen Questions',
      body: 'During the pre-screen call, cover these key areas:\n\n'
          '- "What do you look for in a good employer?"\n'
          '- "What kind of environment brings out your best work?"\n'
          '- "Do you have any questions about the position?"\n'
          '- "What is your availability? How many shifts are you looking for?"\n\n'
          'Note green and red flags. Check social media for professionalism '
          'before moving forward.',
    ),
    PlaybookUnit(
      id: 'hf_general_questions',
      type: PlaybookUnitType.guide,
      badgeHint: 'QUESTIONS',
      title: 'Core Interview Questions',
      body: 'These questions are used across all positions:\n\n'
          '- "What is your interest in coming to work with us?"\n'
          '- "What is your favourite quality about yourself?"\n'
          '- "Which of our core values resonates the most with you? Why?"\n'
          '- "Walk me through the last time you completely screwed something '
          'up. What happened and what did you do about it?"\n'
          '- "What is the hardest piece of feedback you have ever received? '
          'How did you overcome it?"',
    ),
    PlaybookUnit(
      id: 'hf_scenario',
      type: PlaybookUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'Pre-Screen Scenario',
      body: 'You are pre-screening a candidate by phone. They sound friendly '
          'but never ask a single question about the company or the role. '
          'What does this signal?',
      options: [
        PlaybookOption(
          label: 'They are nervous -- give them another chance in person',
          isCorrect: false,
          feedback: 'Nerves are possible, but lack of curiosity is a red '
              'flag. The playbook says to look for genuine interest in the '
              'business and team.',
        ),
        PlaybookOption(
          label: 'Low curiosity about the role -- a red flag to note',
          isCorrect: true,
          feedback: 'Correct! "Shows curiosity about the business and team" '
              'is listed as a green flag. Absence of it is a concern worth '
              'noting before the next stage.',
        ),
        PlaybookOption(
          label: 'It does not matter -- the in-person interview is what counts',
          isCorrect: false,
          feedback: 'Each stage evaluates different traits. Pre-screens '
              'specifically check tone, professionalism, and curiosity.',
        ),
      ],
    ),
    PlaybookUnit(
      id: 'hf_checkpoint',
      type: PlaybookUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'Why does the hiring flow use different people at different '
          'stages?',
      options: [
        PlaybookOption(
          label: 'To share the workload evenly',
          isCorrect: false,
          feedback: 'Workload sharing is a side benefit, but the primary '
              'reason is to minimize bias in evaluation.',
        ),
        PlaybookOption(
          label: 'To test whether the candidate is consistent',
          isCorrect: false,
          feedback: 'Consistency may be observed, but the playbook '
              'specifically calls out bias reduction as the reason.',
        ),
        PlaybookOption(
          label: 'To minimize bias in the evaluation process',
          isCorrect: true,
          feedback: 'Correct! Having different people at different stages '
              'reduces individual bias and gives a more well-rounded view '
              'of each candidate.',
        ),
      ],
    ),
  ],
);

// ---- Section 3: Green & Red Flags (scaffolded) ---------------------------

const _sectionGreenRedFlags = PlaybookSection(
  id: 'green_red_flags',
  title: 'Green & Red Flags',
  subtitle: 'Recognizing signals during interviews',
  iconCodePoint: 0xe28e, // Icons.flag
  units: [
    PlaybookUnit(
      id: 'grf_green',
      type: PlaybookUnitType.guide,
      badgeHint: 'GREEN',
      title: 'Green Flags',
      body: 'Positive signals that suggest a strong candidate:\n\n'
          '- Real, specific stories with ownership over actions\n'
          '- Natural pauses and a calm tone\n'
          '- Shows curiosity about the business and team\n'
          '- Genuine emotion and a pattern of positive behaviour\n'
          '- Open to being challenged\n'
          '- Appreciates different working styles\n'
          '- Has self-regulation strategies for multi-tasking\n'
          '- Sees opportunities, not burdens',
    ),
    PlaybookUnit(
      id: 'grf_red',
      type: PlaybookUnitType.guide,
      badgeHint: 'RED',
      title: 'Red Flags',
      body: 'Warning signals that suggest a poor fit:\n\n'
          '- Vague or rehearsed answers\n'
          '- Places blame or gives excuses\n'
          '- Defensive or passive-aggressive\n'
          '- Focus on money, perks, or shortcuts\n'
          '- Entitlement or unrealistic expectations\n'
          '- Lacks self-awareness\n'
          '- Speaks poorly about others\n'
          '- Views others\' needs as an annoyance',
    ),
    PlaybookUnit(
      id: 'grf_gut',
      type: PlaybookUnitType.guide,
      badgeHint: 'INSTINCT',
      title: 'Trust Your Instincts',
      body: 'The playbook is clear: "If you walk out of an interview feeling '
          'unsure about a candidate, it is a no."\n\n'
          'Trust that gut feeling. Great candidates do not make you question '
          'your instincts.',
    ),
    PlaybookUnit(
      id: 'grf_scenario',
      type: PlaybookUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'Flag Scenario',
      body: 'A candidate speaks poorly about their previous manager but has '
          'strong technical skills. What does the playbook advise?',
      options: [
        PlaybookOption(
          label: 'Note it as a red flag and weigh it in the decision',
          isCorrect: true,
          feedback: 'Correct! "Speaks poorly about others" is listed as a '
              'red flag. The playbook emphasizes using the red/green flag '
              'method for the final decision.',
        ),
        PlaybookOption(
          label: 'Hire them -- skills are hard to find',
          isCorrect: false,
          feedback: 'Speaking poorly about others is a clear red flag. '
              'Skills can be taught, but attitude is harder to change.',
        ),
        PlaybookOption(
          label: 'Overlook it if the rest of the interview is strong',
          isCorrect: false,
          feedback: 'One strong area does not cancel a red flag. The playbook '
              'says to weigh all signals using the red and green flag method '
              'in the final decision.',
        ),
      ],
    ),
    PlaybookUnit(
      id: 'grf_checkpoint',
      type: PlaybookUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'A candidate shares a specific story about recovering from a '
          'service mistake, taking full ownership and describing what they '
          'learned. What kind of signal is this?',
      options: [
        PlaybookOption(
          label: 'Neutral -- everyone has mistakes in their past',
          isCorrect: false,
          feedback: 'The signal is not the mistake itself but how they '
              'describe it. Ownership and genuine learning are clear green flags.',
        ),
        PlaybookOption(
          label: 'A green flag -- real stories with ownership show character',
          isCorrect: true,
          feedback: 'Correct. The playbook lists "real, specific stories with '
              'ownership over actions" as a top green flag.',
        ),
        PlaybookOption(
          label: 'A red flag -- admitting mistakes shows poor judgement',
          isCorrect: false,
          feedback: 'Owning mistakes is a sign of maturity and self-awareness. '
              'The playbook lists "places blame or gives excuses" as the red '
              'flag, not honest reflection.',
        ),
      ],
    ),
  ],
);

// ---- Section 4: Position-Based Questions ---------------------------------

const _sectionPositionQuestions = PlaybookSection(
  id: 'position_questions',
  title: 'Position-Based Questions',
  subtitle: 'Tailored questions by role',
  iconCodePoint: 0xe0c8, // Icons.badge
  units: [
    PlaybookUnit(
      id: 'pq_overview',
      type: PlaybookUnitType.guide,
      badgeHint: 'OVERVIEW',
      title: 'Why Position-Specific Questions Matter',
      body: 'Each role at Barrio Legado carries unique pressures and '
          'priorities. A host navigates guest emotions at the door, a line '
          'cook manages timing and precision under heat, and a server '
          'balances hospitality with multitasking.\n\n'
          'Tailored questions reveal how candidates think under role-specific '
          'conditions. General questions uncover character; position-based '
          'questions uncover competence and instinct for the job itself.',
    ),
    PlaybookUnit(
      id: 'pq_host',
      type: PlaybookUnitType.guide,
      badgeHint: 'HOST',
      title: 'Host Interview Questions',
      body: 'Use these questions when interviewing for the Host position:\n\n'
          '1. What is something you are proud of that won\'t show up on a '
          'resume?\n'
          '2. Who is someone that you admire? Why?\n'
          '3. Can you tell me about a time where your communication skills '
          'solved a conflict?\n'
          '4. How would you handle a situation where a guest demands to be '
          'seated right away even though there is a one hour wait?\n'
          '5. A table arrives 30 minutes late for their reservation, but you '
          'have already given the table away. What do you do?\n'
          '6. A guest calls you over to complain about their experience. '
          'What do you do?',
    ),
    PlaybookUnit(
      id: 'pq_sa',
      type: PlaybookUnitType.guide,
      badgeHint: 'ASSIST',
      title: 'Server Assistant Interview Questions',
      body: 'Use these questions when interviewing for the Server Assistant '
          'position:\n\n'
          '1. What is something you are proud of that won\'t show up on a '
          'resume?\n'
          '2. Who is someone that you admire? Why?\n'
          '3. Tell me about a time when you had to follow strict guidelines '
          'or procedures. How did you ensure you were following them '
          'correctly?\n'
          '4. How do you decide what to prioritize when you have multiple '
          'tasks?\n'
          '5. Tell me about a time when you kept going even though you were '
          'overwhelmed.\n'
          '6. A guest calls you over to complain about their experience. '
          'What do you do?',
    ),
    PlaybookUnit(
      id: 'pq_bartender',
      type: PlaybookUnitType.guide,
      badgeHint: 'BAR',
      title: 'Bartender Interview Questions',
      body: 'Use these questions when interviewing for the Bartender '
          'position:\n\n'
          '1. You notice a regular looks upset but they haven\'t complained. '
          'You are slammed. What do you do?\n'
          '2. What was the best dining experience you ever had? What did '
          'they do differently?\n'
          '3. Our busiest, most chaotic shift is happening. Everything is '
          'going wrong. What do you need from me as your manager in that '
          'moment?\n'
          '4. Food, service, and atmosphere are the three pillars of '
          'hospitality. What do you think is the most important? Why?\n'
          '5. Tell me about your previous manager. What made them great and '
          'what made them difficult? What did you learn from them?\n'
          '6. What is your favourite classic cocktail?',
    ),
    PlaybookUnit(
      id: 'pq_server',
      type: PlaybookUnitType.guide,
      badgeHint: 'SERVER',
      title: 'Server Interview Questions',
      body: 'Use these questions when interviewing for the Server '
          'position:\n\n'
          '1. What is the difference between service and hospitality?\n'
          '2. What is the best dining experience you ever had? What did the '
          'restaurant do differently?\n'
          '3. Tell me about your previous manager. What made them great and '
          'difficult? What did you learn?\n'
          '4. Our busiest, most chaotic shift. Everything going wrong. What '
          'do you need from me as your manager?\n'
          '5. You have food at the pass, a table that needs to be greeted, '
          'and a table waiting to pay. What do you do?\n'
          '6. Tell me about a time when you went above and beyond for a '
          'guest.',
    ),
    PlaybookUnit(
      id: 'pq_dish',
      type: PlaybookUnitType.guide,
      badgeHint: 'DISH',
      title: 'Dishwasher Interview Questions',
      body: 'Use these questions when interviewing for the Dishwasher '
          'position:\n\n'
          '1. What is something you are proud of that won\'t show up on a '
          'resume?\n'
          '2. Who is someone that you admire? Why?\n'
          '3. Tell me about a time when you had to follow strict guidelines '
          'or procedures.\n'
          '4. How do you decide what to prioritize when you have multiple '
          'tasks?\n'
          '5. How do you stay focused and careful while maintaining '
          'efficiency?\n'
          '6. Tell me about a time a coworker took their frustrations out '
          'on you. How did you handle it?',
    ),
    PlaybookUnit(
      id: 'pq_line',
      type: PlaybookUnitType.guide,
      badgeHint: 'LINE',
      title: 'Line Cook Interview Questions',
      body: 'Use these questions when interviewing for the Line Cook '
          'position:\n\n'
          '1. What is your favourite station to work? Why?\n'
          '2. What do you do when you run out of ingredients for a dish '
          'that has already been ordered?\n'
          '3. How do you maintain a positive attitude when confronting long '
          'days, menu changes, or unexpected delays?\n'
          '4. What is your process for an order with an allergy?\n'
          '5. Our busiest, most chaotic shift. Everything going wrong. What '
          'do you need from me as your manager?\n'
          '6. What chefs do you look to for inspiration? Who is the most '
          'influential chef you worked for?',
    ),
    PlaybookUnit(
      id: 'pq_scenario',
      type: PlaybookUnitType.scenario,
      badgeHint: 'SCENARIO',
      title: 'Position Question Scenario',
      body: 'You are interviewing a candidate for the Server position. They '
          'give a strong answer about hospitality but struggle when asked '
          'how they would prioritize food at the pass versus greeting a new '
          'table. What should you take away?',
      options: [
        PlaybookOption(
          label: 'Their hospitality answer is enough -- prioritization '
              'can be trained',
          isCorrect: false,
          feedback: 'Hospitality mindset is important, but servers face '
              'constant prioritization pressure. Position-specific questions '
              'exist to test exactly this kind of instinct.',
        ),
        PlaybookOption(
          label: 'Ask a different question -- that one was too hard',
          isCorrect: false,
          feedback: 'The question is designed to reveal real thinking under '
              'pressure. Switching to an easier question defeats the purpose '
              'of position-based evaluation.',
        ),
        PlaybookOption(
          label: 'Note the gap -- strong character but may need coaching '
              'on floor awareness',
          isCorrect: true,
          feedback: 'Correct! Position-based questions surface role-specific '
              'readiness. A gap here does not disqualify, but it should be '
              'noted so you can plan coaching if you hire them.',
        ),
      ],
    ),
    PlaybookUnit(
      id: 'pq_checkpoint',
      type: PlaybookUnitType.checkpoint,
      badgeHint: 'CHECK',
      title: 'Check Your Understanding',
      body: 'Why does the playbook include different interview questions for '
          'each position?',
      options: [
        PlaybookOption(
          label: 'Each role has unique pressures that general questions '
              'cannot fully reveal',
          isCorrect: true,
          feedback: 'Correct! A host managing wait times, a cook handling '
              'allergies, and a server juggling tables all face different '
              'challenges. Tailored questions expose role-specific instinct.',
        ),
        PlaybookOption(
          label: 'To make the interview longer and more thorough',
          isCorrect: false,
          feedback: 'Length is not the goal. The playbook uses position-based '
              'questions to test competence and instinct for the specific '
              'role, not to extend the interview.',
        ),
        PlaybookOption(
          label: 'To give experienced candidates an advantage',
          isCorrect: false,
          feedback: 'The playbook values potential over experience. '
              'Position-based questions test how candidates think, not '
              'whether they already know the answers.',
        ),
      ],
    ),
  ],
);
