import 'package:flutter/foundation.dart';

/// Tracks iOS/Android notification permission state so UI surfaces can
/// react when the operator has denied permissions.
enum MobilePushPermissionStatus {
  /// Not yet requested or result unknown.
  unknown,

  /// Operator granted permission.
  granted,

  /// Operator tapped "Don't Allow" — iOS will never ask again.
  /// The app must direct the operator to Settings.
  denied,
}

/// Notifier exposed to the widget tree so push-permission-denied cards can
/// be shown on any screen that needs them.
class PushPermissionStateNotifier extends ValueNotifier<MobilePushPermissionStatus> {
  PushPermissionStateNotifier()
      : super(MobilePushPermissionStatus.unknown);

  void setGranted() => value = MobilePushPermissionStatus.granted;
  void setDenied() => value = MobilePushPermissionStatus.denied;
  void setUnknown() => value = MobilePushPermissionStatus.unknown;
}
