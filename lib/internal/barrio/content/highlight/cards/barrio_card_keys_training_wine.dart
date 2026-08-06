// Per-CARD key phrases for the Wine Training manual (doc id
// 'training_wine'), authored against the LIVE card bodies in
// `../../training/training_wine_content.dart`.
//
// Every phrase below is a unique, whole-word, non-overlapping substring of
// THAT card's own body, carries no digit, and does not collide with the
// card's chapter-end quiz answer evidence. Each of those is a silent
// failure mode at render time, not an error: the numeric tier and the
// answer-evidence tier both outrank this one and drop a colliding phrase
// whole, and a phrase that does not match simply never lights up. So the
// check runs before the data ships, never after.
//
// The bar the phrases are written to: scanning ONLY the highlights on a
// card must still convey what that card teaches. Phrases are whole ideas
// (a clause carrying a fact), not single nouns, and they name grape
// characteristics, food pairings, service steps, and regions rather than
// trivia.
//
// Cards with fewer than three phrases that survive those rules carry NO
// entry and fall back to the per-manual list, which is what keeps partial
// coverage safe. See `barrio_card_keys_index.dart` for the full authoring
// contract.

const Map<String, List<String>> kBarrioCardKeysTrainingWine =
    <String, List<String>>{
  // ---- c0: What Is Wine ---------------------------------------------
  'training_wine_c0_u0': <String>[
    'begins with the harvesting and crushing of grapes',
    'yeast converts the natural sugars present in the fruit into alcohol',
    '"Old World" refers to traditional winemaking regions such as France, Italy, and Spain',
    'showcasing the earthiness, minerality, and unique characteristics of the local terroir',
    '"New World" wines emerge from regions like the United States, Australia, and Chile',
    'create fruit-forward wines that highlight the specific grape varieties used',
  ],
  'training_wine_c0_u1': <String>[
    'Unlike table grapes, which are larger and sweeter',
    'wine grapes are smaller, with thicker skins and a concentrated burst of sugars, tannins, and acidity',
    'influenced not only by its genetics but also by the soil, climate, and the choices made by the winemaker',
    'emphasizing the seasonal nature of winemaking',
    'each vintage year on a wine label signifies a snapshot in time',
    'insight into the conditions that shaped that particular bottle',
  ],
  // ---- c1: Key Elements ---------------------------------------------
  'training_wine_c1_u0': <String>[
    'the intricate interplay of factors that define a vineyard\'s unique character',
    'cooler climates are instrumental in preserving high malic acid levels',
    'warmer climates contribute to thicker grape skins and richer tannins',
    'deep clay soils, which retain moisture and soften tannins',
    'gravel soils create natural water stress that encourages deep-rooted vines',
    'deliberate choices in harvest timing, fermentation techniques, and aging methods',
  ],
  'training_wine_c1_u1': <String>[
    'Red grapes are known for delivering rich, intense dark fruit flavors',
    'white grapes typically impart more vibrant and refreshing flavors',
    'how heavy or light it feels on the palate',
    'Full-bodied wines, for instance, deliver a rich and velvety sensation',
    'medium-bodied wines strike a harmonious balance between weight and freshness',
    'Light-bodied wines, on the other hand, offer a more delicate and refreshing profile',
  ],
  'training_wine_c1_u2': <String>[
    'backbone that brings freshness, balance, and aging potential',
    'The three primary acids found in wine are tartaric, malic, and citric',
    'tartaric acid, which serves as the foundational structure and aids in microbial stability',
    'malic acid, abundant in cool-climate grapes and contributing a refreshing crispness',
    'mellowed through malolactic fermentation',
    'citric acid, which adds a subtle citrus zest',
  ],
  'training_wine_c1_u3': <String>[
    'Tannins are the grippy, mouth-drying compounds',
    'adding the structure and assisting with the aging of red wines',
    'vary significantly depending on the grape variety, climate, and winemaking techniques',
    'Bold, high-tannin wines like Cabernet Sauvignon, Nebbiolo, and Syrah can initially present astringency',
    'they develop smoother, more refined textures',
    'softer reds such as Merlot boast lower tannin levels, making them more approachable',
  ],
  // ---- c2: Red v.s White --------------------------------------------
  'training_wine_c2_u0': <String>[
    'Red wine is crafted from dark grapes, undergoing fermentation alongside their skins',
    'allows for the extraction of vibrant color and tannins',
    'impart a rich, bold flavor and a characteristic astringency',
    'white wine is typically produced from lighter-skinned grapes',
    'resulting in a wine devoid of tannins',
    'zesty acidity and bright aromas reminiscent of citrus, apple, and tropical fruits',
  ],
  // ---- c3: Common Red Wine Grape Varietals --------------------------
  'training_wine_c3_u0': <String>[
    'embodies the essence of terroir',
    'sun-drenched vineyards of Napa Valley in California',
    'deep color and full-bodied structure',
    'moderate to high acidity and high tannin levels',
    'In Bordeaux, where Cabernet Sauvignon reigns supreme',
    'layers of black currant, dark spices, and cedarwood',
  ],
  'training_wine_c3_u1': <String>[
    'warm climate allows for grapes to achieve optimal ripeness',
    'rich with blackberry, plum, and hints of cocoa',
    'distinctive terra rossa soil imparting an unmistakable touch of menthol and eucalyptus',
    'Chile\'s Maipo Valley offers a harmonious blend of Old World and New World styles',
    'highlight the savory elements of the grape',
    'intriguing hints of tomato leaf',
  ],
  'training_wine_c3_u2': <String>[
    'The grape\'s thick skins protect it from disease',
    'ability to adapt to various soils and climates',
    'aging potential that reveals complex layers of leather, tobacco, and cedarwood',
    'a favorite among collectors and enthusiasts',
  ],
  'training_wine_c3_u3': <String>[
    'origins traced back to the ancient vineyards of France',
    'moderate to high acidity and low to medium tannins',
    'lighter color and elegant structure',
    'notoriously challenging to cultivate',
    'early harvests tend to produce wines with heightened acidity and lower alcohol',
    'Burgundy, France, remains the spiritual heart of Pinot Noir',
  ],
  'training_wine_c3_u4': <String>[
    'Central Otago in New Zealand, California, and Oregon in the USA',
    'vibrant, fruit-forward expressions that contrast the more restrained style of Burgundy',
    'lush fruit flavors alongside the grape\'s signature earthiness',
    'California\'s diverse climates allow for a wide range of styles',
    'Oregon has also emerged as a notable player',
    'balance fruit, acidity, and complexity',
  ],
  'training_wine_c3_u5': <String>[
    'a key component of Champagne production',
    'Blended with Chardonnay and Pinot Meunier',
    'contributes body and structure to the sparkling wines',
    'delicate balance of flavors',
    'express the nuances of the terroir from which it hails',
  ],
  'training_wine_c3_u6': <String>[
    'producing some of the most intense and complex red wines',
    'Originating from the Rhône Valley in France',
    'cornerstone of renowned wines such as Hermitage and Côte-Rôtie',
    'blackberry, black pepper, and hints of mint',
    'natural medium acidity of these wines invites aging',
  ],
  'training_wine_c3_u7': <String>[
    'the climate is warmer and fruit ripens more fully',
    'vibrant notes of ripe blackberry and distinctive spice',
    'fuller body, medium-high to high tannins, and a luscious mouthfeel',
    'Mendoza in Argentina produces remarkable Syrah wines',
    'benefiting from high altitudes and significant temperature variations between day and night',
    'flavors of licorice and dark chocolate to emerge as the wine matures',
  ],
  'training_wine_c3_u8': <String>[
    'regions like Paso Robles and Sonoma',
    'mirrors the opulence of the Barossa Valley',
    'rich, fruit-driven wines layered with spices and earthy undertones',
    'both bold and nuanced expressions of this powerful grape',
    'convey the essence of its terroir',
  ],
  'training_wine_c3_u9': <String>[
    'its name implying a diminutive version of Syrah',
    'robust structure, elevated tannins, and lively acidity',
    'deeply concentrated and richly textured',
    'Thriving particularly in California\'s diverse wine regions',
    'dense, full-bodied red wines',
    'ripe blackberry, luscious plum, and velvety dark chocolate',
  ],
  'training_wine_c3_u10': <String>[
    'traces back to the Mediterranean regions of Apulia in Italy and Croatia',
    'found a particularly hospitable home in California',
    'bold, black-skinned grape',
    'jammy raspberries and blackberries, intertwined with hints of anise and black pepper',
    'White Zinfandel, a sweeter rosé variant',
    'retains a certain level of residual sweetness due to its high sugar content',
  ],
  'training_wine_c3_u11': <String>[
    'originated in Cahors, France',
    'Locally referred to as Côt',
    'dark fruit profiles and earthy nuances',
    'complex flavors that highlight dark berries and plum',
    'medium acidity and a full body',
    'allowing its tannins to soften and its flavors to evolve',
  ],
  'training_wine_c3_u12': <String>[
    'Mendoza, Argentina has become synonymous with Malbec',
    'high-altitude vineyards that define the region',
    'luscious flavors of ripe plum and dark berries',
    'warm, sunny climate coupled with cool nights allows for optimal ripening',
    'aging process in oak barrels further elevates Malbec\'s profile',
    'enhancing its chocolate and spice notes',
  ],
  'training_wine_c3_u13': <String>[
    'known as Grenache in France',
    'low to medium acidity, low to medium tannins, and a medium body',
    'coupled with high alcohol content',
    'Thriving in warm, arid climates',
    'thick skins and drought-resistant nature',
    'juicy red berry flavors, along with subtle herbal notes and a touch of spice',
  ],
  'training_wine_c3_u14': <String>[
    'iconic wines like Châteauneuf-du-Pape in the Rhône Valley',
    'often blended with Syrah and Mourvèdre',
    'rich, full-bodied wines that are both inviting and richly textured',
    'winemakers experiment with its bold profile',
    'juicy fruit, soft tannins, and warming alcohol',
  ],
  'training_wine_c3_u15': <String>[
    'Bordeaux in France, Napa Valley in the United States, Tuscany in Italy',
    'likely named after the French word "merle" which means blackbird',
    'medium acidity, medium chalky tannins, and a medium-to-full body',
    'notes of red or black plum, depending on the ripeness',
    'subtle hints of chocolate, mild cherry, and leafy nuances',
    'soften the bold tannins of Cabernet Sauvignon',
  ],
  'training_wine_c3_u16': <String>[
    'loose clusters and large berries',
    'high sugar content while maintaining lower levels of malic acid',
    'signature soft and round mouthfeel',
    'earlier picking to retain acidity and enhance the wine\'s aging potential',
    'later harvesting to amplify the ripe fruit characteristics',
    'richer, darker flavors of plum and chocolate',
  ],
  'training_wine_c3_u17': <String>[
    'high acidity, medium-plus tannins, and full-bodied structure',
    'Chianti, Brunello di Montalcino, and Vino Nobile di Montepulciano',
    'warm Mediterranean climate and diverse terroirs allow Sangiovese to flourish',
    'red cherry, earthy herbs, dried flowers, and leather',
    'provide a structure that pairs beautifully with food',
    'compatibility with oak aging enhances its depth and complexity',
  ],
};
