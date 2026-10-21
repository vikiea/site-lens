import 'package:path/path.dart' as p;

/// SAF tree grants can name the same document through different tree prefixes.
String mediaArtifactSourceKey(String source) {
  final uri = Uri.tryParse(source);
  if (uri?.scheme == 'content') {
    final parts = uri!.pathSegments;
    final index = parts.indexOf('document');
    if (index >= 0 && index + 1 < parts.length) {
      return '${uri.authority}/${parts[index + 1]}';
    }
    return uri.toString();
  }
  return p.normalize(uri?.scheme == 'file' ? uri!.toFilePath() : source);
}
