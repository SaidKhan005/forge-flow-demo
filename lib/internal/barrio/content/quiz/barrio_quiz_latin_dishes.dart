// Chapter-end quiz bank for the Latin American Dishes manual.
//
// DATA ONLY. Source manual:
// lib/.../training/training_latin_dishes_content.dart (doc id
// 'training_latin_dishes'). Every question is answerable from the verbatim
// text of the single term card named in `sourceUnitId`. See
// barrio_quiz_models.dart for the authoring contract.
//
// OPERATOR REVIEW REQUIRED: new training content, drafts until read.

import 'barrio_quiz_models.dart';

const BarrioQuizBank kBarrioQuizLatinDishes = BarrioQuizBank(
  docId: 'training_latin_dishes',
  questions: <BarrioQuizQuestion>[
    // ---- Chapter c0: A to C ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c0_q0',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c0',
      prompt: 'Aguachile translates from Spanish to what?',
      options: <String>[
        'Chili water',
        'Fire sauce',
        'Sea broth',
        'Green soup',
      ],
      correctIndex: 0,
      whyLine: 'Aguachile is a Mexican raw seafood dish whose name translates '
          'to "chili water".',
      sourceUnitId: 'training_latin_dishes_c0_u0',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c0_q1',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c0',
      prompt: 'What does "arroz con pollo" translate to?',
      options: <String>[
        'Rice with chicken',
        'Beans with pork',
        'Corn with beef',
        'Fish with lime',
      ],
      correctIndex: 0,
      whyLine: 'Arroz con pollo translates to "rice with chicken".',
      sourceUnitId: 'training_latin_dishes_c0_u5',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c0_q2',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c0',
      prompt: 'Ceviche is the celebrated national dish of which country?',
      options: <String>[
        'Peru',
        'Mexico',
        'Brazil',
        'Argentina',
      ],
      correctIndex: 0,
      whyLine: 'Ceviche is a celebrated national dish of Peru.',
      sourceUnitId: 'training_latin_dishes_c0_u11',
    ),

    // ---- Chapter c1: C to E ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c1_q0',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c1',
      prompt: 'Chimichurri is an uncooked herb sauce from which countries?',
      options: <String>[
        'Argentina and Uruguay',
        'Mexico and Guatemala',
        'Peru and Chile',
        'Brazil and Colombia',
      ],
      correctIndex: 0,
      whyLine: 'Chimichurri is an uncooked herb sauce hailing from Argentina '
          'and Uruguay.',
      sourceUnitId: 'training_latin_dishes_c1_u1',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c1_q1',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c1',
      prompt: 'How is dulce de leche made?',
      options: <String>[
        'By slowly heating sweetened condensed milk into a caramel-like spread',
        'By whipping fresh cream and sugar',
        'By boiling cocoa beans',
        'By freezing coconut milk',
      ],
      correctIndex: 0,
      whyLine: 'Dulce de leche is made by slowly heating sweetened condensed '
          'milk into a thick, caramel-like spread.',
      sourceUnitId: 'training_latin_dishes_c1_u9',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c1_q2',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c1',
      prompt: 'Elote is also known as what?',
      options: <String>[
        'Mexican street corn',
        'Mexican street tacos',
        'Grilled plantain',
        'Fried yuca',
      ],
      correctIndex: 0,
      whyLine: 'Elote is also known as Mexican street corn.',
      sourceUnitId: 'training_latin_dishes_c1_u10',
    ),

    // ---- Chapter c2: E to M ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c2_q0',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c2',
      prompt: 'What does the Spanish word "ensalada" mean?',
      options: <String>[
        'Salad',
        'Soup',
        'Sauce',
        'Dessert',
      ],
      correctIndex: 0,
      whyLine: 'Ensalada is the Spanish word for salad.',
      sourceUnitId: 'training_latin_dishes_c2_u0',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c2_q1',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c2',
      prompt: 'Guacamole is made by mashing which main ingredient?',
      options: <String>[
        'Ripe avocados',
        'Ripe tomatoes',
        'Black beans',
        'Sweet corn',
      ],
      correctIndex: 0,
      whyLine: 'Guacamole is made by mashing ripe avocados with sea salt and '
          'lime juice.',
      sourceUnitId: 'training_latin_dishes_c2_u5',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c2_q2',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c2',
      prompt: 'Lomo saltado showcases the fusion created by which immigrants '
          'in Peru?',
      options: <String>[
        'Chinese immigrants',
        'Japanese immigrants',
        'Italian immigrants',
        'Lebanese immigrants',
      ],
      correctIndex: 0,
      whyLine: 'Lomo saltado showcases the culinary fusion created by Chinese '
          'immigrants in Peru.',
      sourceUnitId: 'training_latin_dishes_c2_u10',
    ),

    // ---- Chapter c3: M to S ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c3_q0',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c3',
      prompt: 'What makes pico de gallo different from blended salsas?',
      options: <String>[
        'Its dry consistency, relying on salt to draw out moisture',
        'It is fully blended and smooth',
        'It is served hot',
        'It contains no vegetables',
      ],
      correctIndex: 0,
      whyLine: 'Unlike blended salsas, pico de gallo has a dry consistency and '
          'relies on salt to draw out moisture.',
      sourceUnitId: 'training_latin_dishes_c3_u2',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c3_q1',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c3',
      prompt: 'Pupusas are a traditional dish from which country?',
      options: <String>[
        'El Salvador (Salvadoran)',
        'Mexico',
        'Argentina',
        'Peru',
      ],
      correctIndex: 0,
      whyLine: 'Pupusas are a traditional Salvadoran dish of thick, handmade '
          'corn or rice flour flatbread.',
      sourceUnitId: 'training_latin_dishes_c3_u5',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c3_q2',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c3',
      prompt: 'What is "salsa inglesa" the Spanish term for?',
      options: <String>[
        'Worcestershire sauce',
        'Soy sauce',
        'Hot sauce',
        'Tomato sauce',
      ],
      correctIndex: 0,
      whyLine: 'Salsa inglesa is the Spanish term for Worcestershire sauce.',
      sourceUnitId: 'training_latin_dishes_c3_u9',
    ),

    // ---- Chapter c4: S to T ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c4_q0',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c4',
      prompt: 'What does the Spanish word "sopa" mean?',
      options: <String>[
        'Soup',
        'Salad',
        'Sauce',
        'Stew',
      ],
      correctIndex: 0,
      whyLine: 'Sopa is the Spanish word for soup.',
      sourceUnitId: 'training_latin_dishes_c4_u0',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c4_q1',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c4',
      prompt: 'How are tamales cooked?',
      options: <String>[
        'Wrapped in a corn husk or banana leaf and steamed',
        'Deep-fried in oil',
        'Grilled over charcoal',
        'Baked in a clay oven',
      ],
      correctIndex: 0,
      whyLine: 'Tamales are wrapped in a corn husk or banana leaf and steamed '
          'to perfection.',
      sourceUnitId: 'training_latin_dishes_c4_u2',
    ),
    BarrioQuizQuestion(
      id: 'training_latin_dishes_c4_q2',
      docId: 'training_latin_dishes',
      chapterId: 'training_latin_dishes_c4',
      prompt: 'What does "taquito" mean in Spanish?',
      options: <String>[
        'Little taco',
        'Little fat one',
        'Little meat',
        'Little cake',
      ],
      correctIndex: 0,
      whyLine: 'Taquito means "little taco" in Spanish.',
      sourceUnitId: 'training_latin_dishes_c4_u3',
    ),
  ],
);
