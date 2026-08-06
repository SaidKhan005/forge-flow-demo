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
  // ---- c4: Common White Wine Grape Varietals ------------------------
  'training_wine_c4_u0': <String>[
    'most notably Bordeaux and the Loire Valley in France',
    'celebrated for its high acidity and distinctive flavor profile',
    'showcases Sauvignon Blanc\'s mineral-driven character',
    'crisp, dry, and often infused with zesty notes of green apple, citrus, and grassy herbs',
    'In New Zealand\'s Marlborough region, Sauvignon Blanc has garnered international fame',
    'Chilean versions may present a more approachable fruitiness with a slightly herbal undertone',
  ],
  'training_wine_c4_u1': <String>[
    'A distinguished variation of Sauvignon Blanc that was introduced in California',
    'unique oak aging process',
    'imparts smoky and toasty flavors to the wine',
    'subtle notes of hazelnut and caramel',
    'offers a richer, rounder texture',
  ],
  'training_wine_c4_u2': <String>[
    'Originating from the esteemed Burgundy region of France',
    'one of the most universally embraced white wine grapes worldwide',
    'In cooler climates, expect vibrant notes of green apple, pear, and citrus',
    'warmer regions present luscious flavors of fig and tropical fruits',
    'chalk and limestone enhancing its structure and minerality',
  ],
  'training_wine_c4_u3': <String>[
    'particularly through oak aging and malolactic fermentation',
    'adding layers of toasty vanilla, spice, and caramel',
    'a creamy, buttery mouthfeel',
    'it plays a vital role in crafting exquisite sparkling wines, most notably Champagne',
    'contributes a seamless balance of elegance and acidity',
  ],
  'training_wine_c4_u4': <String>[
    'while genetically identical, showcase distinct personalities',
    'produces Pinot Gris wines that are often fuller-bodied and more textured',
    'flavors of ripe pear, lemon, and subtle floral notes',
    'smooth, sometimes oily mouthfeel',
    'Italy\'s Pinot Grigio is celebrated for its approachable, light, and crisp character',
    'bright lemon and melon notes',
  ],
  'training_wine_c4_u5': <String>[
    'such as Oregon and Washington in the USA, as well as California and Australia',
    'wines with lower acidity and higher alcohol levels',
    'a fuller mouthfeel that can mimic the richness found in Alsace',
    'leans towards lush fruitiness',
    'a more opulent style, with pronounced fruit flavors',
  ],
  'training_wine_c4_u6': <String>[
    'notably Germany, Alsace, Australia, Washington State, and New Zealand',
    'steep, slate-rich hillsides of the Mosel and Rheingau',
    'allowing it to age gracefully',
    'Alsace produces drier Rieslings that are more structured',
    'Australian Rieslings, especially from the Clare and Eden Valleys, present a vibrant lime character',
  ],
  'training_wine_c4_u7': <String>[
    'balance citrus acidity with aromatic notes',
    'In Washington State, Riesling retains its crisp, refreshing profile',
    'hints of honeysuckle and tropical fruit',
    'emphasize a broader range of flavors, including toast and spice',
    'flavor notes ranging from citrus and honey to wax and even a hint of petrol',
  ],
  'training_wine_c4_u8': <String>[
    'including Alsace in France, Germany, Northern Italy, the Pacific Northwest of the USA, and Australia',
    'low acidity, full body, and high aromatic profile',
    'distinguishes itself with a deeper complexity and an unmistakable lush texture',
    'trace back to a Traminer variety from northern Italy',
    'buds early and thrives best in cooler climates',
    'a lingering residual sweetness that captivates the palate',
  ],
  'training_wine_c4_u9': <String>[
    'originating from the Loire Valley in France',
    'ranging from crisp, dry whites to rich, lusciously sweet dessert styles',
    'high acidity and vibrant fruit notes, such as honeyed apple, quince, and floral undertones',
    'riper flavors like peach and tropical fruit',
    'affectionately known as Steen',
    'the country\'s most widely planted variety',
  ],
  'training_wine_c4_u10': <String>[
    'roots that potentially tracing back to ancient Egypt',
    'a common signature of high aromatics and fruit-forward profiles',
    'highly aromatic and often sweet nature, featuring a light to medium body',
    'Fresh flavor notes of citrus, rose, and peach',
    'complex notes reminiscent of fruit cake, raisins, and toffee',
  ],
  'training_wine_c4_u11': <String>[
    'Muscat of Alexandria stands out for its adaptability and abundance',
    'thriving in warmer climates and lending itself to the production of sweet dessert wines',
    'Muscat Blanc à Petits Grains, revered for its floral and melon flavors',
    'essential in crafting iconic wines such as Moscato d\'Asti',
    'Muscat Ottonel\'s cool-climate origins yield lighter, delicately sweet wines',
    'the Black Muscat variety produces richly aromatic red wines',
  ],
  // ---- c5: Other Notable Grape Varietals ----------------------------
  'training_wine_c5_u0': <String>[
    'A high-acid white grape from northwestern Spain',
    'high tannins, tar and rose aromas',
    'offering dry, aromatic wines with citrus, floral, and mineral notes',
    'high alcohol, bright acidity, red berry flavors, and earthy, gamey notes',
    'high acidity, subtle fruit flavors, and use in Brandy production',
    'high acidity and low tannins, delivering juicy dark fruit flavors',
  ],
  'training_wine_c5_u1': <String>[
    'known for its floral, aromatic wines with bright citrus, peach, and tropical fruit notes',
    'A Greek white variety from Santorini, producing crisp, mineral-rich wines',
    'combining Pinot Noir\'s fruitiness with Cinsault\'s earthiness',
    'A full-bodied, aromatic white from France\'s Rhône Valley',
    'Spain\'s flagship red grape, used in Rioja and Ribera del Duero',
    'known for its rich blackberry, herbal, and meaty characteristics',
  ],
  // ---- c6: Sparkling Wine -------------------------------------------
  'training_wine_c6_u0': <String>[
    'the benchmark for sparkling wine',
    'must originate from the specific Champagne region in northern France',
    'the second fermentation occurs inside a sealed bottle, trapping carbon dioxide to create bubbles',
    'spend extended time on the yeast lees',
    'a distinctive aroma of fresh baked bread and a creamy, luxurious mouthfeel',
  ],
  'training_wine_c6_u1': <String>[
    'a style often celebrated for its remarkable elegance and finesse',
    'a blanc de noirs (white of blacks) is a white Champagne produced exclusively from the red grapes',
    'typically richer and more full-bodied',
    'red base wine is added to white base wine until the desired shade is achieved',
    'a method employed before the second fermentation that is rarely used elsewhere in winemaking',
  ],
  'training_wine_c6_u2': <String>[
    'dominated by non-vintage (NV) offerings',
    'the base wine is a skillful blend of multiple vintages',
    'This blending ensures remarkable consistency from year to year',
    'setting aside the best lots to create a vintage Champagne',
    'A producer\'s finest offering, often made from the best fruit and vineyards, is known as a prestige cuvée',
  ],
  'training_wine_c6_u3': <String>[
    'mandatory sur lie aging where bottles rest on spent yeast cells called lees',
    'imparts bready, biscuit-like flavors and a creamy mouthfeel',
    'the lees must be removed through a process called disgorging',
    'topping up with a reserve wine known as liqueur d\'expédition',
    'which may include added sugar, known as a dosage',
    'from bone-dry Brut Nature to sweet Doux',
  ],
  'training_wine_c6_u4': <String>[
    'its meticulous, labor-intensive production and the prestige of its terroir',
    'the high real estate value of the Champagne region',
    'results in a higher price compared to other bubblies',
    'remarkably flexible with food and sublime on its own',
  ],
  'training_wine_c6_u5': <String>[
    'French sparkling wines produced outside the Champagne region',
    'made using the same traditional method as Champagne',
    'a fraction of the price of their Champagne counterparts',
    'Produced across key wine regions such as the Loire Valley, Alsace, and Burgundy',
    'reliably delicious, refreshing, and consistently affordable',
  ],
  'training_wine_c6_u6': <String>[
    'the best-known examples hailing from Penedès near Barcelona',
    'local Spanish varieties like Macabeo, Xarel·lo, and Parellada',
    'warmer climate typically yields lower acidity than French counterparts',
    'less pronounced bready notes and lower acidity',
    'noticeably more body and structure',
    'pairs well with a wide range of foods',
  ],
  'training_wine_c6_u7': <String>[
    'A premium sparkling wine from Lombardy in northern Italy',
    'crafted primarily from Chardonnay and Pinot Noir',
    'the traditional "metodo classico" (secondary fermentation in bottle)',
    'earned Italy\'s highest DOCG classification',
  ],
  'training_wine_c6_u8': <String>[
    'an appellation in the northeastern corner of Italy',
    'only wines from this specific area can legally bear the name Prosecco',
    'the Conegliano-Valdobbiadene zone',
    'typically made with the local Glera grape varietal',
    'secondary fermentation occurs in large pressurized tanks rather than in individual bottles',
    'preserving fresh fruit flavors like green apple and melon',
  ],
  'training_wine_c6_u9': <String>[
    'significantly more affordable than Champagne',
    'look for "Prosecco Superiore" for premium, extra-fine bottles',
    'the most produced sparkling wine in the world',
    'its light, fruity character is best enjoyed young',
    'pairs beautifully with spicy cuisines and warm-weather occasions',
    'the classic choice for mimosas',
  ],
  'training_wine_c6_u10': <String>[
    'A red sparkling wine from central Italy',
    'ranges in color from light ruby to deep purple',
    'can be either bone dry or semi-sweet',
  ],
  'training_wine_c6_u11': <String>[
    'these aromatic sparkling wines are sweeter and lower in alcohol',
    'delightful flavours of peaches, grapes, and roses',
    'Moscato d\'Asti offers a lightly sparkling style with lower alcohol and less sweetness',
  ],
  'training_wine_c6_u12': <String>[
    'a sparkling wine produced in Germany',
    'often made from grapes imported from Italy or France',
    'Germany itself is the world\'s largest consumer of sparkling wine',
    'bottles labeled as Deutscher Sekt',
    'must be made entirely from German-grown grapes',
    'the finest examples typically crafted from Riesling',
  ],
  'training_wine_c6_u13': <String>[
    'elegant, complex traditional method sparkling wines',
    'primarily from Chardonnay and Pinot Noir',
    'cooler regions such as the Yarra Valley, Adelaide Hills, and Tasmania',
    'the Southern Hemisphere\'s preeminent red sparkling wine',
    'ripe red berry flavors and a touch of sweetness',
  ],
};
