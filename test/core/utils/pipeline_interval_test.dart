// 流水线间隔的纯逻辑测试：语义、边界、以及「暂停/停止 ≤1 秒响应」。
//
// 这里全部用注入的 `now` / `sleep`，**不真的等待**（跑得快、也不会挂）。
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/pipeline_interval.dart';

void main() {
  group('PipelineInterval.resolve', () {
    test('上限为 0 → 不等待', () {
      expect(
        PipelineInterval.resolve(
          minSeconds: 0,
          maxSeconds: 0,
          randomFraction: 0.5,
        ),
        isNull,
      );
    });

    test('min == max → 固定值', () {
      for (final fraction in [0.0, 0.5, 1.0]) {
        expect(
          PipelineInterval.resolve(
            minSeconds: 30,
            maxSeconds: 30,
            randomFraction: fraction,
          )!.inMilliseconds,
          30000,
        );
      }
    });

    test('随机值落在区间内（端点也要对）', () {
      Duration? at(double fraction) => PipelineInterval.resolve(
        minSeconds: 10,
        maxSeconds: 30,
        randomFraction: fraction,
      );
      expect(at(0)!.inMilliseconds, 10000);
      expect(at(0.5)!.inMilliseconds, 20000);
      expect(at(1)!.inMilliseconds, 30000);
    });

    test('填反了（min > max）按 max 处理，不抛错', () {
      expect(
        PipelineInterval.resolve(
          minSeconds: 40,
          maxSeconds: 20,
          randomFraction: 0,
        )!.inMilliseconds,
        20000,
      );
    });

    test('超过上限被钳到 600 秒', () {
      expect(
        PipelineInterval.resolve(
          minSeconds: 900,
          maxSeconds: 1200,
          randomFraction: 1,
        )!.inMilliseconds,
        600000,
      );
    });

    test('randomFraction 越界被钳到 [0, 1]', () {
      expect(
        PipelineInterval.resolve(
          minSeconds: 10,
          maxSeconds: 30,
          randomFraction: -1,
        )!.inMilliseconds,
        10000,
      );
      expect(
        PipelineInterval.resolve(
          minSeconds: 10,
          maxSeconds: 30,
          randomFraction: 2,
        )!.inMilliseconds,
        30000,
      );
    });

    test('默认区间就是 12~24 秒', () {
      expect(kDefaultQueueTaskIntervalMinSeconds, 12);
      expect(kDefaultQueueTaskIntervalMaxSeconds, 24);
    });
  });

  group('PipelineInterval.waitAtLeast（「至少」语义）', () {
    final start = DateTime(2026, 1, 1, 12);

    test('出图本身已经超过间隔 → 立即返回，一次都不睡', () async {
      final slept = <Duration>[];
      await PipelineInterval.waitAtLeast(
        lastStartedAt: start,
        interval: const Duration(seconds: 20),
        shouldAbort: () => false,
        now: () => start.add(const Duration(seconds: 25)),
        sleep: (duration) async => slept.add(duration),
      );
      expect(slept, isEmpty);
    });

    test('没到点 → 按 200ms 步长轮询到点', () async {
      var elapsed = Duration.zero;
      final slept = <Duration>[];
      await PipelineInterval.waitAtLeast(
        lastStartedAt: start,
        interval: const Duration(seconds: 1),
        shouldAbort: () => false,
        now: () => start.add(elapsed),
        sleep: (duration) async {
          slept.add(duration);
          elapsed += duration;
        },
      );
      expect(slept.length, 5);
      expect(slept.every((d) => d == kPipelineIntervalPollStep), isTrue);
      expect(elapsed, const Duration(seconds: 1));
    });

    test('剩余不足一个步长时按剩余时间睡', () async {
      var elapsed = Duration.zero;
      final slept = <Duration>[];
      await PipelineInterval.waitAtLeast(
        lastStartedAt: start,
        interval: const Duration(milliseconds: 250),
        shouldAbort: () => false,
        now: () => start.add(elapsed),
        sleep: (duration) async {
          slept.add(duration);
          elapsed += duration;
        },
      );
      expect(slept, const [
        Duration(milliseconds: 200),
        Duration(milliseconds: 50),
      ]);
    });

    test('等待中暂停/停止 → 立刻中断，不会睡完整个间隔', () async {
      var elapsed = Duration.zero;
      var aborted = false;
      final slept = <Duration>[];
      await PipelineInterval.waitAtLeast(
        lastStartedAt: start,
        interval: const Duration(seconds: 60),
        shouldAbort: () => aborted,
        now: () => start.add(elapsed),
        sleep: (duration) async {
          slept.add(duration);
          elapsed += duration;
          aborted = true; // 第一次轮询后就当作用户按了暂停
        },
      );
      expect(slept.length, 1);
      expect(elapsed, kPipelineIntervalPollStep);
    });

    test('一开始就该中断 → 一次都不睡', () async {
      final slept = <Duration>[];
      await PipelineInterval.waitAtLeast(
        lastStartedAt: start,
        interval: const Duration(seconds: 60),
        shouldAbort: () => true,
        now: () => start,
        sleep: (duration) async => slept.add(duration),
      );
      expect(slept, isEmpty);
    });
  });
}
