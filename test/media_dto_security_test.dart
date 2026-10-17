import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';
import 'package:site_lens/media/media_dto_codec.dart';
import 'package:site_lens/filter/filter_service.dart';
import 'package:site_lens/web_host/host_dto_codec.dart';

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

  test(
    'filter Pigeon DTOs contain only metadata and redacted rule semantics',
    () {
      expect(
        HostDtoCodec.safeFilterSnapshotFields.intersection(
          HostDtoCodec.sensitiveFieldNames,
        ),
        isEmpty,
      );
      expect(
        HostDtoCodec.safeFilterPolicyFields.intersection(
          HostDtoCodec.sensitiveFieldNames,
        ),
        isEmpty,
      );
      expect(
        HostDtoCodec.safeFilterContextFields.intersection(
          HostDtoCodec.sensitiveFieldNames,
        ),
        isEmpty,
      );

      final compiled = const FilterCompiler().compile(
        'example.com##.ad\n||tracker.example^',
        snapshotId: 'snapshot-1',
      );
      final snapshot = FilterSnapshot(
        id: 'snapshot-1',
        sourceId: 3,
        version: '2026.10',
        sourceUrl: Uri.parse('https://rules.example/list.txt'),
        sha256: 'a' * 64,
        state: FilterSnapshotState.valid,
        createdAt: DateTime.utc(2026, 10, 17),
        fileRef: '/private/should-never-cross-boundary.rules',
      );
      final dto = HostDtoCodec.snapshot(
        value: snapshot,
        engine: compiled.engine,
      );
      expect(dto.rules, contains('example.com'));
      expect(dto.rules, isNot(contains('cookie')));
      expect(dto.rules, isNot(contains('authorization')));
      expect(dto.rules, isNot(contains('/private/')));

      final policy = HostDtoCodec.policy(
        const FilterPolicy(enabled: true, domainExceptions: {'example.com'}),
      );
      expect(policy.domainExceptions, ['example.com']);
      final context = HostDtoCodec.context(
        HostFilterContext(
          hostId: 1,
          generation: 2,
          sourceUrl: Uri.parse('https://example.com/watch'),
          snapshotId: 'snapshot-1',
        ),
      );
      expect(context.sourceUrl, 'https://example.com/watch');
    },
  );
}
