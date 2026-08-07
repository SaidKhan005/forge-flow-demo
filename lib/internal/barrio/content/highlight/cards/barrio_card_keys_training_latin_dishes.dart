// Per-CARD key phrases for the Latin American Dishes glossary (doc id
// 'training_latin_dishes'), authored against the LIVE card bodies in
// `../../training/training_latin_dishes_content.dart`.
//
// WHAT GETS HIGHLIGHTED HERE. These are definition cards: the title IS
// the term, and the body opens lowercase straight after it ('AGUACHILE /
// a vibrant and spicy Mexican raw seafood dish...'). That is the house
// style of the source glossary, not a defect, and it decides what the
// phrases have to be. A server is asked 'what is aguachile?' at the
// table, so the highlights carry what it is MADE OF, how it is SERVED,
// and where it COMES FROM. They never restate the name: a title names the
// topic, it does not teach it, and the contract bans a phrase equal to a
// card, chapter, or doc title for exactly that reason.
//
// THIS DOC IS A TERM SOURCE, NOT A TERM HOST. The card titles here (with
// the ingredients glossary) are the tap-to-define registry
// ([BarrioTermLinks.kSourceManualIds]), so 'CEVICHE' and 'MOLE' get
// underlined when they appear in the culinary manuals. The hosts are a
// different, disjoint set ([BarrioTermLinks.kHostManualIds]: the menu
// deck, coffee, tequila, food safety), and `training_doc_screen.dart`
// gates `onTermTap` on exactly that set, so a term link can never render
// on a card in this file. The term-link tier therefore cannot silently
// eat a phrase here.
//
// The tiers that CAN eat one were all checked against the live bodies
// before this data shipped, because every one of them fails silently
// rather than loudly: a phrase must match whole-word inside its own
// card's body, must carry no digit and must not overlap a rendered
// numeric token, must not overlap the card's quiz answer evidence, and
// must not overlap a sibling phrase or straddle a paragraph break.
//
// Three cards carry no entry: ENSALADA, SALSA INGLESA, and SOPA are a
// single short sentence that the chapter quiz already claims as its
// answer evidence, so nothing is left to highlight. A card with no entry
// falls back to the per-manual list, which is empty for this uncurated
// glossary, so those three render exactly as they did before. See
// `barrio_card_keys_index.dart` for the full authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingLatinDishes =
    <String, List<String>>{
  // ---- c0: A to C -----------------------------------------------------
  'training_latin_dishes_c0_u0': <String>[
    'spicy Mexican raw seafood dish',
    'differs from ceviche by featuring raw shrimp or fish',
    'quickly marinated in a zesty blend of lime juice, chili peppers, cilantro, and cucumber',
    'to ensure the seafood remains firm',
    'the green version is traditional, there are red and black variations',
    'served alongside tostadas, tortilla chips, or crackers',
  ],
  'training_latin_dishes_c0_u1': <String>[
    'spicy, creamy Peruvian green sauce',
    'elevates roasted chicken, vegetables, and fries',
    'bright, herbaceous flavor profile',
    'combination of cilantro, garlic, lime, and chili peppers',
    'typically jalapeños or the authentic aji amarillo',
    'emulsified with mayo and cheese',
  ],
  'training_latin_dishes_c0_u2': <String>[
    'traditional sandwich cookies',
    'crumbly shortbread biscuits',
    'melt-in-your-mouth texture',
    'filled with rich dulce de leche',
    'dusted with powdered sugar, rolled in coconut, or elegantly coated in chocolate',
    'iconic comfort food across South America',
  ],
  'training_latin_dishes_c0_u3': <String>[
    'spit-roasted, thinly sliced pork',
    'marinated in a vibrant blend of dried chilies, spices, and achiote',
    'signature bright red hue',
    'served in tacos topped with fresh diced onion, cilantro, lime juice, salsa, and roasted pineapple',
    'inspired by Lebanese immigrants who brought the art of spit-grilling lamb to Mexico',
  ],
  'training_latin_dishes_c0_u4': <String>[
    'gluten-free round cornmeal cake',
    'originating from Colombia and Venezuela',
    'grilled, fried, or baked',
    'crispy exterior and soft interior',
    'commonly eaten plain or as a side dish',
    'savory fillings such as avocado, cheese, or meat',
  ],
  'training_latin_dishes_c0_u5': <String>[
    'beloved one-pot meal',
    'varies across Latin America',
    'tender chicken simmered with aromatic spices like saffron and paprika',
    'vegetables such as peas, onions, and peppers',
    'hearty chicken thighs or legs',
  ],
  'training_latin_dishes_c0_u6': <String>[
    'rich and savory Mexican stew',
    'traditionally made with goat, beef, or lamb',
    'beef variant being the most popular',
    'paste of dried chiles like Guajillo, Ancho, and Arbol',
    'consomé, the braising liquid used as a dipping broth',
  ],
  'training_latin_dishes_c0_u7': <String>[
    'traditional Brazilian confectionary',
    'creamy, chewy texture and intensely chocolatey flavor',
    'combining sweetened condensed milk, cocoa powder, and butter',
    'rolled into small balls and generously coated in chocolate sprinkles',
  ],
  'training_latin_dishes_c0_u8': <String>[
    'Venezuelan savory-sweet pancakes',
    'crafted from fresh ground corn',
    'popular street food',
    'cooked on a hot griddle, folded over',
    'filled with soft, salty cheese and butter',
  ],
  'training_latin_dishes_c0_u9': <String>[
    '"little meats" in Spanish',
    'heavily marbled pork shoulder',
    'slow braising process in lard',
    'shredded and either roasted or fried',
    'signature crispy edges',
  ],
  'training_latin_dishes_c0_u10': <String>[
    '"grilled meat" in Spanish',
    'marinated, grilled, and thinly sliced beef',
    'skirt, flap, or flank steak',
    'marinade of lime juice, garlic, and herbs',
    'cooked over high heat to achieve that perfect charred exterior',
  ],
  'training_latin_dishes_c0_u11': <String>[
    'refreshing cold delicacy',
    'raw fish or shellfish "cooked" in citrus, typically lime juice',
    'the citrus acts as a curing agent rather than a bactericidal one',
    'selection of high quality seafood is paramount',
    'PERUVIAN: Known for very short marinade times using lime',
    'MEXICAN: Finely minced raw fish or shrimp marinated in lime',
  ],
  'training_latin_dishes_c0_u12': <String>[
    'commonly served on crispy tostadas or with crackers',
    'ECUADOR: Features cooked shrimp served in a soup-like bowl with generous citrus juices',
    'CHILE: Typically uses white fish like halibut, Patagonia toothfish, or salmon',
    'marinated with lime and grapefruit juice',
    'COSTA RICA: Traditionally made with white sea bass, mahi-mahi, or tilapia',
  ],
  // ---- c1: C to E -----------------------------------------------------
  'training_latin_dishes_c1_u0': <String>[
    'deep-frying pork belly or pork rinds',
    'irresistible crunch',
    'deliciously salty and savory snack',
    'crispy skin and tender meat',
  ],
  'training_latin_dishes_c1_u1': <String>[
    'vibrant uncooked herb sauce',
    'finely chopped parsley, minced garlic, olive oil, oregano, and red wine vinegar',
    'tangy and garlicky flavor profile',
    'perfect topping or marinade for grilled meats, particularly steak',
  ],
  'training_latin_dishes_c1_u2': <String>[
    'massive and hearty sandwich',
    'thinly sliced grilled beef as its star ingredient',
    'loaded with ham, bacon, melted mozzarella, fresh lettuce, ripe tomato, creamy mayonnaise',
    'topped with a fried or hard-boiled egg',
    'served on a perfectly toasted bun',
  ],
  'training_latin_dishes_c1_u3': <String>[
    'Argentinian street food sandwich',
    'grilled chorizo sausage nestled in crusty bread',
    'typically baguette',
    'topped with chimichurri sauce or salsa criolla',
  ],
  'training_latin_dishes_c1_u4': <String>[
    'small black or blue',
    'mussels native to the coasts',
    'Chile, Argentina, and Peru',
  ],
  'training_latin_dishes_c1_u5': <String>[
    'Costa Rican corn pancakes',
    'made from ground fresh corn, flour, eggs, and sugar',
    'fried to a golden perfection',
    'served warm with sour cream',
    'for breakfast or afternoon snack',
  ],
  'training_latin_dishes_c1_u6': <String>[
    'fried dough pastries',
    'piped into ridges with a star-shaped nozzle',
    'crispy exterior with a soft, fluffy interior',
    'dusted with cinnamon sugar',
    'with chocolate sauce or dulce de leche for dipping',
  ],
  'training_latin_dishes_c1_u7': <String>[
    'Brazilian street food',
    'tender shredded chicken combined with creamy cheese',
    'teardropshaped dough that is battered and deep-fried',
    'staple at festive gatherings',
  ],
  'training_latin_dishes_c1_u8': <String>[
    '"raw" in Spanish',
    'high-quality ingredients like branzino, tuna, and scallops',
    'light dressing of premium olive oil, citrus juice, and flaky salt',
    'crudo highlights the freshness of raw fish, dressed in oil and acid right before serving',
  ],
  'training_latin_dishes_c1_u9': <String>[
    'Latin American confection',
    'often used for topping desserts',
    'filling cookies, cakes, and ice cream',
  ],
  'training_latin_dishes_c1_u10': <String>[
    'grilled or boiled corn on the cob',
    'blend of mayonnaise, Mexican crema, chili powder, lime juice, and cotija cheese',
    'staple at summer BBQs',
    'cherished part of Mexican street food culture',
  ],
  'training_latin_dishes_c1_u11': <String>[
    'delectable turnovers made from dough',
    'filled with a variety of savory or sweet ingredients, such as ground beef, chicken, cheese, and seafood',
    'deep-fried for a satisfying crunch or baked for a lighter touch',
    'vary significantly by region regarding dough, filling, and cooking method',
    'filled with ground or cubed beef, onions, olives, and hard-boiled egg',
    'Regional variations include raisins, potato, or even sweet quince paste',
  ],
  'training_latin_dishes_c1_u12': <String>[
    'generally larger than Argentinian ones',
    'BOLIVIA: A sweet, baked, soup-filled empanada',
    'ECUADOR: Airy, cheese-filled, and fried',
    'PERU: Often filled with chicken or beef, sometimes containing peanuts',
    'COLUMBIA: Almost exclusively fried and made with corn flour',
    'MEXICO: Empanadas can be sweet or savory',
  ],
  // ---- c2: E to M -----------------------------------------------------
  'training_latin_dishes_c2_u1': <String>[
    'refreshing traditional Chilean side dish',
    'sliced tomatoes, thinly sliced white onions, oil, and cilantro',
    'essential component of summer meals in Chile',
    'complementing grilled meats and fried fish',
  ],
  'training_latin_dishes_c2_u2': <String>[
    'popular Tex-Mex dish',
    'grilled, sliced meat served on a warm flour or corn tortilla',
    'sautéed onions and bell peppers',
    'served sizzling on a hot skillet',
    'shredded cheese, sour cream, guacamole, and salsa',
  ],
  'training_latin_dishes_c2_u3': <String>[
    'traditional dish from Central America',
    'stir-fried rice and beans',
    'onion, bell pepper, cilantro, and the distinctive Salsa Lizano',
    'national dish of Costa Rica and Nicaragua',
    'staple breakfast often accompanied by eggs, plantains, cheese, and warm tortillas',
  ],
  'training_latin_dishes_c2_u4': <String>[
    'little fat ones',
    'thick corn masa tortillas',
    'fried or grilled',
    'plump shape makes them perfect for stuffing',
    'savory ingredients such as meats, cheese, and beans',
  ],
  'training_latin_dishes_c2_u5': <String>[
    'traditional Mexican dip with roots in the Aztec Empire',
    'sea salt and lime juice',
    'enhanced with onions, cilantro, and chilies',
    'creamy texture that perfectly complements tortilla chips',
  ],
  'training_latin_dishes_c2_u6': <String>[
    'Spanish word for ice cream or frozen treats',
    'dairy or water-based desserts',
    'cream-based scoops',
    'fruit-filled popsicles',
  ],
  'training_latin_dishes_c2_u7': <String>[
    'creamy, sweet',
    'non-alcoholic beverage',
    'cinnamon-rice flavor profile',
  ],
  'training_latin_dishes_c2_u8': <String>[
    'traditional Mexican breakfast',
    'fried eggs atop lightly fried corn tortillas',
    'smothered in a warm and spicy tomato-chili salsa',
    'refried beans, fresh avocado slices, and crumbled queso fresco',
  ],
  'training_latin_dishes_c2_u9': <String>[
    'bright, spicy, and tangy citrus-based marinade',
    'used to cure fish in Peruvian ceviche',
    'mixing lime juice, fish trimmings, onions, chilies, garlic, and cilantro',
  ],
  'training_latin_dishes_c2_u10': <String>[
    'traditional Peruvian stir-fry',
    'essence of chifa cuisine',
    'marinated strips of sirloin or tenderloin',
    'onions, tomatoes, and aji amarillo peppers',
    'seared at high heat with soy sauce and vinegar',
    'served alongside crispy French fries and rice',
  ],
  'training_latin_dishes_c2_u11': <String>[
    'comfort food in Latin America, especially Argentina',
    'thin, breaded, and fried cutlet of beef, chicken, or pork',
    'served with a squeeze of lemon',
    'topped with ham and cheese',
  ],
  // ---- c3: M to S -----------------------------------------------------
  'training_latin_dishes_c3_u0': <String>[
    'traditional Mexican sauce',
    'deep, rich flavor and thick, velvety texture',
    'complex blend of dried chiles, spices, nuts, seeds',
    'hints of fruit or chocolate',
    'require hours of preparation',
  ],
  'training_latin_dishes_c3_u1': <String>[
    'traditional Guatemalan meat stew',
    'deep indigenous Mayan and Spanish colonial roots',
    'rich, toasted sauce crafted from pepitas, sesame seeds, tomatoes, tomatillos, and chiles',
    'enjoyed with chicken, beef, or pork alongside rice and corn tortillas',
  ],
  'training_latin_dishes_c3_u2': <String>[
    'vibrant and fresh Mexican condiment',
    'chopped raw tomatoes, white onions, and cilantro',
    'heat of serrano or jalapeño peppers',
    'brightened with a splash of lime juice',
    'Unlike blended salsas',
    'perfect topping for tacos or grilled meats',
  ],
  'training_latin_dishes_c3_u3': <String>[
    'traditional Mexican soup or stew',
    'features hominy',
    'accompanied by pork or chicken',
    'seasoned with chili peppers, garlic, and onions',
    'garnished with fresh toppings like shredded cabbage, radishes, lime, and avocado',
  ],
  'training_latin_dishes_c3_u4': <String>[
    'Argentine appetizer',
    'thick slice of semi-hard provolone cheese',
    'grilled or baked to perfection',
    'crispy, golden crust while maintaining a deliciously gooey interior',
    'enhanced with oregano and chili flakes',
  ],
  'training_latin_dishes_c3_u5': <String>[
    'thick, handmade corn or rice flour flatbread',
    'filled with savory ingredients such as creamy quesillo, refried beans, succulent chicharrón, or fresh squash',
    'typically enjoyed by hand',
  ],
  'training_latin_dishes_c3_u6': <String>[
    'corn or flour tortilla folded over melted cheese',
    'assortment of fillings such as meats, spices, and vegetables',
    'best enjoyed crispy',
    'accompanied by salsa, guacamole, or sour cream',
  ],
  'training_latin_dishes_c3_u7': <String>[
    'Venezuelan and Latin American dessert',
    'creamy caramel custard',
    'firmer, airier texture than traditional flan',
    'tiny holes that soak up rich caramel syrup',
    'sweetened condensed milk, whole milk, eggs, sugar, and vanilla',
    'occasionally features rum or coconut',
  ],
  'training_latin_dishes_c3_u8': <String>[
    'vibrant and versatile condiment in Mexican cuisine',
    'traditionally crafted from a delightful blend of tomatoes, chili peppers, onions, garlic, and cilantro',
    'perfect accompaniment for chips, tacos, meats, and even stews',
  ],
  'training_latin_dishes_c3_u10': <String>[
    'thick and hearty traditional stew',
    'from Latin America and the Caribbean',
    'large pieces of meat',
    'starchy tubers like yuca, plantains, and potatoes',
    'simmered together in a rich and flavorful broth',
  ],
  'training_latin_dishes_c3_u11': <String>[
    'aromatic cooking base',
    'Latin American, Spanish, and Caribbean cuisines',
    'enriches stews, rice, beans, and meats',
    'blend of herbs and vegetables such as garlic, onions, peppers, and tomatoes',
    'pureed into a raw paste or slowly sautéed in olive oil',
  ],
  // ---- c4: S to T -----------------------------------------------------
  'training_latin_dishes_c4_u1': <String>[
    'traditional Mexican antojito',
    'thick, pinched-edge corn dough base',
    'fried to a golden perfection',
    'bowl-shaped vessel',
    'topped with refried beans, savory meats, fresh lettuce, onions, crumbled queso fresco, and zesty salsa',
  ],
  'training_latin_dishes_c4_u2': <String>[
    'traditional Mesoamerican dish',
    'blend of masa',
    'filled with an array of ingredients such as meats, cheeses, fruits, or vegetables',
  ],
  'training_latin_dishes_c4_u3': <String>[
    'small tortilla expertly rolled around a savory filling',
    'ranging from beef and chicken to cheese',
    'deep-fried or baked for a crispy texture',
  ],
  'training_latin_dishes_c4_u4': <String>[
    'Venezuelan appetizer',
    'savory white cheese in a delicate, slightly sweet dough',
    'deep-fried to golden perfection',
    'dipping sauces such as guasacaca, garlic mayo, or salsa rosada',
  ],
  'training_latin_dishes_c4_u5': <String>[
    'savory and smoky Mexican dish',
    'tender shredded chicken, sautéed onions, and garlic',
    'rich tomato-based sauce',
    'bold flavors of chipotle chilis in adobo',
  ],
  'training_latin_dishes_c4_u6': <String>[
    'Nikkei cuisine from Peru',
    'raw fish prepared in a sashimi style',
    'vibrant and spicy citrus sauce',
    'served immediately to preserve its tender texture',
  ],
  'training_latin_dishes_c4_u7': <String>[
    'Mexican sandwich',
    'crusty yet soft roll',
    'savory meats such as steak, carnitas, or breaded chicken',
    'layers of beans, creamy avocado, queso fresco, and jalapeños',
    'served hot and pressed',
  ],
  'training_latin_dishes_c4_u8': <String>[
    'fried or toasted corn tortilla',
    'base for an array of toppings',
    'beginning with beans, cheese, or meat',
    'layered with fresh lettuce, zesty salsa, and creamy avocado',
  ],
};
