// Per-CARD key phrases for the Push Schedule SOP (doc id
// 'training_push_sop'), authored against the LIVE card bodies in
// `../../training/training_push_sop_content.dart`.
//
// WHAT GETS HIGHLIGHTED HERE. Push Schedule is not prose teaching, it is
// an operational SOP: what the staff member does in the app and what has
// to be true before it counts. So every phrase names an ACTION or a
// CONDITION ('click on the arrow on the shift you want to swap', 'must be
// approved by management before taken') rather than a screen name. A
// staff member who reads only the highlights on a card still knows what
// to press and what still needs a manager.
//
// THE TRAP THIS MANUAL CARRIES. Shift times, date ranges, PIN lengths,
// and status numbers are everywhere in this doc, and the numeric-fact
// tier outranks this one: any phrase carrying a digit is dropped WHOLE at
// render time, silently. So no phrase below contains a digit, and none
// overlaps a rendered numeric token (which can reach past the digits into
// its unit word). Both were checked against the live bodies before this
// data shipped, not after.
//
// The three other silent-drop tiers were checked the same way: a phrase
// must match whole-word inside its own card's body (or it never lights
// up), must not overlap a sibling phrase (the later one is dropped), and
// must not overlap the card's quiz answer evidence. Term links do not
// apply: `BarrioTermLinks.kHostManualIds` holds the four culinary manuals
// only, and `training_doc_screen.dart` gates `onTermTap` on exactly that
// set, so no tap-to-define span can ever exist on a Push card.
//
// Two cards carry no entry. 'My Files' and 'Pay Stubs' are one or two
// short sentences long, and fewer than three phrases survive on them; a
// card with no entry falls back to the per-manual list, which is empty
// for this uncurated doc, so it highlights nothing, exactly as it did
// before this data landed. See `barrio_card_keys_index.dart` for the full
// authoring contract.

const Map<String, List<String>> kBarrioCardKeysTrainingPushSop =
    <String, List<String>>{
  // ---- c0: Schedule and Availability ----------------------------------
  'training_push_sop_c0_u0': <String>[
    'shows the weekly Schedule you have been assigned',
    'choose the date range',
    'Make sure you are looking at the correct date range',
    'shift tag: This will show you the shift type',
    'managerial notes for your shift',
    'station assignment',
  ],
  'training_push_sop_c0_u1': <String>[
    'burger icon on the top left opens up a side menu',
    'shows your login credentials',
    'what you use to clock in and out on the tablet downstairs in the staff area',
  ],
  'training_push_sop_c0_u2': <String>[
    'shows everyone that is scheduled for the day',
    'use the search bar at the top to see if someone is working that day',
    'you can also adjust the day',
  ],
  'training_push_sop_c0_u3': <String>[
    'set when you are available to work',
    'Clicking on this means you are available in this time period set',
    'Left Unchecked means you are unavailable in that time period',
    'based on your discretion and agreement with your manager',
    'If your availability varies weekly that can be set here weekly',
    'set availability start and end date to any custom date range',
  ],
  'training_push_sop_c0_u4': <String>[
    'set an availability within your normal availability',
    'will expire and default back to the original availability that is set in weekly',
    'Exam week but going back to regular availability after',
    'Custom takes precedence over weekly on the scheduling side',
    'make sure you are communicating with management on this',
  ],
  'training_push_sop_c0_u5': <String>[
    'send a request to management to not be scheduled for a particular date or date range',
    'Vacation, exams, emergencies, illness',
    'must be approved by management before taken',
    'availability defaults to what is set in weekly/custom once your time off period ends',
  ],
  // ---- c1: Hours and Shift Management ---------------------------------
  'training_push_sop_c1_u0': <String>[
    'shows what hours you have clocked in for',
    'All clocked in hours need to go through Manager approval first',
    'approval status on the shift display',
    'the Shift display turns green and the approved hours get displayed at the top',
  ],
  'training_push_sop_c1_u1': <String>[
    'Shows shifts that the you have requested to swap with a teammate',
    'The status of the swap will show in yellow',
    'Pending Manager approval',
  ],
  'training_push_sop_c1_u2': <String>[
    'shows shifts that your teammates have requested to swap with you',
    'You can approve the request on your end here',
    'Make sure all shift swaps go through the Push app',
  ],
  'training_push_sop_c1_u3': <String>[
    'Navigate back to the My schedule screen',
    'click on the arrow on the shift you want to swap',
    'switch shifts here with a teammate that is also assigned the same shift type',
    'a bartender can swap with another bartender',
    'A bartender cannot swap with a server unless Manager authorized',
  ],
  'training_push_sop_c1_u4': <String>[
    'give up your shift into a pool for a teammate to pickup',
    'you are fully responsible for your shift release all the way up to manager approval',
    'If not approved by a manager the shift defaults to its original scheduled state',
    'shows shift you have submitted into the pool',
  ],
  'training_push_sop_c1_u5': <String>[
    'shifts that have been put up for \'auction\' by other teammates',
    'These are available for you to pickup',
    'Pickup also goes through manager approval',
  ],
  'training_push_sop_c1_u6': <String>[
    'click on the arrow icon on the shift you want to release',
    'Add a note before sending it over for the manger to approve',
    'they will apear with a yellow status banner below',
    'Click "Accept" to confirm the shift swap request',
    'Click on "Cancel" to reject the shift swap request',
    'Once any release or swap is accepted by a teammate it has to go through manager approval',
  ],
  // ---- c2: Documents and Communication --------------------------------
  'training_push_sop_c2_u2': <String>[
    'communicate with management or teammates',
    'sends users an email and sms based on their notification preferences',
    'a typical Inbox and Outbox',
  ],
  // ---- c3: Account Settings -------------------------------------------
  'training_push_sop_c3_u0': <String>[
    'setup how you want alerts to appear on your phone',
    'set via sms, email and push app notification',
    'set notifications for all actions we have discussed above',
  ],
  'training_push_sop_c3_u1': <String>[
    'sync your schedule with your ios calendar app or google calender',
    'Settings > Calendar > Accounts > Add Account > Other',
    'Tap "Add Subscribed Calendar"',
    'Paste the URL, tap Next, then Save',
    'must be done on a computer, not the phone app',
    'Paste the URL and click "Add calendar"',
  ],
};
