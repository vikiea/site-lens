import 'package:flutter_test/flutter_test.dart';

import 'package:site_lens/adapters/direct_route.dart';
import 'package:site_lens/adapters/huangguo/huangguo_wire.dart';

void main() {
  group('site recognition', () {
    test('认得站点自己的发址，按宿主名匹配', () {
      expect(
        DirectRouteSite.of([
          Uri.parse('https://${HuangguoHosts.all.first.host}'),
        ]),
        DirectRouteSite.huangguo,
      );
    });

    test('备用地址也算同一个站点', () {
      for (final host in HuangguoHosts.all) {
        expect(
          DirectRouteSite.of([Uri.parse('https://${host.host}/some/page')]),
          DirectRouteSite.huangguo,
          reason: '${host.host} 是站点自己的发址',
        );
      }
    });

    test('不认识的站点没有直连出口，而不是给一个会编目录的适配器', () {
      expect(DirectRouteSite.of([Uri.parse('https://example.com')]), isNull);
      expect(DirectRouteSite.of(const []), isNull);
    });

    test('没给出任何地址时没有直连出口', () {
      expect(DirectRouteSite.of(const <Uri>[]), isNull);
    });
  });
}
