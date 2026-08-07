// Per-CARD key phrases for the General Words To Know glossary (doc id
// 'training_general_words'), authored against the LIVE card bodies in
// `../../training/training_general_words_content.dart`.
//
// WHAT A GLOSSARY CARD NEEDS. Every card here defines one term, and the
// term is already the card's TITLE. So the phrases never restate the
// term; they carry the part of the definition a server acts on: what
// the thing is, when it is called out, and what it changes on the
// floor. On CHIT that is 'prints on a slip of paper', not 'chit'.
//
// Every phrase below is a unique, whole-word, non-overlapping substring
// of THAT card's own body, carries no digit, and sits inside one
// rendered chunk. Each of those is a SILENT failure at render time, not
// an error: the key-term tier is the lowest of five
// (`handbook_lesson_card.dart` `_composeChunk`), so a phrase that
// overlaps a numeric pop or an answer span is dropped whole and shows
// nothing, and a phrase that does not match simply never lights up.
// That is why the check runs before the data ships, never after.
//
// PARTIAL COVERAGE IS THE POINT. This doc has no per-manual fallback
// list (`barrio_key_terms.dart` does not register it), so a card with
// no entry here highlights nothing at all, exactly as it did before
// this data landed. Twenty-four of the ninety-two cards are one short
// sentence ('BOH: Refers to the kitchen team.') and cannot carry three
// non-overlapping phrases that teach anything; they carry NO entry
// rather than a padded set. A thin set is worse than none.
//
// See `barrio_card_keys_index.dart` for the full authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingGeneralWords =
    <String, List<String>>{
  // ---- c0: 8 to C ---------------------------------------------------
  'training_general_words_c0_u2': <String>[
    'menu featuring individually priced items',
    'select and order each dish separately',
    'rather than opting for a pre-set meal',
  ],
  'training_general_words_c0_u3': <String>[
    'Average guest check',
    'average amount a guest spends',
    'in the restaurant',
  ],
  'training_general_words_c0_u4': <String>[
    'the body\'s immune system sees a certain food as harmful',
    'reacts by triggering an allergic reaction',
    'their immune system mistakenly treats something in a particular food',
    'most often, the protein',
    'as if it\'s dangerous to them',
  ],
  'training_general_words_c0_u7': <String>[
    'employees call out',
    'let their co-worker know',
    'they are behind them',
    'often with full hands',
  ],
  'training_general_words_c0_u8': <String>[
    'comprehensive document',
    'outlines all critical details for an event',
    'including menus, setup arrangements, timelines, and guest lists',
    'a roadmap for staff',
    'ensure seamless execution of the occasion',
  ],
  'training_general_words_c0_u10': <String>[
    'unique identity of a company',
    'names, logos, designs, symbols, and the emotions they evoke',
    'a critical differentiator in the marketplace',
    'shapes guest perceptions and expectations',
    'builds loyalty through a holistic guest experience',
    'communicating quality and lifestyle beyond mere physical attributes',
  ],
  'training_general_words_c0_u11': <String>[
    'stay seated',
    'for a long period of time',
    'after they have finished their dining experience',
  ],
  // ---- c1: C to C ---------------------------------------------------
  'training_general_words_c1_u0': <String>[
    'An order put into the POS',
    'prints on a slip of paper',
    'called a ticket or a chit',
  ],
  'training_general_words_c1_u1': <String>[
    'a server takes multiple orders',
    'from different tables',
    'rings them in all at once',
  ],
  'training_general_words_c1_u2': <String>[
    'Removing used dishes, cutlery, glasses, and any leftover food',
    'emptying the table surface',
    'distinct from the subsequent cleaning step',
    'wiping or sanitizing the table',
  ],
  'training_general_words_c1_u3': <String>[
    'an employee closes at night',
    'comes in to open',
    'the next morning',
  ],
  'training_general_words_c1_u4': <String>[
    'complimentary item',
    'give an item away',
    'for free',
  ],
  'training_general_words_c1_u5': <String>[
    'fundamental, guiding beliefs and principles',
    'define an organization\'s culture',
    'direct employee behavior towards a shared mission',
    'an ethical compass',
    'from hiring practices to guest interactions',
    'creates alignment, accountability, and a strong, consistent workplace environment',
  ],
  'training_general_words_c1_u6': <String>[
    'employees call out',
    'coming around a corner',
    'potentially bump into another staff member',
  ],
  'training_general_words_c1_u7': <String>[
    'An individual dish or a collection of dishes presented together',
    'served in a sequential manner',
    'a short pause in between',
    'progression from lighter to heavier fare',
    'an appetizer, main dish, and dessert',
  ],
  'training_general_words_c1_u8': <String>[
    'the number of people reserved for the night',
    'the amount of guests',
    'expect to arrive for reservations',
  ],
  'training_general_words_c1_u9': <String>[
    'A tall table',
    'events and cocktail parties',
    'stand around',
  ],
  'training_general_words_c1_u10': <String>[
    'shared personality of an organization',
    'core values, beliefs, attitudes, and behaviors',
    'guide employee interactions and decision-making',
    'shapes the daily workplace experience',
    'both stated principles and unwritten rules',
    'nurturing a sense of belonging',
  ],
  'training_general_words_c1_u11': <String>[
    'management takes someone out of their regular duties',
    'do side duties',
    'clock out',
  ],
  // ---- c2: D to F ---------------------------------------------------
  'training_general_words_c2_u1': <String>[
    'sitting for too long',
    'without being delivered to the table',
    'its quality to be compromised',
    'no longer servable',
  ],
  'training_general_words_c2_u2': <String>[
    'end-of-shift reconciliation process',
    'submit the cash owed to the restaurant',
    'taking their total sales',
    'subtracting any credit card tips and payments received',
  ],
  'training_general_words_c2_u3': <String>[
    'two tables',
    'sat in a servers section back to back',
    'without allowing time in between',
    'greet the first table',
  ],
  'training_general_words_c2_u4': <String>[
    'overwhelmed by a significant workload',
    'an excessive number of tables, delayed orders, or insufficient staff',
    'hinder the ability to maintain efficient service',
    'chaotic conditions and heightened stress levels',
    'feelings of helplessness or anxiety',
  ],
  'training_general_words_c2_u5': <String>[
    'in charge of prepping the plates',
    'quality checking items',
    'ensuring accuracy before sending food to the guest',
  ],
  'training_general_words_c2_u6': <String>[
    'communal and casual dining atmosphere',
    'large platters and bowls of various dishes',
    'placed at the center of the table for sharing',
    'rather than serving individual meals',
    'sample a variety of flavors',
  ],
  'training_general_words_c2_u7': <String>[
    'stocked, used, and rotated',
    'stored the longest (first in) should be used/consumed first (first out)',
    'Newer products should be stored at the back',
    'moved to the front',
    'following best by and expiry dates',
  ],
  // ---- c3: G to M ---------------------------------------------------
  'training_general_words_c3_u0': <String>[
    'Added to a drink or dish',
    'after it\'s been made',
    'add something to the flavor profile or aroma',
    'enhance the drink\'s appearance',
  ],
  'training_general_words_c3_u1': <String>[
    'treated like our friends',
    'welcoming them into our space',
    'creating an experience for them',
    'someone we would recognize if we saw them again',
    'we do not refer to them as customers',
  ],
  'training_general_words_c3_u2': <String>[
    'rectifying errors and addressing guest complaints',
    'transform a negative dining experience into a positive one',
    'restore guest satisfaction, build trust',
    'promote repeat business',
    'demonstrating empathy, delivering sincere apologies',
    'taking immediate corrective action',
  ],
  'training_general_words_c3_u3': <String>[
    'given by the expo or kitchen',
    'the food is ready',
    'brought to the guest',
  ],
  'training_general_words_c3_u6': <String>[
    'transcends mere functionality',
    'fostering an emotional connection and a welcoming atmosphere',
    'anticipating unspoken needs',
    'building relationships and weaving care into every interaction',
    'transforming routine encounters into memorable experiences',
  ],
  'training_general_words_c3_u7': <String>[
    'crucial safety alert',
    'navigating a busy area',
    'carrying hot food, liquids, plates, or equipment',
  ],
  'training_general_words_c3_u8': <String>[
    'so busy that you have fallen behind',
    'may not be able to catch up',
    'service quality taking a hit',
  ],
  'training_general_words_c3_u9': <String>[
    'heated area located between the kitchen and the service area',
    'chefs place completed dishes',
    'ready for servers to collect',
  ],
  'training_general_words_c3_u11': <String>[
    'Merging two partially filled bottles or containers of the same product',
    'into a single, full container',
    'reduce waste and maximize usage',
    'items that have a long shelf life',
    'salt, ketchup, and spices',
  ],
  // ---- c4: M to P ---------------------------------------------------
  'training_general_words_c4_u1': <String>[
    'everything in its place',
    'organizing and preparing all ingredients and components necessary for cooking',
    'preparation and arrangement of the dining area and service stations',
    'prior to the arrival of guests',
  ],
  'training_general_words_c4_u2': <String>[
    'concise declaration of a company\'s fundamental purpose',
    'why it exists, what it does, who it serves, and how it operates',
    'guiding decisions, motivating employees',
    'informing stakeholders about its core values, culture, and objectives',
  ],
  'training_general_words_c4_u3': <String>[
    'based on its current cost in the market',
    'often seen with seafood items',
    'subject to change',
    'availability, seasonality and market fluctuations',
  ],
  'training_general_words_c4_u5': <String>[
    'a valuable gauge of guest loyalty',
    'recommending their dining experience to others',
    'categorize responses into three groups',
    'The resulting score reflects overall guest satisfaction',
    'establish a feedback loop',
    'boost guest retention',
  ],
  'training_general_words_c4_u6': <String>[
    'An event',
    'at a location outside of the restaurant',
    'still managed by the restaurant team',
  ],
  'training_general_words_c4_u7': <String>[
    'a dish or drink',
    'needed immediately',
    'the original order was wrong, unsatisfactory, or spilled',
  ],
  'training_general_words_c4_u8': <String>[
    'The amount of guests',
    'have a menu',
    'have not ordered yet',
  ],
  'training_general_words_c4_u10': <String>[
    'multiple servers all serving the same group',
    'rang in under a party card instead of an individual server',
    'access to ring in orders and take payments',
  ],
  'training_general_words_c4_u11': <String>[
    'chefs showcase finished dishes for inspection, garnishing, and final handoff to servers',
    'a crucial control checkpoint between the BOH and the FOH',
    'overseen by an expeditor or head chef',
    'components from different stations are meticulously assembled for final plating',
    'highest standards of consistency and quality',
  ],
  // ---- c5: P to R ---------------------------------------------------
  'training_general_words_c5_u0': <String>[
    'Pay At The Table',
    'the machine used to process',
    'debit and credit card payments',
  ],
  'training_general_words_c5_u2': <String>[
    'chefs often use the term',
    'communicate to their team',
    'a dish is ready for completion',
  ],
  'training_general_words_c5_u3': <String>[
    'A service charge when guests bring their own food',
    'such as a birthday cake',
    'cover costs related to cleaning, providing tableware, and labour costs for staff efforts',
  ],
  'training_general_words_c5_u4': <String>[
    'hand-drying and cleaning items right after washing',
    'eliminating water spots, streaks, fingerprints, and lint',
    'linens or steam techniques',
    'a streak-free, sparkling finish',
    'pristine and sanitary presentation',
  ],
  'training_general_words_c5_u5': <String>[
    'Point of Sale',
    'the machine where orders are rang in',
    'staff clock in and out',
  ],
  'training_general_words_c5_u6': <String>[
    'fixed price',
    'curated multi-course meal available at a set cost',
    'an appetizer, entree, and dessert',
    'select from a limited menu for each course',
    'popular during holidays and special occasions',
  ],
  'training_general_words_c5_u7': <String>[
    'Quality Service Assurance',
    'the code supervisors and management use',
    'discounting a bill',
    'ensure the guest leaves happy',
  ],
  'training_general_words_c5_u8': <String>[
    'A frequent visitor to a dining establishment',
    'stopping by weekly or monthly',
    'a familiar face to the staff',
    'sitting in their favorite spots and ordering signature dishes',
    'cultivate relationships with the front-of-house team',
  ],
  'training_general_words_c5_u9': <String>[
    'recreating a dish or beverage',
    'the initially prepared item',
    'unsatisfactory, incorrect, or spoiled',
  ],
  'training_general_words_c5_u10': <String>[
    'A form employers must issue',
    'an interruption of earnings',
    'Service Canada uses to determine EI eligibility, benefit amounts, and duration',
  ],
  // ---- c6: S to T ---------------------------------------------------
  'training_general_words_c6_u0': <String>[
    'designated section of tables',
    'assigned to a specific server during their shift',
    'streamline service',
    'organized and efficient',
  ],
  'training_general_words_c6_u1': <String>[
    'a new employee follows a senior employee',
    'receive training',
    'see how the role is performed',
  ],
  'training_general_words_c6_u2': <String>[
    'A vital safety alert',
    'moving behind others while carrying knives or other sharp, hazardous tools',
    'help prevent accidents and injuries in a busy environment',
  ],
  'training_general_words_c6_u3': <String>[
    'All tasks',
    'secondary to the guest experience',
    'cleaning, prep work, and stocking',
  ],
  'training_general_words_c6_u5': <String>[
    'Wasted items',
    'cannot be sold',
    'spilled, wasted, spoiled, or even returned',
  ],
  'training_general_words_c6_u7': <String>[
    'A series of actions and interactions',
    'servers perform',
    'a seamless dining experience for guests',
  ],
  'training_general_words_c6_u9': <String>[
    'An official tax document',
    'employment income and deductions for the year',
    'accurately complete personal income tax returns',
  ],
  'training_general_words_c6_u10': <String>[
    'efficiently serving guests and clearing tables',
    'a prompt reset for new patrons',
    'maximizing guest capacity and revenue during peak hours',
    'balancing the quality of the dining experience with operational speed',
  ],
  'training_general_words_c6_u11': <String>[
    'array of software, applications, and hardware',
    'streamline its operations',
    'the digital backbone',
    'point-of-sale transactions, inventory management, reservations, online ordering, marketing, and staff scheduling',
    'the modern evolution of a single cash register',
    'integrating multiple systems to enhance efficiency',
  ],
  // ---- c7: T to W ---------------------------------------------------
  'training_general_words_c7_u0': <String>[
    'where bacteria multiply the quickest',
    'the range you want to keep food out of',
    'keep hot foods hot and cold foods cold',
  ],
  'training_general_words_c7_u1': <String>[
    'employees merge all or part of their individual tips',
    'distributing them among the team according to a predetermined formula',
    'promote teamwork',
    'all team members who enhance the guest experience are fairly compensated',
  ],
  'training_general_words_c7_u3': <String>[
    'The rate at which employees exit a business',
    'voluntary resignation or involuntary separation',
    'measured as a percentage over a specific timeframe',
    'significant costs, service disruptions, and potential declines in morale',
    'demanding work environments and inadequate compensation',
  ],
  'training_general_words_c7_u4': <String>[
    'manage and organize guest wait times',
    'all tables are occupied',
    'parties still waiting to be seated',
  ],
  'training_general_words_c7_u5': <String>[
    'spacious, insulated storage facility',
    'built to commercial standards',
    'maintain consistent and safe temperatures for perishable goods',
  ],
};
