// Wave 2 Q-2c — Firebase Test Lab matrix model.
//
// Models the Android / iOS device + OS pairs the Q-2c push round-trip
// soak fans out over Firebase Test Lab. Keeping the matrix in a
// dedicated file (instead of inline in the runner) so reviewers can
// scan the device list at a glance and the orchestrator can serialise
// the matrix into the run report's "Per-device coverage" table.
//
// Pre-populated defaults:
//
//   Android: Pixel 6 on API 30 (Android 11), API 33 (Android 13),
//            API 34 (Android 14). Pixel 6 is the lowest-cost virtual
//            device that supports Play Services + Google APIs (FCM
//            delivery requires Google APIs). API 30/33/34 brackets
//            the operator base: 30 is the practical floor, 34 is the
//            current ceiling.
//
//   iOS:     iPhone 14 on iOS 16, iOS 17. iPhone 14 is the lowest-
//            cost physical device exposed in Test Lab that supports
//            APNs push delivery. iOS 16/17 brackets the operator base.
//
// Why a model class (rather than a list of records)
// -------------------------------------------------
// The runner consumes the matrix in two shapes: (1) a flat list of
// `gcloud firebase test android run --device …` args, (2) the
// orchestrator's Markdown report. Both shapes need stable field
// labels; a model class keeps the field names in one place.

/// Mobile OS lane. Test Lab models Android + iOS in two separate
/// gcloud subcommands, so the lane discriminator is structural.
enum FirebaseTestLabLane {
  android,
  ios,
}

/// One row in the matrix: one device + one OS version. The runner
/// expands this into the gcloud `--device` flag shape.
class FirebaseTestLabMatrixEntry {
  const FirebaseTestLabMatrixEntry({
    required this.lane,
    required this.deviceModel,
    required this.osVersion,
    required this.locale,
    required this.orientation,
  });

  /// `android` or `ios`. Maps to the gcloud subcommand.
  final FirebaseTestLabLane lane;

  /// Device model id as Test Lab exposes it. Examples: `Pixel6`,
  /// `iphone14`. The values match the `gcloud firebase test android
  /// models list` / `gcloud firebase test ios models list` outputs.
  final String deviceModel;

  /// OS version string. For Android this is the API level (`30`,
  /// `33`, `34`). For iOS this is the dotted version string (`16.0`,
  /// `17.0`).
  final String osVersion;

  /// Locale tag. We pin `en_US` across the matrix — the F&F UX
  /// writing standard is plain English, and exercising the locale
  /// machinery is out of scope for the push round-trip soak.
  final String locale;

  /// Device orientation. Pinned to portrait — the in-app notification
  /// surface renders the same in either orientation, and exercising
  /// rotation is out of scope.
  final String orientation;

  /// Format this entry as the `--device` flag value gcloud expects.
  /// Example: `model=Pixel6,version=33,locale=en_US,orientation=portrait`.
  String toGcloudDeviceFlag() {
    return 'model=$deviceModel,version=$osVersion,locale=$locale,'
        'orientation=$orientation';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'lane': lane.name,
        'device_model': deviceModel,
        'os_version': osVersion,
        'locale': locale,
        'orientation': orientation,
      };
}

/// The full matrix the Q-2c soak fans out over. Group entries by lane
/// so the runner can emit one gcloud invocation per lane (the gcloud
/// Android subcommand takes only Android entries, ditto iOS).
class FirebaseTestLabMatrix {
  const FirebaseTestLabMatrix({required this.entries});

  /// The entries that comprise this matrix.
  final List<FirebaseTestLabMatrixEntry> entries;

  /// Entries scoped to the Android lane. Used by the runner to build
  /// one `gcloud firebase test android run` invocation per lane.
  List<FirebaseTestLabMatrixEntry> get androidEntries =>
      entries.where((e) => e.lane == FirebaseTestLabLane.android).toList();

  /// Entries scoped to the iOS lane.
  List<FirebaseTestLabMatrixEntry> get iosEntries =>
      entries.where((e) => e.lane == FirebaseTestLabLane.ios).toList();

  /// True when this matrix has at least one entry per lane. Used by
  /// the runner to refuse to run an incomplete matrix.
  bool get isComplete => androidEntries.isNotEmpty && iosEntries.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'entry_count': entries.length,
        'android_entries':
            androidEntries.map((e) => e.toJson()).toList(growable: false),
        'ios_entries':
            iosEntries.map((e) => e.toJson()).toList(growable: false),
      };
}

/// The default Q-2c matrix. Three Android API levels on Pixel 6 plus
/// two iOS versions on iPhone 14 — five device-runs total. Costs are
/// metered per minute of device-time; the soak budget is documented
/// in `tool/firebase_test_lab/README.md`.
const FirebaseTestLabMatrix kDefaultFirebaseTestLabMatrix =
    FirebaseTestLabMatrix(
  entries: <FirebaseTestLabMatrixEntry>[
    FirebaseTestLabMatrixEntry(
      lane: FirebaseTestLabLane.android,
      deviceModel: 'Pixel6',
      osVersion: '30',
      locale: 'en_US',
      orientation: 'portrait',
    ),
    FirebaseTestLabMatrixEntry(
      lane: FirebaseTestLabLane.android,
      deviceModel: 'Pixel6',
      osVersion: '33',
      locale: 'en_US',
      orientation: 'portrait',
    ),
    FirebaseTestLabMatrixEntry(
      lane: FirebaseTestLabLane.android,
      deviceModel: 'Pixel6',
      osVersion: '34',
      locale: 'en_US',
      orientation: 'portrait',
    ),
    FirebaseTestLabMatrixEntry(
      lane: FirebaseTestLabLane.ios,
      deviceModel: 'iphone14',
      osVersion: '16.0',
      locale: 'en_US',
      orientation: 'portrait',
    ),
    FirebaseTestLabMatrixEntry(
      lane: FirebaseTestLabLane.ios,
      deviceModel: 'iphone14',
      osVersion: '17.0',
      locale: 'en_US',
      orientation: 'portrait',
    ),
  ],
);
