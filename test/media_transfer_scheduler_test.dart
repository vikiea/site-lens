import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:site_lens/media/media_transfer_scheduler.dart';

void main() {
  test(
    'limits active transfers and lets playback priority run first',
    () async {
      final scheduler = MediaTransferScheduler(maxActive: 1);
      final release = Completer<void>();
      var active = 0;
      var peak = 0;
      final order = <String>[];

      final first = scheduler.schedule<void>(
        priority: 10,
        action: () async {
          active++;
          peak = active > peak ? active : peak;
          order.add('first');
          await release.future;
          active--;
        },
      );
      final ordinary = scheduler.schedule<void>(
        priority: 10,
        action: () async => order.add('ordinary'),
      );
      final playback = scheduler.schedule<void>(
        priority: 100,
        action: () async => order.add('playback'),
      );

      await Future<void>.delayed(Duration.zero);
      expect(peak, 1);
      release.complete();
      await Future.wait([first, ordinary, playback]);
      expect(order, ['first', 'playback', 'ordinary']);
    },
  );

  test(
    'waiting ordinary work ages while a high priority queue is active',
    () async {
      final scheduler = MediaTransferScheduler(maxActive: 1);
      final release = Completer<void>();
      final order = <String>[];
      final first = scheduler.schedule<void>(
        priority: 0,
        action: () async {
          order.add('first');
          await release.future;
        },
      );
      final ordinary = scheduler.schedule<void>(
        priority: 0,
        action: () async => order.add('ordinary'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      final playback = scheduler.schedule<void>(
        priority: 100,
        action: () async => order.add('playback'),
      );
      release.complete();
      await Future.wait([first, ordinary, playback]);
      expect(order, ['first', 'playback', 'ordinary']);
    },
  );
}
