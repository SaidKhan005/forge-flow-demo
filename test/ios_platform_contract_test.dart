// Phase 9 live-closeout - iOS Firebase Auth platform floor coverage.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS platform floor', () {
    test('pins CocoaPods to the Firebase Auth iOS 15 floor', () {
      final podfile = File('ios/Podfile').readAsStringSync();

      expect(podfile, contains("platform :ios, '15.0'"));
      expect(
        podfile,
        contains(
          "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'",
        ),
      );
    });

    test('keeps Xcode and Flutter framework minimums aligned', () {
      final project = File(
        'ios/Runner.xcodeproj/project.pbxproj',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final appFrameworkInfo = File(
        'ios/Flutter/AppFrameworkInfo.plist',
      ).readAsStringSync();

      expect(project, isNot(contains('IPHONEOS_DEPLOYMENT_TARGET = 13.0;')));
      expect(project, contains('IPHONEOS_DEPLOYMENT_TARGET = 15.0;'));
      expect(appFrameworkInfo, contains('<string>15.0</string>'));
      expect(appFrameworkInfo, isNot(contains('<string>13.0</string>')));
    });
  });
}
