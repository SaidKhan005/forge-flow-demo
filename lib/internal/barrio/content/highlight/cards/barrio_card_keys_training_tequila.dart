// Per-CARD key phrases for the Tequila manual (doc id 'training_tequila'),
// authored against the LIVE card bodies in
// `../../training/training_tequila_content.dart`.
//
// Every phrase below is a unique, whole-word, non-overlapping substring of
// THAT card's own body, carries no digit, and does not collide with the
// card's chapter-end quiz answer evidence. Each of those is a silent
// failure mode at render time, not an error: the numeric tier and the
// answer-evidence tier both outrank this one and drop a colliding phrase
// whole, and a phrase that does not match simply never lights up. So the
// check runs before the data ships, never after.
//
// TEQUILA IS A TERM-LINK HOST. This manual sits in
// [BarrioTermLinks.kHostManualIds], so a FIFTH tier is live on these cards
// that is not live on most of the corpus: tap-to-define glossary links,
// which outrank key phrases and drop an overlapping phrase whole. Every
// phrase here was validated against the deployed matcher
// ([BarrioTermLinks.matchesIn] over [chunksForBody] chunks, with one
// `alreadyLinked` set threaded in reading order), not an approximation of
// it. The matcher claims no span on any tequila card today, so the
// collision count is zero by content rather than by luck;
// `test/barrio_card_keys_term_link_test.dart` is what keeps it that way.
//
// The bar the phrases are written to: scanning ONLY the highlights on a
// card must still convey what that card teaches. Phrases are whole ideas
// (a clause carrying a fact), not single nouns, and they name the legal
// definition, the production steps, what separates each class, and how to
// serve the spirit rather than trivia.
//
// The no-digit rule bites on the class cards in particular: every class is
// defined by an ageing window, and those windows are numeric-tier facts
// ('a minimum of two months but less than a year' survives because the
// source writes it in words, while '600 liters' and '51% agave' cannot).
// The phrases carry the character the ageing produces instead.
//
// Cards with fewer than three phrases that survive those rules carry NO
// entry and fall back to the per-manual list, which is what keeps partial
// coverage safe. Tequila has one: c2_u0 is a single lead-in line ('All
// Tequila falls into one of these five categories:') that introduces the
// five class cards and teaches nothing on its own. See
// `barrio_card_keys_index.dart` for the full authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingTequila =
    <String, List<String>>{
  // ---- c0: Tequila Training -----------------------------------------
  'training_tequila_c0_u0': <String>[
    'one of the most highly regulated alcoholic beverages in the world',
    'Originating from the small town of Amatitán',
    'The town\'s railway system played a crucial role in transporting tequila',
    'vino de mezcal',
    'The distinctive "Tequila" stamp on shipments highlighted its origins',
    'the mezcal descriptor was dropped altogether',
  ],
  'training_tequila_c0_u1': <String>[
    'must adhere to stringent production regulations',
    'distilled from the blue weber agave',
    'thrives in the specific climates found in designated regions of Mexico',
    'derived from the cooked and fermented juices of this exquisite agave',
    'the remaining components derived from other sugars',
    'preserving the integrity of tequila as a unique Mexican spirit',
  ],
  'training_tequila_c0_u2': <String>[
    'its Denomination of Origin status',
    'legally protects the production of tequila to certain regions of Mexico',
    'effectively preventing imitations',
    'a unique NOM (Norma Oficial Mexicana) number, which identifies the specific distillery',
    'The Consejo Regulador de Tequila (CRT) plays an essential role in maintaining these standards',
    'from planting the agave to bottling the final product',
  ],
  // ---- c1: How Tequila Is Made --------------------------------------
  'training_tequila_c1_u0': <String>[
    'crafted from the heart of the Blue Weber agave plant',
    'Native to the volcanic soils of the Jalisco region',
    'Skilled harvesters known as jimadores use a tool called the coa',
    'strip away the agave\'s spiky leaves revealing the piña, or heart of the agave',
    'resembles a giant pineapple',
    'This labor-intensive method reflects not only skill but also a deep respect for the plant',
  ],
  'training_tequila_c1_u1': <String>[
    'slow-baked in large steam ovens, known as hornos',
    'converts the complex carbohydrates within the agave into fermentable sugars',
    'traditional volcanic stone wheels called tahonas',
    'yeast is introduced to commence fermentation',
    'the yeast converts the sugars into alcohol',
    'distilled twice (and sometimes even three times) in copper or stainless steel stills',
  ],
  'training_tequila_c1_u2': <String>[
    'allow for variations in flavor and character',
    'bottled immediately or within a couple of months to produce a clear "Blanco" (Silver) tequila',
    'others are aged in oak barrels for extended periods',
    'This aging process not only deepens the color',
    'drawing out notes of vanilla, caramel, and spice',
  ],
  // ---- c2: Classes of Tequila ---------------------------------------
  'training_tequila_c2_u1': <String>[
    'celebrated for its purity and authenticity',
    'Typically bottled shortly after distillation',
    'this unaged spirit highlights the skill of the distiller',
    'enhancing its complexity without overshadowing its vibrant essence',
    'the rich aromas and flavors of cooked agave',
  ],
  'training_tequila_c2_u2': <String>[
    'Also known as "oro" or "joven" in Spanish',
    'typically falls under the mixto classification',
    'essentially a blanco tequila enhanced with added flavors and colors',
    'alternative sources such as cane sugar, beet sugar, or even high-fructose corn syrup',
    'This blending of sugar sources is what gives the mixtos their name',
    'joven tequila represents a sophisticated blend of blanco and other types of tequila',
  ],
  'training_tequila_c2_u3': <String>[
    'undergoes a unique aging process that lasts a minimum of two months but less than a year',
    'ranging from traditional barrels to larger tanks',
    'strike a harmonious balance between the vibrant, agave-forward flavors of a blanco tequila',
    'the smooth, complex notes of vanilla and caramel imparted by the toasted oak',
    'falls between the fresh vibrancy of blanco and the deep complexity of añejo',
  ],
  'training_tequila_c2_u4': <String>[
    'Derived from the Spanish word for "year" (año)',
    'requirement to age for a minimum of one year but no more than three years in oak barrels',
    'often repurposed from whiskey production',
    'infusing the tequila with rich, oaky flavors',
    'develop a smooth, sophisticated profile',
    'a long, intricate finish',
  ],
  'training_tequila_c2_u5': <String>[
    'undergoes a minimum of three years of maturation in oak barrels',
    'The influence of oak tends to dominate the palate',
    'retain a noticeable essence of agave',
    'the environmental conditions of Jalisco\'s arid climate can lead to significant evaporation',
    'further intensifying the remaining spirit',
    'contributing to the elevated costs associated with this premium tequila class',
  ],
  // ---- c3: Popular Tequila Cocktails --------------------------------
  'training_tequila_c3_u0': <String>[
    'combines the crispness of blanco tequila and the tartness of lime juice',
    'a touch of sweetness from orange liqueur, agave syrup',
    'the refreshing combination of tequila, grapefruit soda, and lime juice',
    'The unofficial cocktail of West Texas',
    'a delightful mix of blanco tequila, lime juice, and sparkling mineral water',
    'grenadine is added last to the combination of tequila and orange juice',
  ],
  'training_tequila_c3_u1': <String>[
    'A Spicy Margarita riff that combines muddled jalapeño and refreshing watermelon cubes',
    'Combines a blanco tequila with Cointreau, lemon juice, and an egg white',
    'replacing the traditional whiskey base with a delightful blend of reposado tequila and smoky mezcal',
    'sweetened with agave nectar',
  ],
  // ---- c4: Mezcal ---------------------------------------------------
  'training_tequila_c4_u0': <String>[
    'celebrated for its distinctive complexity and earthy character',
    'Known primarily for its signature smoky flavor',
    'vary significantly based on the species of agave used and the region of production',
    'the traditional technique of roasting piñas, in open wood-fired earthen pits',
    'rich notes reminiscent of campfire smoke, cedar, and even hints of dark chocolate and leather',
    'The most commonly used agave for mezcal production is Espadín',
  ],
  'training_tequila_c4_u1': <String>[
    'mezcal also reflects its terroir',
    'each bottle represents the unique attributes of its environment',
    'from baked pumpkin and banana to citrus and floral essences like rose and elderflower',
    'hints of green pepper, eucalyptus, mint, or the mineral qualities of wet stone',
    'crafted by artisanal producers known as mezcaleros',
    'employ generational techniques that honor the land',
  ],
  // ---- c5: How to Serve Tequila -------------------------------------
  'training_tequila_c5_u0': <String>[
    'especially the aged varieties like Reposado and Añejo',
    'should be sipped neat at room temperature',
    'preferably from a narrow, tulip-shaped glass or a snifter',
    'tilt the glass for an aromatic preview',
    'younger tequilas or "mixtos" are more suited for icy cocktails',
    'dipping a lime wedge in salt and enjoying it between sips',
  ],
};
