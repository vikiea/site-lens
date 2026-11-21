import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/theater/series_line_memory.dart';

/// 线路选择记忆：用户在某集选了哪条线路，本集之内保持不变（T10）。
///
/// 作用域只有一个维度：站点适配器 + 剧集 + 集数。换清晰度、换候选、重新构建
/// 详情页都不改这条记忆；换集、换剧、换站点各自独立。
void main() {
  late SeriesLineMemory memory;

  setUp(() => memory = SeriesLineMemory());

  test('没选过时不替用户决定：读回 null，由页面落到目录给出的第一条', () {
    expect(memory.remembered('fake', 's1', 1), isNull);
  });

  test('选了哪条就记住哪条', () {
    memory.remember('fake', 's1', 1, 'line-b');
    expect(memory.remembered('fake', 's1', 1), 'line-b');
  });

  test('记住了就一直保持：重复读取不会退回默认', () {
    memory.remember('fake', 's1', 3, 'line-b');
    expect(memory.remembered('fake', 's1', 3), 'line-b');
    expect(memory.remembered('fake', 's1', 3), 'line-b');
  });

  test('作用域是单集：换集不会带走上一集的选择', () {
    memory.remember('fake', 's1', 1, 'line-b');
    expect(memory.remembered('fake', 's1', 2), isNull);
  });

  test('作用域含剧集与站点：同名剧集在不同站点各自独立', () {
    memory.remember('fake-a', 's1', 1, 'line-b');
    memory.remember('fake-b', 's1', 1, 'line-c');
    expect(memory.remembered('fake-a', 's1', 1), 'line-b');
    expect(memory.remembered('fake-b', 's1', 1), 'line-c');
    expect(memory.remembered('fake-a', 's9', 1), isNull);
  });

  test('记住的选择已不在本集线路里时读回 null，页面回落到可用线路', () {
    memory.remember('fake', 's1', 1, 'line-gone');
    expect(
      memory.resolved('fake', 's1', 1, const ['line-a', 'line-b']),
      isNull,
    );
  });

  test('记住的选择仍在线路里时照原样读回', () {
    memory.remember('fake', 's1', 1, 'line-b');
    expect(
      memory.resolved('fake', 's1', 1, const ['line-a', 'line-b']),
      'line-b',
    );
  });

  test('记住的选择被用户改掉后，旧选择不再生效', () {
    memory.remember('fake', 's1', 1, 'line-a');
    memory.remember('fake', 's1', 1, 'line-b');
    expect(memory.remembered('fake', 's1', 1), 'line-b');
  });
}
