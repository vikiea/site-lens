import '../domain/models.dart';
import '../web_host/web_host.g.dart';

/// Explicit conversion at the Flutter/native boundary. Keeping these helpers
/// in one place makes it hard to accidentally add cookies, authorization
/// headers, Web Storage or filesystem paths to a Pigeon snapshot.
class MediaDtoCodec {
  const MediaDtoCodec._();

  /// Audits the public DTO field names in one place. Pigeon DTOs are plain
  /// mutable records, so keeping this allow-list close to the conversion
  /// helpers prevents a future credential/path field from crossing the host
  /// boundary unnoticed.
  static const safeCandidateFields = <String>{
    'id',
    'hostId',
    'generation',
    'sourceUrl',
    'mediaUrl',
    'title',
    'mime',
    'source',
    'durationMs',
  };

  static const safeTaskFields = <String>{
    'id',
    'candidateId',
    'hostId',
    'generation',
    'state',
    'cacheKey',
    'bytesDownloaded',
    'totalBytes',
    'errorCode',
  };

  static const sensitiveFieldNames = <String>{
    'cookie',
    'cookies',
    'authorization',
    'webStorage',
    'localPath',
    'nativePath',
    'capabilityToken',
  };

  static MediaCandidateDto candidate(MediaCandidate value) => MediaCandidateDto(
    id: value.id,
    hostId: value.hostId,
    generation: value.generation,
    sourceUrl: value.sourceUrl.toString(),
    mediaUrl: value.mediaUrl.toString(),
    title: value.title,
    mime: value.mime,
    source: value.source.name,
    durationMs: value.durationMs,
  );

  static MediaTaskDto task(MediaTask value) => MediaTaskDto(
    id: value.id,
    candidateId: value.candidateId,
    hostId: value.hostId,
    generation: value.generation,
    state: value.state.name,
    cacheKey: value.cacheKey,
    bytesDownloaded: value.bytesDownloaded,
    totalBytes: value.totalBytes,
    errorCode: value.errorCode,
  );

  static CastDeviceDto device(CastDevice value) => CastDeviceDto(
    id: value.id,
    name: value.name,
    address: value.address.toString(),
    model: value.model,
    supportsMp4: value.supportsMp4,
    supportsHls: value.supportsHls,
    supportsSeek: value.supportsSeek,
  );

  static CastSessionDto session(CastSession value) => CastSessionDto(
    id: value.id,
    deviceId: value.deviceId,
    mediaTaskId: value.mediaTaskId,
    state: value.state.name,
    errorCode: value.errorCode,
  );
}
