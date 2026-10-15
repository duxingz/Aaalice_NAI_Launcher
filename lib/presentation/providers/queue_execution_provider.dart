import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/storage_keys.dart';
import '../../core/platform/platform_capabilities.dart';
import '../../core/storage/local_storage_service.dart';
import '../../core/storage/queue_state_storage.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/pipeline_interval.dart';
import '../../core/utils/queue_auto_loop.dart';
import '../../data/models/queue/replication_task.dart';
import '../../data/models/queue/replication_task_generation_snapshot.dart';
import '../../data/models/queue/replication_task_status.dart';
import '../../data/models/queue/failure_handling_strategy.dart';
import 'character_prompt_provider.dart';
import 'image_generation_provider.dart';
import '../../data/services/auth_provider.dart';
import 'krita/krita_bridge_notifier.dart';
import 'notification_settings_provider.dart';
import 'replication_queue_provider.dart';
import '../../core/services/notification_service.dart';

part 'queue_execution_provider.g.dart';

/// 队列执行状态
enum QueueExecutionStatus {
  /// 空闲，等待用户触发
  idle,

  /// 已填充提示词，等待用户点击生成
  ready,

  /// 正在执行
  running,

  /// 已暂停
  paused,

  /// 已完成
  completed,
}

enum QueueStartResult { started, empty, busy, authRequired }

/// 队列重试的默认值。
///
/// 原来 10 次 × 1 秒：对 429（并发/频率限制）连打 10 次短间隔对账号不友好，
/// 改成 5 次 × 5 秒（429 再叠加指数退避）。
const int kDefaultQueueRetryCount = 5;
const double kDefaultQueueRetryIntervalSeconds = 5.0;


/// 队列执行状态
class QueueExecutionState {
  final QueueExecutionStatus status;
  final int completedCount;
  final int failedCount;
  final int skippedCount;
  final String? currentTaskId;
  final int retryCount;
  final List<String> failedTaskIds;
  final bool autoExecuteEnabled;
  final double taskIntervalMinSeconds;
  final double taskIntervalMaxSeconds;
  final DateTime? pipelineWaitUntil;
  final FailureHandlingStrategy failureStrategy;
  final int totalTasksInSession;
  final DateTime? sessionStartTime;

  /// 整批循环的总轮数：1 = 只跑一遍（默认），0 = 关闭，>1 = 跑完再灌下一轮。
  final int autoLoopRounds;

  const QueueExecutionState({
    this.status = QueueExecutionStatus.idle,
    this.completedCount = 0,
    this.failedCount = 0,
    this.skippedCount = 0,
    this.currentTaskId,
    this.retryCount = 0,
    this.failedTaskIds = const [],
    this.autoExecuteEnabled = false,
    this.taskIntervalMinSeconds = kDefaultQueueTaskIntervalMinSeconds,
    this.taskIntervalMaxSeconds = kDefaultQueueTaskIntervalMaxSeconds,
    this.pipelineWaitUntil,
    this.failureStrategy = FailureHandlingStrategy.skip,
    this.totalTasksInSession = 0,
    this.sessionStartTime,
    this.autoLoopRounds = 1,
  });

  QueueExecutionState copyWith({
    QueueExecutionStatus? status,
    int? completedCount,
    int? failedCount,
    int? skippedCount,
    String? currentTaskId,
    bool clearCurrentTaskId = false,
    int? retryCount,
    List<String>? failedTaskIds,
    bool? autoExecuteEnabled,
    double? taskIntervalMinSeconds,
    double? taskIntervalMaxSeconds,
    DateTime? pipelineWaitUntil,
    bool clearPipelineWaitUntil = false,
    FailureHandlingStrategy? failureStrategy,
    int? totalTasksInSession,
    DateTime? sessionStartTime,
    int? autoLoopRounds,
  }) {
    return QueueExecutionState(
      status: status ?? this.status,
      completedCount: completedCount ?? this.completedCount,
      failedCount: failedCount ?? this.failedCount,
      skippedCount: skippedCount ?? this.skippedCount,
      currentTaskId: clearCurrentTaskId
          ? null
          : (currentTaskId ?? this.currentTaskId),
      retryCount: retryCount ?? this.retryCount,
      failedTaskIds: failedTaskIds ?? this.failedTaskIds,
      autoExecuteEnabled: autoExecuteEnabled ?? this.autoExecuteEnabled,
      taskIntervalMinSeconds:
          taskIntervalMinSeconds ?? this.taskIntervalMinSeconds,
      taskIntervalMaxSeconds:
          taskIntervalMaxSeconds ?? this.taskIntervalMaxSeconds,
      pipelineWaitUntil: clearPipelineWaitUntil
          ? null
          : (pipelineWaitUntil ?? this.pipelineWaitUntil),
      failureStrategy: failureStrategy ?? this.failureStrategy,
      totalTasksInSession: totalTasksInSession ?? this.totalTasksInSession,
      sessionStartTime: sessionStartTime ?? this.sessionStartTime,
      autoLoopRounds: autoLoopRounds ?? this.autoLoopRounds,
    );
  }

  /// 流水线间隔是否生效（上限为 0 即视作关闭）。
  bool get hasTaskInterval => taskIntervalMaxSeconds > 0;

  bool get isRunning => status == QueueExecutionStatus.running;
  bool get isReady => status == QueueExecutionStatus.ready;
  bool get isPaused => status == QueueExecutionStatus.paused;
  bool get isIdle => status == QueueExecutionStatus.idle;
  bool get isCompleted => status == QueueExecutionStatus.completed;

  /// 获取进度百分比 (0.0 - 1.0)
  double get progress {
    if (totalTasksInSession <= 0) return 0.0;
    return (completedCount + failedCount + skippedCount) / totalTasksInSession;
  }

  /// 是否有失败任务
  bool get hasFailedTasks => failedTaskIds.isNotEmpty;
}

/// 队列设置
///
/// 流水线间隔（`taskInterval*`）不在这里：它随执行状态走
/// （见 [QueueExecutionState]）—— 原先这里有个 `taskIntervalSeconds` 字段
/// 和一个 `taskInterval` getter，**没有任何调用点**，已删除以免改错地方。
class QueueSettings {
  final int retryCount;
  final double retryIntervalSeconds;
  final bool autoExecuteEnabled;
  final FailureHandlingStrategy failureStrategy;

  const QueueSettings({
    this.retryCount = 10,
    this.retryIntervalSeconds = 1.0,
    this.autoExecuteEnabled = false,
    this.failureStrategy = FailureHandlingStrategy.skip,
  });

  Duration get retryInterval =>
      Duration(milliseconds: (retryIntervalSeconds * 1000).toInt());

  QueueSettings copyWith({
    int? retryCount,
    double? retryIntervalSeconds,
    bool? autoExecuteEnabled,
    FailureHandlingStrategy? failureStrategy,
  }) {
    return QueueSettings(
      retryCount: retryCount ?? this.retryCount,
      retryIntervalSeconds: retryIntervalSeconds ?? this.retryIntervalSeconds,
      autoExecuteEnabled: autoExecuteEnabled ?? this.autoExecuteEnabled,
      failureStrategy: failureStrategy ?? this.failureStrategy,
    );
  }
}

/// 队列执行引擎 Provider
///
/// 管理复刻队列的自动执行，包括：
/// - 填充提示词到主界面
/// - 监听生成完成事件
/// - 自动处理下一项
/// - 错误重试机制
/// - 暂停/恢复功能
/// - 失败处理策略
@Riverpod(keepAlive: true)
class QueueExecutionNotifier extends _$QueueExecutionNotifier {
  late final QueueStateStorage _stateStorage;
  bool _generationTriggerPending = false;
  Future<void> _pendingStateWrite = Future.value();
  int _executionRevision = 0;

  /// 上一张任务**开始出图**的时刻。流水线间隔按它计时（「至少」语义）。
  DateTime? _lastTaskStartedAt;

  /// 流水线间隔在区间内随机取样用的随机源。
  final Random _intervalRandom = Random();

  /// 本轮要循环的整批任务快照（开始跑时抓一次）。
  ///
  /// 不持久化：重启后队列会恢复成暂停态，快照丢失即不再续轮 —— 比拿一个
  /// 过期的快照去灌队列安全。
  List<ReplicationTask>? _autoLoopBatch;

  /// 已经跑完的轮数（0 = 第一轮还没跑完）。
  int _autoLoopCompletedRounds = 0;

  @override
  QueueExecutionState build() {
    _stateStorage = ref.read(queueStateStorageProvider);

    // 使用 ref.listen 监听生成状态变化（不会触发 provider 重建，避免竞态条件）
    ref.listen<ImageGenerationState>(imageGenerationNotifierProvider, (
      previous,
      next,
    ) {
      _onGenerationStateChanged(previous, next);
    });

    // 同步加载持久化状态（Hive Box 已在 main.dart 中预先打开）
    return _loadFromStorageSync();
  }

  /// 同步加载状态
  QueueExecutionState _loadFromStorageSync() {
    try {
      final data = _stateStorage.loadExecutionState();
      final queueState = ref.read(replicationQueueNotifierProvider);
      final currentTaskStillExists =
          data.currentTaskId != null &&
          queueState.tasks.any((task) => task.id == data.currentTaskId);
      final shouldRecoverPaused =
          queueState.tasks.isNotEmpty &&
          (data.isPaused || currentTaskStillExists);
      return QueueExecutionState(
        status: shouldRecoverPaused
            ? QueueExecutionStatus.paused
            : QueueExecutionStatus.idle,
        completedCount: data.completedCount,
        failedCount: data.failedCount,
        skippedCount: data.skippedCount,
        currentTaskId: currentTaskStillExists ? data.currentTaskId : null,
        failedTaskIds: data.failedTaskIds,
        autoExecuteEnabled: data.autoExecuteEnabled,
        taskIntervalMinSeconds: data.taskIntervalMinSeconds,
        taskIntervalMaxSeconds: data.taskIntervalMaxSeconds,
        autoLoopRounds: data.autoLoopRounds,
        failureStrategy: data.failureStrategy,
        totalTasksInSession:
            data.completedCount +
            data.failedCount +
            data.skippedCount +
            queueState.count,
      );
    } catch (e) {
      return const QueueExecutionState();
    }
  }

  /// 序列化执行状态写入，确保停止或清空后的状态不会被旧任务覆盖。
  Future<void> _saveToStorage() {
    final snapshot = QueueExecutionStateData(
      completedCount: state.completedCount,
      failedCount: state.failedCount,
      skippedCount: state.skippedCount,
      autoExecuteEnabled: state.autoExecuteEnabled,
      taskIntervalMinSeconds: state.taskIntervalMinSeconds,
      taskIntervalMaxSeconds: state.taskIntervalMaxSeconds,
      autoLoopRounds: state.autoLoopRounds,
      failureStrategy: state.failureStrategy,
      isPaused: state.isPaused,
      currentTaskId: state.currentTaskId,
      failedTaskIds: List<String>.unmodifiable(state.failedTaskIds),
    );
    final operation = _pendingStateWrite.then(
      (_) => _stateStorage.saveExecutionState(snapshot),
    );
    _pendingStateWrite = operation.catchError((_) {});
    return operation;
  }

  /// 获取队列设置
  QueueSettings _getSettings() {
    final storage = ref.read(localStorageServiceProvider);
    final retryCount =
        storage.getSetting<int>(
          StorageKeys.queueRetryCount,
          defaultValue: kDefaultQueueRetryCount,
        ) ??
        kDefaultQueueRetryCount;
    final retryInterval =
        storage.getSetting<double>(
          StorageKeys.queueRetryInterval,
          defaultValue: kDefaultQueueRetryIntervalSeconds,
        ) ??
        kDefaultQueueRetryIntervalSeconds;
    return QueueSettings(
      retryCount: retryCount,
      retryIntervalSeconds: retryInterval,
      autoExecuteEnabled: state.autoExecuteEnabled,
      failureStrategy: state.failureStrategy,
    );
  }

  /// 设置自动执行模式
  Future<void> setAutoExecute(bool enabled) async {
    state = state.copyWith(autoExecuteEnabled: enabled);
    await _saveToStorage();
  }

  /// 设置流水线间隔区间（**仅队列生效**）。
  ///
  /// 两个值都钳到 `0~600`；`min > max` 时自动交换（界面填反了不该变成"永远按
  /// max 等"）。上限为 0 表示关闭 —— 队列跑完一张就不额外等。
  Future<void> setTaskIntervalRange({
    required double minSeconds,
    required double maxSeconds,
  }) async {
    var min = minSeconds.clamp(0.0, kMaxQueueTaskIntervalSeconds);
    var max = maxSeconds.clamp(0.0, kMaxQueueTaskIntervalSeconds);
    if (min > max) {
      final swapped = min;
      min = max;
      max = swapped;
    }
    state = state.copyWith(
      taskIntervalMinSeconds: min,
      taskIntervalMaxSeconds: max,
    );
    await _saveToStorage();
  }

  /// 设置整批循环的总轮数（**仅队列生效**）。
  ///
  /// 1 = 只跑一遍（默认），0 等同于关闭；>1 时每跑完一批就换新 id 再灌一批，
  /// 直到跑满轮数。中途 `stop` / `clearQueue` 会立刻终止循环（见 [stopExecution]）。
  Future<void> setAutoLoopRounds(int rounds) async {
    final value = rounds < 0
        ? 0
        : (rounds > kMaxQueueAutoLoopRounds
              ? kMaxQueueAutoLoopRounds
              : rounds);
    if (value <= 1) {
      _autoLoopBatch = null;
      _autoLoopCompletedRounds = 0;
    }
    state = state.copyWith(autoLoopRounds: value);
    await _saveToStorage();
  }

  /// 设置失败处理策略
  Future<void> setFailureStrategy(FailureHandlingStrategy strategy) async {
    state = state.copyWith(failureStrategy: strategy);
    await _saveToStorage();
  }

  /// 暂停执行
  ///
  /// 已经提交给 NovelAI 的当前任务不会被取消；暂停会在该任务完成后生效。
  Future<void> pause() async {
    if (state.status != QueueExecutionStatus.running &&
        state.status != QueueExecutionStatus.ready) {
      return;
    }
    state = state.copyWith(status: QueueExecutionStatus.paused);
    await _saveToStorage();
  }

  /// 恢复执行
  Future<void> resume() async {
    if (state.status != QueueExecutionStatus.paused) return;

    final queueState = ref.read(replicationQueueNotifierProvider);
    if (queueState.isEmpty) {
      state = state.copyWith(
        status: QueueExecutionStatus.idle,
        clearCurrentTaskId: true,
      );
      return;
    }

    if (!requireAuthenticatedAction(ref, AuthPromptReason.queueExecution)) {
      return;
    }

    final firstTask = queueState.tasks.first;
    if (state.currentTaskId == null || state.currentTaskId != firstTask.id) {
      _processNextTask();
    } else if (firstTask.status == ReplicationTaskStatus.running) {
      // 当前请求仍在飞行时，恢复只解除“完成后暂停”，不能再次提交同一任务。
      state = state.copyWith(status: QueueExecutionStatus.running);
    } else {
      state = state.copyWith(status: QueueExecutionStatus.ready);
      _fillPrompt(firstTask);
    }
    await _saveToStorage();
    if (state.status == QueueExecutionStatus.ready) {
      _triggerAutoGenerate();
    }
  }

  /// 从任意页面启动队列。
  Future<QueueStartResult> startQueue() async {
    final queueState = ref.read(replicationQueueNotifierProvider);
    if (queueState.isEmpty) return QueueStartResult.empty;

    if (!requireAuthenticatedAction(ref, AuthPromptReason.queueExecution)) {
      return QueueStartResult.authRequired;
    }

    final generationState = ref.read(imageGenerationNotifierProvider);
    final isKritaGenerating =
        PlatformCapabilities.current.supportsKritaBridge &&
        ref.read(kritaBridgeNotifierProvider).isBridgeGenerating;
    if (generationState.isBusy || isKritaGenerating) {
      return QueueStartResult.busy;
    }

    prepareNextTask();
    _triggerAutoGenerate();
    return QueueStartResult.started;
  }

  /// 准备执行队列（填充第一项提示词）
  ///
  /// 当用户进入主界面且队列非空时调用
  void prepareNextTask() {
    if (state.status == QueueExecutionStatus.running ||
        state.status == QueueExecutionStatus.paused) {
      return;
    }

    final queueState = ref.read(replicationQueueNotifierProvider);
    if (queueState.isEmpty) {
      state = state.copyWith(status: QueueExecutionStatus.idle);
      return;
    }

    final nextTask = queueState.tasks.first;

    // 记录会话开始，先更新状态为 ready。完成后的新一轮队列必须重置
    // 统计，否则进度会继续沿用上一轮结果。
    final isNewSession = state.isIdle || state.isCompleted;
    state = state.copyWith(
      status: QueueExecutionStatus.ready,
      currentTaskId: nextTask.id,
      retryCount: 0,
      completedCount: isNewSession ? 0 : state.completedCount,
      failedCount: isNewSession ? 0 : state.failedCount,
      skippedCount: isNewSession ? 0 : state.skippedCount,
      failedTaskIds: isNewSession ? const [] : state.failedTaskIds,
      totalTasksInSession: isNewSession
          ? queueState.count
          : state.totalTasksInSession,
      sessionStartTime: isNewSession ? DateTime.now() : state.sessionStartTime,
    );

    // 填充提示词（此时状态已是 ready，prompt_input 不会同步）
    _fillPrompt(nextTask);

    // 注意：这里不更新任务状态，任务保持 pending 状态
    // 只有在实际开始生成时（startExecution）才更新为 running
  }

  /// 填充提示词到主界面
  void _fillPrompt(ReplicationTask task) {
    // 队列任务只回填用户基础提示词；固定词、质量词和 UC 预设仍由生成链路统一组装。
    final paramsNotifier = ref.read(generationParamsNotifierProvider.notifier);
    paramsNotifier.updatePrompt(task.prompt);
    if (task.applyNegativePrompt) {
      paramsNotifier.updateNegativePrompt(task.negativePrompt);
    }

    final characterPrompts = task.characterPrompts;
    if (characterPrompts != null) {
      final notifier = ref.read(characterPromptNotifierProvider.notifier);
      notifier.replaceAll([
        for (var index = 0; index < characterPrompts.length; index++)
          characterPrompts[index].toCharacterPrompt(
            id: '${task.id}-character-$index',
            index: index,
          ),
      ]);
      notifier.setGlobalAiChoice(
        !characterPrompts.any(
          (character) =>
              character.positionX != null && character.positionY != null,
        ),
      );
    }
  }

  /// 触发队列当前任务生成。
  ///
  /// 执行入口必须由队列引擎持有，不能依赖生成页 Widget 是否挂载。
  void _triggerAutoGenerate() {
    if (_generationTriggerPending) return;
    _generationTriggerPending = true;
    unawaited(_generateReadyTask());
  }

  Future<void> _generateReadyTask() async {
    try {
      await ref.read(generationCooldownProvider.notifier).waitUntilAvailable();

      final generationNotifier = ref.read(
        imageGenerationNotifierProvider.notifier,
      );
      // completed/error 会先于生成调用的 finally 对外可见。等待旧调用释放
      // invocation 所有权，避免下一任务因 generate() 的并发保护而被静默丢弃。
      await generationNotifier.waitUntilGenerationInvocationSettled();

      if (state.status != QueueExecutionStatus.ready) return;
      if (ref.read(imageGenerationNotifierProvider).isBusy ||
          (PlatformCapabilities.current.supportsKritaBridge &&
              ref.read(kritaBridgeNotifierProvider).isBridgeGenerating)) {
        return;
      }

      final baseParams = ref.read(generationParamsNotifierProvider);
      final queueState = ref.read(replicationQueueNotifierProvider);
      ReplicationTask? task;
      for (final candidate in queueState.tasks) {
        if (candidate.id == state.currentTaskId) {
          task = candidate;
          break;
        }
      }
      if (task == null) return;
      final snapshot = task.generationSnapshot;
      final batchSizeOverride = snapshot == null
          ? null
          : ReplicationTaskGenerationSnapshot.decodeBatchSize(snapshot);
      final queuedFocused = snapshot == null
          ? null
          : ReplicationTaskGenerationSnapshot.decodeFocused(snapshot);
      final params = snapshot == null
          ? baseParams.copyWith(
              prompt: task.prompt,
              negativePrompt: task.applyNegativePrompt
                  ? task.negativePrompt
                  : baseParams.negativePrompt,
              model: task.model ?? baseParams.model,
              sampler: task.sampler ?? baseParams.sampler,
              steps: task.steps ?? baseParams.steps,
              scale: task.cfgScale ?? baseParams.scale,
              seed: task.seed ?? -1,
              width: task.width ?? baseParams.width,
              height: task.height ?? baseParams.height,
              nSamples: 1,
            )
          : ReplicationTaskGenerationSnapshot.decode(snapshot).copyWith(
              prompt: task.prompt,
              negativePrompt: task.applyNegativePrompt
                  ? task.negativePrompt
                  : baseParams.negativePrompt,
              nSamples: 1,
            );

      // generate() 在首次异步让出前会把状态切到 generating；此后由生成状态
      // 本身阻止重复提交，不要让该锁跨越整次生成而吞掉下一任务的触发。
      _generationTriggerPending = false;
      // 流水线间隔从「这一张开始出图」计时。
      _lastTaskStartedAt = DateTime.now();
      await generationNotifier.generate(
        params,
        batchSizeOverride: batchSizeOverride,
        preserveCharacterSnapshot: snapshot != null,
        focusedOverride: queuedFocused == null
            ? null
            : GenerationFocusedSnapshot(
                enabled: queuedFocused.enabled,
                minimumContextMegaPixels: queuedFocused.contextPadding,
                selectionRect: queuedFocused.selectionRect,
                contextCrop: queuedFocused.contextCrop,
              ),
      );
    } on FormatException catch (error, stackTrace) {
      final taskId = state.currentTaskId;
      AppLogger.e(
        'Queued generation snapshot is invalid',
        error,
        stackTrace,
        'QueueExecution',
      );
      if (taskId != null) {
        final message = 'Invalid generation snapshot: $error';
        await ref
            .read(replicationQueueNotifierProvider.notifier)
            .updateTaskStatus(
              taskId,
              ReplicationTaskStatus.running,
              errorMessage: message,
            );
        await _handleFailedTask(errorMessage: message, retryable: false);
      } else {
        state = state.copyWith(
          status: QueueExecutionStatus.idle,
          clearCurrentTaskId: true,
        );
        await _saveToStorage();
      }
    } finally {
      _generationTriggerPending = false;
    }
  }

  /// 开始执行队列
  ///
  /// 当用户点击生成按钮后，由生成状态监听器自动触发
  void startExecution() {
    if (state.status != QueueExecutionStatus.ready) return;

    state = state.copyWith(status: QueueExecutionStatus.running);

    // 第一轮开跑时抓一次整批快照；后续每一轮都用它造副本。
    if (state.autoLoopRounds > 1 && _autoLoopBatch == null) {
      _autoLoopBatch = List<ReplicationTask>.of(
        ref.read(replicationQueueNotifierProvider).tasks,
      );
      _autoLoopCompletedRounds = 0;
    }

    // 实际开始执行时，更新当前任务状态为 running
    if (state.currentTaskId != null) {
      ref
          .read(replicationQueueNotifierProvider.notifier)
          .updateTaskStatus(
            state.currentTaskId!,
            ReplicationTaskStatus.running,
          );
    }
  }

  /// 停止执行队列。已提交的生成请求继续完成，但不再推进队列。
  Future<void> stopExecution() async {
    _executionRevision++;
    _generationTriggerPending = false;
    // 停止即终止整批循环：清掉快照，正在进行的续轮也会被 revision 检查拦下。
    _autoLoopBatch = null;
    _autoLoopCompletedRounds = 0;
    final currentTaskId = state.currentTaskId;
    state = state.copyWith(
      status: QueueExecutionStatus.idle,
      clearCurrentTaskId: true,
    );
    if (currentTaskId != null) {
      await ref
          .read(replicationQueueNotifierProvider.notifier)
          .resetRunningTask(currentTaskId);
    }
    await _saveToStorage();
  }

  /// 原子停止执行状态后再清空待处理任务，避免运行中的回调复活旧队列。
  Future<void> clearQueue() async {
    await stopExecution();
    await ref.read(replicationQueueNotifierProvider.notifier).clear();
  }

  /// 监听生成状态变化
  void _onGenerationStateChanged(
    ImageGenerationState? previous,
    ImageGenerationState next,
  ) {
    // 检测生成完成（优先处理，无论队列模式还是普通模式）
    if (previous?.status == GenerationStatus.generating &&
        next.status == GenerationStatus.completed) {
      // 判断是否为队列模式
      final isQueueMode =
          state.currentTaskId != null &&
          (state.status == QueueExecutionStatus.running ||
              state.status == QueueExecutionStatus.ready ||
              state.status == QueueExecutionStatus.paused);

      if (isQueueMode) {
        // 队列模式：不播放单张完成音效，等队列全部完成后播放
        _onTaskCompleted();
      } else {
        // 非队列模式：立即播放生成完成音效
        _triggerGenerationNotification();
      }
      return;
    }

    // 以下逻辑仅在队列模式下执行
    if (state.status != QueueExecutionStatus.running &&
        state.status != QueueExecutionStatus.ready) {
      return;
    }

    // 检测到开始生成，进入运行状态
    if (previous?.status != GenerationStatus.generating &&
        next.status == GenerationStatus.generating) {
      if (state.status == QueueExecutionStatus.ready) {
        startExecution(); // 调用 startExecution 来同时更新队列状态和任务状态
      }
      return;
    }

    // 生成错误
    if (previous?.status == GenerationStatus.generating &&
        next.status == GenerationStatus.error) {
      _onTaskError();
      return;
    }

    // 生成取消
    if (next.status == GenerationStatus.cancelled) {
      unawaited(stopExecution());
      return;
    }
  }

  /// 触发生成完成音效
  void _triggerGenerationNotification() {
    final settings = ref.read(notificationSettingsNotifierProvider);
    if (!settings.soundEnabled) return;

    Future.microtask(() async {
      await NotificationService.instance.notifyGenerationComplete(
        playSound: settings.soundEnabled,
        customSoundPath: settings.customSoundPath,
      );
    });
  }

  /// 任务完成处理
  Future<void> _onTaskCompleted() async {
    final revision = _executionRevision;
    final currentTaskId = state.currentTaskId;
    if (currentTaskId == null) {
      AppLogger.e(
        'Queue completion received without a current task ID',
        null,
        null,
        'QueueExecution',
      );
      await stopExecution();
      return;
    }

    final completed = await ref
        .read(replicationQueueNotifierProvider.notifier)
        .markCompleted(currentTaskId);
    if (revision != _executionRevision) return;
    if (!completed) {
      AppLogger.e(
        'Queue completion target no longer exists: $currentTaskId',
        null,
        null,
        'QueueExecution',
      );
      await stopExecution();
      return;
    }

    state = state.copyWith(
      completedCount: state.completedCount + 1,
      retryCount: 0,
      clearCurrentTaskId: state.isPaused,
    );
    await _saveToStorage();

    // 运行中点击暂停表示“当前任务完成后暂停”。
    if (state.isPaused) return;

    // 流水线间隔（仅队列生效）：从上一张「开始出图」算起至少隔 d 秒，
    // 出图本身的时间算在里面；等待中暂停/停止要在 1 秒内响应。
    await _waitForPipelineInterval(revision);
    if (revision != _executionRevision) return;

    _processNextTask();
  }

  /// 等到流水线间隔满足；暂停或停止时立即返回（不再额外等待）。
  ///
  /// 只被队列调用 —— 手动生成路径读不到这两个字段。
  Future<void> _waitForPipelineInterval(int revision) async {
    final lastStartedAt = _lastTaskStartedAt;
    if (lastStartedAt == null) return;
    final interval = PipelineInterval.resolve(
      minSeconds: state.taskIntervalMinSeconds,
      maxSeconds: state.taskIntervalMaxSeconds,
      randomFraction: _intervalRandom.nextDouble(),
    );
    if (interval == null) return;

    state = state.copyWith(
      pipelineWaitUntil: lastStartedAt.add(interval),
    );
    try {
      await PipelineInterval.waitAtLeast(
        lastStartedAt: lastStartedAt,
        interval: interval,
        shouldAbort: () => revision != _executionRevision || state.isPaused,
      );
    } finally {
      if (revision == _executionRevision && state.pipelineWaitUntil != null) {
        state = state.copyWith(clearPipelineWaitUntil: true);
      }
    }
  }

  /// 任务错误处理
  Future<void> _onTaskError() async {
    final settings = _getSettings();

    if (state.retryCount < settings.retryCount) {
      // 重试
      state = state.copyWith(retryCount: state.retryCount + 1);

      // 等重试间隔：普通错误用设置里的固定值；429（并发/频率限制）改用指数
      // 退避 —— 对 429 连打固定短间隔对账号不友好。
      await Future.delayed(_retryDelay(settings));

      // 检查是否仍在运行或暂停
      if (state.status != QueueExecutionStatus.running) return;

      // 重新设置为 ready 状态，等待用户再次点击或自动执行
      state = state.copyWith(status: QueueExecutionStatus.ready);

      _triggerAutoGenerate();
    } else {
      // 超过重试次数，根据策略处理
      await _handleFailedTask();
    }
  }

  /// 上限：429 退避最多等这么久。
  static const Duration _maxRetryBackoff = Duration(seconds: 60);

  /// 本次重试要等多久。
  ///
  /// - 普通错误：设置里的固定间隔。
  /// - 429（`API_ERROR_429`）：指数退避 `间隔 × 2^(第几次-1)`，封顶
  ///   [_maxRetryBackoff]。判据与 `ImageGenerationCoordinator` 里的一致。
  Duration _retryDelay(QueueSettings settings) {
    final base = settings.retryInterval;
    final message = ref.read(imageGenerationNotifierProvider).errorMessage;
    if (message == null || !_looksRateLimited(message)) return base;
    final attempt = state.retryCount < 1
        ? 1
        : (state.retryCount > 5 ? 5 : state.retryCount);
    final scaled = base * (1 << (attempt - 1));
    return scaled > _maxRetryBackoff ? _maxRetryBackoff : scaled;
  }

  static bool _looksRateLimited(String text) =>
      text.contains('API_ERROR_429') || text.contains(' 429');

  /// 处理失败任务
  Future<void> _handleFailedTask({
    String? errorMessage,
    bool retryable = true,
  }) async {
    final currentTaskId = state.currentTaskId;
    if (currentTaskId == null) {
      _processNextTask();
      return;
    }

    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    final task = ref
        .read(replicationQueueNotifierProvider)
        .tasks
        .firstWhere(
          (t) => t.id == currentTaskId,
          orElse: () => ReplicationTask.create(prompt: ''),
        );

    switch (state.failureStrategy) {
      case FailureHandlingStrategy.autoRetry:
        if (!retryable) {
          await queueNotifier.moveToFailedPool(currentTaskId);
          break;
        }
        // 重新入队到末尾。执行中的任务只能通过专用结算入口移除。
        final removed = await queueNotifier.removeRunningTaskForRetry(
          currentTaskId,
        );
        if (!removed) {
          AppLogger.e(
            'Queue retry target no longer exists: $currentTaskId',
            null,
            null,
            'QueueExecution',
          );
          await stopExecution();
          return;
        }
        await queueNotifier.add(
          task.copyWith(
            status: ReplicationTaskStatus.pending,
            retryCount: 0,
            errorMessage: null,
          ),
        );
        break;

      case FailureHandlingStrategy.skip:
        // 更新任务状态为 failed 并移入失败池
        await queueNotifier.moveToFailedPool(currentTaskId);
        break;

      case FailureHandlingStrategy.pauseAndWait:
        // 更新任务状态为 failed
        await queueNotifier.updateTaskStatus(
          currentTaskId,
          ReplicationTaskStatus.failed,
          errorMessage: errorMessage,
        );
        // 暂停执行
        state = state.copyWith(
          status: QueueExecutionStatus.paused,
          failedCount: state.failedCount + 1,
          failedTaskIds: [...state.failedTaskIds, currentTaskId],
          retryCount: 0,
        );
        await _saveToStorage();
        return;
    }

    state = state.copyWith(
      failedCount: state.failedCount + 1,
      failedTaskIds: [...state.failedTaskIds, currentTaskId],
      retryCount: 0,
    );

    await _saveToStorage();

    // 处理下一个任务
    _processNextTask();
  }

  /// 处理下一个任务
  void _processNextTask() {
    final queueState = ref.read(replicationQueueNotifierProvider);

    if (queueState.isEmpty) {
      // 队列空了：可能还要续下一轮（整批循环），交给异步方法决定。
      unawaited(_completeOrStartNextRound());
      return;
    }

    // 先更新状态为 ready
    // 重要：必须在 _fillPrompt 之前更新状态，
    // 这样 prompt_input 才能检测到队列正在执行，从而跳过同步
    final nextTask = queueState.tasks.first;
    state = state.copyWith(
      status: QueueExecutionStatus.ready,
      currentTaskId: nextTask.id,
      retryCount: 0,
    );

    // 填充下一个任务的提示词（此时状态已是 ready）
    _fillPrompt(nextTask);

    // 注意：这里不更新任务状态，任务保持 pending 状态；生成状态切换后
    // startExecution() 会将当前任务标记为 running。
    _triggerAutoGenerate();
  }

  /// 队列跑空时：还有剩余轮数就换新 id 再灌一批，否则按完成收尾。
  ///
  /// 续轮期间被 `stop` / `clearQueue` 打断（revision 变化）就**不再推进** ——
  /// 否则旧回调会把用户刚清掉的队列复活。
  Future<void> _completeOrStartNextRound() async {
    final revision = _executionRevision;
    final batch = _autoLoopBatch;
    if (shouldStartNextRound(
      totalRounds: state.autoLoopRounds,
      completedRounds: _autoLoopCompletedRounds,
      batchLength: batch?.length ?? 0,
    )) {
      final notifier = ref.read(replicationQueueNotifierProvider.notifier);
      for (final task in batch!) {
        // 每加一条都查一次：用户在续轮中途点「停止/清空」时，不能把任务
        // 又加回刚被清掉的队列里（加完再查会漏掉这条路径）。
        if (revision != _executionRevision) return;
        await notifier.add(cloneTaskForNewRound(task, id: const Uuid().v4()));
      }
      if (revision != _executionRevision) return;
      _autoLoopCompletedRounds++;
      await _saveToStorage();
      _processNextTask();
      return;
    }

    _autoLoopBatch = null;
    _autoLoopCompletedRounds = 0;
    state = state.copyWith(
      status: QueueExecutionStatus.completed,
      clearCurrentTaskId: true,
    );
    await _saveToStorage();

    // 触发队列完成通知
    _triggerGenerationNotification();
  }

  /// 手动重试指定的失败任务
  Future<bool> retryFailedTask(String taskId) async {
    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    final requeued = await queueNotifier.retryFailedTask(taskId);
    if (!requeued) return false;

    state = state.copyWith(
      failedTaskIds: state.failedTaskIds.where((id) => id != taskId).toList(),
    );
    await _saveToStorage();
    return true;
  }

  /// 将失败任务重新入队
  Future<bool> requeueFailedTask(String taskId) async {
    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    final requeued = await queueNotifier.requeueFailedTask(taskId);
    if (!requeued) return false;

    state = state.copyWith(
      failedTaskIds: state.failedTaskIds.where((id) => id != taskId).toList(),
    );
    await _saveToStorage();
    return true;
  }

  /// 清除所有失败任务
  Future<void> clearFailedTasks() async {
    final queueNotifier = ref.read(replicationQueueNotifierProvider.notifier);
    await queueNotifier.clearFailedTasks();

    state = state.copyWith(failedTaskIds: []);
    await _saveToStorage();
  }

  /// 重置执行状态
  void reset() {
    state = const QueueExecutionState();
    _saveToStorage();
  }

  /// 开始新的执行会话
  void startNewSession() {
    final queueState = ref.read(replicationQueueNotifierProvider);
    state = state.copyWith(
      completedCount: 0,
      failedCount: 0,
      skippedCount: 0,
      failedTaskIds: [],
      totalTasksInSession: queueState.count,
      sessionStartTime: DateTime.now(),
    );
    _saveToStorage();
  }
}

/// 队列设置 Provider（从本地存储读取）
@riverpod
QueueSettings queueSettings(Ref ref) {
  final storage = ref.watch(localStorageServiceProvider);
  final executionState = ref.watch(queueExecutionNotifierProvider);

  return QueueSettings(
    retryCount:
        storage.getSetting<int>(
          StorageKeys.queueRetryCount,
          defaultValue: kDefaultQueueRetryCount,
        ) ??
        kDefaultQueueRetryCount,
    retryIntervalSeconds:
        storage.getSetting<double>(
          StorageKeys.queueRetryInterval,
          defaultValue: kDefaultQueueRetryIntervalSeconds,
        ) ??
        kDefaultQueueRetryIntervalSeconds,
    autoExecuteEnabled: executionState.autoExecuteEnabled,
    failureStrategy: executionState.failureStrategy,
  );
}
