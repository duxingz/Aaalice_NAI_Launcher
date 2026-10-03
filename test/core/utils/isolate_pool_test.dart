import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/isolate_pool.dart';

/// 「拖图卡住、每次都要重启」的根因回归。
///
/// 从前 [ComputeGate] 没有任何超时：只要有一个任务永不返回，`finally` 就不会
/// 执行，名额永久丢失；默认名额只有 3 个，漏满之后**所有**走闸门的操作
/// （拖图解析元数据、保存写元数据）都会永久挂起，只能重启进程。
void main() {
  group('ComputeGate', () {
    test('runs tasks and keeps its slot accounting', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 2);

      expect(gate.maxConcurrentTasks, 2);
      expect(gate.availableSlots, 2);
      expect(await gate.run(() => 42), 42);
      expect(gate.availableSlots, 2);
    });

    test('a runner that never completes times out and hands the slot back', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);
      final never = Completer<int>();

      await expectLater(
        gate.run(
          () => never.future,
          timeout: const Duration(milliseconds: 50),
          debugLabel: 'hang',
        ),
        throwsA(isA<ComputeGateTimeout>()),
      );

      // 这是关键：名额必须回来，否则闸门会永久卡死。
      expect(gate.availableSlots, 1);
      expect(await gate.run(() => 7), 7);
    });

    test('times out while still queued when the budget is spent', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);
      final release = Completer<void>();
      final first = gate.run(
        () => release.future,
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(Duration.zero);

      await expectLater(
        gate.run(
          () => 1,
          timeout: const Duration(milliseconds: 50),
          debugLabel: 'queued',
        ),
        throwsA(isA<ComputeGateTimeout>()),
      );

      release.complete();
      await first;
      expect(gate.availableSlots, 1);
    });

    test('a throwing task still hands the slot back', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);

      await expectLater(
        gate.run<int>(() => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );

      expect(gate.availableSlots, 1);
      expect(await gate.run(() => 'ok'), 'ok');
    });

    test('three leaked tasks no longer starve the gate', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 3);
      final hangs = [for (var i = 0; i < 3; i++) Completer<int>()];

      for (final hang in hangs) {
        unawaited(
          gate
              .run(
                () => hang.future,
                timeout: const Duration(milliseconds: 30),
              )
              .catchError((Object _) => -1),
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 150));

      // 从前这里会永久停在 0 个名额；现在闸门自愈。
      expect(gate.availableSlots, 3);
      expect(
        await gate.run(
          () => 'recovered',
          timeout: const Duration(milliseconds: 500),
        ),
        'recovered',
      );
    });

    test('budget also covers the queue wait', () async {
      final gate = ComputeGate.forTesting(maxConcurrentTasks: 1);
      final release = Completer<void>();
      final first = gate.run(
        () => release.future,
        timeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(Duration.zero);

      final queued = Stopwatch()..start();
      await expectLater(
        gate.run(
          () => 'never reached',
          timeout: const Duration(milliseconds: 80),
        ),
        throwsA(isA<ComputeGateTimeout>()),
      );
      queued.stop();
      // 排队就已经耗尽预算，不该再多等。
      expect(queued.elapsedMilliseconds, lessThan(1000));

      release.complete();
      await first;
    });
  });
}
