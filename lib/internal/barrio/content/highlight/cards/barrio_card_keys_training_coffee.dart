// Per-CARD key phrases for the Coffee manual (doc id 'training_coffee'),
// authored against the LIVE card bodies in
// `../../training/training_coffee_content.dart`.
//
// Every phrase below is a unique, whole-word, non-overlapping substring of
// THAT card's own body, carries no digit, and does not collide with the
// card's chapter-end quiz answer evidence. Each of those is a silent
// failure mode at render time, not an error: the numeric tier and the
// answer-evidence tier both outrank this one and drop a colliding phrase
// whole, and a phrase that does not match simply never lights up. So the
// check runs before the data ships, never after.
//
// COFFEE IS A TERM-LINK HOST. This manual sits in
// [BarrioTermLinks.kHostManualIds], so a FIFTH tier is live on these cards
// that is not live on most of the corpus: tap-to-define glossary links,
// which outrank key phrases and drop an overlapping phrase whole. Every
// phrase here was validated against the deployed matcher
// ([BarrioTermLinks.matchesIn] over [chunksForBody] chunks, with one
// `alreadyLinked` set threaded in reading order), not an approximation of
// it. The matcher claims no span on any coffee card today (the glossaries
// are Latin dishes and ingredients), so the collision count is zero by
// content rather than by luck; `test/barrio_card_keys_term_link_test.dart`
// is what keeps it that way if either side changes.
//
// The bar the phrases are written to: scanning ONLY the highlights on a
// card must still convey what that card teaches. Phrases are whole ideas
// (a clause carrying a fact), not single nouns, and they name bean origin,
// roast behaviour, storage rules, extraction technique, milk technique,
// machine maintenance, and the drink builds rather than trivia.
//
// The no-digit rule bites hard on a manual written around temperatures,
// ratios, and timings: the espresso-extraction, milk, and Brazilian-coffee
// cards all carry their headline number in the numeric tier's colour, so
// the phrases here carry the surrounding technique instead of the figure.
//
// Cards with fewer than three phrases that survive those rules carry NO
// entry and fall back to the per-manual list, which is what keeps partial
// coverage safe. Coffee has one: the Cup Types card is three caption words
// and one of them is already the quiz answer evidence. See
// `barrio_card_keys_index.dart` for the full authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingCoffee =
    <String, List<String>>{
  // ---- c0: What Is Coffee -------------------------------------------
  'training_coffee_c0_u0': <String>[
    'crafted from the roasted and ground seeds',
    'these beans originate from coffee cherries',
    'green beans undergo roasting at high temperatures',
    'While native to Africa, coffee farming has expanded across the globe',
    'coffee serves as a central nervous system stimulant',
    'rich in antioxidants known as polyphenols',
  ],
  // ---- c1: Roasting -------------------------------------------------
  'training_coffee_c1_u0': <String>[
    'they expand and release their natural oils',
    'transitioning through a spectrum of colors from light to dark roast',
    'Blonde roasts showcase the natural notes of fruits, berries, and citrus',
    'these beans are roasted for a shorter duration',
    'emphasizes the bean\'s unique origin and terroir',
  ],
  'training_coffee_c1_u1': <String>[
    'cooking the beans at lower temperatures for extended periods',
    'bringing out the inherent sugars while avoiding excessive oiliness',
    'hints of dark chocolate, floral undertones, and nuances of hazelnuts',
    'elevates the oils within the beans to the surface',
    'rich notes of smoke and caramel',
    'high oil content can lead to potential buildup in brewing equipment',
  ],
  // ---- c2: Enemies of Coffee ----------------------------------------
  'training_coffee_c2_u0': <String>[
    'four main adversaries',
    'Oxygen is the most notorious culprit',
    'leads to oxidation, a process that quickly turns vibrant flavors into stale remnants',
    'degrading the quality of coffee and potentially introducing mildew or unwanted odors',
    'Heat creates issues by accelerating chemical reactions within the beans',
    'The act of grinding releases volatile oils that were once protected inside the bean',
  ],
  // ---- c3: Proper Storage -------------------------------------------
  'training_coffee_c3_u0': <String>[
    'ensures maximum freshness and flavor retention',
    'Avoid storing coffee in the fridge',
    'the fluctuating temperatures and high humidity can negatively affect its delicate profile',
    'grind your coffee just before use',
    'ground coffee loses its vitality rapidly',
  ],
  // ---- c4: Brazilian Coffee -----------------------------------------
  'training_coffee_c4_u0': <String>[
    'primarily cultivating both Arabica and Robusta varieties',
    'hundreds of thousands of coffee plantations sprawling across vast flat terrains',
    'which classifies them as high-grown',
    'floral notes and a bright acidity',
    'clear, sweet, medium-bodied nature, and low acidity',
    'often roasted to a light-medium profile',
  ],
  // ---- c5: Colombian Coffee -----------------------------------------
  'training_coffee_c5_u0': <String>[
    'rugged mountains and diverse ecosystems',
    'consistently mild and well-balanced coffees',
    'two distinct harvest seasons each year',
    'signature smoothness, rich flavor profile, and aromatic sweetness',
    'notes of citrus, caramel, and chocolate',
    'small, family-run farms',
  ],
  'training_coffee_c5_u1': <String>[
    'labor-intensive practices of Colombian coffee cultivation are integral to its premium quality',
    'Farmers meticulously hand-pick the cherries',
    'guarantees the selection of only the best fruit',
    'a distinctive wet-washing method that enhances their clean and bright acidity',
    'strict adherence to growing high-grade Arabica',
  ],
  // ---- c6: Extracting Espresso --------------------------------------
  'training_coffee_c6_u0': <String>[
    'the basket inside the group handle is thoroughly dried',
    'dose the basket with freshly ground coffee',
    'paying attention to the grind size and distribution',
    'clean any loose grounds off the rim of the handle for a proper seal',
    'the emergence of the first drops of rich crema',
    'transitions to a "mouse tail" appearance with a lighter color',
  ],
  // ---- c7: Milk -----------------------------------------------------
  'training_coffee_c7_u0': <String>[
    'it significantly enhances the sensory experience of the drink',
    'the luxurious texture and richness that expertly steamed and foamed milk provides',
    'purge the steam valve to eliminate any water',
    'Position the steam nozzle just beneath the milk\'s surface to avoid large bubbles',
    'maintain a central hold to create a smooth whirlpool motion',
    'swirl the milk to combine it with the micro-foam for a glossy finish',
  ],
  // ---- c8: Troubleshooting ------------------------------------------
  'training_coffee_c8_u0': <String>[
    'Under-Extracted Espresso',
    'colour will become pale to almost white very quickly',
    'Over-Extracted Espresso',
    'if the basket is over filled or if the grind is too fine',
    'taste sharp and burnt',
    'If you lose steam pressure you will need to wait for several minutes',
  ],
  // ---- c9: Cleaning & Maintenance -----------------------------------
  'training_coffee_c9_u0': <String>[
    'essential for ensuring optimal performance and longevity',
    'remove the filter baskets from the group handles',
    'a thorough scrubbing of the interior of the handles',
    'wipe the steam arms clean to prevent milk residue buildup',
    'never soak them overnight',
    'detach the screw-on steam arm head and use a pin to clear out any accumulated residue',
  ],
  'training_coffee_c9_u1': <String>[
    'scrubbing the group head with a clean brush to eliminate any coffee residue',
    'remove the filter basket from the espresso handle',
    'which allows for proper backflushing',
    'Insert the handle back into the group head and initiate the water flow',
    'rinse the blind disk thoroughly',
    'Repeat this process several times until no coffee grounds are visible',
  ],
  'training_coffee_c9_u2': <String>[
    'scrubbing the group head with a dedicated head clean brush',
    'place a quarter teaspoon of head clean shampoo into your blank or blind disk',
    'Activate the water flow and count to ten',
    'white froth emerging from the exhaust tube',
    'run the continuous flow button until no further froth is visible',
    'repeat this entire procedure for each group head',
  ],
  'training_coffee_c9_u3': <String>[
    'turn off the grinder, shut off the bean flow, and empty the hopper',
    'clean the grinder thoroughly by wiping it down',
    'removing any leftover ground coffee from the doser',
    'A soft cloth or brush can help you clear away any loose grinds',
  ],
  // ---- c10: Drinks --------------------------------------------------
  'training_coffee_c10_u0': <String>[
    'carefully pour the espresso extraction over the hot water',
    'filling your espresso cup slightly beyond halfway with hot water',
    'Due to the increased surface area, achieving a rich crema can be more challenging',
    'the cup should not be filled to the brim',
    'A short black coffee with a touch of hot milk',
    'gently add a spoonful of hot milk',
  ],
  'training_coffee_c10_u1': <String>[
    'allowing for a secure pour without any spills',
    'gently pour the silky steamed milk into the center of the coffee',
    'using a spoon to hold back most of the froth',
    'scoop off the excess froth from the milk jug before pouring',
    'slightly creamier compared to that of a flat white',
    'the thicker, lightly textured milk',
  ],
  'training_coffee_c10_u2': <String>[
    'gently spooning the thick, textured top milk into your cappuccino cup',
    'pour the hot, lightly textured milk through the center of the frothed milk',
    'set aside the heavily textured milk',
    'pour about half a cup of the lighter milk directly into the double shot',
    'Use the spoon to carefully incorporate the remaining thick milk into the cup',
  ],
  // ---- c11: Our Coffee ----------------------------------------------
  'training_coffee_c11_u0': <String>[
    'Base Camp is a distinguished Colombian coffee',
    'sweet, full-bodied profile',
    'exceptional choice for both espresso and milk-based drinks',
    'fostering cooperatives that prioritize gender equality',
    'delightful impressions of cacao, crème brûlée, and cherry',
  ],
  'training_coffee_c11_u1': <String>[
    'a Brazilian coffee expertly ground for drip brewing',
    'tasting notes of chocolate, apple, and nougat',
    'an ideal companion for milk',
    'A delightful Colombian coffee',
    'notes of brownie, candied pecan, and honey',
  ],
  // ---- c13: Words to Know -------------------------------------------
  'training_coffee_c13_u0': <String>[
    'a manual, portable coffee maker that brews a smooth, rich cup in under two minutes',
    'The world\'s most widely consumed coffee species',
    'Grown in elevated, mountainous regions',
    'advanced deep-cleaning technique for espresso machines',
    'helps dissolve accumulated coffee oils and grounds, thereby preventing clogs',
    'A perforated metal filter designed specifically for holding your ground coffee',
  ],
  'training_coffee_c13_u1': <String>[
    'A solid filter basket that effectively cleans the internal group head and valves',
    'This seamless, hole-less design prevents water from flowing through',
    'The naturally occurring fruit of the coffee plant',
    'A miniature spoon traditionally used to stir espresso in small cups',
    'A mechanical, pie-compartmented chamber attached to the front of a coffee grinder',
    'gradually pouring hot water over ground coffee contained in a filter',
  ],
  'training_coffee_c13_u2': <String>[
    'A medium grind size that resembles standard granulated sugar or rough sand',
    'Positioned beneath the brewing spout, it effectively collects any spilled coffee',
    'A very fine grind of coffee, similar in texture to table salt or powdered sugar',
    'A porous barrier used in coffee brewing to separate liquid coffee from ground beans',
    'steeping coarse grounds directly in hot water, then pressing the plunger down',
  ],
  'training_coffee_c13_u3': <String>[
    'A device designed to crush or cut whole coffee beans into smaller particles',
    'Also known as a portafilter, it is the removable, handled device on an espresso machine',
    'ensures an even distribution of hot, pressurized water',
    'A specialized chemical powder or tablet formulated to effectively dissolve bitter coffee oils',
    'The container on top of an espresso grinder that holds whole coffee beans before they are ground',
  ],
  'training_coffee_c13_u4': <String>[
    'expertly dehydrated into a soluble powder or crystalline form',
    'A specialized container used to cleanly and quickly dispose of spent espresso grounds',
    'continuously cycling boiling or near-boiling water through coffee grounds',
    'a percolator recirculates the brewed coffee over the beans multiple times',
    'hot water is slowly poured over a bed of coffee grounds in a filter',
  ],
  'training_coffee_c13_u5': <String>[
    'Releasing a brief burst of steam both before and after frothing from the steam wand',
    'eliminate trapped condensation and remove any milk residue from the wand',
    'A robust and high-yielding coffee species',
    'bold, earthy flavor profile and rich crema',
    'A metal pipe attached to an espresso machine that releases pressurized steam',
    'introducing air into cold milk using an espresso machine\'s steam wand to create microfoam',
  ],
  'training_coffee_c13_u6': <String>[
    'A durable, non-slip silicone or rubber mat used in espresso preparation',
    'compress and level ground coffee into a dense, even puck',
    'Milk that has been steamed and aerated using an espresso machine\'s steam wand to create microfoam',
    'Roasted coffee beans left in their natural, full form before being ground',
  ],
};
