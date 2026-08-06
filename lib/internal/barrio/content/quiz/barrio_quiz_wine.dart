// Chapter-end quiz bank for the Wine Training manual.
//
// DATA ONLY. Source manual: lib/.../training/training_wine_content.dart
// (doc id 'training_wine'). Every question is answerable from the verbatim
// text of the single card named in `sourceUnitId`, and every
// `answerEvidence` string is copied character-for-character out of that
// card's body. See barrio_quiz_models.dart for the authoring contract.
//
// Density matches the existing prose banks (2 to 3 questions per chapter,
// the same band the Food Safety and Coffee banks ship). Questions cover
// what a server needs on the floor: grape characteristics, food pairing,
// service steps, and regions.
//
// Answer order is shuffled at render time by
// `BarrioQuizCheckpointCard.displayOrderFor`, so the authored option order
// carries no meaning.
//
// OPERATOR REVIEW REQUIRED: new training content, drafts until read.

import 'barrio_quiz_models.dart';

const BarrioQuizBank kBarrioQuizWine = BarrioQuizBank(
  docId: 'training_wine',
  questions: <BarrioQuizQuestion>[
    // ---- c0: What Is Wine ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c0_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c0',
      prompt: 'A guest asks what wine actually is. What is the simplest accurate '
          'answer?',
      options: <String>[
        'Fermented grape juice',
        'Grape juice with neutral spirit added',
        'Distilled grape brandy diluted with water',
        'Grape juice sweetened and then aged',
      ],
      correctIndex: 0,
      whyLine: 'Wine is simply fermented grape juice: yeast turns the grape\'s '
          'natural sugars into alcohol.',
      sourceUnitId: 'training_wine_c0_u0',
      answerEvidence: 'simply fermented grape juice',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c0_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c0',
      prompt: 'A guest asks what the vintage year on the label means. What do '
          'you tell them?',
      options: <String>[
        'The year of harvest and production',
        'The year the bottle was opened for tasting',
        'The number of years the wine was aged in oak',
        'The year the winery was founded',
      ],
      correctIndex: 0,
      whyLine: 'Vintage is the year the grapes were harvested and the wine was '
          'produced.',
      sourceUnitId: 'training_wine_c0_u1',
      answerEvidence: 'the year of harvest and production',
    ),
    // ---- c1: Key Elements ---------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c1_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c1',
      prompt: 'Terroir is the interplay of which vineyard factors?',
      options: <String>[
        'Soil composition, climate, altitude, sunlight exposure',
        'Bottle shape, label design, cork length',
        'Barrel size, cellar temperature, shipping route',
        'Vine age, pruning shears, harvest crew size',
      ],
      correctIndex: 0,
      whyLine: 'Terroir covers a vineyard\'s soil composition, climate, altitude, '
          'and sunlight exposure, plus the local microflora.',
      sourceUnitId: 'training_wine_c1_u0',
      answerEvidence: 'soil composition, climate, altitude, sunlight exposure',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c1_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c1',
      prompt: 'What happens to a wine that does not have enough acidity?',
      options: <String>[
        'It risks tasting flabby or overly sweet',
        'It becomes far too tannic to drink',
        'It turns sparkling in the bottle',
        'It loses all of its colour',
      ],
      correctIndex: 0,
      whyLine: 'Acidity is the backbone of a wine, so without enough of it a '
          'wine tastes flabby or overly sweet.',
      sourceUnitId: 'training_wine_c1_u2',
      answerEvidence: 'wines risk tasting flabby or overly sweet',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c1_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c1',
      prompt: 'A guest says a red wine feels drying in the mouth. Which part of '
          'the grape is responsible?',
      options: <String>[
        'The skins, seeds, and stems',
        'The pulp and the juice',
        'The stalk of the vine',
        'The yeast left after fermentation',
      ],
      correctIndex: 0,
      whyLine: 'Tannins are the mouth-drying compounds found in grape skins, '
          'seeds, and stems.',
      sourceUnitId: 'training_wine_c1_u3',
      answerEvidence: 'found in grape skins, seeds, and stems',
    ),
    // ---- c2: Red v.s White --------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c2_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c2',
      prompt: 'What mainly decides whether a wine turns out red or white?',
      options: <String>[
        'The treatment of the grape skins during fermentation',
        'The colour of the barrel used for aging',
        'How long the bottle rests before release',
        'Whether the juice is chilled before bottling',
      ],
      correctIndex: 0,
      whyLine: 'Red wine ferments with its skins for colour and tannin, while '
          'white wine is pressed off the skins.',
      sourceUnitId: 'training_wine_c2_u0',
      answerEvidence: 'the treatment of grape skins during fermentation',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c2_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c2',
      prompt: 'Why does a typical white wine carry no tannins?',
      options: <String>[
        'White wine is pressed immediately to separate the skins',
        'The tannins are filtered out just before bottling',
        'White grapes never contain tannins anywhere',
        'The tannins burn off during a warm fermentation',
      ],
      correctIndex: 0,
      whyLine: 'White wine has no skin contact, so it carries none of the tannin '
          'that skins would add.',
      sourceUnitId: 'training_wine_c2_u0',
      answerEvidence: 'pressed immediately to separate the skins',
    ),
    // ---- c3: Common Red Wine Grape Varietals --------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c3_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c3',
      prompt: 'In Bordeaux, Cabernet Sauvignon is most often blended with which '
          'two grapes?',
      options: <String>[
        'Merlot and Cabernet Franc',
        'Pinot Noir and Chardonnay',
        'Syrah and Garnacha',
        'Sangiovese and Nebbiolo',
      ],
      correctIndex: 0,
      whyLine: 'Bordeaux blends Cabernet Sauvignon with Merlot and Cabernet '
          'Franc for a powerful but nuanced wine.',
      sourceUnitId: 'training_wine_c3_u0',
      answerEvidence: 'blended with Merlot and Cabernet Franc',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c3_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c3',
      prompt: 'A guest wants a lighter red. Which flavour notes would you '
          'describe for Pinot Noir?',
      options: <String>[
        'Violet, strawberry, earthy forest floor, and herbal undertones',
        'Black pepper, licorice, and dark chocolate',
        'Green apple, lime zest, and wet stone',
        'Vanilla, coconut, and toasted marshmallow',
      ],
      correctIndex: 0,
      whyLine: 'Pinot Noir is light in colour with typical notes of violet, '
          'strawberry, earthy forest floor, and herbs.',
      sourceUnitId: 'training_wine_c3_u3',
      answerEvidence: 'violet, strawberry, earthy forest floor, and herbal '
          'undertones',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c3_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c3',
      prompt: 'A guest asks whether Shiraz and Syrah are the same grape. What do '
          'you tell them?',
      options: <String>[
        'Yes, Syrah is known as Shiraz in Australia',
        'No, Shiraz is a blend of Syrah and Merlot',
        'No, Shiraz is a white grape from Australia',
        'Yes, but only when the wine is sparkling',
      ],
      correctIndex: 0,
      whyLine: 'Syrah and Shiraz are the same grape: Australia uses the name '
          'Shiraz.',
      sourceUnitId: 'training_wine_c3_u6',
      answerEvidence: 'known as Shiraz in Australia',
    ),
    // ---- c4: Common White Wine Grape Varietals ------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c4_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c4',
      prompt: 'A guest asks what a Marlborough Sauvignon Blanc tastes like. What '
          'do you describe?',
      options: <String>[
        'Bursting with tropical fruit notes like passionfruit and lime',
        'Rich vanilla and toasted oak with a buttery finish',
        'Dark plum, leather, and cedar',
        'Nutty and oxidised, like a dry sherry',
      ],
      correctIndex: 0,
      whyLine: 'New Zealand\'s Marlborough Sauvignon Blanc is famous for its bold '
          'tropical fruit and intense passionfruit and lime aromas.',
      sourceUnitId: 'training_wine_c4_u0',
      answerEvidence: 'bursting with tropical fruit notes and intense aromas '
          'like passionfruit and lime',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c4_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c4',
      prompt: 'Which two traits are the hallmark of Riesling?',
      options: <String>[
        'High acidity and low alcohol',
        'Low acidity and high alcohol',
        'High tannin and full body',
        'No acidity and heavy oak',
      ],
      correctIndex: 0,
      whyLine: 'Riesling keeps its hallmark high acidity and low alcohol '
          'wherever it is grown.',
      sourceUnitId: 'training_wine_c4_u6',
      answerEvidence: 'hallmark high acidity and low alcohol content',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c4_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c4',
      prompt: 'A guest wants a highly aromatic white. Which notes would you '
          'promise from Gewurztraminer?',
      options: <String>[
        'Passion fruit, rose, orange peel, and tropical spices',
        'Green apple, wet stone, and grassy herbs',
        'Blackcurrant, cedar, and dark spice',
        'Toasted bread, hazelnut, and cream',
      ],
      correctIndex: 0,
      whyLine: 'Gewurztraminer is prized for aromatic notes of passion fruit, '
          'rose, orange peel, and tropical spices.',
      sourceUnitId: 'training_wine_c4_u8',
      answerEvidence: 'hints of passion fruit, rose, orange peel, and tropical '
          'spices',
    ),
    // ---- c5: Other Notable Grape Varietals ----------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c5_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c5',
      prompt: 'A guest wants a bold Italian red with high tannins and tar and '
          'rose aromas. Which grape fits?',
      options: <String>[
        'Nebbiolo',
        'Albarino',
        'Vermentino',
        'Trebbiano',
      ],
      correctIndex: 0,
      whyLine: 'Nebbiolo is the bold Piedmont red known for high tannins and tar '
          'and rose aromas.',
      sourceUnitId: 'training_wine_c5_u0',
      answerEvidence: 'A bold Italian red from Piedmont',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c5_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c5',
      prompt: 'Which grape is Argentina\'s signature white?',
      options: <String>[
        'Torrontes',
        'Assyrtiko',
        'Viognier',
        'Pinotage',
      ],
      correctIndex: 0,
      whyLine: 'Torrontes is Argentina\'s signature white grape, floral and '
          'aromatic with citrus and peach.',
      sourceUnitId: 'training_wine_c5_u1',
      answerEvidence: 'Argentina\'s signature white grape',
    ),
    // ---- c6: Sparkling Wine -------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c6_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c6',
      prompt: 'Which three grapes make up the usual Champagne blend?',
      options: <String>[
        'Chardonnay, Pinot Noir, and Pinot Meunier',
        'Chardonnay, Riesling, and Gewurztraminer',
        'Glera, Macabeo, and Parellada',
        'Pinot Noir, Merlot, and Syrah',
      ],
      correctIndex: 0,
      whyLine: 'Champagne is blended from Chardonnay, Pinot Noir, and Pinot '
          'Meunier.',
      sourceUnitId: 'training_wine_c6_u0',
      answerEvidence: 'a blend of Chardonnay, Pinot Noir, and Pinot Meunier',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c6_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c6',
      prompt: 'What is a Champagne made entirely from Chardonnay called?',
      options: <String>[
        'Blanc de blancs',
        'Blanc de noirs',
        'Rose Champagne',
        'Prestige cuvee',
      ],
      correctIndex: 0,
      whyLine: 'A Champagne made only from Chardonnay is a blanc de blancs, '
          'white of whites.',
      sourceUnitId: 'training_wine_c6_u1',
      answerEvidence: 'it is called a blanc de blancs',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c6_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c6',
      prompt: 'How does Prosecco get its bubbles, and why does that matter to '
          'the taste?',
      options: <String>[
        'The Tank or Charmat Method, in large pressurized tanks',
        'A second fermentation in each individual bottle',
        'Carbon dioxide injected just before corking',
        'Long aging on the lees in oak barrels',
      ],
      correctIndex: 0,
      whyLine: 'Prosecco ferments a second time in large pressurized tanks, '
          'which keeps fresh fruit flavours instead of Champagne\'s bready '
          'notes.',
      sourceUnitId: 'training_wine_c6_u8',
      answerEvidence: 'the Tank Method or Charmat Method',
    ),
  ],
);
