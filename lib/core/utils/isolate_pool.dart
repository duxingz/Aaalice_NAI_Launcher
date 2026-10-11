import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' as foundation;

/// 计算闸门在预算内没能完成时抛出。
///
/// 调用方按普通异常处理即可；关键是闸门**一定**会归还名额。
class ComputeGateTimeout implements Exception {
  const ComputeGateTimeout(this.message);

  final String message;

  @override
  String toString() => 'ComputeGateTimeout: $message';
}

/// 全局重型计算闸门，统一限制 compute/Isolate.run 并发数量。
///
/// 该类只负责全局背压；它不会复用常驻 isolate。
///
/// **每一次 [run] 都有总预算**（排队 + 执行）。这是「名额泄漏」的防线：
/// 从前只要有一个任务永不返回，`finally` 就不会执行，名额永久丢失；默认
/// 名额只有 3 个，漏满之后**所有**走闸门的操作都会永久挂起，只能重启进程
/// （用户报告的「拖图卡住、每次都要重启」就是这个形态）。现在超预算必定
/// 抛 [ComputeGateTimeout] 并归还名额，闸门在结构上不可能被卡死。
class ComputeGate {
  static final ComputeGate _instance = ComputeGate._internal(
    maxConcurrentTasks: defaultMaxConcurrentTasks(),
  );
  static final ComputeGate _singleTask = ComputeGate._internal(
    maxConcurrentTasks: 1,
  );

  factory ComputeGate() => _instance;

  factory ComputeGate.singleTask() => _singleTask;

  ComputeGate._internal({required int maxConcurrentTasks})
    : _semaphore = _Semaphore(math.max(1, maxConcurrentTasks));

  @foundation.visibleForTesting
  factory ComputeGate.forTesting({required int maxConcurrentTasks}) {
    return ComputeGate._internal(maxConcurrentTasks: maxConcurrentTasks);
  }

  /// 单次 [run] 的默认总预算（排队 + 执行）。
  ///
  /// 定得极宽（正常任务是毫秒到秒级），只当防线用，不去打断任何真实工作。
  /// 界面等不起的入口（拖图解析、保存写元数据）用参数给更紧的预算。
  static const Duration defaultTimeout = Duration(minutes: 10);

  final _Semaphore _semaphore;

  int get maxConcurrentTasks => _semaphore.maxCount;

  static int defaultMaxConcurrentTasks({int? processorCount}) {
    final processors = math.max(
      1,
      processorCount ?? Platform.numberOfProcessors,
    );
    return math.min(3, math.max(1, processors - 1));
  }

  /// 在全局计算闸门内运行异步/同步任务。
  ///
  /// [timeout] 是**排队 + 执行**的总预算，默认 [defaultTimeout]。排队阶段也会
  /// 被预算截断：名额被别人长期占住时，调用方会在预算耗尽后抛
  /// [ComputeGateTimeout]，而不是无限等下去。
  ///
  /// [debugLabel] 只用于超时信息，方便在日志里定位是哪个入口卡住。
  Future<T> run<T>(
    FutureOr<T> Function() task, {
    Duration? timeout,
    String? debugLabel,
  }) async {
    final budget = timeout ?? defaultTimeout;
    final label = debugLabel ?? 'compute task';
    final stopwatch = Stopwatch()..start();
    final acquired = await _semaphore.acquire(timeout: budget);
    if (!acquired) {
      throw ComputeGateTimeout('$label 排队已耗尽 ${budget.inSeconds}s 预算');
    }
    try {
      final remaining = budget - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw ComputeGateTimeout('$label 排队已耗尽 ${budget.inSeconds}s 预算');
      }
      // 注意：超时只是让调用方不再等、并归还名额；被放弃的 isolate 本身
      // 无法从 Dart 侧终止，会自己跑完。这里要的是「不再毒住全局闸门」。
      return await Future<T>.sync(task).timeout(
        remaining,
        onTimeout: () => throw ComputeGateTimeout('$label 超过 ${budget.inSeconds}s 预算'),
      );
    } finally {
      _semaphore.release();
    }
  }

  /// 在全局计算闸门内运行 Flutter compute。
  Future<R> runCompute<M, R>(
    foundation.ComputeCallback<M, R> callback,
    M message, {
    String? debugLabel,
    Duration? timeout,
  }) {
    return run(
      () => foundation.compute(callback, message, debugLabel: debugLabel),
      timeout: timeout,
      debugLabel: debugLabel,
    );
  }

  /// 在全局计算闸门内运行一次 Isolate.run。
  ///
  /// 这仍会为本次任务创建 isolate，不是常驻 worker 池。
  Future<T> runIsolate<T>(
    FutureOr<T> Function() task, {
    Duration? timeout,
    String? debugLabel,
  }) {
    return run(() => Isolate.run(task), timeout: timeout, debugLabel: debugLabel);
  }

  /// 当前是否还有空闲名额；仅用于诊断日志。
  @foundation.visibleForTesting
  int get availableSlots => _semaphore.availableSlots;
}

/// 信号量实现，用于控制并发数量。
///
/// 许可采用「转交」而非「先还再取」：`release()` 在有等待者时把许可直接交给
/// 队首，不递减计数，避免出现短暂的超额窗口。
///
/// 等待者可以带超时放弃排队：放弃时要把它从队列里摘掉，并且**必须跳过已经被
/// 超时丢弃的占位**，否则会把许可交给一个已经不再等待的 Completer
/// （对它 `complete()` 会抛「Future already completed」）。
class _Semaphore {
  final int maxCount;
  int _currentCount = 0;
  final _waitQueue = <Completer<bool>>[];

  _Semaphore(this.maxCount);

  int get availableSlots => math.max(0, maxCount - _currentCount);

  /// 获取许可；[timeout] 为 null 时无限等待。
  Future<bool> acquire({Duration? timeout}) async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return true;
    }
    final completer = Completer<bool>();
    _waitQueue.add(completer);
    if (timeout == null) {
      await completer.future;
      return true;
    }
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      if (completer.isCompleted) {
        // 竞态：超时与授予同时发生。许可已算在我们头上，让给下一个等待者。
        release();
        return false;
      }
      _waitQueue.remove(completer);
      return false;
    }
  }

  /// 释放许可
  void release() {
    while (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeAt(0);
      // 已被超时丢弃的等待者不再接收许可。
      if (completer.isCompleted) continue;
      completer.complete(true);
      return;
    }
    if (_currentCount > 0) _currentCount--;
  }
}
