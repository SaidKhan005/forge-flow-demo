// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Forge & Flow';

  @override
  String get navShift => 'Shift';

  @override
  String get navVariance => 'Variance';

  @override
  String get navPlan => 'Plan';

  @override
  String get navBenchmark => 'Benchmark';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get notificationsTitle => 'Notifications';

  @override
  String get locationsTitle => 'Locations';

  @override
  String get searchLocations => 'Search locations';

  @override
  String get noLocationsAvailable =>
      'Your available locations will appear here.';

  @override
  String get noMatchingLocations => 'No matching locations.';

  @override
  String get allLocations => 'All locations';

  @override
  String get buttonSave => 'Save';

  @override
  String get buttonCancel => 'Cancel';

  @override
  String get buttonRetry => 'Retry';

  @override
  String get buttonUpdate => 'Update';

  @override
  String get buttonOpenSettings => 'Open Settings';

  @override
  String get errorGeneric => 'Something went wrong. Please try again.';

  @override
  String get errorNetwork =>
      'Network error. Check your connection and try again.';

  @override
  String get errorUnauthorized =>
      'Your session has expired. Please sign in again.';

  @override
  String get pushPermissionDeniedTitle => 'Notifications are off';

  @override
  String get pushPermissionDeniedBody =>
      'Open Settings to turn on notifications for Forge & Flow.';

  @override
  String get forceUpdateTitle => 'Update Required';

  @override
  String get forceUpdateBody =>
      'A newer version of Forge & Flow is required to continue. Please update the app.';

  @override
  String get forceUpdateButton => 'Update Now';

  @override
  String get softUpdateBannerText => 'A new version is available.';

  @override
  String get softUpdateBannerAction => 'Update';

  @override
  String get pushNotificationNewShiftAlert => 'Shift alert';

  @override
  String get pushNotificationLaborThreshold => 'Labor threshold reached';

  @override
  String get pushNotificationSyncComplete => 'Sync complete';

  @override
  String get businessTooltip => 'Business';

  @override
  String get notificationsTooltip => 'Notifications';

  @override
  String get settingsTooltip => 'Settings';
}
