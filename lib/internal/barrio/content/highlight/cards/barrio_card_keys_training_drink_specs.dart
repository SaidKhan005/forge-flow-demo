// Per-CARD key phrases for the Drink Specs manual (doc id
// 'training_drink_specs'), authored against the LIVE card bodies in
// `../../training/training_drink_specs_content.dart`.
//
// Every phrase below is a unique, whole-word, non-overlapping substring of
// THAT card's own body, carries no digit, and does not collide with the
// card's quiz answer evidence. Each of those is a silent failure mode at
// render time, not an error: the numeric tier and the answer-evidence tier
// both outrank this one and drop a colliding phrase whole, and a phrase
// that does not match simply never lights up. So the check runs before the
// data ships, never after.
//
// THE NO-DIGIT RULE IS THE WHOLE STORY ON THIS MANUAL. A spec card is
// pours and counts: '1.5oz Iceberg Vodka', '0.75oz Lime Juice', '3 Dashes
// Worcestershire Sauce', 'Mixing Method: Shake'. Every measurement belongs
// to the numeric tier, which already colours it, so a phrase may only take
// the part of the line the number does NOT own. The phrases here are
// therefore deliberately shorter than on a prose manual: each ingredient
// line contributes its product name, not its pour. Read in order they
// still give a bartender the whole build: garnish, glassware, mixing
// method, the spirits and modifiers in pour order, then the one direction
// step that is not boilerplate ('double strain', 'dry shake', 'clap the
// mint', 'express the peel').
//
// A SECOND, QUIETER TRAP: repetition. A spec card names the same thing
// twice, once in the ingredient list and once in the directions ('Iced
// Tea' / 'iced tea', 'Beer Glass' / 'beer glass', 'Dehydrated Pineapple' /
// 'dehydrated pineapple'). The matcher is case-insensitive, so a phrase
// that is not unique in the body would highlight the first occurrence and
// leave the reader unsure which one was meant. Those phrases were dropped
// and replaced with a longer one that occurs once ('equal parts lemonade
// and iced tea' instead of 'Iced Tea').
//
// TERM LINKS: Drink Specs is NOT in [BarrioTermLinks.kHostManualIds], so
// tap-to-define links do not render here today. The phrases are written
// clear of the four spans the matcher WOULD claim anyway ('Dulce De Leche'
// on c0_u0, 'Yerba Mate' on c2_u0 and c8_u0, 'Tamarind' on c15_u0),
// because staying clear costs those four cards nothing they cannot say
// another way and it means adding this manual to the host set later is a
// config change rather than four silently dark phrases.
//
// All sixteen cards support three or more phrases, so this manual has no
// fall-through card. See `barrio_card_keys_index.dart` for the full
// authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingDrinkSpecs =
    <String, List<String>>{
  // ---- c0: Espresso De Dulce De Leche -------------------------------
  'training_drink_specs_c0_u0': <String>[
    'Salted Caramel',
    'Gold Rim Coupe',
    'Iceberg Vodka',
    'JD Shore Rum Cream',
    'Chilled Espresso',
    'double strain shaker contents into glass',
  ],
  // ---- c1: Picoso Ananas --------------------------------------------
  'training_drink_specs_c1_u0': <String>[
    'Dehydrated Pineapple, Pineapple Frond, Black Salt Rim',
    'Gold Deco Rocks Glass',
    'Alida Blanco Tequila',
    'Jalapeno Syrup',
    'Put large square ice cube in rimmed glass',
    'shake vigorously',
  ],
  // ---- c2: Alegría De Hierbas ---------------------------------------
  'training_drink_specs_c2_u0': <String>[
    'Lemon Twist, Mint Sprig',
    'Nick & Nora',
    'Open Coast Gin',
    'Green Chartreuse',
    'Agave Syrup',
    'Peel lemon, express on drink, twist and skewer with mint',
  ],
  // ---- c3: Cálidas Old Fashioned ------------------------------------
  'training_drink_specs_c3_u0': <String>[
    'Yarai Mixing Glass',
    'Orange Twist',
    'Gold Deco Rocks Glass',
    'Dos Maderas',
    'Vanilla, Cardamom, Clove Extract',
    'Peel orange, express on drink, twist and place in drink',
  ],
  // ---- c4: Sangria De Verano ----------------------------------------
  'training_drink_specs_c4_u0': <String>[
    'Grapefruit Slice, Cherry',
    'Wine Glass',
    'Build',
    'Red or White Wine',
    'Orange, Mango, Pineapple Juice',
    'top with soda water and stir gently',
  ],
  // ---- c5: Ahumado Carjillo -----------------------------------------
  'training_drink_specs_c5_u0': <String>[
    'Orange Twist',
    'Nick & Nora',
    'Mezcal',
    'Simple Syrup',
    'Chilled Espresso',
    'double strain into glass',
  ],
  // ---- c6: El Ruibarbo ----------------------------------------------
  'training_drink_specs_c6_u0': <String>[
    'Gold Rim Coupe',
    'Dry Shake',
    'Pisco',
    'Egg White',
    'Rhubarb Syrup',
    'Remove ice from shaker and shake again',
  ],
  // ---- c7: Cítricos Pisco -------------------------------------------
  'training_drink_specs_c7_u0': <String>[
    'Mint Sprig, Lemon Wheel',
    'Gold Deco Collins Glass',
    'Build',
    'Grapefruit Juice',
    'Add lemon, grapefruit, pisco, and st. germain to glass',
    'Slide lemon wheel down side of glass and add mint sprig',
  ],
  // ---- c8: Coco Mojito ----------------------------------------------
  'training_drink_specs_c8_u0': <String>[
    'Lime Wedge, Mint Sprig',
    'Bamboo Glass',
    'Iceberg White Rum',
    'Agave Syrup',
    'Coconut Milk',
    'Lay a sprig of mint in the center of one palm and clap hands',
  ],
  // ---- c9: Breakfast Margarita --------------------------------------
  'training_drink_specs_c9_u0': <String>[
    'Dehydrated Orange, Salt Rim',
    'Gold Deco Rocks Glass',
    'Shaken',
    'Alida Blanco Tequila',
    'Triple Sec',
    'Rim glass with salt and fill with ice',
  ],
  // ---- c10: Pina Colada Spritz --------------------------------------
  'training_drink_specs_c10_u0': <String>[
    'lime wedge, dehydrated pineapple, pineapple frond',
    'Build',
    'Aluna Coconut Rum',
    'Vado Sparkling',
    'top with soda water and sparkling then stir',
  ],
  // ---- c11: Té Borracho ---------------------------------------------
  'training_drink_specs_c11_u0': <String>[
    'Gold Deco Collins Glass',
    'Build',
    'Iceberg Vodka',
    'Housemade Lemonade',
    'equal parts lemonade and iced tea',
    'Put lemon wheel on side of glass',
  ],
  // ---- c12: Barrio Michelada ----------------------------------------
  'training_drink_specs_c12_u0': <String>[
    'Lime Wedge, Pickled Chili Pepper, Pickled Spicy Bean, Tajin Rim',
    'Build',
    'Crown & Anchor',
    'Clamato Juice',
    'Worcestershire Sauce',
    'top with beer and stir gently',
  ],
  // ---- c13: Legado Caesar -------------------------------------------
  'training_drink_specs_c13_u0': <String>[
    'Lime Wedge, Pickled Chili Pepper, Pickled Spicy Bean, Tajin Rim',
    'Gold Deco Collins Glass',
    'Build',
    'Alida Reposado Tequila',
    'Clamato Juice',
    'Worcestershire Sauce',
  ],
  // ---- c14: Mimosa De Toronja ---------------------------------------
  'training_drink_specs_c14_u0': <String>[
    'Wine Measure',
    'Champagne Flute',
    'Build',
    'Vado Sparkling',
    'Fill flute with grapefruit juice and sparkling',
    'Add grapefruit slice to side of glass',
  ],
  // ---- c15: Tropical Sour -------------------------------------------
  'training_drink_specs_c15_u0': <String>[
    'Nick and Nora Glass',
    'Dry Shake',
    'Alida Blanco',
    'Pineapple Juice',
    'Mango Juice',
    'Egg White',
  ],
};
