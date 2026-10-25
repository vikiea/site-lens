import '../settings/app_settings.dart';

class BackgroundSnapshot {
  const BackgroundSnapshot({
    this.mode = BackgroundMode.defaultGradient,
    this.imagePath,
    this.assetMissing = false,
  });

  final BackgroundMode mode;
  final String? imagePath;
  final bool assetMissing;

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  BackgroundSnapshot copyWith({
    BackgroundMode? mode,
    String? imagePath,
    bool clearImage = false,
    bool? assetMissing,
  }) => BackgroundSnapshot(
    mode: mode ?? this.mode,
    imagePath: clearImage ? null : imagePath ?? this.imagePath,
    assetMissing: assetMissing ?? this.assetMissing,
  );
}
