/// Phase 8 W2.B - notification event catalog.
///
/// Durable contract: every event_key the system emits, plus its
/// default channels, role gate, and human-readable description /
/// category for the operator-web Notifications screen.
///
/// Authority: master plan W2.B section + notification_preferences
/// table (`db/migrations/202605070400_phase_8_notification_preferences.sql`).
library;

/// Role-gate marker. The operator-web screen hides events whose gate
/// is not satisfied by the actor's roles.
enum NotificationRoleGate {
  /// Any signed-in operator-web actor can subscribe.
  any,

  /// Only operator owners. Audit chain anchor failures are owner-only.
  adminOnly,

  /// Current v2 roles that manage shifts and weekly plans: operator
  /// owners, operator general managers, location managers, and
  /// supervisors. Open-shift staleness and weekly plan updates land here.
  managerOnly,
}

/// Categorization for the on-screen grouping. Plain English labels
/// land alongside in `kNotificationCategoryLabels`.
enum NotificationCategory { backfill, vendor, audit, shift, plan, security }

/// Stable role-key lists. Mirror the operator-web auth source role
/// strings. Kept here (not in `lib/auth/permission_keys.dart`) because
/// these are operator-web-side gates, not the system permission key
/// catalog.
const String roleOperatorOwner = 'operator_owner';
const String roleOperatorGeneralManager = 'operator_general_manager';
const String roleLocationManager = 'location_manager';
const String roleSupervisor = 'supervisor';

const Set<String> _adminRoles = <String>{roleOperatorOwner};

const Set<String> _managerRoles = <String>{
  roleOperatorOwner,
  roleOperatorGeneralManager,
  roleLocationManager,
  roleSupervisor,
};

/// Returns true when `roles` satisfies `gate`.
bool roleSatisfiesGate(NotificationRoleGate gate, Iterable<String> roles) {
  switch (gate) {
    case NotificationRoleGate.any:
      return true;
    case NotificationRoleGate.adminOnly:
      return roles.any(_adminRoles.contains);
    case NotificationRoleGate.managerOnly:
      return roles.any(_managerRoles.contains);
  }
}

/// One catalog entry. The operator-web screen renders one row per
/// catalog event. Default-channel rows are the "out-of-the-box"
/// channels - the operator can opt-out by toggling the channel off
/// (which writes an `enabled=false` preference row).
class NotificationCatalogEntry {
  const NotificationCatalogEntry({
    required this.eventKey,
    required this.title,
    required this.description,
    required this.category,
    required this.roleGate,
    required this.defaultChannels,
  });

  final String eventKey;
  final String title;
  final String description;
  final NotificationCategory category;
  final NotificationRoleGate roleGate;

  /// Wire values from `NotificationChannel.wire`. Stored as strings
  /// here so this catalog has zero `dart:io` / persistence-layer
  /// dependencies and ships fine under `lib/operator_web/**` Web
  /// builds.
  final Set<String> defaultChannels;
}

const List<NotificationCatalogEntry> kNotificationCatalog =
    <NotificationCatalogEntry>[
      // Backfill - any operator-web actor
      NotificationCatalogEntry(
        eventKey: 'notif.backfill.complete',
        title: 'First Connect Backfill complete',
        description:
            '60 days of P.O.S. data has been uploaded and your '
            'initial benchmark is now live.',
        category: NotificationCategory.backfill,
        roleGate: NotificationRoleGate.any,
        defaultChannels: <String>{'push', 'email'},
      ),
      NotificationCatalogEntry(
        eventKey: 'notif.backfill.failed',
        title: 'First Connect Backfill failed',
        description:
            'Forge & Flow could not finish uploading the 60 days of '
            'P.O.S. data needed for your initial benchmark. We will retry '
            'automatically and let you know if we need your help.',
        category: NotificationCategory.backfill,
        roleGate: NotificationRoleGate.any,
        defaultChannels: <String>{'push', 'email'},
      ),
      // Vendor availability - any
      NotificationCatalogEntry(
        eventKey: 'notif.vendor.now_available',
        title: 'Vendor became available',
        description:
            'A vendor you have been waiting on is now available '
            'to connect.',
        category: NotificationCategory.vendor,
        roleGate: NotificationRoleGate.any,
        defaultChannels: <String>{'push', 'email'},
      ),
      // Audit - admins only
      NotificationCatalogEntry(
        eventKey: 'notif.audit.anchor_failure',
        title: "Daily audit log didn't anchor today",
        description:
            "Each night Forge & Flow seals your audit log so its "
            "history can't be changed without us noticing. Today's seal "
            "didn't go through. Your audit log itself is still being "
            "recorded — for example, every team invite, role change, "
            "password reset, and sign-in is still captured. This is rare "
            "and never blocks operations, but you should know.",
        category: NotificationCategory.audit,
        roleGate: NotificationRoleGate.adminOnly,
        defaultChannels: <String>{'push', 'email'},
      ),
      // Shift - managers only
      NotificationCatalogEntry(
        eventKey: 'notif.shift.stale',
        title: 'Open-shift snapshot stale',
        description:
            'A live shift has not received fresh covers or labor '
            'data in a while. The snapshot may be out of date.',
        category: NotificationCategory.shift,
        roleGate: NotificationRoleGate.managerOnly,
        defaultChannels: <String>{'push'},
      ),
      // Star override - any
      NotificationCatalogEntry(
        eventKey: 'notif.star.override',
        title: 'Benchmark override applied',
        description:
            'Someone on your team replaced a Forge & Flow '
            'benchmark recommendation with their own number. Open the '
            'shift to see who changed it, when, and what they entered.',
        category: NotificationCategory.shift,
        roleGate: NotificationRoleGate.any,
        defaultChannels: <String>{'push'},
      ),
      // Weekly plan - managers only
      NotificationCatalogEntry(
        eventKey: 'notif.plan.updated',
        title: 'New weekly plan locked in',
        description:
            'A new week-in-force plan was locked in for the '
            'upcoming week. This is the plan Forge & Flow will compare '
            'your actual results against. Open the planner to review the '
            'targets, headcount, and dayparts in the new snapshot.',
        category: NotificationCategory.plan,
        roleGate: NotificationRoleGate.managerOnly,
        defaultChannels: <String>{'push'},
      ),
      // Security - any signed-in actor (the recipient is the user whose
      // factor changed, not every user in the operator). The fanout
      // worker does not drive this event; the MFA removal worker dispatches
      // a single-recipient email directly via
      // [MfaFactorChangedNoticeDispatcher]. The catalog entry is kept so
      // the operator-web Notifications screen can later render a "MFA
      // changes" row for the affected user, and so the canonical
      // `event_key` lives in one place.
      NotificationCatalogEntry(
        eventKey: 'notif.mfa.factor_changed',
        title: 'Your two-factor settings changed',
        description:
            'A two-factor method on your account was added or '
            'removed. If this was not you, sign in and review your account '
            'security right away.',
        category: NotificationCategory.security,
        roleGate: NotificationRoleGate.any,
        defaultChannels: <String>{'email', 'inbox'},
      ),
    ];

const Map<NotificationCategory, String> kNotificationCategoryLabels =
    <NotificationCategory, String>{
      NotificationCategory.backfill: 'First Connect Backfill',
      NotificationCategory.vendor: 'Vendor integrations',
      NotificationCategory.audit: 'Audit and integrity',
      NotificationCategory.shift: 'Live shift',
      NotificationCategory.plan: 'Weekly plan',
      NotificationCategory.security: 'Account security',
    };

/// All channel wire values surfaced in the UI. Order matters - this
/// is the column order on the screen.
const List<String> kNotificationChannelOrder = <String>[
  'push',
  'email',
  'inbox',
];

/// Plain-English labels for the channel column headers.
const Map<String, String> kNotificationChannelLabels = <String, String>{
  'push': 'Mobile',
  'email': 'Email',
  'inbox': 'Inbox',
};
