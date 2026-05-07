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

  /// Only operator owners + operator admins. Audit chain anchor
  /// failures are admin-only.
  adminOnly,

  /// Only roles that manage shifts (operator owner / admin / manager).
  /// Open-shift staleness, weekly plan updates land here.
  managerOnly,
}

/// Categorization for the on-screen grouping. Plain English labels
/// land alongside in `kNotificationCategoryLabels`.
enum NotificationCategory { backfill, vendor, audit, shift, plan }

/// Stable role-key lists. Mirror the operator-web auth source role
/// strings. Kept here (not in `lib/auth/permission_keys.dart`) because
/// these are operator-web-side gates, not the system permission key
/// catalog.
const String roleOperatorOwner = 'operator_owner';
const String roleOperatorAdmin = 'operator_admin';
const String roleOperatorManager = 'operator_manager';
const String roleLocationManager = 'location_manager';

const Set<String> _adminRoles = <String>{
  roleOperatorOwner,
  roleOperatorAdmin,
};

const Set<String> _managerRoles = <String>{
  roleOperatorOwner,
  roleOperatorAdmin,
  roleOperatorManager,
  roleLocationManager,
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
    title: 'First-connect backfill complete',
    description: 'Your 60-day historical seed has finished and the '
        'connector is now live.',
    category: NotificationCategory.backfill,
    roleGate: NotificationRoleGate.any,
    defaultChannels: <String>{'push', 'email'},
  ),
  NotificationCatalogEntry(
    eventKey: 'notif.backfill.failed',
    title: 'First-connect backfill failed',
    description: 'Your 60-day historical seed could not finish. '
        'Forge & Flow will retry automatically; we will let you know '
        'if it needs your attention.',
    category: NotificationCategory.backfill,
    roleGate: NotificationRoleGate.any,
    defaultChannels: <String>{'push', 'email'},
  ),
  // Vendor availability - any
  NotificationCatalogEntry(
    eventKey: 'notif.vendor.now_available',
    title: 'Vendor became available',
    description: 'A vendor you have been waiting on is now available '
        'to connect.',
    category: NotificationCategory.vendor,
    roleGate: NotificationRoleGate.any,
    defaultChannels: <String>{'push', 'email'},
  ),
  // Audit - admins only
  NotificationCatalogEntry(
    eventKey: 'notif.audit.anchor_failure',
    title: 'Audit chain anchor failed',
    description: 'A daily audit-log integrity anchor failed to land. '
        'This is rare and never blocks operations, but you should know.',
    category: NotificationCategory.audit,
    roleGate: NotificationRoleGate.adminOnly,
    defaultChannels: <String>{'push', 'email'},
  ),
  // Shift - managers only
  NotificationCatalogEntry(
    eventKey: 'notif.shift.stale',
    title: 'Open-shift snapshot stale',
    description: 'A live shift has not received fresh covers or labor '
        'data in a while. The snapshot may be out of date.',
    category: NotificationCategory.shift,
    roleGate: NotificationRoleGate.managerOnly,
    defaultChannels: <String>{'push'},
  ),
  // Star override - any
  NotificationCatalogEntry(
    eventKey: 'notif.star.override',
    title: 'Manager override applied',
    description: 'Someone on your team adjusted a recommendation. '
        'See who, when, and what changed.',
    category: NotificationCategory.shift,
    roleGate: NotificationRoleGate.any,
    defaultChannels: <String>{'push'},
  ),
  // Weekly plan - managers only
  NotificationCatalogEntry(
    eventKey: 'notif.plan.updated',
    title: 'Weekly plan snapshot updated',
    description: 'A new weekly plan snapshot was locked in. Open the '
        'planner to review the latest version.',
    category: NotificationCategory.plan,
    roleGate: NotificationRoleGate.managerOnly,
    defaultChannels: <String>{'push'},
  ),
];

const Map<NotificationCategory, String> kNotificationCategoryLabels =
    <NotificationCategory, String>{
  NotificationCategory.backfill: 'First-connect backfill',
  NotificationCategory.vendor: 'Vendor connections',
  NotificationCategory.audit: 'Audit and integrity',
  NotificationCategory.shift: 'Live shift',
  NotificationCategory.plan: 'Weekly plan',
};

/// All channel wire values surfaced in the UI. Order matters - this
/// is the column order on the screen.
const List<String> kNotificationChannelOrder = <String>['push', 'email', 'inbox'];

/// Plain-English labels for the channel column headers.
const Map<String, String> kNotificationChannelLabels = <String, String>{
  'push': 'Phone',
  'email': 'Email',
  'inbox': 'Inbox',
};
