enum MediaStorageMode { appPrivate, safTree, directPath }

extension MediaStorageModeWireId on MediaStorageMode {
  String get wireId => switch (this) {
    MediaStorageMode.appPrivate => 'app_private',
    MediaStorageMode.safTree => 'saf_tree',
    MediaStorageMode.directPath => 'direct_path',
  };
}

extension MediaStorageModeLabel on MediaStorageMode {
  String get label => switch (this) {
    MediaStorageMode.appPrivate => '应用私有目录',
    MediaStorageMode.safTree => '系统目录（SAF）',
    MediaStorageMode.directPath => '直接文件目录',
  };
}
