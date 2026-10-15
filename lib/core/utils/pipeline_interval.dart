/// 队列「流水线间隔」的常量与纯逻辑。
///
/// 语义是「**至少**」——从上一张**开始出图**的时刻算起，下一张至少隔这么久；
/// **出图本身占用的时间算在里面**，所以出图比间隔慢时不会再额外等。
/// 该间隔**只作用于队列**：手动生成路径读不到它。
library;

/// 默认区间（秒）：12~24。
const double kDefaultQueueTaskIntervalMinSeconds = 12;
const double kDefaultQueueTaskIntervalMaxSeconds = 24;

/// 允许的上限（秒）。上限为 0 即关闭（不等待）。
const double kMaxQueueTaskIntervalSeconds = 600;

/// 等待下一个任务时，检查「暂停/停止」的轮询步长。
///
/// 不用一次性 `Future.delayed(整个间隔)`：那样暂停/停止要等满间隔才响应。
const Duration kPipelineIntervalPollStep = Duration(milliseconds: 200);

/// 间隔的计算与等待（纯逻辑，不依赖 Riverpod，可直接单测）。
abstract final class PipelineInterval {
  /// 本次要用多长的间隔；上限为 0 时返回 null（不等待）。
  ///
  /// [randomFraction] 取 `[0, 1)`，由调用方给（测试里可以固定它）。
  /// 区间非法（min > max）时按 max 处理，不抛错。
  static Duration? resolve({
    required double minSeconds,
    required double maxSeconds,
    required double randomFraction,
  }) {
    final max = maxSeconds.clamp(0.0, kMaxQueueTaskIntervalSeconds);
    if (max <= 0) return null;
    final min = minSeconds.clamp(0.0, max);
    final seconds = min >= max
        ? max
        : min + randomFraction.clamp(0.0, 1.0) * (max - min);
    return Duration(milliseconds: (seconds * 1000).round());
  }

  /// 等到 `lastStartedAt + interval`。
  ///
  /// 「至少」语义：出图本身的时间算在间隔里，所以已经过了时间点就立即返回。
  /// 等待期间每 [pollStep] 检查一次 [shouldAbort]，保证暂停/停止**≤1 秒**响应。
  /// [sleep] 只为测试注入（默认真的等）。
  static Future<void> waitAtLeast({
    required DateTime lastStartedAt,
    required Duration interval,
    required bool Function() shouldAbort,
    DateTime Function() now = DateTime.now,
    Duration pollStep = kPipelineIntervalPollStep,
    Future<void> Function(Duration)? sleep,
  }) async {
    final deadline = lastStartedAt.add(interval);
    final wait = sleep ?? (duration) => Future<void>.delayed(duration);
    while (true) {
      if (shouldAbort()) return;
      final left = deadline.difference(now());
      if (left <= Duration.zero) return;
      await wait(left < pollStep ? left : pollStep);
    }
  }
}
