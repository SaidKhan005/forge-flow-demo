import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/baseline_manager_service.dart';

/// Shared Forge & Flow app bootstrap used by both standalone and host shells.
Future<void> bootstrapAndRunApp(Widget app) async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  // Compatibility bridge: prime in-memory BaselineData from persisted
  // selection. Persisted ActiveTargetProfile remains the canonical authority
  // while BaselineData stays as a temporary compatibility layer.
  await BaselineManagerService.instance.primeManagerOverride();

  runApp(app);
}
