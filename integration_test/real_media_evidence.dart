/// Reads the complete explicit episode map from a bounded DOM inspection.
/// Other page JSON may have been truncated, but this object must be complete.
library;

import 'dart:convert';

/// The site under verification encodes selection in its final /video route.
/// Mirrors may change hostname; a different series is never the requested one.
int selectedEpisodeFromFinalPage(Uri entry, Uri finalPage) {
  final route = RegExp(r'^/video/([1-9]\d{0,11})(?:/ep-([1-9]\d{0,4}))?/?$');
  final requested = route.firstMatch(entry.path);
  final selected = route.firstMatch(finalPage.path);
  if (requested == null ||
      selected == null ||
      requested.group(1) != selected.group(1)) {
    throw const FormatException(
      'Final page does not identify the requested series',
    );
  }
  return int.parse(selected.group(2) ?? '1');
}

Map<int, Uri> explicitEpisodeUrls(String text, Uri page) {
  final marker = RegExp(r'"epPlaySrcs"\s*:\s*\{').firstMatch(text);
  if (marker == null) throw const FormatException('No explicit episode map');
  final start = marker.end - 1;
  var depth = 0;
  var quoted = false;
  var escaped = false;
  for (var index = start; index < text.length; index++) {
    final char = text[index];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
      continue;
    }
    if (char == '"') {
      quoted = true;
    } else if (char == '{') {
      depth++;
    } else if (char == '}' && --depth == 0) {
      final map = jsonDecode(text.substring(start, index + 1));
      if (map is! Map<String, dynamic> || map.isEmpty) {
        throw const FormatException('Empty explicit episode map');
      }
      final result = <int, Uri>{};
      for (final entry in map.entries) {
        final number = int.tryParse(entry.key);
        if (number == null || number <= 0 || entry.value is! String) {
          throw const FormatException('Unsupported episode identity');
        }
        final uri = page.resolve(entry.value as String).removeFragment();
        if (!{'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          throw const FormatException('Unsafe explicit episode URL');
        }
        if (result.containsKey(number)) {
          throw const FormatException('Conflicting episode number');
        }
        result[number] = uri;
      }
      return result;
    }
  }
  throw const FormatException('Explicit episode map was truncated');
}
