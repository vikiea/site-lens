/// Source-page identity rules for the media task surfaces.
///
/// A task's 来源页 (source page) is the page the media was observed on. The
/// app only ever opens that page back for the user when it is the *same site*
/// as the page and media the task belongs to; anything else would turn a
/// recovery entry into a general-purpose navigation escape hatch.
library;

/// The scheme/host/port triple two addresses must share to count as one site.
///
/// Fragments never take part, and a port written explicitly is the same origin
/// as the default port for its scheme (`https://a:443/` == `https://a/`).
/// Returns `null` when [uri] cannot be a web page at all.
String? webOriginKey(Uri uri) {
  if (!const {'http', 'https'}.contains(uri.scheme.toLowerCase())) return null;
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  final scheme = uri.scheme.toLowerCase();
  final port = uri.hasPort ? uri.port : null;
  final defaultPort = scheme == 'https' ? 443 : 80;
  final buffer = StringBuffer()
    ..write(scheme)
    ..write('://')
    ..write(uri.host.toLowerCase());
  if (port != null && port != defaultPort) buffer.write(':$port');
  return buffer.toString();
}

/// True when [page] and [other] are the same web origin.
///
/// Fail-closed: anything unparseable or non-HTTP(S) is *not* the same origin.
bool sameWebOrigin(Uri page, Uri? other) {
  if (other == null) return false;
  final left = webOriginKey(page);
  return left != null && left == webOriginKey(other);
}

/// Normalises a stored source page address into the URL the browser may open.
///
/// Returns `null` when the task recorded no usable source page, so callers hide
/// the entry instead of opening an empty address.
Uri? webSourcePageUrl(Object? sourceUrl) {
  final raw = switch (sourceUrl) {
    Uri uri => uri.toString(),
    String text => text,
    null => '',
    _ => sourceUrl.toString(),
  }.trim();
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || webOriginKey(uri) == null) return null;
  return uri.removeFragment();
}
