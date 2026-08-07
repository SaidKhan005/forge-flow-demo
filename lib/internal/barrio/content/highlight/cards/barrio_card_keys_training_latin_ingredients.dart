// Per-CARD key phrases for the Latin American Ingredients glossary (doc
// id 'training_latin_ingredients'), authored against the LIVE card bodies
// in `../../training/training_latin_ingredients_content.dart`.
//
// WHAT GETS HIGHLIGHTED HERE. Like its sibling dishes glossary, these are
// definition cards whose title IS the term and whose body opens lowercase
// straight after it ('ACHIOTE / a spice and natural colorant derived
// from...'). The phrases carry what the ingredient IS, what it TASTES
// like, and what it is USED IN, because that is the answer a server needs
// when a guest asks what is in a dish. They never restate the name.
//
// THIS DOC IS A TERM SOURCE, NOT A TERM HOST. These card titles (with the
// dishes glossary) are the tap-to-define registry
// ([BarrioTermLinks.kSourceManualIds]), so 'COTIJA' and 'TOMATILLO' get
// underlined when they appear in the culinary manuals. The hosts are a
// different, disjoint set ([BarrioTermLinks.kHostManualIds]: the menu
// deck, coffee, tequila, food safety), and `training_doc_screen.dart`
// gates `onTermTap` on exactly that set, so a term link can never render
// on a card in this file, not even for a term this file itself defines.
// The term-link tier therefore cannot silently eat a phrase here.
//
// The tiers that CAN eat one were all checked against the live bodies
// before this data shipped, because every one of them fails silently
// rather than loudly: a phrase must match whole-word inside its own
// card's body, must carry no digit and must not overlap a rendered
// numeric token (SHISHITO PEPPER's 'about 10% of these peppers' is the
// live example: the numeric tier claims '10%' whole), must not overlap
// the card's quiz answer evidence, and must not overlap a sibling phrase
// or straddle a paragraph break.
//
// Seven cards carry no entry: ARROZ, CERDO, MAIZE/EL MAIZ, MANTECA,
// MARACUYA, POLLO, and PULPO are one-line translations ('Spanish word for
// rice.') with fewer than three phrases in them. A card with no entry
// falls back to the per-manual list, which is empty for this uncurated
// glossary, so those seven render exactly as they did before. See
// `barrio_card_keys_index.dart` for the full authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingLatinIngredients =
    <String, List<String>>{
  // ---- c0: A to C -----------------------------------------------------
  'training_latin_ingredients_c0_u0': <String>[
    'spice and natural colorant',
    'derived from the reddish seeds',
    'mild, earthy, and slightly peppery flavor',
    'vibrant orange-red hue to food',
    'meats, stews, and rice',
  ],
  'training_latin_ingredients_c0_u1': <String>[
    'versatile marinade, sauce, or dry seasoning blend',
    'enhances the flavors of meats, poultry, fish, and vegetables',
    'serves as a preservative',
    'aromatic dry rubs in the Caribbean',
    'rich red chili pastes in Mexico',
  ],
  'training_latin_ingredients_c0_u2': <String>[
    'vibrant orange-yellow chili pepper native to South America',
    'cornerstone of Peruvian cuisine',
    'medium-hot heat level',
    'fruity flavor reminiscent of passion fruit',
    'used fresh, dried, or as a blended paste with oils, cream, or cheese',
  ],
  'training_latin_ingredients_c0_u3': <String>[
    'dried unripe berry from the Pimenta dioica tree',
    'native to the Caribbean and Central America',
    'combines the warmth of clove, cinnamon, and nutmeg',
    'subtle peppery kick',
    'both sweet and savory dishes',
  ],
  'training_latin_ingredients_c0_u4': <String>[
    'dried poblano pepper',
    'sweet, mild flavor',
    'staple in Mexican and Southwestern cuisine',
    'rich, dark red or black hue',
    'notes of dried fruit, cocoa, and tobacco',
    'available both whole and in powder form',
  ],
  'training_latin_ingredients_c0_u5': <String>[
    'herbaceous annual plant in the parsley family',
    'small, brown, crescent-shaped seeds',
    'distinctive sweet licorice flavor',
    'popular spice in baking, cooking, and even flavoring alcohols',
    'often confused with licorice root and star anise',
  ],
  'training_latin_ingredients_c0_u7': <String>[
    'commonly known as star fruit',
    'sweet and tangy flavor',
    'distinctive five-angled shape',
    'crunchy texture',
    'particularly in Brazil, Colombia, Mexico, and the Caribbean',
    'refreshing juices, salads, and jams',
  ],
  'training_latin_ingredients_c0_u8': <String>[
    'Venezuelan-style black beans',
    'creamy and often slightly sweet',
    'typically soaked and slow-cooked',
  ],
  'training_latin_ingredients_c0_u9': <String>[
    'translates to meat',
    'all types of edible animal flesh',
    'in many Spanish-speaking regions',
    'refer specifically to beef',
  ],
  'training_latin_ingredients_c0_u10': <String>[
    'also known as yuca or manioc',
    'starchy root vegetable that thrives in tropical and subtropical regions',
    'essential to peel and thoroughly cook this fibrous tuber to eliminate toxic cyanogenic glycosides',
    'mild, sweet, and slightly nutty flavor',
    'flour, cakes, stews, and even tapioca pearls',
    'boiled, mashed, roasted, or fried',
  ],
  // ---- c1: C to H -----------------------------------------------------
  'training_latin_ingredients_c1_u0': <String>[
    'small, potent Mexican chili pepper',
    'bright red color, grassy flavor, and intense, clean heat',
    'long, thin, and bright red',
    'retains its vibrant color even when dried',
  ],
  'training_latin_ingredients_c1_u1': <String>[
    'smoke-dried, fully ripened red jalapeño pepper',
    'deep, smoky, and sweet flavor profile',
    'left to mature on the vine until turning red',
    'carefully smoked for several hours',
    'medium, manageable heat',
  ],
  'training_latin_ingredients_c1_u2': <String>[
    'highly seasoned pork sausage',
    'deep red color and bold flavor',
    'comes in two primary forms',
    'ready-to-eat Spanish chorizo, which is cured and smoked for a firm texture',
    'fresh Mexican chorizo, which is typically removed from its casing and fried',
  ],
  'training_latin_ingredients_c1_u3': <String>[
    'vibrant green herb',
    'fresh, citrusy, and slightly peppery flavor',
    'enhancing dishes like salsas, tacos, and curries',
    'genetic trait affecting taste perception',
    'soaplike or metallic flavor',
  ],
  'training_latin_ingredients_c1_u4': <String>[
    'features dried seeds',
    'warm, citrusy spice',
    'lemony, floral, and slightly peppery flavors',
    'particularly when toasted and ground',
    'coriander and cilantro are the same plant',
    'cilantro is the leaves and coriander is the seeds',
  ],
  'training_latin_ingredients_c1_u5': <String>[
    'Mexican Parmesan',
    'firm, dry, and salty cow\'s milk cheese',
    'pungent flavor',
    'softens when heated, it retains its crumbly texture',
    'ideal topping for a variety of hot, finished dishes',
  ],
  'training_latin_ingredients_c1_u6': <String>[
    'dried seed spice from the parsley family',
    'warm, earthy aroma and slightly bitter flavor',
    'harvested by hand',
    'yellow-brown to grey seeds',
    'resemblance to caraway or fennel',
    'fine longitudinal ridges',
  ],
  'training_latin_ingredients_c1_u7': <String>[
    'pungent and aromatic herb native to Central America',
    'enhance the flavor of black beans',
    'notes of oregano, anise, mint, and citrus',
    'hints of petroleum or camphor',
  ],
  'training_latin_ingredients_c1_u8': <String>[
    'Spanish word for beans',
    'refers generally to beans',
    'seasoned, stewed pinto or black beans',
  ],
  'training_latin_ingredients_c1_u9': <String>[
    'dried Mexican chili pepper',
    'derived from the mirasol variety',
    'smooth, shiny reddish-brown skin',
    'mildly spicy flavor profile that is both bright and fruity',
    'essential ingredient in pastes, moles, and salsas',
  ],
  'training_latin_ingredients_c1_u10': <String>[
    'highly pungent chili pepper',
    'small, lantern-shaped, and brightly colored pods',
    'intense heat and a distinctive fruity and floral aroma',
    'salsas, hot sauces, and tropical-themed dishes',
    'vibrant orange variety is the most common',
    'pairs beautifully with tropical fruits like mango, pineapple, and citrus',
  ],
  'training_latin_ingredients_c1_u11': <String>[
    'also known as Peruvian Black Mint',
    'distinctive herb native to the Andean mountains of Peru',
    'notes of mint, basil, tarragon, lime, and cilantro',
  ],
  // ---- c2: J to P -----------------------------------------------------
  'training_latin_ingredients_c2_u0': <String>[
    'crunchy and slightly sweet root vegetable native to Mexico',
    'crisp texture that remains intact even when cooked',
    'delightful alternative to potatoes',
    'brown skin is papery and inedible',
    'white flesh can be eaten raw or cooked',
  ],
  'training_latin_ingredients_c2_u1': <String>[
    'climbing vine native to Central America',
    'particularly in El Salvador and Guatemala',
    'edible, pungent green flower buds',
    'earthy, woody, and slightly acidic flavor',
    'primary filling for traditional pupusas',
  ],
  'training_latin_ingredients_c2_u5': <String>[
    'finely ground flour derived from dried, nixtamalized corn dough',
    'tortillas, tamales, and pupusas',
    'distinct earthy flavor',
    'texture that binds instantly',
    'soaking corn in calcium hydroxide before grinding it into a fine powder',
  ],
  'training_latin_ingredients_c2_u6': <String>[
    'finely ground, precooked corn flour',
    'predominantly in Colombian and Venezuelan cuisine',
    'soft texture and mild flavor that enhances arepas',
    'cooking, drying, and grinding non-nixtamalized corn kernels',
  ],
  'training_latin_ingredients_c2_u7': <String>[
    'edible pads of the prickly pear cactus',
    'mild, grassy, and slightly tart flavors',
    'reminiscent of green beans or okra',
    'Packed with fiber, antioxidants, and essential vitamins',
    'enjoyed grilled, sautéed, or boiled',
  ],
  'training_latin_ingredients_c2_u8': <String>[
    'nutrient-dense tropical fruit',
    'native to Mexico and South America',
    'soft, sweet, orangecolored flesh',
    'unique black seeds',
    'buttery texture',
    'reminiscent of both cantaloupe and mango',
  ],
  'training_latin_ingredients_c2_u9': <String>[
    'small, shell-free green seeds',
    'harvested from select hulless pumpkin varieties',
    'flat, dark green appearance',
    'mild, nutty flavor with a hint of sweetness',
    'enjoyed raw, roasted, or salted',
  ],
  'training_latin_ingredients_c2_u10': <String>[
    'Spanish term for fish',
    'freshly caught',
    'ready for consumption or sale',
  ],
  'training_latin_ingredients_c2_u11': <String>[
    'starchy and low-sugar tropical fruit from the banana family',
    'larger and thickerskinned than the common banana',
    'require cooking - whether boiling, frying, or baking - before consumption',
    'function similarly to potatoes',
    'develop a richer, sweeter flavor profile as they ripen from yellow to black',
  ],
  // ---- c3: P to T -----------------------------------------------------
  'training_latin_ingredients_c3_u0': <String>[
    'heart-shaped chili',
    'staple in Mexican cuisine',
    'mild heat comparable to or slightly spicier than a jalapeño',
    'deep green hue',
    'smoky and slightly sweet flavors, particularly when roasted',
    'transforms into a rich dark red or brown as it reaches full ripeness',
  ],
  'training_latin_ingredients_c3_u3': <String>[
    'soft and moist Mexican cheese',
    'made primarily from cow\'s milk',
    'mild, tangy flavor reminiscent of a cross between mozzarella and goat cheese',
    'ideal topping for spicy dishes like tacos, enchiladas, and salads',
    'without melting or becoming gooey',
  ],
  'training_latin_ingredients_c3_u4': <String>[
    'highly nutritious and gluten-free seed',
    'originating from South America',
    'often treated as a whole grain',
    'complete protein containing all nine essential amino acids',
    'staple for vegetarian and vegan diets',
    'mild, earthy, and slightly nutty flavor',
  ],
  'training_latin_ingredients_c3_u5': <String>[
    'Brazilian creamy cheese spread',
    'smooth, mild, and slightly salty flavor profile',
    'perfect addition to toast, crackers',
    'thick, spreadable consistency',
  ],
  'training_latin_ingredients_c3_u6': <String>[
    'medium-sized plum-type tomato',
    'distinctive elongated shape and meaty flesh',
    'ideal choice for creating flavorful sauces, canning, and salsas',
    'low moisture content and thick skin',
  ],
  'training_latin_ingredients_c3_u7': <String>[
    'seasoning blend in Latin American cuisine',
    'infuses dishes such as rice, beans, and meats',
    'vibrant red-orange hue',
    'earthy, umami-packed flavor',
    'coriander, cumin, garlic powder, oregano, salt, and achiote',
  ],
  'training_latin_ingredients_c3_u8': <String>[
    'small yet fiery chili',
    'bright and sharp flavor profile',
    'thick, crisp flesh',
    'typically found in green but can also mature to vibrant shades of red, yellow, or orange',
    'pico de gallo, sauces, and ceviche',
    'hotter substitute for jalapeños',
  ],
  'training_latin_ingredients_c3_u9': <String>[
    'small and slender pepper',
    'vibrant green hue',
    'Mostly mild with a sweet flavor profile',
    'smoky, citrusy undertone',
    'can surprise the palate with unexpected spiciness',
    'modern Latin-fusion cuisine',
  ],
  'training_latin_ingredients_c3_u10': <String>[
    'long, thin pasta noodles',
    'such as spaghetti or linguine',
    'most commonly used in Peruvian cuisine',
  ],
  'training_latin_ingredients_c3_u11': <String>[
    'tropical fruit pod with a sticky, brown pulp',
    'sweet-and-sour, caramellike flavor',
    'refreshing beverages, candies, and sauces',
    'Originally hailing from Africa',
    'staple in Mexican and Central American cuisine',
    'high concentration of tartaric acid',
  ],
  // ---- c4: T to Y -----------------------------------------------------
  'training_latin_ingredients_c4_u0': <String>[
    'versatile starch extracted from the storage roots of the cassava plant',
    'white flour, flakes, or pearls',
    'almost flavorless nature',
    'thickener for soups, sauces, and pie fillings',
    'higher thickening power than cornstarch',
  ],
  'training_latin_ingredients_c4_u1': <String>[
    'small and firm bright-green fruit native to Mexico',
    '"little tomato" in Spanish',
    'only distantly related to tomatoes',
    'tart, acidic, and slightly earthy flavor profile',
    'key ingredient in salsa verde',
    'Encased in a distinctive papery husk',
  ],
  'training_latin_ingredients_c4_u2': <String>[
    'thin, round, unleavened flatbread',
    'originating from Mesoamerica',
    'Traditionally made from masa harina',
    'now also made from wheat flour',
  ],
  'training_latin_ingredients_c4_u3': <String>[
    'twice-fried, savory green plantain slices',
    'popular in Latin American and Caribbean cuisine',
    'slicing unripe, starchy green plantains',
    'frying them until soft, smashing them flat and frying them again until crispy and golden',
    'Known as patacones in Costa Rica',
  ],
  'training_latin_ingredients_c4_u4': <String>[
    'traditional South American herbal tea',
    'natural stimulant providing a smooth energy boost akin to coffee',
    'nutritional benefits associated with green tea',
    'popular in Paraguay, Uruguay, Brazil, and Argentina',
    'traditionally enjoyed through a metal straw',
  ],
  'training_latin_ingredients_c4_u5': <String>[
    'starchy root vegetable',
    'native to South America',
    'SEE CASSAVA',
  ],
};
