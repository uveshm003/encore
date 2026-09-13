/// Facts about this build, in one place.
///
/// There is no `package_info` plugin here: it would be one more dependency to
/// answer a question the app already knows the answer to. Keep [version] in
/// step with `pubspec.yaml` when releasing.
abstract final class AppInfo {
  static const String name = 'Encore';
  static const String tagline = 'Offline vocal studio';
  static const String version = '1.0.0';
  static const int build = 1;

  static String get versionLabel => '$version ($build)';
}
