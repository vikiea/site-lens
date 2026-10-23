import 'package:flutter_test/flutter_test.dart';

import '../integration_test/real_media_evidence.dart';

void main() {
  final page = Uri.parse('https://example.org/video/42/');
  test(
    'selected episode follows the final mirror route after a resume redirect',
    () {
      expect(
        selectedEpisodeFromFinalPage(
          page,
          Uri.parse('https://mirror.example/video/42/ep-2/'),
        ),
        2,
      );
      expect(
        selectedEpisodeFromFinalPage(
          Uri.parse('https://example.org/video/42/ep-8/'),
          page,
        ),
        1,
      );
      expect(selectedEpisodeFromFinalPage(page, page), 1);
    },
  );
  for (final path in [
    '/video/43/ep-2/',
    '/video/42/ep-0/',
    '/video/42/ep-two/',
    '/login/',
  ]) {
    test('ambiguous or different final series route fails closed: $path', () {
      expect(
        () => selectedEpisodeFromFinalPage(page, page.replace(path: path)),
        throwsFormatException,
      );
    });
  }
  test('preserves episode-to-resource pairs instead of comparing counts', () {
    final result = explicitEpisodeUrls(
      '{"total":8,"epPlaySrcs":{"1":"/one.m3u8?episode=1",'
      '"2":"/two.m3u8?episode=2"},"largeOtherData":"truncated',
      page,
    );
    expect(result, {
      1: Uri.parse('https://example.org/one.m3u8?episode=1'),
      2: Uri.parse('https://example.org/two.m3u8?episode=2'),
    });
    expect(result.keys, isNot(contains(3)));
  });
  test('quoted braces and escaped JSON are not mistaken for the map end', () {
    final result = explicitEpisodeUrls(
      r'{"epPlaySrcs":{"1":"https://cdn.example/a.m3u8?selection={one}&q=\"a\""}}',
      page,
    );
    expect(result[1]!.queryParameters['selection'], '{one}');
    expect(result[1]!.queryParameters['q'], '"a"');
  });
  for (final value in [
    '{"epPlaySrcs":{"1":"/one.m3u8"',
    '{"epPlaySrcs":{}}',
    '{"epPlaySrcs":{"1":{"url":"/one.m3u8"}}}',
    '{"epPlaySrcs":{"0":"/one.m3u8"}}',
    '{"epPlaySrcs":{"1":"file:///etc/private"}}',
    '{"epPlaySrcs":{"1":"https://user:secret@example.org/"}}',
    '{"epPlaySrcs":{"1":"/a.m3u8","01":"/b.m3u8"}}',
  ]) {
    test('incomplete or unsafe evidence is refused: $value', () {
      expect(() => explicitEpisodeUrls(value, page), throwsFormatException);
    });
  }
}
