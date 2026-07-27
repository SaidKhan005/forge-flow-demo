// Chapter-end quiz bank for the Food Safety Manual.
//
// DATA ONLY. Source manual: lib/.../training/training_food_safety_content.dart
// (doc id 'training_food_safety'). Every question is answerable from the
// verbatim text of the single card named in `sourceUnitId`. See
// barrio_quiz_models.dart for the authoring contract.
//
// OPERATOR REVIEW REQUIRED: new training content, drafts until read.

import 'barrio_quiz_models.dart';

const BarrioQuizBank kBarrioQuizFoodSafety = BarrioQuizBank(
  docId: 'training_food_safety',
  questions: <BarrioQuizQuestion>[
    // ---- Chapter c0: What Is Food Safety --------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c0_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c0',
      prompt: 'What are the 4 C\'s of food safety?',
      options: <String>[
        'Cleaning, cross-contamination prevention, cooking, and chilling',
        'Cleaning, cooling, cutting, and canning',
        'Cooking, chilling, chopping, and covering',
        'Cleaning, cross-contamination prevention, chopping, and canning',
      ],
      correctIndex: 0,
      whyLine: 'The 4 C\'s of food safety are cleaning, cross-contamination '
          'prevention, cooking, and chilling.',
      sourceUnitId: 'training_food_safety_c0_u1',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c0_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c0',
      prompt: 'In a restaurant, who is responsible for upholding food safety '
          'standards?',
      options: <String>[
        'Each team member',
        'Only the head chef',
        'Only the manager on duty',
        'Only the health inspector',
      ],
      correctIndex: 0,
      whyLine: 'In a restaurant setting, each team member plays a vital role '
          'in upholding food safety standards.',
      sourceUnitId: 'training_food_safety_c0_u0',
      answerEvidence: 'each team member plays a vital role',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c0_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c0',
      prompt: 'In the Chilling step, perishable food should be kept below what '
          'temperature?',
      options: <String>[
        'Below 40 degrees Fahrenheit (4 degrees Celsius)',
        'Below 60 degrees Fahrenheit (16 degrees Celsius)',
        'Below 50 degrees Fahrenheit (10 degrees Celsius)',
        'Below 32 degrees Fahrenheit (0 degrees Celsius)',
      ],
      correctIndex: 0,
      whyLine: 'Chilling means keeping perishable food below 40 degrees '
          'Fahrenheit, which is 4 degrees Celsius.',
      sourceUnitId: 'training_food_safety_c0_u1',
      answerEvidence: 'below 40 degrees Fahrenheit (4 degrees Celsius)',
    ),

    // ---- Chapter c1: Governing Laws And Regulations ---------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c1_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c1',
      prompt: 'Which two federal bodies are primarily responsible for food '
          'safety standards in Canada?',
      options: <String>[
        'The Canadian Food Inspection Agency (CFIA) and Health Canada',
        'The FDA and the USDA',
        'The World Health Organization and Health Canada',
        'The CFIA and the provincial health ministry',
      ],
      correctIndex: 0,
      whyLine: 'At the federal level, the Canadian Food Inspection Agency and '
          'Health Canada set and enforce food safety standards.',
      sourceUnitId: 'training_food_safety_c1_u0',
      answerEvidence: 'Canadian Food Inspection Agency (CFIA) and Health Canada',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c1_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c1',
      prompt: 'Roughly how many Canadians become ill each year from foodborne '
          'pathogens?',
      options: <String>[
        'Approximately 1 in 8 Canadians',
        'Approximately 1 in 100 Canadians',
        'Approximately 1 in 3 Canadians',
        'Approximately 1 in 50 Canadians',
      ],
      correctIndex: 0,
      whyLine: 'Statistics indicate that approximately 1 in 8 Canadians '
          'becomes ill each year from foodborne pathogens.',
      sourceUnitId: 'training_food_safety_c1_u1',
      answerEvidence: 'approximately 1 in 8 Canadians',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c1_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c1',
      prompt: 'Who holds the legal liability for food safety in a food service '
          'operation?',
      options: <String>[
        'The owner, operator, and person in charge',
        'Only the public health inspector',
        'Only the federal government',
        'Every guest who dines there',
      ],
      correctIndex: 0,
      whyLine: 'The legal liability for food safety lies with the owner, '
          'operator, and person in charge.',
      sourceUnitId: 'training_food_safety_c1_u1',
      answerEvidence: 'the owner, operator, and person in charge',
    ),

    // ---- Chapter c2: Personal Hygiene -----------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c2_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c2',
      prompt: 'How long should you scrub your hands during handwashing?',
      options: <String>[
        'At least 20 seconds',
        'At least 5 seconds',
        'About 1 minute',
        'Until they feel warm',
      ],
      correctIndex: 0,
      whyLine: 'Scrub hands thoroughly for at least 20 seconds, including '
          'backs of hands, between fingers, and under fingernails.',
      sourceUnitId: 'training_food_safety_c2_u1',
      answerEvidence: 'at least 20 seconds',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c2_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c2',
      prompt: 'How often should disposable gloves be changed at minimum?',
      options: <String>[
        'A minimum of every 4 hours',
        'Once per shift',
        'Every 8 hours',
        'Only when they look dirty',
      ],
      correctIndex: 0,
      whyLine: 'Change gloves a minimum of every 4 hours, and whenever moving '
          'from raw to ready-to-eat food.',
      sourceUnitId: 'training_food_safety_c2_u4',
      answerEvidence: 'Change gloves a minimum of every 4 hours',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c2_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c2',
      prompt: 'Do gloves replace the need for handwashing?',
      options: <String>[
        'No, gloves do not replace handwashing because small holes and tears can occur',
        'Yes, wearing gloves means you never need to wash your hands',
        'Yes, as long as the gloves are brand new',
        'Only handwashing is needed if the gloves tear',
      ],
      correctIndex: 0,
      whyLine: 'Gloves do not replace handwashing because small holes and '
          'tears can let bacteria escape.',
      sourceUnitId: 'training_food_safety_c2_u4',
      answerEvidence: 'gloves DO NOT replace handwashing',
    ),

    // ---- Chapter c3: Foodborne Illness ----------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c3_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c3',
      prompt: 'Foodborne illness is also commonly known as what?',
      options: <String>[
        'Food poisoning',
        'The common cold',
        'A food allergy',
        'Food intolerance',
      ],
      correctIndex: 0,
      whyLine: 'Foodborne illness is often referred to as food poisoning.',
      sourceUnitId: 'training_food_safety_c3_u0',
      answerEvidence: 'often referred to as food poisoning',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c3_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c3',
      prompt: 'Which of these is one of the most common symptoms of foodborne '
          'illness?',
      options: <String>[
        'Diarrhea',
        'A skin rash',
        'Hair loss',
        'Sneezing',
      ],
      correctIndex: 0,
      whyLine: 'The most common symptoms of foodborne illness include stomach '
          'cramps, nausea, vomiting, diarrhea, and fever.',
      sourceUnitId: 'training_food_safety_c3_u1',
      answerEvidence: 'Diarrhea',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c3_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c3',
      prompt: 'Which of these is listed among the top causes of foodborne '
          'illness?',
      options: <String>[
        'Improper cooling',
        'Eating too quickly',
        'Using a clean cutting board',
        'Washing your hands often',
      ],
      correctIndex: 0,
      whyLine: 'Improper cooling is listed among the top causes of foodborne '
          'illness.',
      sourceUnitId: 'training_food_safety_c3_u3',
      answerEvidence: 'Improper cooling',
    ),

    // ---- Chapter c4: Contamination --------------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c4_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c4',
      prompt: 'What are the two ways cross-contamination can occur?',
      options: <String>[
        'Direct contact and indirect transfer through a vehicle',
        'Only through direct physical contact',
        'Only through the air',
        'Freezing and thawing',
      ],
      correctIndex: 0,
      whyLine: 'Cross-contamination can occur directly through physical '
          'contact or indirectly through a vehicle that transfers '
          'contaminants.',
      sourceUnitId: 'training_food_safety_c4_u0',
      answerEvidence: 'direct cross-contamination happens when there is physical contact between a hazardous source and food, while indirect cross-contamination occurs through a vehicle',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c4_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c4',
      prompt: 'What does contamination introduce into food?',
      options: <String>[
        'Microbial, physical, chemical, or allergenic hazards',
        'Extra vitamins and minerals',
        'Only visible dirt',
        'Beneficial bacteria',
      ],
      correctIndex: 0,
      whyLine: 'Contamination is the unwanted presence of microbial, physical, '
          'chemical, or allergenic hazards in food.',
      sourceUnitId: 'training_food_safety_c4_u0',
      answerEvidence: 'microbial, physical, chemical, or allergenic hazards',
    ),

    // ---- Chapter c5: Categories of Hazards ------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c5_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c5',
      prompt: 'What is a hazard, as defined in this section?',
      options: <String>[
        'Anything in food with the potential to harm someone by causing illness or injury',
        'Only bacteria that you can see',
        'A food that tastes bad',
        'Any food served cold',
      ],
      correctIndex: 0,
      whyLine: 'A hazard is anything present in food with the potential to '
          'harm someone by causing illness or injury.',
      sourceUnitId: 'training_food_safety_c5_u0',
      answerEvidence: 'anything present in food with the potential to harm someone',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c5_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c5',
      prompt: 'Bacteria, viruses, and parasites are examples of which hazard '
          'category?',
      options: <String>[
        'Biological hazards',
        'Chemical hazards',
        'Physical hazards',
        'Allergenic hazards',
      ],
      correctIndex: 0,
      whyLine: 'Bacteria, viruses, and parasites are biological hazards that '
          'could cause foodborne illness.',
      sourceUnitId: 'training_food_safety_c5_u1',
      answerEvidence: 'Bacteria, viruses, or parasites that could cause foodborne illness',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c5_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c5',
      prompt: 'How can you protect food from physical hazards?',
      options: <String>[
        'Conduct regular visual inspections',
        'Store all food at room temperature',
        'Skip cleaning between tasks',
        'Remove all labels from containers',
      ],
      correctIndex: 0,
      whyLine: 'Protect food from physical hazards by conducting regular '
          'visual inspections.',
      sourceUnitId: 'training_food_safety_c5_u3',
      answerEvidence: 'Conducting regular visual inspections',
    ),

    // ---- Chapter c6: Hazards In Food ------------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c6_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c6',
      prompt: 'What is a food hazard?',
      options: <String>[
        'Any biological, chemical, or physical agent in food that can harm consumers',
        'Any food that has expired',
        'Only chemicals used for cleaning',
        'A food that is too spicy',
      ],
      correctIndex: 0,
      whyLine: 'A food hazard is any biological, chemical, or physical agent '
          'present in food that can potentially harm consumers.',
      sourceUnitId: 'training_food_safety_c6_u0',
      answerEvidence: 'any biological, chemical, or physical agent present in food that can potentially harm consumers',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c6_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c6',
      prompt: 'Which type of hazard accounts for most foodborne illnesses '
          'reported in Canada?',
      options: <String>[
        'Biological hazards',
        'Chemical hazards',
        'Physical hazards',
        'Radioactive hazards',
      ],
      correctIndex: 0,
      whyLine: 'Biological hazards account for most foodborne illnesses '
          'reported in Canada.',
      sourceUnitId: 'training_food_safety_c6_u1',
      answerEvidence: 'Biological hazards account for most foodborne illnesses',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c6_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c6',
      prompt: 'What should you do when you are unsure whether a food item is '
          'safe?',
      options: <String>[
        'When in doubt, throw it out',
        'Serve it anyway to avoid waste',
        'Taste a small amount to check',
        'Leave it out overnight and recheck',
      ],
      correctIndex: 0,
      whyLine: 'When in doubt about food safety, throw it out to prevent '
          'foodborne illness.',
      sourceUnitId: 'training_food_safety_c6_u6',
      answerEvidence: 'When in doubt, throw it out',
    ),

    // ---- Chapter c7: Food Allergies -------------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c7_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c7',
      prompt: 'What causes a food allergy?',
      options: <String>[
        'The immune system mistakenly treats a food protein as dangerous',
        'Eating too much of one food',
        'Food that has gone bad',
        'A lack of vitamins',
      ],
      correctIndex: 0,
      whyLine: 'A food allergy occurs when the immune system mistakenly treats '
          'a food protein as if it is dangerous.',
      sourceUnitId: 'training_food_safety_c7_u0',
      answerEvidence: 'immune system mistakenly treats something in a particular food',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c7_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c7',
      prompt: 'About what share of children have food allergies, according to '
          'the manual?',
      options: <String>[
        'An estimated 8% of children',
        'An estimated 25% of children',
        'An estimated 50% of children',
        'An estimated 1% of children',
      ],
      correctIndex: 0,
      whyLine: 'An estimated 8% of children and 4% of adults have food '
          'allergies.',
      sourceUnitId: 'training_food_safety_c7_u0',
      answerEvidence: 'An estimated 8% of children',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c7_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c7',
      prompt: 'Is there a cure for food allergies?',
      options: <String>[
        'No, there is no cure, though some children outgrow them',
        'Yes, a daily pill cures them',
        'Yes, they are cured by cooking food thoroughly',
        'No, and no one ever outgrows them',
      ],
      correctIndex: 0,
      whyLine: 'There is no cure for food allergies, though some children do '
          'outgrow them.',
      sourceUnitId: 'training_food_safety_c7_u0',
      answerEvidence: 'There is no cure for allergies, however, some children do outgrow them',
    ),

    // ---- Chapter c8: Food Allergies: Keep Your Guests Safe --------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c8_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c8',
      prompt: 'What are the "top eight" common food allergens?',
      options: <String>[
        'Peanuts, tree nuts, fish, shellfish, eggs, milk, wheat, and soy',
        'Corn, rice, beans, potato, tomato, garlic, onion, and pepper',
        'Chicken, beef, pork, lamb, duck, turkey, veal, and fish',
        'Apple, banana, orange, grape, melon, berry, peach, and plum',
      ],
      correctIndex: 0,
      whyLine: 'The top eight common food allergens are peanuts, tree nuts, '
          'fish, shellfish, eggs, milk, wheat, and soy.',
      sourceUnitId: 'training_food_safety_c8_u0',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c8_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c8',
      prompt: 'How often does a food allergy reaction send someone to the '
          'emergency room?',
      options: <String>[
        'Every 3 minutes',
        'Every 3 hours',
        'Once a day',
        'Once a week',
      ],
      correctIndex: 0,
      whyLine: 'Every 3 minutes, a food allergy reaction sends someone to the '
          'emergency room.',
      sourceUnitId: 'training_food_safety_c8_u0',
      answerEvidence: 'Every 3 minutes',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c8_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c8',
      prompt: 'At the first sign of an allergic reaction, what should you do?',
      options: <String>[
        'Call 911',
        'Offer the guest a glass of water and wait',
        'Move the guest outside for fresh air',
        'Ask the guest to drive themselves to a clinic',
      ],
      correctIndex: 0,
      whyLine: 'Call 911 at the first sign of an allergic reaction.',
      sourceUnitId: 'training_food_safety_c8_u1',
      answerEvidence: 'Call 911 at the first sign of a reaction',
    ),

    // ---- Chapter c9: Temperature Danger Zone ----------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c9_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c9',
      prompt: 'What is the temperature danger zone where bacteria thrive?',
      options: <String>[
        '40 to 140 degrees Fahrenheit (4 to 60 degrees Celsius)',
        '0 to 32 degrees Fahrenheit (-18 to 0 degrees Celsius)',
        '150 to 200 degrees Fahrenheit (66 to 93 degrees Celsius)',
        '20 to 40 degrees Fahrenheit (-6 to 4 degrees Celsius)',
      ],
      correctIndex: 0,
      whyLine: 'Bacteria thrive in the temperature danger zone, from 40 to '
          '140 degrees Fahrenheit, which is 4 to 60 degrees Celsius.',
      sourceUnitId: 'training_food_safety_c9_u0',
      answerEvidence: '40 to 140 degrees Fahrenheit (4 to 60 degrees Celsius)',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c9_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c9',
      prompt: 'How quickly can bacteria double in number in the danger zone?',
      options: <String>[
        'In as little as 20 minutes',
        'In about 12 hours',
        'In roughly 3 days',
        'In one week',
      ],
      correctIndex: 0,
      whyLine: 'In the temperature danger zone, bacteria can double in number '
          'in as little as 20 minutes.',
      sourceUnitId: 'training_food_safety_c9_u0',
      answerEvidence: 'double in number in as little as 20 minutes',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c9_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c9',
      prompt: 'How long can perishable items safely be left out of '
          'refrigeration?',
      options: <String>[
        'No longer than two hours',
        'No longer than six hours',
        'Up to a full day',
        'As long as they still smell fine',
      ],
      correctIndex: 0,
      whyLine: 'Perishable items should never be left out of refrigeration '
          'for longer than two hours.',
      sourceUnitId: 'training_food_safety_c9_u0',
      answerEvidence: 'never be left out of refrigeration for longer than two hours',
    ),

    // ---- Chapter c10: Temperature Danger Zone Reference -----------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c10_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c10',
      prompt: 'What is the refrigeration temperature range?',
      options: <String>[
        '0 degrees C to 4 degrees C',
        '4 degrees C to 60 degrees C',
        '57 degrees C and above',
        '0 degrees C to -18 degrees C',
      ],
      correctIndex: 0,
      whyLine: 'The refrigeration temperature range is 0 degrees C to 4 '
          'degrees C.',
      sourceUnitId: 'training_food_safety_c10_u0',
      answerEvidence: '0 degrees C - 4 degrees C',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c10_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c10',
      prompt: 'What is the hot-holding temperature for thoroughly cooked '
          'foods?',
      options: <String>[
        '57 degrees C and above',
        '40 degrees C and above',
        '21 degrees C and above',
        '74 degrees C and above',
      ],
      correctIndex: 0,
      whyLine: 'Hot-holding temperature for thoroughly cooked foods is 57 '
          'degrees C and above.',
      sourceUnitId: 'training_food_safety_c10_u0',
      answerEvidence: '57 degrees C and above',
    ),

    // ---- Chapter c11: Cooling And Reheating -----------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c11_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c11',
      prompt: 'In the two-step cooling method, cooked food must first cool '
          'from 57 degrees C to 21 degrees C within how long?',
      options: <String>[
        'Within 2 hours',
        'Within 6 hours',
        'Within 30 minutes',
        'Within 1 hour',
      ],
      correctIndex: 0,
      whyLine: 'In step one of the two-step cooling method, food must cool '
          'from 57 degrees C to 21 degrees C within 2 hours.',
      sourceUnitId: 'training_food_safety_c11_u2',
      answerEvidence: 'to 21 degrees C / 70 degrees F within 2 hours',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c11_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c11',
      prompt: 'What is the maximum total time allowed for the entire two-step '
          'cooling process?',
      options: <String>[
        'A maximum of 6 hours',
        'A maximum of 2 hours',
        'A maximum of 12 hours',
        'A maximum of 24 hours',
      ],
      correctIndex: 0,
      whyLine: 'The entire two-step cooling process must be completed within a '
          'maximum of 6 hours.',
      sourceUnitId: 'training_food_safety_c11_u2',
      answerEvidence: 'a maximum time of 6 hours',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c11_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c11',
      prompt: 'To what internal temperature should food be reheated?',
      options: <String>[
        'At least 165 degrees F (74 degrees C)',
        'At least 100 degrees F (38 degrees C)',
        'At least 140 degrees F (60 degrees C)',
        'At least 200 degrees F (93 degrees C)',
      ],
      correctIndex: 0,
      whyLine: 'When reheating, food should reach an internal temperature of '
          'at least 165 degrees F, which is 74 degrees C.',
      sourceUnitId: 'training_food_safety_c11_u3',
      answerEvidence: 'at least 165 degrees F (74 degrees C)',
    ),

    // ---- Chapter c12: Thermometer Calibration ---------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c12_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c12',
      prompt: 'An ice bath checks a thermometer against the freezing point of '
          'water. What temperature is that?',
      options: <String>[
        '32 degrees F (0 degrees C)',
        '40 degrees F (4 degrees C)',
        '100 degrees F (38 degrees C)',
        '0 degrees F (-18 degrees C)',
      ],
      correctIndex: 0,
      whyLine: 'An ice bath checks a thermometer against the freezing point '
          'of water, 32 degrees F or 0 degrees C.',
      sourceUnitId: 'training_food_safety_c12_u0',
      answerEvidence: '32.0 degrees F/0 degrees C',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c12_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c12',
      prompt: 'When creating an ice bath, what type of ice is ideal?',
      options: <String>[
        'Crushed ice',
        'A single large ice cube',
        'Shaved ice mixed with salt',
        'Dry ice',
      ],
      correctIndex: 0,
      whyLine: 'Crushed ice is ideal for an ice bath because it creates a '
          'denser, more consistent temperature.',
      sourceUnitId: 'training_food_safety_c12_u1',
      answerEvidence: 'Crushed ice is ideal',
    ),

    // ---- Chapter c13: Thermometer Ice Bath Calibration ------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c13_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c13',
      prompt: 'Why is crushed ice preferred when making a proper ice bath?',
      options: <String>[
        'There are fewer gaps between the ice',
        'It melts faster',
        'It is colder than cubed ice',
        'It floats better',
      ],
      correctIndex: 0,
      whyLine: 'Crushed ice is preferred because there are fewer gaps between '
          'the ice.',
      sourceUnitId: 'training_food_safety_c13_u0',
      answerEvidence: 'there are fewer gaps between the ice',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c13_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c13',
      prompt: 'In an ice bath, what should a correctly calibrated thermometer '
          'read?',
      options: <String>[
        '32 degrees F (0 degrees C)',
        '40 degrees F (4 degrees C)',
        '212 degrees F (100 degrees C)',
        '25 degrees F (-4 degrees C)',
      ],
      correctIndex: 0,
      whyLine: 'In an ice bath, a correctly calibrated thermometer should read '
          '32 degrees F, which is 0 degrees C.',
      sourceUnitId: 'training_food_safety_c13_u1',
      answerEvidence: '32 degrees F (0 degrees C)',
    ),

    // ---- Chapter c14: Safe Storage --------------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c14_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c14',
      prompt: 'In dry storage, how far off the floor should food be stored?',
      options: <String>[
        'At least 6 inches (15 cm) off the floor',
        'At least 1 inch off the floor',
        'Directly on the floor',
        'At least 24 inches off the floor',
      ],
      correctIndex: 0,
      whyLine: 'In dry storage, food should be kept at least 6 inches, or 15 '
          'cm, off the floor.',
      sourceUnitId: 'training_food_safety_c14_u0',
      answerEvidence: 'at least 6 inches (15 cm) off the floor',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c14_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c14',
      prompt: 'Where should raw meat, poultry, and fish be stored in the '
          'fridge?',
      options: <String>[
        'In sealed containers on the bottom shelf',
        'On the top shelf',
        'On the door shelves',
        'Next to ready-to-eat foods',
      ],
      correctIndex: 0,
      whyLine: 'Store raw meat, poultry, and fish in sealed containers on the '
          'bottom shelf to prevent drips onto other foods.',
      sourceUnitId: 'training_food_safety_c14_u1',
      answerEvidence: 'in sealed containers on the bottom shelf',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c14_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c14',
      prompt: 'What temperature should a refrigerator be kept at or below?',
      options: <String>[
        'At or below 40 degrees F (4 degrees C)',
        'At or below 60 degrees F (16 degrees C)',
        'At or below 55 degrees F (13 degrees C)',
        'At or below 70 degrees F (21 degrees C)',
      ],
      correctIndex: 0,
      whyLine: 'A refrigerator should be kept at or below 40 degrees F, which '
          'is 4 degrees C.',
      sourceUnitId: 'training_food_safety_c14_u1',
      answerEvidence: 'at or below 40 degrees F (4 degrees C)',
    ),

    // ---- Chapter c15: FIFO ----------------------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c15_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c15',
      prompt: 'What does FIFO stand for?',
      options: <String>[
        'First-In, First-Out',
        'Fresh-In, Fresh-Out',
        'Fast-In, Fast-Out',
        'Frozen-In, Frozen-Out',
      ],
      correctIndex: 0,
      whyLine: 'FIFO stands for First-In, First-Out, using the oldest stock '
          'before newer stock.',
      sourceUnitId: 'training_food_safety_c15_u0',
      answerEvidence: 'First-In, First-Out',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c15_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c15',
      prompt: 'Under FIFO, which items should be used first?',
      options: <String>[
        'The oldest items, with the earliest expiration dates',
        'The newest items',
        'The most expensive items',
        'Whatever is easiest to reach',
      ],
      correctIndex: 0,
      whyLine: 'Under FIFO, the oldest items, with the earliest expiration '
          'dates, are used before newer stock.',
      sourceUnitId: 'training_food_safety_c15_u0',
      answerEvidence: 'the oldest items are used or sold before newer stock',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c15_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c15',
      prompt: 'What is a common FIFO mistake to avoid?',
      options: <String>[
        'Restocking without proper rotation, with new items placed in front of older ones',
        'Labeling every item with a date',
        'Checking regularly for spoilage',
        'Storing food in sealed containers',
      ],
      correctIndex: 0,
      whyLine: 'A common FIFO mistake is restocking without proper rotation, '
          'placing new items in front of older ones.',
      sourceUnitId: 'training_food_safety_c15_u3',
      answerEvidence: 'restocking without proper rotation, where new items are placed in front of older ones',
    ),

    // ---- Chapter c16: Labelling -----------------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c16_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c16',
      prompt: 'What details should every food label include?',
      options: <String>[
        'Product name, prepared or defrosted date and time, use-by date, and staff initials',
        'Only the price of the product',
        'Only the product name',
        'The supplier phone number',
      ],
      correctIndex: 0,
      whyLine: 'Each label should include the product name, the date and time '
          'it was prepared or defrosted, the use-by date, and staff initials.',
      sourceUnitId: 'training_food_safety_c16_u2',
      answerEvidence: 'the name of the product, the date and time it was prepared or defrosted, the "use by" date, and the initials of the staff member',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c16_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c16',
      prompt: 'What sticker helps ensure team members use existing open '
          'supplies first?',
      options: <String>[
        'A "use first" sticker',
        'A "discard now" sticker',
        'A "handle with care" sticker',
        'A "keep frozen" sticker',
      ],
      correctIndex: 0,
      whyLine: 'A "use first" sticker on open products helps team members use '
          'existing supplies before opening new ones.',
      sourceUnitId: 'training_food_safety_c16_u1',
      answerEvidence: '"use first" sticker',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c16_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c16',
      prompt: 'When should a product be labelled?',
      options: <String>[
        'When it is defrosted, prepared in-house, removed from original packaging, or transferred to another container',
        'Only when it is thrown away',
        'Only on the day it is delivered',
        'Never, if it stays in the kitchen',
      ],
      correctIndex: 0,
      whyLine: 'Label a product anytime it is defrosted, prepared in-house, '
          'removed from its original packaging, or transferred to a different '
          'container.',
      sourceUnitId: 'training_food_safety_c16_u0',
      answerEvidence: 'defrosted, prepared in-house, removed from its original packaging, or transferred to a different container',
    ),

    // ---- Chapter c17: Cleaning And Sanitation ---------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c17_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c17',
      prompt: 'What is the difference between cleaning and sanitizing?',
      options: <String>[
        'Cleaning is the removal of dirt and debris; sanitizing is the reduction of harmful microorganisms to a safe level',
        'They are exactly the same thing',
        'Cleaning kills all bacteria; sanitizing only wipes surfaces',
        'Sanitizing removes food; cleaning adds soap',
      ],
      correctIndex: 0,
      whyLine: 'Cleaning removes dirt, food, and grease, while sanitizing '
          'reduces harmful microorganisms and pathogens to a safe level.',
      sourceUnitId: 'training_food_safety_c17_u0',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c17_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c17',
      prompt: 'In the five-step cleaning and sanitation process, what is the '
          'final step?',
      options: <String>[
        'Air-dry the sanitized surface',
        'Rinse with cold water',
        'Wipe dry with a towel',
        'Scrape off food waste',
      ],
      correctIndex: 0,
      whyLine: 'The final step of the five-step process is to air-dry the '
          'sanitized surface.',
      sourceUnitId: 'training_food_safety_c17_u1',
      answerEvidence: 'Allow the sanitized surface to air dry',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c17_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c17',
      prompt: 'After how many hours of continuous use should you clean and '
          'sanitize?',
      options: <String>[
        'After 4 hours of continuous use',
        'After 12 hours of continuous use',
        'After 1 hour of continuous use',
        'Only at the end of the day',
      ],
      correctIndex: 0,
      whyLine: 'Clean and sanitize after 4 hours of continuous use, among '
          'other times.',
      sourceUnitId: 'training_food_safety_c17_u3',
      answerEvidence: 'After 4 hours of continuous use',
    ),

    // ---- Chapter c18: HACCP ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c18_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c18',
      prompt: 'What does HACCP stand for?',
      options: <String>[
        'Hazard Analysis Critical Control Point',
        'Hygiene And Cleaning Control Plan',
        'Hazard And Chemical Control Procedure',
        'Health Agency Compliance Checkpoint',
      ],
      correctIndex: 0,
      whyLine: 'HACCP stands for Hazard Analysis Critical Control Point.',
      sourceUnitId: 'training_food_safety_c18_u0',
      answerEvidence: 'Hazard Analysis Critical Control Point',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c18_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c18',
      prompt: 'How does HACCP differ from traditional inspection methods?',
      options: <String>[
        'It is preventative, aiming to prevent hazards before they emerge',
        'It only reacts to problems after they occur',
        'It replaces the need for staff training',
        'It focuses only on chemical hazards',
      ],
      correctIndex: 0,
      whyLine: 'HACCP has a preventative focus, aiming to prevent hazards '
          'before they emerge rather than reacting afterward.',
      sourceUnitId: 'training_food_safety_c18_u1',
      answerEvidence: 'aiming to prevent hazards before they emerge',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c18_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c18',
      prompt: 'What is the first of the 7 principles of HACCP?',
      options: <String>[
        'Conduct a hazard analysis',
        'Establish record-keeping procedures',
        'Identify critical control points',
        'Establish corrective actions',
      ],
      correctIndex: 0,
      whyLine: 'The first HACCP principle is to conduct a hazard analysis to '
          'identify potential food safety hazards.',
      sourceUnitId: 'training_food_safety_c18_u2',
      answerEvidence: 'Conduct a Hazard Analysis',
    ),

    // ---- Chapter c19: Bar Food Safety -----------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c19_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c19',
      prompt: 'Where should the ice scoop be stored?',
      options: <String>[
        'Never directly in the ice bin',
        'Inside the ice bin for convenience',
        'In your apron pocket',
        'In the sink',
      ],
      correctIndex: 0,
      whyLine: 'Ice scoops should never be stored directly in the ice bin, to '
          'avoid introducing contaminants.',
      sourceUnitId: 'training_food_safety_c19_u3',
      answerEvidence: 'never be stored directly in the ice bin',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c19_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c19',
      prompt: 'How should broken glass be discarded?',
      options: <String>[
        'Immediately into a bin labelled for broken glass only',
        'Into the regular kitchen trash',
        'Left on the counter until the end of shift',
        'Rinsed and reused',
      ],
      correctIndex: 0,
      whyLine: 'Broken glass should be discarded immediately into a bin '
          'labelled for broken glass only.',
      sourceUnitId: 'training_food_safety_c19_u1',
      answerEvidence: 'discarded immediately into a bin, labelled for broken glass only',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c19_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c19',
      prompt: 'What should never be used to scoop ice?',
      options: <String>[
        'Glassware',
        'A designated metal scoop',
        'A clean plastic scoop',
        'Tongs',
      ],
      correctIndex: 0,
      whyLine: 'Never use glassware to scoop ice, because it can shatter and '
          'contaminate the ice supply.',
      sourceUnitId: 'training_food_safety_c19_u3',
      answerEvidence: 'never glassware, to prevent the risk of glass shattering',
    ),

    // ---- Chapter c20: Food Servers Role ---------------------------------
    BarrioQuizQuestion(
      id: 'training_food_safety_c20_q0',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c20',
      prompt: 'To help prevent foodborne illness, what should servers '
          'minimize?',
      options: <String>[
        'Bare hand contact with food, using utensils and food-safe gloves instead',
        'The number of tables they serve',
        'How often they wash their hands',
        'The use of clean utensils',
      ],
      correctIndex: 0,
      whyLine: 'Servers should minimize bare hand contact with food and use '
          'utensils and food-safe gloves instead.',
      sourceUnitId: 'training_food_safety_c20_u2',
      answerEvidence: 'minimizing bare hand contact with food is critical',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c20_q1',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c20',
      prompt: 'What must servers be able to tell guests about the food they '
          'serve?',
      options: <String>[
        'Potential allergens in the food',
        'The exact cost of each ingredient',
        'The name of the farm that grew it',
        'A secret personal recipe',
      ],
      correctIndex: 0,
      whyLine: 'Servers must be trained to inform guests about potential '
          'allergens in the food they serve.',
      sourceUnitId: 'training_food_safety_c20_u1',
      answerEvidence: 'inform guests about potential allergens in the food',
    ),
    BarrioQuizQuestion(
      id: 'training_food_safety_c20_q2',
      docId: 'training_food_safety',
      chapterId: 'training_food_safety_c20',
      prompt: 'When is proper handwashing especially important for servers?',
      options: <String>[
        'After handling raw ingredients or using the restroom',
        'Only at the start of the shift',
        'Only before going home',
        'Only when a manager is watching',
      ],
      correctIndex: 0,
      whyLine: 'Proper handwashing is especially important after handling raw '
          'ingredients or using the restroom.',
      sourceUnitId: 'training_food_safety_c20_u2',
      answerEvidence: 'after handling raw ingredients or using the restroom',
    ),
  ],
);
