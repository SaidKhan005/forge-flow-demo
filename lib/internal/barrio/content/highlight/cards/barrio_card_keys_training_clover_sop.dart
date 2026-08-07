// Per-CARD key phrases for the Clover POS manual (doc id
// 'training_clover_sop'), authored against the LIVE card bodies in
// `../../training/training_clover_sop_content.dart`.
//
// WHAT A STEP CARD NEEDS. This is a step-by-step point-of-sale manual,
// so the phrases carry the ACTION and the CONDITION, not the UI chrome:
// 'each item must be voided individually' over 'the three-dot icon',
// 'this action is irreversible' over 'Confirm the transfer'. Where a
// step's only content IS a control ('Select Fire All to send the
// order.'), the card carries no entry at all rather than highlighting
// furniture.
//
// WATCH THE NUMERIC TIER HERE. Step numbers, table numbers, guest
// numbers, and prices are everywhere in this manual, and the numeric
// tier outranks this one, so a phrase carrying a digit is dropped whole
// and appears NOWHERE, silently. Every phrase below is digit-free and
// was checked against the live numeric spans of its own chunk. The
// spelled-out forms the source already uses carry the fact instead:
// 'your assigned six-digit code', 'from the past thirty days', 'seated
// for longer than one and a half hours'.
//
// Every phrase is a unique, whole-word, non-overlapping substring of
// THAT card's own body and sits inside one rendered chunk. Bullet rows
// render with the leading '- ' stripped (`barrio_body_chunks.dart`), so
// the legend and payment-options cards are anchored per bullet.
//
// PARTIAL COVERAGE IS THE POINT. This doc has no per-manual fallback
// list, so a card with no entry here highlights nothing at all, exactly
// as it did before this data landed.
//
// See `barrio_card_keys_index.dart` for the full authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingCloverSop =
    <String, List<String>>{
  // ---- c0: Intro ----------------------------------------------------
  'training_clover_sop_c0_u0': <String>[
    'Clover station',
    'your assigned fingerprint',
    'your assigned six-digit code',
  ],
  'training_clover_sop_c0_u1': <String>[
    'the first person to log in for the day',
    'select Clover Dining',
    'open the food and beverage point-of-sale system',
  ],
  'training_clover_sop_c0_u4': <String>[
    'The options along the top of the screen',
    'navigate between the different rooms and revenue types',
    'Takeout and Bar Tabs',
  ],
  // ---- c1: Bar Tabs -------------------------------------------------
  'training_clover_sop_c1_u0': <String>[
    'the Bar Tab screen',
    'the green plus icon',
    'in the bottom right corner',
  ],
  'training_clover_sop_c1_u1': <String>[
    'the number of guests for the tab',
    'typically assigned to a single individual',
    'enter one guest',
  ],
  'training_clover_sop_c1_u4': <String>[
    'Once all items for the bar tab have been added',
    'select the three-dot icon',
    'on the bottom bar',
  ],
  'training_clover_sop_c1_u5': <String>[
    'For bar tabs',
    'always add a note to label the name on the tab',
    'identify the person responsible for the bar tab',
  ],
  'training_clover_sop_c1_u8': <String>[
    'appears under Bar Tabs with the relevant name',
    'Select the tab to reopen it',
    'make adjustments',
  ],
  // ---- c2: Floor Plan Screen Navigation -----------------------------
  'training_clover_sop_c2_u0': <String>[
    'select the three-dot icon in the top right corner',
    'At the Bar station',
    'prompt you to open the cash drawer',
  ],
  'training_clover_sop_c2_u1': <String>[
    'Selecting Open Cash Drawer',
    'prompts you to enter a reason',
    'This field is mandatory',
    'without providing a reason',
  ],
  'training_clover_sop_c2_u2': <String>[
    'Next to the three-dot icon is a search icon',
    'opens the search function',
    'includes open tables',
  ],
  'training_clover_sop_c2_u3': <String>[
    'locate specific orders by name, table, or the note made on the table',
    'quickly take action on a table or tab',
    'start an order, view or modify an order, and pay for an order',
  ],
  'training_clover_sop_c2_u5': <String>[
    'The menu icon in the top right corner',
    'opens the main navigation sidebar',
    'both open and closed',
    'select View All Orders',
  ],
  'training_clover_sop_c2_u6': <String>[
    'opens a new screen',
    'displays all orders',
    'from the past thirty days',
  ],
  'training_clover_sop_c2_u8': <String>[
    'select the filter icon',
    'organize and display orders more granularly',
    'filter orders by employee',
  ],
  // ---- c3: Table Status ---------------------------------------------
  'training_clover_sop_c3_u0': <String>[
    'Select Legend in the bottom right corner',
    'Light blue indicates a table you own that has been seated',
    'Red indicates a table you own that has been seated for longer than one and a half hours',
    'Green indicates that the table has paid',
    'Because payments are integrated, this status should not normally appear',
  ],
  'training_clover_sop_c3_u1': <String>[
    'your teammates\' names on the tables they own',
    'Unless you have the assigned permissions',
    'such as those of a manager or supervisor',
    'cannot access another teammate\'s table',
  ],
  'training_clover_sop_c3_u2': <String>[
    'not be able to see a teammate\'s bar tabs',
    'unless you have the same or a higher access level',
    'a server cannot see a supervisor\'s tables',
    'a supervisor can see a server\'s tables',
  ],
  // ---- c4: Order Screen Walkthrough ---------------------------------
  'training_clover_sop_c4_u0': <String>[
    'Once inside a table',
    'you will see the order screen',
    'The table number is displayed in the top left corner',
  ],
  'training_clover_sop_c4_u1': <String>[
    'Below the table number',
    'the guest count',
    'adjust the number of guests for the table',
  ],
  'training_clover_sop_c4_u2': <String>[
    'On the left side, the categories are organized in a list',
    'Scroll up and down to view all the categories',
    'broken down into color-coded subcategories',
    'The items appear in order of subcategory',
    'The final item in each category is a custom item',
    'available to higher access levels',
  ],
  'training_clover_sop_c4_u3': <String>[
    'Within each category',
    'select a subcategory',
    'filter into that specific subcategory',
  ],
  'training_clover_sop_c4_u4': <String>[
    'Large subcategory lists',
    'bottled wine lists and longer liquor lists',
    'organized in alphabetical order',
  ],
  // ---- c5: Guest Management -----------------------------------------
  'training_clover_sop_c5_u0': <String>[
    'first select the guest the item belongs to',
    'unless it is an item being shared by the whole table',
    'essential for the kitchen to understand timing, plating, and fulfillment',
    'The Whole Table option is used only for shareable items',
  ],
  'training_clover_sop_c5_u1': <String>[
    'Select the three dots on each guest',
    'opens a menu',
    'manage the guest and their items',
  ],
  'training_clover_sop_c5_u2': <String>[
    'Use Add Allergens to record any allergens that a guest has',
    'If an allergen is not available as an option',
    'use the Add Custom Allergen function',
  ],
  'training_clover_sop_c5_u3': <String>[
    'Use Move Items to transfer items from one guest to another',
    'move items to the entire table',
    'Select the item you want to move on the left',
    'select the destination on the right side tabs',
  ],
  'training_clover_sop_c5_u5': <String>[
    'Once a guest has been moved to another table',
    'appear at the destination table',
    'Moving a guest adds another guest to the destination table',
    'does not merge the guest number from the former table',
  ],
  // ---- c6: Item Management ------------------------------------------
  'training_clover_sop_c6_u0': <String>[
    'To add a custom modifier',
    'select an item',
    'choose Custom Modifier',
    'type in the modifier',
  ],
  'training_clover_sop_c6_u1': <String>[
    'Select the quantity at the top',
    'choose the number of items to ring in',
    'six tequila shots',
  ],
  'training_clover_sop_c6_u3': <String>[
    'make quantity adjustments',
    'apply item-level discounts',
    'Use the plus and minus icons to adjust the quantity of items',
    'Select the Add Discount button',
    'apply a discount to the selected item only',
  ],
  'training_clover_sop_c6_u6': <String>[
    'Subtracting the quantity of items that have already been fired',
    'triggers a void of that individual item quantity',
    'Voided item receipts are printed for transparent tracking and accountability',
  ],
  'training_clover_sop_c6_u7': <String>[
    'Selecting Void while on an item',
    'deletes the entire item',
    'including all quantities of it',
  ],
  'training_clover_sop_c6_u8': <String>[
    'When items have not been fired',
    'deleted directly',
    'does not trigger a void',
  ],
  'training_clover_sop_c6_u9': <String>[
    'allows for splitting and sharing among seats and guests',
    'If any items under a guest need to be split',
    'move them to the Whole Table first',
    'Selecting the three-dot icon on Whole Table',
  ],
  'training_clover_sop_c6_u10': <String>[
    'Select Split Item Cost to divide shared items between guests',
    'Select the items on the left',
    'the guests who will split the item on the right',
  ],
  // ---- c7: Payments -------------------------------------------------
  'training_clover_sop_c7_u0': <String>[
    'To initiate a payment',
    'on either a handheld or stationed device',
    'select Pay by Guest',
  ],
  'training_clover_sop_c7_u1': <String>[
    'opens a window with multiple options',
    'Pay the full amount of the bill',
    'Split the entire bill into custom or equal amounts',
    'Split by Items allows you to take payments per item',
    'Split by Guest allows you to split the bill by the guests on the table',
  ],
  'training_clover_sop_c7_u2': <String>[
    'Selecting Pay by Guest',
    'will first prompt you',
    'share the Whole Table items or not',
  ],
  // ---- c8: Order Management -----------------------------------------
  'training_clover_sop_c8_u0': <String>[
    'Use Move Order',
    'transfer a table or tab',
    'to another table or tab',
  ],
  'training_clover_sop_c8_u3': <String>[
    'this action is irreversible',
    'You will need to perform a manual re-transfer',
    'to undo it',
  ],
  'training_clover_sop_c8_u4': <String>[
    'add discounts to the entire order',
    'rather than a single item',
    'use Add Order Discounts',
  ],
  'training_clover_sop_c8_u5': <String>[
    'the same pop-up seen with item discounts',
    'apply to the entire bill',
    'stack on top of item discounts',
  ],
  'training_clover_sop_c8_u6': <String>[
    'Selecting the three-dot icon',
    'on the lower toolbar',
    'opens the full function menu',
  ],
  'training_clover_sop_c8_u7': <String>[
    'Select Transfer Server',
    'reassign the order',
    'to another team member',
  ],
  'training_clover_sop_c8_u11': <String>[
    'create custom notes for yourself or any team member',
    'track bar tabs',
    'record special reservation details for a table',
    'your personal go-to reference for a table or tab',
  ],
  'training_clover_sop_c8_u12': <String>[
    'Use Delete to cancel an order',
    'start over',
    'can only be used before anything has been fired',
  ],
};
