# App-specific R8/ProGuard keep rules.
#
# The Flutter Gradle plugin already injects the Flutter engine and
# embedding keep rules, and each Firebase AAR ships its own consumer
# rules, so only genuinely app-specific additions belong here.

# MP1 - Crashlytics: keep file names and line numbers so crash reports
# stay symbolicated and readable after R8 obfuscation.
-keepattributes SourceFile,LineNumberTable

# Crashlytics recommendation for custom exception types: keep exception
# class names so grouped crash titles stay meaningful.
-keep public class * extends java.lang.Exception

# The app does not use Play Core deferred components; Flutter's
# generated rules can reference the Play Core split-install API it
# would use if it did. Silence the missing-class warnings instead of
# pulling in an unused dependency.
-dontwarn com.google.android.play.core.**
