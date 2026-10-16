import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/domain/models.dart';

void main() {
  test('publishing directory fallback only adds a slash to address pages', () {
    expect(
      publishingDirectoryVariant(Uri.parse('https://hddj.tv/dizhi')).toString(),
      'https://hddj.tv/dizhi/',
    );
    expect(
      publishingDirectoryVariant(Uri.parse('https://example.com/address?x=1'))
          .toString(),
      'https://example.com/address/?x=1',
    );
    expect(
      publishingDirectoryVariant(Uri.parse('https://example.com/video')),
      isNull,
    );
    expect(
      publishingDirectoryVariant(Uri.parse('https://example.com/dizhi/')),
      isNull,
    );
  });
}
