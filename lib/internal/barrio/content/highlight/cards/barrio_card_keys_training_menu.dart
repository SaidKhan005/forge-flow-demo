// Per-CARD key phrases for the MENU deck (registry id
// 'training_menu_concept', content `../../training/training_menu_content.dart`),
// authored against the LIVE card bodies.
//
// Every phrase below is a unique, whole-word, non-overlapping substring of
// THAT card's own body, carries no digit, and does not collide with the
// card's quiz answer evidence. Each of those is a silent failure mode at
// render time, not an error: the higher tiers drop a colliding phrase
// whole, and a phrase that does not match simply never lights up. So the
// check runs before the data ships, never after.
//
// THIS IS THE FIRST LIVE SURFACE OF THE TERM-LINK TIER.
//
// The menu deck is the only manual in the corpus where tap-to-define
// glossary links actually fire: 19 of its 24 cards carry 39 spans over 18
// distinct terms ('salsa', 'ceviche', 'aguachile', 'chimichurri', 'lomo
// saltado', 'al pastor', 'tinga', 'mole', 'empanadas', 'fajitas', 'gallo
// pinto', 'tallarines', 'queso fresco', 'ancho', 'cilantro', 'tortilla',
// 'aji amarillo', 'salsa inglesa'). Term links OUTRANK key phrases, so a
// phrase overlapping one is dropped WHOLE and silently at render
// (`handbook_lesson_card.dart` `_composeChunk`). That vocabulary is
// exactly what an author reaches for on a menu deck, which is why
// `test/barrio_card_keys_term_link_test.dart` was written before this
// file existed; until now it had no card carrying both tiers to guard.
//
// Two matcher behaviours did most of the work here, and both were read off
// the deployed matcher rather than guessed:
//
//   * FIRST-OCCURRENCE-PER-CARD. One `alreadyLinked` set is threaded
//     across a card's chunks in reading order, so a term links only its
//     first occurrence. 'Ceviche' links on the Scallop line of c0_u0, so
//     the Vegan Ceviche line below it is free and carries a phrase; the
//     same shape frees 'Empanadas' on c3_u2, 'Al Pastor' and 'Tinga' on
//     c3_u0, 'Chimichurri' on c4_u5, 'Tallarines' on c4_u2 and c4_u3,
//     'Lomo Saltado' on c4_u1, and 'Gallo Pinto' on c5_u0. Those are the
//     cards where the deck's actual teaching lives, and they would have
//     been unreachable under a naive "never say a glossary word" rule.
//   * WHOLE-WORD MATCHING. 'Ceviches' and 'Tortillas' never link, because
//     the registry holds the singular and the plural fails the trailing
//     boundary check.
//
// Where a term IS claimed, the phrase is written around it: c0_u0 takes
// 'Cancha, Burnt Onion, Lava Salt' after the 'Aji Amarillo' link rather
// than swallowing it, and c2_u0 takes 'Mexican Style' up to (not through)
// the 'Ceviche' link.
//
// The bar the phrases are written to: scanning ONLY the highlights on a
// card must still convey what that card teaches. On the Dinner Menu
// chapter that means the dish and what is in it; on the story slides it
// means the translation, the origin, and the technique.
//
// Cards with fewer than three phrases that survive those rules carry NO
// entry and fall back to the per-manual list, which is what keeps partial
// coverage safe. The menu deck has three, all of them genuinely two-line
// title slides: c1_u0 and c1_u1 ('THE CIVILIZATIONS' plus 'The INCA:' /
// 'The Maya:') and c6_u0 ('BARRIO LEGADO' plus 'Continued Legacy, Fresh
// Chapter'). See `barrio_card_keys_index.dart` for the full authoring
// contract.

const Map<String, List<String>> kBarrioCardKeysTrainingMenu =
    <String, List<String>>{
  // ---- c0: Dinner Menu ----------------------------------------------
  'training_menu_concept_c0_u0': <String>[
    'Shrimp Cocktail - Lime Cured',
    'Saltine Crackers',
    'Cancha, Burnt Onion, Lava Salt',
    'Red Onion, Cucumber, Jalapeño, Lime',
    'Vegan Ceviche - Mushroom, Corn Tigers Milk, Tangles',
  ],
  'training_menu_concept_c0_u1': <String>[
    'Charred Jumbo Prawns - Chilli Paprika Butter, Pickled Onions',
    'Sliced Beets',
    'Marinated Mussels - Salsa Azafran ( saffron sauce)',
    'Sikil Pak (Pumpkin Seed Dip)',
    'Beef Filling Served with Aji Sauce',
    'Flautas - Salsa Jitomate, Queso',
  ],
  'training_menu_concept_c0_u2': <String>[
    'Pork Belly - Rococo Marinade',
    'Beef Skewer - Aji Marinade',
    'Corn, Chives, Lime Zest',
    'Carrots, Aji Panca Marinade, Pumpkin Seed Dukkah',
  ],
  'training_menu_concept_c0_u3': <String>[
    'Pork Chop with Corn Husk Glaze',
    'Potato, Peppers,Onion,Tomato',
    'tagliatelle noodle',
    'Poblano Crema, Tajin',
    'Half Chicken',
    'Choice of Chicken or Vegetarian Served with Shredded Cheese',
  ],
  'training_menu_concept_c0_u4': <String>[
    'Whole Fried Fish or Grilled',
    'Rib Eye',
    'Choice of two sides',
    'Half Chicken',
  ],
  'training_menu_concept_c0_u5': <String>[
    'Street Corn',
    'Potatoes',
    'Red pepper, Onion, Black Bean',
    'Grilled Pineapple, Grilled Jalapeño',
    'Cactus',
    'Vegan Green Goddess',
  ],
  // ---- c2: Ceviches: The Story --------------------------------------
  'training_menu_concept_c2_u0': <String>[
    'Shrimp Cocktail - Tomato, Mint',
    'Saltine Crackers',
    'Mexican Style',
    'Salsa Inglesa = Worchestire Sauce',
  ],
  'training_menu_concept_c2_u1': <String>[
    'Cancha, Burnt Onion, Lava Salt',
    'Peruvian Ceviche with Guatemalan Touch',
    'Aji Amarillo =Yellow Chili Pepper',
    'Cancha = Premium Peruvian Snack',
    'Toasted Corn Kernel from Andean',
    'the longest Continental Mountain Range across Chile Peru Bolivia Argentina',
  ],
  'training_menu_concept_c2_u2': <String>[
    'Lava Salt = In Latin called Salnegra',
    'an Ancestral Mayan Salt cooked for hours in clay pots',
    'over wood fire from Volcanic fed Saline Springs',
  ],
  'training_menu_concept_c2_u3': <String>[
    'Red Onion, Cucumber, Jalapeño, Lime',
    'Translates to Chili Water',
    'by featuring quicker marinated fish for a more firm texture',
    'This dish is from Sinoaloa Mexico',
  ],
  // ---- c3: Shareables: The Story ------------------------------------
  'training_menu_concept_c3_u0': <String>[
    'Charred Jumbo Prawns - Chilli Paprika Butter, Pickled Onions',
    'Al Pastor - Pork, Pineapple, Cilantro, Onion',
    'Tinga - Chicken, Chipotle, Cilantro',
    'Quesongo - Mushrooms, Cheese, Onion',
    'Fish - Coleslaw, Chipotle Mayo',
  ],
  'training_menu_concept_c3_u1': <String>[
    'Sikil Pak (Pumpkin Seed Dip) - Chile, Tomato, Chives',
    'Sikil Pak means Pumpkin tomato',
    'Mayan Hummus Substitute',
    'Tetelas - Mushroom, Carrot',
    'Masa is Corn Dough',
    'Traditionally from the Mixtera region in Mexico',
  ],
  'training_menu_concept_c3_u2': <String>[
    'Empanadas (Deep Fried) - Beef Filling Served with Aji Sauce',
    'Vegetarian Version with Cactus or Jackfruit',
    'Mexican Cuisine is heavily influenced by the Nopal Cactus',
    'The Aztec People, Early settlers of Mexico',
    'Built Tenochtilian which is now Mexico City',
    'an Eagle perched on a Nopal',
  ],
  // ---- c4: Mains: The Story -----------------------------------------
  'training_menu_concept_c4_u0': <String>[
    'Pork Chop with Corn Husk Glaze Served with a dipable sauce',
    'Lomo - Onions, Tomato, Pepper',
    'Lomo = Beef loin',
    'Saltado = Stir-fried',
  ],
  'training_menu_concept_c4_u1': <String>[
    'one of Peru\'s most iconic dishes',
    'a defining example of Chifa cuisine',
    'the fusion of Chinese and Peruvian culinary traditions',
    'developed when Cantonese immigrants introduced Chinese cooking techniques',
    'brought the wok, high-heat stir-frying, and ingredients such as soy sauce',
    'combined with Peruvian beef, onions, tomatoes, ají peppers, and native potatoes',
  ],
  'training_menu_concept_c4_u2': <String>[
    'Whole Fried Fish/ Deep Fried or Grilled',
    'Tallarines (tagliatelle noodle), Poblano Crema, Tajin',
    'Italian ribbon pasta; long and flat',
    'made from sheets of fresh egg dough',
    'Tagliatelle translates to one precise ribbon',
    'It comes from Emilia-Romagna, the region around Bologna, Italy',
  ],
  'training_menu_concept_c4_u3': <String>[
    'Tagliatelle crossed over to Latin America',
    'the name loosened to tallarines',
    'a general word for any long noodle, spaghetti, wok noodles, ribbon pasta',
    'Poblano Creamy Green Chile Sauce',
    'Burn skin off mild green pepper over a flame',
    'Mexican table cream. Lighter than sour cream',
  ],
  'training_menu_concept_c4_u4': <String>[
    'Half Chicken - Brasa Marinade',
    'Brasa Means Ember in Spanish',
    'Polo a la Brasa: Peru\'s Charcoal Rotisserie Chicken',
    'A swiss settler named Roger Scheler started roasting Chicken this way outside Lima Peru',
    'A Swiss Engineer friend built him a rotating system',
    'Peru declared it a national cultural heritage',
  ],
  'training_menu_concept_c4_u5': <String>[
    'Choice of two sides',
    'Argentina\'s signature herb sauce',
    'traditionally served with Asado (barbecue)',
    'Its flavor deepens as the ingredients meld over time',
    'The traditional open-fire grilling culture of Argentina\'s Pampas region',
    'chimichurri tastes even better after resting',
  ],
  'training_menu_concept_c4_u6': <String>[
    'Choice of Chicken or Vegetarian Served with Shredded Cheese',
    'Street Corn',
    'Potatoes, Rosemary,Pickles',
    'Red pepper, Onion, Black Bean',
    'Salad Has Cactus in it with Tequila Lime Vinagre',
  ],
  // ---- c5: Sides: The Story -----------------------------------------
  'training_menu_concept_c5_u0': <String>[
    'The national breakfast of both Costa Rica and Nicaragua',
    'translates to "Spotted Rooster," named for the speckled appearance',
    'created by mixing rice and black beans',
  ],
};
