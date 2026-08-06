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
    // ---- c7: Argentinian Wine -----------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c7_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c7',
      prompt: 'Where does Argentina rank among the world\'s wine producers?',
      options: <String>[
        'The fifth largest wine producer in the world',
        'The largest wine producer in the world',
        'Outside the top twenty producers',
        'The second largest, behind France',
      ],
      correctIndex: 0,
      whyLine: 'Argentina is the fifth largest wine producer in the world.',
      sourceUnitId: 'training_wine_c7_u0',
      answerEvidence: 'the fifth-largest wine producer globally',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c7_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c7',
      prompt: 'Which two Argentine regions show the spread from warm to cool '
          'growing conditions?',
      options: <String>[
        'The sun-drenched vineyards of Mendoza and the cooler climates of Patagonia',
        'The tropical north coast and the rainforest interior',
        'Bordeaux and the Loire Valley',
        'Penedes and Rioja',
      ],
      correctIndex: 0,
      whyLine: 'Argentina runs from the sun-drenched vineyards of Mendoza to the '
          'cooler climates of Patagonia.',
      sourceUnitId: 'training_wine_c7_u0',
      answerEvidence: 'From the sun-drenched vineyards of Mendoza to the cooler '
          'climates of Patagonia',
    ),
    // ---- c8: History of Argentinian Wine ------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c8_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c8',
      prompt: 'Which immigrant group brought the advanced techniques that '
          'revolutionised Argentine winemaking?',
      options: <String>[
        'Italian immigrants',
        'Portuguese immigrants',
        'Greek immigrants',
        'Dutch immigrants',
      ],
      correctIndex: 0,
      whyLine: 'Italian immigrants brought advanced viticultural techniques and '
          'traditions that revolutionised the industry.',
      sourceUnitId: 'training_wine_c8_u0',
      answerEvidence: 'Italian immigrants brought advanced viticultural '
          'techniques and traditions',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c8_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c8',
      prompt: 'What was the Malbec boom?',
      options: <String>[
        'A surge in global demand for Argentina\'s signature Malbec',
        'A season when hail destroyed most of the Malbec crop',
        'A law requiring every Argentine winery to plant Malbec',
        'A price collapse that pushed Malbec out of export markets',
      ],
      correctIndex: 0,
      whyLine: 'The Malbec boom was a surge in global demand for Argentina\'s '
          'signature Malbec varietal.',
      sourceUnitId: 'training_wine_c8_u1',
      answerEvidence: 'a surge in global demand for its signature Malbec '
          'varietal',
    ),
    // ---- c9: Argentina Terroir ----------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c9_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c9',
      prompt: 'Argentina\'s wine regions span a huge range of latitude. Why do '
          'their climates stay so similar?',
      options: <String>[
        'Altitude compensates for latitude',
        'Every region uses the same irrigation schedule',
        'The Atlantic keeps the whole country at one temperature',
        'All the vineyards sit on identical soil',
      ],
      correctIndex: 0,
      whyLine: 'Vineyards sit progressively higher as you travel north, so '
          'altitude cancels out the change in latitude.',
      sourceUnitId: 'training_wine_c9_u0',
      answerEvidence: 'the decisive role of altitude, which effectively '
          'compensates for latitude',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c9_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c9',
      prompt: 'Why do Argentine producers deliberately limit irrigation?',
      options: <String>[
        'To concentrate flavors and improve grape quality',
        'To keep the vineyard soil permanently wet',
        'Because the Andes supply no water at all',
        'To raise yields as high as possible',
      ],
      correctIndex: 0,
      whyLine: 'Too much water dilutes the grapes, so producers restrict it to '
          'concentrate flavour and lift quality.',
      sourceUnitId: 'training_wine_c9_u1',
      answerEvidence: 'concentrate flavors and improve the overall quality of '
          'their grapes',
    ),
    // ---- c10: Argentina's Wine Growing Regions ------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c10_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c10',
      prompt: 'Mendoza is the historic birthplace of which Argentine flagship '
          'grape?',
      options: <String>[
        'Malbec',
        'Tempranillo',
        'Bonarda',
        'Torrontés',
      ],
      correctIndex: 0,
      whyLine: 'Mendoza is the historic birthplace of Argentina\'s flagship '
          'grape, Malbec.',
      sourceUnitId: 'training_wine_c10_u0',
      answerEvidence: 'the historic birthplace of Argentina\'s flagship grape, '
          'Malbec',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c10_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c10',
      prompt: 'A guest asks what Patagonia does best. Which wine do you point '
          'to?',
      options: <String>[
        'Pinot Noir, prized for delicate red fruit',
        'Full-bodied Cabernet Sauvignon',
        'Sweet dessert Muscat',
        'Heavily oaked Chardonnay',
      ],
      correctIndex: 0,
      whyLine: 'Cool Atlantic winds make Patagonia\'s Pinot Noir prized for '
          'delicate cherry, plum, and raspberry notes.',
      sourceUnitId: 'training_wine_c10_u4',
      answerEvidence: 'The region\'s Pinot Noir is especially prized for its '
          'delicate red fruit notes',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c10_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c10',
      prompt: 'What is Salta known for?',
      options: <String>[
        'Crisp Torrontés whites and bold reds like Malbec and Tannat',
        'Sweet fortified wines and brandy',
        'Light sparkling wines made in tanks',
        'Sea-level vineyards on the Atlantic coast',
      ],
      correctIndex: 0,
      whyLine: 'Salta is known for crisp Torrontés whites and bold reds like '
          'Malbec, Cabernet Sauvignon, and Tannat.',
      sourceUnitId: 'training_wine_c10_u6',
      answerEvidence: 'producing crisp Torrontés whites and bold reds like '
          'Malbec, Cabernet Sauvignon, and Tannat',
    ),
    // ---- c11: Argentina's Wine Varietals ------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c11_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c11',
      prompt: 'A guest orders a Mendoza Malbec. Which dishes do you suggest '
          'alongside it?',
      options: <String>[
        'Grilled meats and rich sauces',
        'Raw oysters and citrus salad',
        'Light green salad with vinaigrette',
        'Fresh fruit and sorbet',
      ],
      correctIndex: 0,
      whyLine: 'Mendoza Malbec\'s plum, black cherry, and spice make it a perfect '
          'companion for grilled meats and rich sauces.',
      sourceUnitId: 'training_wine_c11_u0',
      answerEvidence: 'a perfect companion for grilled meats and rich sauces',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c11_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c11',
      prompt: 'Which dishes suit an Argentine Syrah?',
      options: <String>[
        'Barbecued ribs, charcuterie, aged cheeses, and game meats',
        'Steamed white fish and lemon',
        'Vanilla ice cream and berries',
        'Cucumber sandwiches and mint tea',
      ],
      correctIndex: 0,
      whyLine: 'Argentine Syrah\'s bold black fruit and smoked meat notes suit '
          'barbecued ribs, charcuterie, aged cheeses, and game.',
      sourceUnitId: 'training_wine_c11_u4',
      answerEvidence: 'barbecued ribs, charcuterie, aged cheeses, and game meats',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c11_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c11',
      prompt: 'How would you describe Torrontés to a guest?',
      options: <String>[
        'Floral and fruity notes of peach, apricot, and orange blossom',
        'Earthy, tannic, and full of black pepper',
        'Nutty and oxidised with a dry finish',
        'Smoky and toasty from long oak aging',
      ],
      correctIndex: 0,
      whyLine: 'Torrontés is intensely aromatic, with floral and fruity notes of '
          'peach, apricot, and orange blossom.',
      sourceUnitId: 'training_wine_c11_u6',
      answerEvidence: 'floral and fruity notes of peach, apricot, and orange '
          'blossom',
    ),
    // ---- c12: Chilean Wine --------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c12_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c12',
      prompt: 'Why are Chilean wines so consistent from vintage to vintage?',
      options: <String>[
        'A reliable climate of abundant sun, cool nights, and minimal rainfall',
        'Every bottle is blended from ten different years',
        'The wines are all made in one single winery',
        'Heavy rainfall every spring evens out the crop',
      ],
      correctIndex: 0,
      whyLine: 'Chile\'s reliable climate plus controlled irrigation keeps '
          'quality steady from one vintage to the next.',
      sourceUnitId: 'training_wine_c12_u0',
      answerEvidence: 'a reliable climate of abundant sun, cool nights, and '
          'minimal rainfall',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c12_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c12',
      prompt: 'Chile does not permit chaptalization. What does that mean for its '
          'lower-priced wines?',
      options: <String>[
        'They avoid synthetic sweetness',
        'They must be aged for ten years',
        'They are always fortified with spirit',
        'They can only be sold within Chile',
      ],
      correctIndex: 0,
      whyLine: 'Because chaptalization is banned, cheaper Chilean wines avoid '
          'synthetic sweetness and stay fruit-forward.',
      sourceUnitId: 'training_wine_c12_u1',
      answerEvidence: 'chaptalization is not permitted, so lower-priced wines '
          'avoid synthetic sweetness',
    ),
    // ---- c13: Chilean Wine History ------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c13_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c13',
      prompt: 'What did Chile first become known for internationally?',
      options: <String>[
        'Inexpensive, approachable Cabernets and Merlots',
        'Expensive traditional method sparkling wine',
        'Sweet fortified dessert wines',
        'Orange wines made in clay amphorae',
      ],
      correctIndex: 0,
      whyLine: 'Chile\'s first international reputation was built on inexpensive, '
          'approachable Cabernets and Merlots.',
      sourceUnitId: 'training_wine_c13_u0',
      answerEvidence: 'its inexpensive, approachable Cabernets and Merlots',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c13_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c13',
      prompt: 'What makes Chile\'s vineyards unusual compared with almost every '
          'other wine region?',
      options: <String>[
        'They remained untouched by the phylloxera blight',
        'They are all planted below sea level',
        'They are watered only by rainfall',
        'They use no rootstock selection at all',
      ],
      correctIndex: 0,
      whyLine: 'Chile\'s vineyards never suffered phylloxera, so its wines can '
          'show old-world vines the Old World no longer has.',
      sourceUnitId: 'training_wine_c13_u1',
      answerEvidence: 'Chile\'s vineyards remained untouched by the phylloxera '
          'blight',
    ),
    // ---- c14: Chilean Terroir -----------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c14_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c14',
      prompt: 'What let Chile plant vineyards on cooler, less fertile slopes?',
      options: <String>[
        'The advent of drip irrigation',
        'A shift back to flood irrigation',
        'Removing all rootstock diversity',
        'Planting only in the Central Valley',
      ],
      correctIndex: 0,
      whyLine: 'Drip irrigation opened up cooler, less fertile south-facing '
          'slopes that flood irrigation could never reach.',
      sourceUnitId: 'training_wine_c14_u0',
      answerEvidence: 'the advent of drip irrigation transformed the industry',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c14_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c14',
      prompt: 'Which soils on the Maipo River terraces suit late-ripening '
          'Cabernet Sauvignon?',
      options: <String>[
        'Warm, well-drained gravelly soils',
        'Cold, waterlogged clay',
        'Pure sand with no drainage',
        'Deep peat bog',
      ],
      correctIndex: 0,
      whyLine: 'The Maipo River\'s alluvial terraces give warm, well-drained '
          'gravelly soils ideal for late-ripening Cabernet Sauvignon.',
      sourceUnitId: 'training_wine_c14_u1',
      answerEvidence: 'warm, well-drained gravelly soils ideal for late-ripening '
          'cabernet sauvignon',
    ),
    // ---- c15: Chilean Wine Regions ------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c15_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c15',
      prompt: 'Chilean wine regions have historically been named after what?',
      options: <String>[
        'The rivers that flow from the Andes to the sea',
        'The family that founded each winery',
        'The grape planted most widely there',
        'The year the first vines went in',
      ],
      correctIndex: 0,
      whyLine: 'Chile\'s regions take their names from the rivers running '
          'perpendicular to the coast, Andes to sea.',
      sourceUnitId: 'training_wine_c15_u0',
      answerEvidence: 'named after the rivers flowing perpendicular to the coast',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c15_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c15',
      prompt: 'Which valley was Chile\'s first cool-climate vineyard area?',
      options: <String>[
        'Casablanca Valley',
        'Colchagua',
        'Upper Maipo',
        'Curico',
      ],
      correctIndex: 0,
      whyLine: 'Casablanca Valley was Chile\'s first cool-climate vineyard area, '
          'a bowl-shaped valley near the coast.',
      sourceUnitId: 'training_wine_c15_u10',
      answerEvidence: 'Chile\'s first cool-climate vineyard area',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c15_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c15',
      prompt: 'Leyda established itself as a premier Chilean region for which '
          'two grapes?',
      options: <String>[
        'Sauvignon Blanc and Pinot Noir',
        'Cabernet Sauvignon and Carmenere',
        'Malbec and Tannat',
        'Glera and Macabeo',
      ],
      correctIndex: 0,
      whyLine: 'Cooled by the Pacific, Leyda became a premier region for '
          'Sauvignon Blanc and Pinot Noir.',
      sourceUnitId: 'training_wine_c15_u11',
      answerEvidence: 'a premier region for Sauvignon Blanc and Pinot Noir',
    ),
    // ---- c16: Chilean Wine Varietals ----------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c16_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c16',
      prompt: 'How would you describe a Chilean Cabernet Sauvignon to a guest?',
      options: <String>[
        'Black currant, fresh berries, violets, and chocolate',
        'Green apple, lime, and wet stone',
        'Rose petal, lychee, and orange peel',
        'Toasted bread, almond, and cream',
      ],
      correctIndex: 0,
      whyLine: 'Chilean Cabernet Sauvignon is full-bodied and intense, with '
          'black currant, fresh berries, violets, and chocolate.',
      sourceUnitId: 'training_wine_c16_u0',
      answerEvidence: 'notes of black currant, fresh berries, violets, and '
          'chocolate',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c16_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c16',
      prompt: 'Which grape was Carmenere long mistaken for in Chile?',
      options: <String>[
        'Merlot',
        'Syrah',
        'Pinot Noir',
        'Tempranillo',
      ],
      correctIndex: 0,
      whyLine: 'Carmenere was long mistaken for Merlot until DNA testing proved '
          'Chilean Merlot was actually Carmenere.',
      sourceUnitId: 'training_wine_c16_u1',
      answerEvidence: 'it was long mistaken for Merlot',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c16_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c16',
      prompt: 'A guest orders ceviche. Which Chilean white is the standout '
          'match?',
      options: <String>[
        'Sauvignon Blanc from Casablanca or San Antonio',
        'An oaked Chardonnay from Casablanca',
        'A sweet Riesling from Maule',
        'A Carmenere from Colchagua',
      ],
      correctIndex: 0,
      whyLine: 'Chilean Sauvignon Blanc\'s high acidity and green jalapeno hint '
          'complement citrus-marinated seafood.',
      sourceUnitId: 'training_wine_c16_u3',
      answerEvidence: 'an exceptional pairing for ceviche',
    ),
    // ---- c17: Spanish Wine --------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c17_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c17',
      prompt: 'A guest asks what goes into Sangria. What do you tell them?',
      options: <String>[
        'Red wine, fresh fruit, and often a splash of brandy',
        'White wine, soda water, and mint',
        'Sparkling wine and orange juice',
        'Sherry, sugar, and cream',
      ],
      correctIndex: 0,
      whyLine: 'Sangria is made with red wine, fresh fruit, and often a splash '
          'of brandy.',
      sourceUnitId: 'training_wine_c17_u0',
      answerEvidence: 'Made with red wine, fresh fruit, and often a splash of '
          'brandy',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c17_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c17',
      prompt: 'What are Spain\'s three aging categories on a wine label?',
      options: <String>[
        'Crianza, Reserva, and Gran Reserva',
        'Brut, Sec, and Doux',
        'Joven, Fino, and Oloroso',
        'Alta, Alavesa, and Oriental',
      ],
      correctIndex: 0,
      whyLine: 'Spanish wines are graded by aging into Crianza, Reserva, and '
          'Gran Reserva.',
      sourceUnitId: 'training_wine_c17_u1',
      answerEvidence: 'Crianza, Reserva, and Gran Reserva',
    ),
    // ---- c18: Spanish Wine History ------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c18_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c18',
      prompt: 'Where does Spain rank among the world\'s wine producers today?',
      options: <String>[
        'The third largest wine producer in the world',
        'The largest wine producer in the world',
        'Tenth, behind most of Europe',
        'It no longer exports wine at all',
      ],
      correctIndex: 0,
      whyLine: 'Spain is the world\'s third largest wine producer.',
      sourceUnitId: 'training_wine_c18_u0',
      answerEvidence: 'the world\'s third-largest wine producer',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c18_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c18',
      prompt: 'What are tinajas, and why did Spanish winemakers use them?',
      options: <String>[
        'Clay vessels with narrow openings that minimize oxygen exposure',
        'Oak barrels that add vanilla and spice',
        'Steel tanks that hold a second fermentation',
        'Glass bottles sealed with pine resin',
      ],
      correctIndex: 0,
      whyLine: 'Tinajas are clay vessels whose narrow openings minimize oxygen '
          'exposure and slow oxidation.',
      sourceUnitId: 'training_wine_c18_u1',
      answerEvidence: 'clay vessels with narrow openings that minimized oxygen '
          'exposure',
    ),
    // ---- c19: Spanish Terroir -----------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c19_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c19',
      prompt: 'How are Spanish winemakers adapting to water scarcity and '
          'drought?',
      options: <String>[
        'Water-efficient irrigation and drought-resistant grape varieties',
        'Flooding the vineyards more often',
        'Harvesting every crop several months early',
        'Moving all production indoors',
      ],
      correctIndex: 0,
      whyLine: 'Spain is fitting water-efficient irrigation, planting '
          'drought-resistant varieties, and going sustainable.',
      sourceUnitId: 'training_wine_c19_u0',
      answerEvidence: 'water-efficient irrigation systems, planting '
          'drought-resistant grape varieties',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c19_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c19',
      prompt: 'What is la Meseta?',
      options: <String>[
        'Spain\'s vast central plateau',
        'A river that runs through Rioja',
        'The Atlantic coastal strip of Galicia',
        'A sherry aging method',
      ],
      correctIndex: 0,
      whyLine: 'La Meseta is Spain\'s vast central plateau, where altitude '
          'matters as much as latitude.',
      sourceUnitId: 'training_wine_c19_u1',
      answerEvidence: 'the vast central plateau known as la Meseta',
    ),
    // ---- c20: Spanish Wine Regions ------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c20_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c20',
      prompt: 'Which grape is the backbone of Rioja\'s reds?',
      options: <String>[
        'Tempranillo',
        'Garnacha',
        'Mencia',
        'Monastrell',
      ],
      correctIndex: 0,
      whyLine: 'Rioja\'s elegant, age-worthy reds are built on a robust backbone '
          'of Tempranillo.',
      sourceUnitId: 'training_wine_c20_u0',
      answerEvidence: 'a robust backbone of Tempranillo grapes',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c20_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c20',
      prompt: 'A guest wants a crisp Atlantic white from Galicia. Which grape '
          'and region?',
      options: <String>[
        'Albariño from Rías Baixas',
        'Verdejo from Rueda',
        'Palomino from Jerez',
        'Airen from La Mancha',
      ],
      correctIndex: 0,
      whyLine: 'Rías Baixas in Galicia makes crisp, aromatic Albariño shaped by '
          'the cool Atlantic.',
      sourceUnitId: 'training_wine_c20_u3',
      answerEvidence: 'the region\'s crisp, aromatic Albariño white wines',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c20_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c20',
      prompt: 'Jerez is the sherry capital. Which wines does it make, and from '
          'which grape?',
      options: <String>[
        'Fino, Manzanilla, and Oloroso, made from Palomino grapes',
        'Cava and Crianza, made from Macabeo',
        'Port and Madeira, made from Touriga Nacional',
        'Txakoli and Albariño, made from Hondarrabi Zuri',
      ],
      correctIndex: 0,
      whyLine: 'Jerez makes Fino, Manzanilla, and Oloroso from Palomino grapes, '
          'aged through the solera system.',
      sourceUnitId: 'training_wine_c20_u5',
      answerEvidence: 'its iconic fortified wines like Fino, Manzanilla, and '
          'Oloroso from Palomino grapes',
    ),
    // ---- c21: Spanish Red Wine Varietals ------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c21_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c21',
      prompt: 'How would you describe a Tempranillo to a guest?',
      options: <String>[
        'Cherry and raspberry with hints of tobacco and leather',
        'Green apple, lime, and sea salt',
        'Rose, lychee, and orange peel',
        'Banana and pineapple with no tannin',
      ],
      correctIndex: 0,
      whyLine: 'Tempranillo shows bright cherry and raspberry with tobacco and '
          'leather, over smooth tannins.',
      sourceUnitId: 'training_wine_c21_u0',
      answerEvidence: 'bright red fruit flavors like cherry and raspberry mingle '
          'with hints of tobacco and leather',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c21_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c21',
      prompt: 'Why was Garnacha neglected by Spanish producers for so long?',
      options: <String>[
        'It oxidizes more readily than Tempranillo',
        'It has no colour at all',
        'It cannot be blended with other grapes',
        'It ripens far too early to harvest',
      ],
      correctIndex: 0,
      whyLine: 'Garnacha oxidizes more readily than Tempranillo and needs a '
          'longer ripening window, so producers avoided it.',
      sourceUnitId: 'training_wine_c21_u1',
      answerEvidence: 'it oxidizes more readily than Tempranillo',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c21_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c21',
      prompt: 'Monastrell is known by which other name?',
      options: <String>[
        'Mourvèdre',
        'Mencia',
        'Bobal',
        'Cariñena',
      ],
      correctIndex: 0,
      whyLine: 'Monastrell is the Spanish name for Mourvèdre.',
      sourceUnitId: 'training_wine_c21_u2',
      answerEvidence: 'Also known as Mourvèdre',
    ),
    // ---- c22: Spanish White Wine Varietals ----------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c22_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c22',
      prompt: 'Albariño from Rías Baixas is the time-honoured match for which '
          'food?',
      options: <String>[
        'The region\'s celebrated seafood',
        'Slow-roasted lamb',
        'Strong blue cheese',
        'Dark chocolate desserts',
      ],
      correctIndex: 0,
      whyLine: 'Albariño\'s mineral-driven, never cloying style is the classic '
          'match for Galician seafood.',
      sourceUnitId: 'training_wine_c22_u1',
      answerEvidence: 'a perfect, time-honored match for the region\'s celebrated '
          'seafood',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c22_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c22',
      prompt: 'What does the Palomino grape contribute that makes Fino sherry '
          'possible?',
      options: <String>[
        'A Flor yeast coat that drives the solera aging process',
        'A very high tannin level',
        'Deep purple colour from thick skins',
        'Natural sparkle from a second fermentation',
      ],
      correctIndex: 0,
      whyLine: 'In Jerez\'s chalky soils, Palomino develops the prized Flor yeast '
          'coat that drives solera aging.',
      sourceUnitId: 'training_wine_c22_u5',
      answerEvidence: 'its prized Flor yeast coat emerges to drive the intricate '
          'solera aging process',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c22_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c22',
      prompt: 'Which Spanish grape is the most planted grape variety in the '
          'world?',
      options: <String>[
        'Airen',
        'Verdejo',
        'Godello',
        'Parellada',
      ],
      correctIndex: 0,
      whyLine: 'Airen, grown across La Mancha, is the world\'s most planted grape '
          'variety.',
      sourceUnitId: 'training_wine_c22_u8',
      answerEvidence: 'the world\'s most planted grape variety',
    ),
    // ---- c23: Spanish Wine Classification -----------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c23_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c23',
      prompt: 'How long must a red Crianza be aged?',
      options: <String>[
        'At least 2 years, with a minimum of 6 months in oak',
        'At least 5 years, with a minimum of 18 months in oak',
        'No minimum aging at all',
        'At least 10 years, all of it in oak',
      ],
      correctIndex: 0,
      whyLine: 'Red Crianza needs at least two years of aging, six months of it '
          'in oak.',
      sourceUnitId: 'training_wine_c23_u0',
      answerEvidence: 'Red wines aged for at least 2 years, with a minimum of 6 '
          'months in oak',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c23_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c23',
      prompt: 'How long must a red Gran Reserva be aged?',
      options: <String>[
        'At least 5 years, with a minimum of 18 months in oak',
        'At least 2 years, with a minimum of 6 months in oak',
        'At least 1 year, with no oak requirement',
        'At least 3 years, with a minimum of 1 year in oak',
      ],
      correctIndex: 0,
      whyLine: 'Red Gran Reserva needs at least five years of aging, eighteen '
          'months of it in oak.',
      sourceUnitId: 'training_wine_c23_u2',
      answerEvidence: 'Red wines aged for at least 5 years, with a minimum of 18 '
          'months in oak',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c23_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c23',
      prompt: 'What does Vinos de Pago on a Spanish label mean?',
      options: <String>[
        'Single-estate wines that meet strict quality standards',
        'Wines blended from several regions for value',
        'Wines with no denomination of origin',
        'Wines aged at least five years',
      ],
      correctIndex: 0,
      whyLine: 'Vinos de Pago is the single-estate classification: grapes and '
          'winemaking both stay on one estate.',
      sourceUnitId: 'training_wine_c23_u4',
      answerEvidence: 'single-estate wines that meet strict quality standards',
    ),
    // ---- c24: Portuguese Wine -----------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c24_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c24',
      prompt: 'Instead of planting global varieties, what did Portuguese '
          'winemakers stay committed to?',
      options: <String>[
        'Their native cultivars',
        'Cabernet, Merlot, and Chardonnay',
        'Only fortified wine production',
        'Imported American rootstock varieties',
      ],
      correctIndex: 0,
      whyLine: 'Portugal held to its native cultivars, and that patience is now '
          'its greatest market asset.',
      sourceUnitId: 'training_wine_c24_u0',
      answerEvidence: 'their commitment to native cultivars',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c24_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c24',
      prompt: 'How would you describe cork harvesting to a guest who asks about '
          'the cork in their bottle?',
      options: <String>[
        'A time-honoured, fully renewable practice',
        'A one-time harvest that kills the tree',
        'A synthetic process done in a factory',
        'A recent invention from the last decade',
      ],
      correctIndex: 0,
      whyLine: 'Harvesting cork bark is time-honoured and fully renewable, '
          'supporting both the environment and local livelihoods.',
      sourceUnitId: 'training_wine_c24_u1',
      answerEvidence: 'a time-honoured, fully renewable practice',
    ),
    // ---- c25: Portuguese Wine Regions ---------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c25_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c25',
      prompt: 'Which grape backs Vinho Verde in the north of the region?',
      options: <String>[
        'Alvarinho, called Albariño in Spain',
        'Loureiro, called Verdejo in Spain',
        'Baga, called Bobal in Spain',
        'Arinto, called Airen in Spain',
      ],
      correctIndex: 0,
      whyLine: 'Alvarinho, the same grape Spain calls Albariño, is the backbone '
          'of northern Vinho Verde blends.',
      sourceUnitId: 'training_wine_c25_u0',
      answerEvidence: 'Alvarinho (Spain\'s Albariño) reigns supreme in the north',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c25_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c25',
      prompt: 'The Douro is famous for Port. What has it also become?',
      options: <String>[
        'The country\'s premier source of unfortified table wines',
        'Portugal\'s largest sparkling wine region',
        'A region that now grows only white grapes',
        'The only Portuguese region using international varieties',
      ],
      correctIndex: 0,
      whyLine: 'The Douro now leads Portugal for unfortified table wines, driven '
          'by the port shippers themselves.',
      sourceUnitId: 'training_wine_c25_u3',
      answerEvidence: 'the country\'s premier source of unfortified table wines',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c25_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c25',
      prompt: 'Bairrada is one of the few Portuguese regions dominated by a '
          'single grape. Which one?',
      options: <String>[
        'Baga',
        'Touriga Nacional',
        'Castelao',
        'Alvarinho',
      ],
      correctIndex: 0,
      whyLine: 'Bairrada is dominated by baga: tough and astringent young, '
          'elegantly perfumed with age.',
      sourceUnitId: 'training_wine_c25_u7',
      answerEvidence: 'dominated by a single grape: baga',
    ),
    // ---- c26: Portuguese White Wine Varietals -------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c26_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c26',
      prompt: 'What is remarkable about Portugal\'s grape diversity?',
      options: <String>[
        'It has more indigenous grape varieties than any other wine-producing nation',
        'It grows only three permitted grape varieties',
        'Every one of its grapes came from France',
        'It has fewer varieties than any other nation',
      ],
      correctIndex: 0,
      whyLine: 'Portugal has more indigenous grape varieties than any other '
          'wine-producing nation.',
      sourceUnitId: 'training_wine_c26_u0',
      answerEvidence: 'more than any other wine-producing nation',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c26_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c26',
      prompt: 'Alvarinho from the Minho is known by which name across the border '
          'in Spain?',
      options: <String>[
        'Albariño',
        'Verdejo',
        'Godello',
        'Macabeo',
      ],
      correctIndex: 0,
      whyLine: 'Alvarinho in Portugal is the same grape Spain calls Albariño.',
      sourceUnitId: 'training_wine_c26_u1',
      answerEvidence: 'known as Albariño across the border in Spain',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c26_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c26',
      prompt: 'Verdelho gives the rich, medium-sweet character of which '
          'fortified wine?',
      options: <String>[
        'Madeira',
        'Port',
        'Sherry',
        'Marsala',
      ],
      correctIndex: 0,
      whyLine: 'Verdelho is behind the rich, medium-sweet style of Madeira, and '
          'also makes dry table wines.',
      sourceUnitId: 'training_wine_c26_u5',
      answerEvidence: 'the rich, medium-sweet character of Madeira',
    ),
    // ---- c27: Portuguese Red Wine Varietals ---------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c27_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c27',
      prompt: 'Aragonez, the cornerstone Douro red, is known by which name in '
          'Spain?',
      options: <String>[
        'Tempranillo',
        'Garnacha',
        'Monastrell',
        'Mencia',
      ],
      correctIndex: 0,
      whyLine: 'Aragonez is Tinta Roriz in northern Portugal and Tempranillo in '
          'Spain: one grape, three names.',
      sourceUnitId: 'training_wine_c27_u0',
      answerEvidence: 'Tempranillo in Spain',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c27_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c27',
      prompt: 'What does Baga give in skilled hands?',
      options: <String>[
        'Dense, bright cherry-driven wines with remarkable aging potential',
        'Soft, low-acid wines meant to drink immediately',
        'Sweet fortified wines with a black hue',
        'Neutral white wines used for brandy',
      ],
      correctIndex: 0,
      whyLine: 'Baga can be lean and tannic in lesser hands, but skilled '
          'winemaking gives dense, cherry-driven, age-worthy reds.',
      sourceUnitId: 'training_wine_c27_u2',
      answerEvidence: 'dense, bright cherry-driven wines with remarkable aging '
          'potential',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c27_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c27',
      prompt: 'Why is Touriga Nacional so well suited to long ageing?',
      options: <String>[
        'Its small berries give exceptional concentration of colour, extract, and aroma',
        'Its very large berries dilute the tannins',
        'It has almost no colour or aroma to lose',
        'It is always fortified before bottling',
      ],
      correctIndex: 0,
      whyLine: 'Touriga Nacional\'s small berries deliver exceptional '
          'concentration of colour, extract, and aroma.',
      sourceUnitId: 'training_wine_c27_u4',
      answerEvidence: 'an exceptional concentration of colour, extract, and '
          'aroma',
    ),
    // ---- c28: Port ----------------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c28_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c28',
      prompt: 'How does Port get its signature sweetness?',
      options: <String>[
        'Fermentation is halted early with aguardente, a neutral grape brandy',
        'Sugar is stirred in just before bottling',
        'The grapes are dried in the sun for a year',
        'A second fermentation is run inside the bottle',
      ],
      correctIndex: 0,
      whyLine: 'Port stops fermentation early by adding aguardente, so '
          'unfermented grape sugar stays in the wine.',
      sourceUnitId: 'training_wine_c28_u0',
      answerEvidence: 'halting fermentation early with the addition of '
          'aguardente',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c28_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c28',
      prompt: 'Where must a wine come from to be called Port?',
      options: <String>[
        'Only the Douro Valley',
        'Anywhere in Portugal',
        'Anywhere a fortified style is made',
        'Only the city of Lisbon',
      ],
      correctIndex: 0,
      whyLine: 'Only wines from the UNESCO-designated Douro Valley may be called '
          'Port, a rule as strict as Champagne\'s.',
      sourceUnitId: 'training_wine_c28_u0',
      answerEvidence: 'only wines from this UNESCO-designated region may bear '
          'its name',
    ),
    // ---- c29: Wine Glasses --------------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c29_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c29',
      prompt: 'Why does a wine glass have a long stem?',
      options: <String>[
        'A long stem prevents body heat from warming the wine',
        'It makes the glass easier to stack',
        'It increases the surface area for aeration',
        'It concentrates aromas at the rim',
      ],
      correctIndex: 0,
      whyLine: 'The stem keeps your hand off the bowl so body heat does not warm '
          'the wine.',
      sourceUnitId: 'training_wine_c29_u0',
      answerEvidence: 'a long stem prevents body heat from warming the wine',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c29_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c29',
      prompt: 'What does swirling a wine in a large, wide bowl do?',
      options: <String>[
        'Increases oxygen contact, releasing compounds that soften tannins',
        'Cools the wine several degrees',
        'Removes sulfites from the wine',
        'Raises the alcohol level in the glass',
      ],
      correctIndex: 0,
      whyLine: 'Swirling in a wide bowl raises oxygen contact, softening tannins '
          'and unlocking aromas in young reds.',
      sourceUnitId: 'training_wine_c29_u1',
      answerEvidence: 'increases oxygen contact, releasing volatile compounds '
          'that soften tannins',
    ),
    // ---- c30: Red Wine Glasses ----------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c30_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c30',
      prompt: 'What shape do red wine glasses generally take, and why?',
      options: <String>[
        'Full, round bowls and wide rim diameters, which maximize aeration',
        'Narrow bowls and tight rims, to keep oxygen out',
        'Straight sides with no bowl, to hold more wine',
        'Shallow saucers, to release the bubbles faster',
      ],
      correctIndex: 0,
      whyLine: 'Red glasses use full, round bowls and wide rims to maximize '
          'aeration and soften harsh tannins.',
      sourceUnitId: 'training_wine_c30_u0',
      answerEvidence: 'full, round bowls and wide rim diameters, which together '
          'maximize aeration',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c30_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c30',
      prompt: 'The Pinot Noir glass goes by which other name?',
      options: <String>[
        'A Burgundy glass',
        'A Bordeaux glass',
        'A flute',
        'A coupe',
      ],
      correctIndex: 0,
      whyLine: 'The Pinot Noir glass is also called a Burgundy glass: round wide '
          'bowl, narrow mouth.',
      sourceUnitId: 'training_wine_c30_u1',
      answerEvidence: 'the Pinot Noir glass, also known as a Burgundy glass',
    ),
    // ---- c31: White Wine Glasses --------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c31_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c31',
      prompt: 'Why are white wine glasses smaller and narrower than red wine '
          'glasses?',
      options: <String>[
        'To preserve acidity and keep the wine cooler',
        'To let as much oxygen in as possible',
        'To make the wine taste sweeter',
        'To hold a larger pour',
      ],
      correctIndex: 0,
      whyLine: 'Tighter bowls preserve acidity, hold a cooler serving '
          'temperature, and protect delicate aromatics.',
      sourceUnitId: 'training_wine_c31_u0',
      answerEvidence: 'engineered to preserve acidity, maintain a cooler serving '
          'temperature',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c31_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c31',
      prompt: 'Which white wine glass breaks the narrow-bowl rule, and why?',
      options: <String>[
        'The Chardonnay and White Burgundy glass, with a wider bowl that softens acidity',
        'The Riesling glass, with a tall narrow opening',
        'The Sauvignon Blanc glass, with a narrow bowl',
        'The flute, with its tall straight sides',
      ],
      correctIndex: 0,
      whyLine: 'Chardonnay and White Burgundy get a wider bowl so oak-aged '
          'whites develop creamy texture and layered flavour.',
      sourceUnitId: 'training_wine_c31_u1',
      answerEvidence: 'the Chardonnay and White Burgundy glass, which offers a '
          'wider bowl that softens acidity',
    ),
    // ---- c32: Specialty Glasses ---------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c32_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c32',
      prompt: 'Which glass is tailored for medium-bodied reds with gripping '
          'tannins?',
      options: <String>[
        'The Syrah/Shiraz glass',
        'The Riesling glass',
        'The coupe',
        'The Sauvignon Blanc glass',
      ],
      correctIndex: 0,
      whyLine: 'The Syrah/Shiraz glass suits medium-bodied reds, balancing '
          'gripping tannins with concentrated fruit.',
      sourceUnitId: 'training_wine_c32_u0',
      answerEvidence: 'the Syrah/Shiraz glass is tailored for medium-bodied reds',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c32_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c32',
      prompt: 'What do red wines of every style benefit from in a glass?',
      options: <String>[
        'Larger bowls that encourage interaction with air',
        'Smaller bowls that keep air out',
        'A chilled glass straight from the freezer',
        'A stemless tumbler held in the palm',
      ],
      correctIndex: 0,
      whyLine: 'Larger bowls let reds interact with air, and the wider opening '
          'tames tannins and releases aromatics.',
      sourceUnitId: 'training_wine_c32_u0',
      answerEvidence: 'larger bowls that encourage interaction with air',
    ),
    // ---- c33: Reading Wine Labels -------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c33_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c33',
      prompt: 'A label names a single vineyard rather than a broad region. What '
          'does that usually signal?',
      options: <String>[
        'Higher quality and greater expense',
        'A cheaper, value-oriented wine',
        'That the wine is non-vintage',
        'That the wine contains no sulfites',
      ],
      correctIndex: 0,
      whyLine: 'The narrower the source on the label, the more refined and '
          'expensive the wine tends to be.',
      sourceUnitId: 'training_wine_c33_u0',
      answerEvidence: 'suggests higher quality and greater expense',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c33_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c33',
      prompt: 'A guest asks what Reserve on a label guarantees. What is the '
          'honest answer?',
      options: <String>[
        'Nothing official: the term has no legal definition',
        'At least ten years in oak',
        'That the wine is estate bottled',
        'That the grapes came from a single vineyard',
      ],
      correctIndex: 0,
      whyLine: 'Reserve has no official legal definition, so it guarantees '
          'nothing on its own.',
      sourceUnitId: 'training_wine_c33_u2',
      answerEvidence: 'carries no official legal definition',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c33_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c33',
      prompt: 'Does Old Vine on a label mean the vines are a regulated minimum '
          'age?',
      options: <String>[
        'No, there is no regulatory threshold for vine age',
        'Yes, the vines must be at least fifty years old',
        'Yes, but only in the United States',
        'Yes, and no younger fruit may be blended in',
      ],
      correctIndex: 0,
      whyLine: 'Old Vine has no regulatory threshold, and the blend may even '
          'include younger vine grapes.',
      sourceUnitId: 'training_wine_c33_u3',
      answerEvidence: 'there is no regulatory threshold for vine age',
    ),
    // ---- c34: How to Open Wine ----------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c34_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c34',
      prompt: 'When you present a bottle at the table, which way should the '
          'label face?',
      options: <String>[
        'Facing the guests',
        'Facing you, so you can read it',
        'Turned down toward the floor',
        'It does not matter',
      ],
      correctIndex: 0,
      whyLine: 'Present the bottle with the label facing the guests while you '
          'introduce the wine.',
      sourceUnitId: 'training_wine_c34_u0',
      answerEvidence: 'holding it with the label facing the guests',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c34_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c34',
      prompt: 'Why do you set the cork to the side after opening?',
      options: <String>[
        'So guests can see the cork is moist on the wine end and dry on the outer end',
        'So the sommelier can reuse it later',
        'To keep the table looking full',
        'Because the cork must stay warm',
      ],
      correctIndex: 0,
      whyLine: 'A well-preserved cork is moist on the submerged end and dry '
          'outside, a simple sign of good storage.',
      sourceUnitId: 'training_wine_c34_u3',
      answerEvidence: 'a well-preserved cork will be noticeably moist on the end '
          'that was submerged in wine',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c34_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c34',
      prompt: 'From which side is wine poured, and whose glass is filled last?',
      options: <String>[
        'From the right, with the host\'s glass filled last',
        'From the left, with the host\'s glass filled first',
        'From the right, with the host\'s glass filled first',
        'From wherever there is space, in any order',
      ],
      correctIndex: 0,
      whyLine: 'Food goes from the left and wine from the right, pouring '
          'clockwise with the host served last.',
      sourceUnitId: 'training_wine_c34_u4',
      answerEvidence: 'wine is poured from the right',
    ),
    // ---- c35: How to Open Champagne/Sparkling -------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c35_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c35',
      prompt: 'Why chill a sparkling wine before opening it?',
      options: <String>[
        'It reduces internal pressure and prevents a geyser',
        'It makes the cork easier to twist off',
        'It raises the pressure for a louder pop',
        'It dissolves the wire cage',
      ],
      correctIndex: 0,
      whyLine: 'Chilling lowers the internal pressure, which is what prevents '
          'the explosive geyser effect.',
      sourceUnitId: 'training_wine_c35_u0',
      answerEvidence: 'a step that reduces internal pressure',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c35_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c35',
      prompt: 'When opening sparkling wine, do you turn the cork or the bottle?',
      options: <String>[
        'Rotate the bottle from its base while holding the cork steady',
        'Twist the cork hard while holding the bottle still',
        'Shake the bottle until the cork loosens',
        'Pull the cork straight out with both hands',
      ],
      correctIndex: 0,
      whyLine: 'Never twist the cork itself: it can snap. Turn the bottle from '
          'the base and hold the cork steady.',
      sourceUnitId: 'training_wine_c35_u1',
      answerEvidence: 'never twist the cork itself, as that could cause it to '
          'snap',
    ),
    // ---- c36: How to Pour Champagne/Sparkling -------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c36_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c36',
      prompt: 'What happens if you pour champagne straight down into an upright '
          'flute?',
      options: <String>[
        'It creates a turbulent rush of carbon dioxide that rapidly overflows',
        'It loses all of its bubbles instantly',
        'It warms the wine by several degrees',
        'It makes the wine taste sweeter',
      ],
      correctIndex: 0,
      whyLine: 'Pouring straight down churns up carbon dioxide, so the glass '
          'overflows and wine is wasted.',
      sourceUnitId: 'training_wine_c36_u0',
      answerEvidence: 'creates a turbulent rush of carbon dioxide that rapidly '
          'overflows',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c36_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c36',
      prompt: 'What is the clean way to pour a sparkling wine?',
      options: <String>[
        'Tilt the flute and let the wine cascade down the inner side of the glass',
        'Hold the flute upright and pour as fast as possible',
        'Fill the glass to the very rim in one go',
        'Pour into the centre from a height to aerate it',
      ],
      correctIndex: 0,
      whyLine: 'Tilt the flute, rest the bottle lip on the rim, and let the wine '
          'run down the side to limit foaming.',
      sourceUnitId: 'training_wine_c36_u0',
      answerEvidence: 'tilting the flute at a 45-degree angle and resting the '
          'bottle\'s lip on the rim of the glass',
    ),
    // ---- c37: How to Decant Wine --------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c37_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c37',
      prompt: 'Why decant an older red?',
      options: <String>[
        'To pour it away from the sediment',
        'To warm it up quickly',
        'To add oxygen so it tastes younger',
        'To remove its colour',
      ],
      correctIndex: 0,
      whyLine: 'Older reds throw sediment, and stirring it up clouds the wine '
          'and adds bitter, gritty texture.',
      sourceUnitId: 'training_wine_c37_u0',
      answerEvidence: 'gently pouring an older vintage away from the sediment',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c37_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c37',
      prompt: 'As a practical rule, which reds are worth decanting even with no '
          'visible sediment?',
      options: <String>[
        'Any red that has spent five to ten years in bottle',
        'Only reds opened on the same day they were bottled',
        'Only white wines, never reds',
        'Any red under one year old',
      ],
      correctIndex: 0,
      whyLine: 'A red with five to ten years in bottle has likely thrown enough '
          'sediment to warrant decanting.',
      sourceUnitId: 'training_wine_c37_u0',
      answerEvidence: 'any red wine that has spent five to ten years in bottle',
    ),
    // ---- c38: How to Taste Wine ---------------------------------------
    BarrioQuizQuestion(
      id: 'training_wine_c38_q0',
      docId: 'training_wine',
      chapterId: 'training_wine_c38',
      prompt: 'Why hold a tasting glass by the stem?',
      options: <String>[
        'It keeps your hand\'s warmth and finger oils from interfering',
        'It gives you a stronger grip when swirling',
        'It makes the wine look darker',
        'It stops the bowl from cracking',
      ],
      correctIndex: 0,
      whyLine: 'Holding the stem keeps hand warmth and finger oils away from the '
          'wine\'s temperature and clarity.',
      sourceUnitId: 'training_wine_c38_u0',
      answerEvidence: 'holding the glass by the stem keeps your hand\'s warmth '
          'and any lingering finger oils from interfering',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c38_q1',
      docId: 'training_wine',
      chapterId: 'training_wine_c38',
      prompt: 'A guest points at the legs running down the glass and asks if '
          'that means the wine is good. What do they actually show?',
      options: <String>[
        'Higher levels of alcohol and residual sugar',
        'That the wine is of higher quality',
        'That the wine is older than ten years',
        'That the wine has been filtered',
      ],
      correctIndex: 0,
      whyLine: 'Legs betray alcohol and residual sugar, not quality: their '
          'viscosity is what makes them creep.',
      sourceUnitId: 'training_wine_c38_u2',
      answerEvidence: 'what legs actually betray are higher levels of alcohol '
          'and residual sugar',
    ),
    BarrioQuizQuestion(
      id: 'training_wine_c38_q2',
      docId: 'training_wine',
      chapterId: 'training_wine_c38',
      prompt: 'What is the reliable way to judge a wine\'s acidity?',
      options: <String>[
        'Notice how quickly you begin to salivate after swallowing',
        'Count the legs on the side of the glass',
        'Check how dark the colour is',
        'Smell for oak and vanilla',
      ],
      correctIndex: 0,
      whyLine: 'After swallowing, the faster and more copiously you salivate, '
          'the higher the acid.',
      sourceUnitId: 'training_wine_c38_u8',
      answerEvidence: 'pay attention to how quickly you begin to salivate',
    ),
  ],
);
