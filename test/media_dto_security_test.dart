import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_dto_codec.dart';

void main() {
  test(
    'media DTOs expose only auditable metadata, never credentials or paths',
    () {
      expect(
        MediaDtoCodec.safeCandidateFields.intersection(
          MediaDtoCodec.sensitiveFieldNames,
        ),
        isEmpty,
      );
      expect(
        MediaDtoCodec.safeTaskFields.intersection(
          MediaDtoCodec.sensitiveFieldNames,
        ),
        isEmpty,
      );
      final candidate = MediaCandidate(
        id: 'c',
        hostId: 1,
        generation: 2,
        sourceUrl: Uri.parse('https://example.com/watch'),
        mediaUrl: Uri.parse('https://cdn.example/video.mp4'),
        title: 'fixture',
        mime: 'video/mp4',
        source: MediaCandidateSource.dom,
      );
      final dto = MediaDtoCodec.candidate(candidate);
      expect(dto.mediaUrl, 'https://cdn.example/video.mp4');
      expect(dto.sourceUrl, 'https://example.com/watch');
      expect(dto.title, 'fixture');
    },
  );
}
