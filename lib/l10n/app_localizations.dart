import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_fr.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('fr'),
    Locale('fr', 'CA'),
  ];

  /// Application name shown in the top bar
  ///
  /// In en, this message translates to:
  /// **'Forge & Flow'**
  String get appTitle;

  /// Bottom navigation label — shift dashboard
  ///
  /// In en, this message translates to:
  /// **'Shift'**
  String get navShift;

  /// Bottom navigation label — variance report
  ///
  /// In en, this message translates to:
  /// **'Variance'**
  String get navVariance;

  /// Bottom navigation label — schedule builder
  ///
  /// In en, this message translates to:
  /// **'Plan'**
  String get navPlan;

  /// Bottom navigation label — baseline tracker
  ///
  /// In en, this message translates to:
  /// **'Benchmark'**
  String get navBenchmark;

  /// Settings screen title
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Notifications screen title
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsTitle;

  /// Drawer heading for location list
  ///
  /// In en, this message translates to:
  /// **'Locations'**
  String get locationsTitle;

  /// Hint text in the location search field
  ///
  /// In en, this message translates to:
  /// **'Search locations'**
  String get searchLocations;

  /// Placeholder when no locations are loaded
  ///
  /// In en, this message translates to:
  /// **'Your available locations will appear here.'**
  String get noLocationsAvailable;

  /// Placeholder when location search yields no results
  ///
  /// In en, this message translates to:
  /// **'No matching locations.'**
  String get noMatchingLocations;

  /// Subtitle for operator-wide scope
  ///
  /// In en, this message translates to:
  /// **'All locations'**
  String get allLocations;

  /// Generic save button label
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get buttonSave;

  /// Generic cancel button label
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get buttonCancel;

  /// Generic retry button label
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get buttonRetry;

  /// Generic update / confirm button label
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get buttonUpdate;

  /// Button that deep-links to device Settings
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get buttonOpenSettings;

  /// Generic error message
  ///
  /// In en, this message translates to:
  /// **'Something went wrong. Please try again.'**
  String get errorGeneric;

  /// Network connectivity error
  ///
  /// In en, this message translates to:
  /// **'Network error. Check your connection and try again.'**
  String get errorNetwork;

  /// Auth 401 error message
  ///
  /// In en, this message translates to:
  /// **'Your session has expired. Please sign in again.'**
  String get errorUnauthorized;

  /// Card title when push permission is denied
  ///
  /// In en, this message translates to:
  /// **'Notifications are off'**
  String get pushPermissionDeniedTitle;

  /// Card body when push permission is denied
  ///
  /// In en, this message translates to:
  /// **'Open Settings to turn on notifications for Forge & Flow.'**
  String get pushPermissionDeniedBody;

  /// Force-update modal title
  ///
  /// In en, this message translates to:
  /// **'Update Required'**
  String get forceUpdateTitle;

  /// Force-update modal body
  ///
  /// In en, this message translates to:
  /// **'A newer version of Forge & Flow is required to continue. Please update the app.'**
  String get forceUpdateBody;

  /// Force-update modal primary button
  ///
  /// In en, this message translates to:
  /// **'Update Now'**
  String get forceUpdateButton;

  /// Soft-update banner message
  ///
  /// In en, this message translates to:
  /// **'A new version is available.'**
  String get softUpdateBannerText;

  /// Soft-update banner action label
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get softUpdateBannerAction;

  /// Push notification title for shift alerts
  ///
  /// In en, this message translates to:
  /// **'Shift alert'**
  String get pushNotificationNewShiftAlert;

  /// Push notification title for labor cost threshold
  ///
  /// In en, this message translates to:
  /// **'Labor threshold reached'**
  String get pushNotificationLaborThreshold;

  /// Push notification title for completed sync
  ///
  /// In en, this message translates to:
  /// **'Sync complete'**
  String get pushNotificationSyncComplete;

  /// Tooltip for the drawer/menu icon button
  ///
  /// In en, this message translates to:
  /// **'Business'**
  String get businessTooltip;

  /// Tooltip for the notifications icon button
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notificationsTooltip;

  /// Tooltip for the settings icon button
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTooltip;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'fr'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when language+country codes are specified.
  switch (locale.languageCode) {
    case 'fr':
      {
        switch (locale.countryCode) {
          case 'CA':
            return AppLocalizationsFrCa();
        }
        break;
      }
  }

  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'fr':
      return AppLocalizationsFr();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
