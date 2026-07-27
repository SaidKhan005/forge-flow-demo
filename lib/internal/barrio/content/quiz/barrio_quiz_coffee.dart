// Chapter-end quiz bank for the Coffee Training manual.
//
// DATA ONLY. Source manual: lib/.../training/training_coffee_content.dart
// (doc id 'training_coffee'). Every question is answerable from the
// verbatim text of the single card named in `sourceUnitId`. See
// barrio_quiz_models.dart for the authoring contract.
//
// OPERATOR REVIEW REQUIRED: new training content, drafts until read.

import 'barrio_quiz_models.dart';

const BarrioQuizBank kBarrioQuizCoffee = BarrioQuizBank(
  docId: 'training_coffee',
  questions: <BarrioQuizQuestion>[
    // ---- Chapter c0: What Is Coffee -------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c0_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c0',
      prompt: 'What are the two most prized coffee species for consumption?',
      options: <String>[
        'Arabica and Robusta',
        'Liberica and Excelsa',
        'Blonde and Dark',
        'Colombian and Brazilian',
      ],
      correctIndex: 0,
      whyLine: 'The two most prized coffee species for consumption are Arabica '
          'and Robusta.',
      sourceUnitId: 'training_coffee_c0_u0',
      answerEvidence: 'Arabica and Robusta',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c0_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c0',
      prompt: 'Coffee acts as a stimulant because of which component?',
      options: <String>[
        'Its caffeine content',
        'Its sugar content',
        'Its water content',
        'Its fibre content',
      ],
      correctIndex: 0,
      whyLine: 'Coffee is a central nervous system stimulant because of its '
          'caffeine content.',
      sourceUnitId: 'training_coffee_c0_u0',
      answerEvidence: 'due to its caffeine content',
    ),

    // ---- Chapter c1: Roasting -------------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c1_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c1',
      prompt: 'What happens to caffeine content as coffee beans are roasted?',
      options: <String>[
        'It gradually decreases',
        'It gradually increases',
        'It stays exactly the same',
        'It disappears completely',
      ],
      correctIndex: 0,
      whyLine: 'As beans are roasted, the caffeine content gradually '
          'decreases.',
      sourceUnitId: 'training_coffee_c1_u0',
      answerEvidence: 'the caffeine content gradually decreases',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c1_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c1',
      prompt: 'Which roast is particularly well-suited for espresso '
          'extraction?',
      options: <String>[
        'Medium dark roast',
        'Blonde roast',
        'Green, unroasted beans',
        'Instant coffee',
      ],
      correctIndex: 0,
      whyLine: 'Medium dark roast is particularly well-suited for espresso '
          'extraction thanks to its balanced taste and velvety crema.',
      sourceUnitId: 'training_coffee_c1_u1',
      answerEvidence: 'particularly well-suited for espresso extraction',
    ),

    // ---- Chapter c2: Enemies of Coffee ----------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c2_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c2',
      prompt: 'What are the four main enemies of coffee freshness?',
      options: <String>[
        'Oxygen, moisture, heat, and light',
        'Salt, sugar, acid, and fat',
        'Water, milk, sugar, and ice',
        'Time, pressure, altitude, and soil',
      ],
      correctIndex: 0,
      whyLine: 'The four main enemies of coffee freshness are oxygen, '
          'moisture, heat, and light.',
      sourceUnitId: 'training_coffee_c2_u0',
      answerEvidence: 'oxygen, moisture, heat, and light',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c2_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c2',
      prompt: 'When is coffee at its prime freshness?',
      options: <String>[
        'Immediately after grinding',
        'One week after grinding',
        'After it has been stored in the fridge',
        'Only once it is brewed',
      ],
      correctIndex: 0,
      whyLine: 'Coffee is at its prime immediately after grinding, when '
          'volatile oils are released.',
      sourceUnitId: 'training_coffee_c2_u0',
      answerEvidence: 'coffee is at its prime immediately after grinding',
    ),

    // ---- Chapter c3: Proper Storage -------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c3_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c3',
      prompt: 'For best freshness, should you buy whole beans or pre-ground '
          'coffee?',
      options: <String>[
        'Whole beans',
        'Pre-ground coffee',
        'Instant coffee',
        'Coffee pods',
      ],
      correctIndex: 0,
      whyLine: 'Buying whole beans instead of pre-ground coffee ensures '
          'maximum freshness and flavor retention.',
      sourceUnitId: 'training_coffee_c3_u0',
      answerEvidence: 'purchase whole beans instead of pre-ground varieties',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c3_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c3',
      prompt: 'Where should coffee beans be stored?',
      options: <String>[
        'In a cool, dry, dark, airtight container away from sunlight',
        'In the refrigerator',
        'On a sunny windowsill',
        'In an open bowl on the counter',
      ],
      correctIndex: 0,
      whyLine: 'Store beans in a cool, dry, dark, airtight container away from '
          'direct sunlight, and avoid the fridge.',
      sourceUnitId: 'training_coffee_c3_u0',
      answerEvidence: 'cool, dry, and dark environment, ideally in an airtight container away from direct sunlight',
    ),

    // ---- Chapter c4: Brazilian Coffee -----------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c4_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c4',
      prompt: 'Which country is the world\'s leading coffee producer?',
      options: <String>[
        'Brazil',
        'Colombia',
        'Ethiopia',
        'Vietnam',
      ],
      correctIndex: 0,
      whyLine: 'Brazil has been the leading coffee producer in the world since '
          '1840.',
      sourceUnitId: 'training_coffee_c4_u0',
      answerEvidence: 'Brazil stands as the world\'s leading coffee producer',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c4_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c4',
      prompt: 'Since what year has Brazil held the title of leading coffee '
          'producer?',
      options: <String>[
        'Since 1840',
        'Since 1920',
        'Since 1750',
        'Since 2000',
      ],
      correctIndex: 0,
      whyLine: 'Brazil has held the title of leading coffee producer since '
          '1840.',
      sourceUnitId: 'training_coffee_c4_u0',
      answerEvidence: 'since 1840',
    ),

    // ---- Chapter c5: Colombian Coffee -----------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c5_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c5',
      prompt: 'Where does Colombia rank in global coffee production?',
      options: <String>[
        'Third globally',
        'First globally',
        'Tenth globally',
        'Second globally',
      ],
      correctIndex: 0,
      whyLine: 'Colombia ranks third globally in annual coffee production.',
      sourceUnitId: 'training_coffee_c5_u0',
      answerEvidence: 'Colombia ranks third globally',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c5_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c5',
      prompt: 'In 2011, what recognition did UNESCO give Colombia\'s Coffee '
          'Cultural Landscape?',
      options: <String>[
        'A World Heritage Site',
        'The world\'s largest coffee farm',
        'A protected wildlife reserve',
        'An Olympic venue',
      ],
      correctIndex: 0,
      whyLine: 'In 2011, UNESCO recognized the Colombian Coffee Cultural '
          'Landscape as a World Heritage Site.',
      sourceUnitId: 'training_coffee_c5_u1',
      answerEvidence: 'UNESCO recognized Colombia\'s Coffee Cultural Landscape in the Andean foothills as a World Heritage Site',
    ),

    // ---- Chapter c6: Extracting Espresso --------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c6_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c6',
      prompt: 'About how long should a full espresso shot take to extract?',
      options: <String>[
        'Around 25 seconds',
        'Around 5 seconds',
        'Around 60 seconds',
        'Around 3 minutes',
      ],
      correctIndex: 0,
      whyLine: 'A well-balanced espresso has a total extraction time of around '
          '25 seconds.',
      sourceUnitId: 'training_coffee_c6_u0',
      answerEvidence: 'a total extraction time of around 25 seconds',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c6_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c6',
      prompt: 'Why is tamping described as a crucial step?',
      options: <String>[
        'It applies firm, even pressure for uniform extraction',
        'It heats the water to boiling',
        'It grinds the beans finer',
        'It cleans the group head',
      ],
      correctIndex: 0,
      whyLine: 'Tamping applies firm and even pressure to form a flat surface '
          'that ensures uniform extraction.',
      sourceUnitId: 'training_coffee_c6_u0',
      answerEvidence: 'apply firm and even pressure to form a solid, flat surface that ensures uniform extraction',
    ),

    // ---- Chapter c7: Milk -----------------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c7_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c7',
      prompt: 'What temperature should milk be heated to when steaming?',
      options: <String>[
        '65 to 70 degrees Celsius',
        '90 to 100 degrees Celsius',
        '40 to 45 degrees Celsius',
        '30 to 35 degrees Celsius',
      ],
      correctIndex: 0,
      whyLine: 'When steaming milk, aim for a temperature of 65 to 70 degrees '
          'Celsius.',
      sourceUnitId: 'training_coffee_c7_u0',
      answerEvidence: '65-70 degrees Celsius',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c7_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c7',
      prompt: 'How full should the milk jug be for optimal frothing?',
      options: <String>[
        'About one-third full',
        'Completely full',
        'About three-quarters full',
        'Just a splash at the bottom',
      ],
      correctIndex: 0,
      whyLine: 'Fill the milk jug to about one-third to ensure optimal '
          'frothing.',
      sourceUnitId: 'training_coffee_c7_u0',
      answerEvidence: 'about one-third to ensure optimal frothing',
    ),

    // ---- Chapter c8: Troubleshooting ------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c8_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c8',
      prompt: 'What can cause an under-extracted espresso?',
      options: <String>[
        'You run out of coffee, or the grind is too coarse',
        'A grind that is too fine',
        'Overfilling the basket',
        'Water that is too hot',
      ],
      correctIndex: 0,
      whyLine: 'An under-extracted espresso can occur if you run out of coffee '
          'or the grind is too coarse.',
      sourceUnitId: 'training_coffee_c8_u0',
      answerEvidence: 'if you run out of coffee or if the grind is too course',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c8_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c8',
      prompt: 'What are signs of an over-extracted espresso?',
      options: <String>[
        'It drips slowly, is very dark, has no crema, and tastes burnt',
        'It flows very quickly and tastes weak',
        'It is pale and watery',
        'It has extra crema and tastes sweet',
      ],
      correctIndex: 0,
      whyLine: 'An over-extracted espresso drips slowly, is very dark, has no '
          'crema, and tastes sharp and burnt.',
      sourceUnitId: 'training_coffee_c8_u0',
      answerEvidence: 'drip slowly and will be very dark with almost no coffee coming out of the spout and no crema',
    ),

    // ---- Chapter c9: Cleaning & Maintenance -----------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c9_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c9',
      prompt: 'How long should steam arms be immersed in warm water to soften '
          'milk residue?',
      options: <String>[
        'No longer than 10 minutes',
        'For at least one hour',
        'Overnight',
        'For a full day',
      ],
      correctIndex: 0,
      whyLine: 'Immerse steam arms in warm water for no longer than 10 '
          'minutes, and never soak them overnight.',
      sourceUnitId: 'training_coffee_c9_u0',
      answerEvidence: 'no longer than 10 minutes',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c9_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c9',
      prompt: 'During group head back flushing, what replaces the filter '
          'basket?',
      options: <String>[
        'A blind disk',
        'A paper filter',
        'A second filter basket',
        'A metal scoop',
      ],
      correctIndex: 0,
      whyLine: 'During back flushing, the filter basket is replaced with a '
          'blind disk.',
      sourceUnitId: 'training_coffee_c9_u1',
      answerEvidence: 'replace it with a blind disk',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c9_q2',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c9',
      prompt: 'How should filter baskets be cleaned according to the handles '
          'section?',
      options: <String>[
        'Regularly soak them in hot, soapy water',
        'Once a year',
        'Only when they break',
        'Never, they are self-cleaning',
      ],
      correctIndex: 0,
      whyLine: 'Regularly remove the filter baskets and soak them in hot, '
          'soapy water.',
      sourceUnitId: 'training_coffee_c9_u0',
      answerEvidence: 'soak them in hot, soapy water',
    ),

    // ---- Chapter c10: Drinks --------------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c10_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c10',
      prompt: 'How is a Short Black prepared?',
      options: <String>[
        'Extract a double shot of espresso into an espresso cup',
        'Pour espresso over a cup of hot water',
        'Steam milk into a tall glass',
        'Add cold milk to a single shot',
      ],
      correctIndex: 0,
      whyLine: 'A Short Black is a double shot of espresso extracted into an '
          'espresso cup.',
      sourceUnitId: 'training_coffee_c10_u0',
      answerEvidence: 'extract double shot of espresso into an espresso cup',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c10_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c10',
      prompt: 'What distinguishes the milk texture of a flat white?',
      options: <String>[
        'Smooth and velvety milk with minimal froth',
        'Thick, heavily frothed milk',
        'Cold, unsteamed milk',
        'No milk at all',
      ],
      correctIndex: 0,
      whyLine: 'A flat white uses smooth, velvety milk with minimal froth.',
      sourceUnitId: 'training_coffee_c10_u1',
      answerEvidence: 'smooth and velvety with minimal froth',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c10_q2',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c10',
      prompt: 'What tops a cappuccino?',
      options: <String>[
        'A dome of foam that rises above the rim',
        'A layer of cold water',
        'A scoop of ice cream',
        'A shot of espresso poured on top',
      ],
      correctIndex: 0,
      whyLine: 'A cappuccino is finished with a dome of foam that rises above '
          'the rim.',
      sourceUnitId: 'training_coffee_c10_u2',
      answerEvidence: 'a delightful dome of foam that rises above the rim',
    ),

    // ---- Chapter c11: Our Coffee ----------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c11_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c11',
      prompt: 'Where is the Base Camp espresso coffee sourced from?',
      options: <String>[
        'The Las Rosas Women\'s Coffee Project in La Plata, Colombia',
        'A large corporate farm in Brazil',
        'A cooperative in Ethiopia',
        'A plantation in Vietnam',
      ],
      correctIndex: 0,
      whyLine: 'Base Camp is sourced from the Las Rosas Women\'s Coffee '
          'Project in La Plata, Colombia.',
      sourceUnitId: 'training_coffee_c11_u0',
      answerEvidence: 'Las Rosas Women\'s Coffee Project',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c11_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c11',
      prompt: 'Which of our coffees is the decaf option?',
      options: <String>[
        'Sleeper Cabin',
        'Base Camp',
        'Bird with No Name',
        'Las Rosas',
      ],
      correctIndex: 0,
      whyLine: 'Sleeper Cabin is the decaf Colombian coffee.',
      sourceUnitId: 'training_coffee_c11_u1',
      answerEvidence: 'SLEEPER CABIN - DECAF',
    ),

    // ---- Chapter c12: Cup Types -----------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c12_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c12',
      prompt: 'Which three cup types are shown on the cup-reference page?',
      options: <String>[
        'Espresso cup, cappuccino cup, and coffee mug',
        'Teacup, mug, and glass',
        'Espresso cup, latte glass, and travel mug',
        'Shot glass, tumbler, and bowl',
      ],
      correctIndex: 0,
      whyLine: 'The cup-reference page shows an espresso cup, a cappuccino '
          'cup, and a coffee mug.',
      sourceUnitId: 'training_coffee_c12_u0',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c12_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c12',
      prompt: 'Which cup type is listed for serving a cappuccino?',
      options: <String>[
        'The cappuccino cup',
        'The espresso cup',
        'The coffee mug',
        'A shot glass',
      ],
      correctIndex: 0,
      whyLine: 'A cappuccino is served in a cappuccino cup, one of the three '
          'listed cup types.',
      sourceUnitId: 'training_coffee_c12_u0',
      answerEvidence: 'CAPPUCCINO CUP',
    ),

    // ---- Chapter c13: Words to Know -------------------------------------
    BarrioQuizQuestion(
      id: 'training_coffee_c13_q0',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c13',
      prompt: 'Approximately what share of global coffee production does '
          'Arabica account for?',
      options: <String>[
        'Approximately 60%',
        'Approximately 10%',
        'Approximately 90%',
        'Approximately 40%',
      ],
      correctIndex: 0,
      whyLine: 'Arabica accounts for approximately 60% of global coffee '
          'production.',
      sourceUnitId: 'training_coffee_c13_u0',
      answerEvidence: 'approximately 60% of global production',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c13_q1',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c13',
      prompt: 'What is crema?',
      options: <String>[
        'The golden-brown foam on top of an espresso',
        'The metal filter that holds coffee',
        'A type of milk froth for lattes',
        'The ground coffee puck',
      ],
      correctIndex: 0,
      whyLine: 'Crema is the golden-brown foam on top of an espresso.',
      sourceUnitId: 'training_coffee_c13_u1',
      answerEvidence: 'The golden-brown foam on top of an espresso',
    ),
    BarrioQuizQuestion(
      id: 'training_coffee_c13_q2',
      docId: 'training_coffee',
      chapterId: 'training_coffee_c13',
      prompt: 'Compared with Arabica, how much caffeine does Robusta contain?',
      options: <String>[
        'Nearly double the caffeine of Arabica',
        'About half the caffeine of Arabica',
        'The same caffeine as Arabica',
        'No caffeine at all',
      ],
      correctIndex: 0,
      whyLine: 'Robusta boasts nearly double the caffeine content of Arabica '
          'coffee.',
      sourceUnitId: 'training_coffee_c13_u5',
      answerEvidence: 'nearly double the caffeine content of Arabica coffee',
    ),
  ],
);
