import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../constants/storage_keys.dart';
import '../utils/pipeline_interval.dart';
import '../../data/models/queue/replication_task.dart';
import '../../data/models/queue/failure_handling_strategy.dart';
import 'base_hive_storage.dart';

part 'queue_state_storage.g.dart';

/// 队列执行状态数据
class QueueExecutionStateData {
  final int completedCount;
  final int failedCount;
  final int skippedCount;
  final bool autoExecuteEnabled;
  final double taskIntervalMinSeconds;
  final double taskIntervalMaxSeconds;
  final FailureHandlingStrategy failureStrategy;
  final bool isPaused;
  final String? currentTaskId;
  final List<String> failedTaskIds;

  /// 整批循环的总轮数（1 = 只跑一遍）。
  final int autoLoopRounds;

  const QueueExecutionStateData({
    this.completedCount = 0,
    this.failedCount = 0,
    this.skippedCount = 0,
    this.autoExecuteEnabled = false,
    this.taskIntervalMinSeconds = kDefaultQueueTaskIntervalMinSeconds,
    this.taskIntervalMaxSeconds = kDefaultQueueTaskIntervalMaxSeconds,
    this.failureStrategy = FailureHandlingStrategy.skip,
    this.isPaused = false,
    this.currentTaskId,
    this.failedTaskIds = const [],
    this.autoLoopRounds = 1,
  });

  Map<String, dynamic> toJson() => {
    'completedCount': completedCount,
    'failedCount': failedCount,
    'skippedCount': skippedCount,
    'autoExecuteEnabled': autoExecuteEnabled,
    'taskIntervalMinSeconds': taskIntervalMinSeconds,
    'taskIntervalMaxSeconds': taskIntervalMaxSeconds,
    'failureStrategy': failureStrategy.index,
    'isPaused': isPaused,
    'currentTaskId': currentTaskId,
    'failedTaskIds': failedTaskIds,
    'autoLoopRounds': autoLoopRounds,
  };

  factory QueueExecutionStateData.fromJson(Map<String, dynamic> json) {
    return QueueExecutionStateData(
      completedCount: json['completedCount'] as int? ?? 0,
      failedCount: json['failedCount'] as int? ?? 0,
      skippedCount: json['skippedCount'] as int? ?? 0,
      autoExecuteEnabled: json['autoExecuteEnabled'] as bool? ?? false,
      taskIntervalMinSeconds: _migratedMin(json),
      taskIntervalMaxSeconds: _migratedMax(json),
      failureStrategy:
          FailureHandlingStrategy.values[json['failureStrategy'] as int? ?? 1],
      isPaused: json['isPaused'] as bool? ?? false,
      currentTaskId: json['currentTaskId'] as String?,
      failedTaskIds:
          (json['failedTaskIds'] as List<dynamic>?)?.cast<String>() ?? [],
      autoLoopRounds: (json['autoLoopRounds'] as num?)?.toInt() ?? 1,
    );
  }

  /// 旧存档只有单个 `taskIntervalSeconds`（默认 0＝当时等于关闭）。
  ///
  /// 迁移规则：写了新字段就用新的；只有旧字段且 >0 时，把它当成 min=max；
  /// 其余（老字段为 0 或没有字段）落到**新的默认区间**。
  static double _legacyTaskInterval(Map<String, dynamic> json) =>
      (json['taskIntervalSeconds'] as num?)?.toDouble() ?? 0;

  static double _migratedMin(Map<String, dynamic> json) {
    final min = (json['taskIntervalMinSeconds'] as num?)?.toDouble();
    if (min != null) return min;
    final legacy = _legacyTaskInterval(json);
    return legacy > 0 ? legacy : kDefaultQueueTaskIntervalMinSeconds;
  }

  static double _migratedMax(Map<String, dynamic> json) {
    final max = (json['taskIntervalMaxSeconds'] as num?)?.toDouble();
    if (max != null) return max;
    final legacy = _legacyTaskInterval(json);
    return legacy > 0 ? legacy : kDefaultQueueTaskIntervalMaxSeconds;
  }

  QueueExecutionStateData copyWith({
    int? completedCount,
    int? failedCount,
    int? skippedCount,
    bool? autoExecuteEnabled,
    double? taskIntervalMinSeconds,
    double? taskIntervalMaxSeconds,
    FailureHandlingStrategy? failureStrategy,
    bool? isPaused,
    String? currentTaskId,
    List<String>? failedTaskIds,
    int? autoLoopRounds,
  }) {
    return QueueExecutionStateData(
      completedCount: completedCount ?? this.completedCount,
      failedCount: failedCount ?? this.failedCount,
      skippedCount: skippedCount ?? this.skippedCount,
      autoExecuteEnabled: autoExecuteEnabled ?? this.autoExecuteEnabled,
      taskIntervalMinSeconds:
          taskIntervalMinSeconds ?? this.taskIntervalMinSeconds,
      taskIntervalMaxSeconds:
          taskIntervalMaxSeconds ?? this.taskIntervalMaxSeconds,
      failureStrategy: failureStrategy ?? this.failureStrategy,
      isPaused: isPaused ?? this.isPaused,
      currentTaskId: currentTaskId ?? this.currentTaskId,
      failedTaskIds: failedTaskIds ?? this.failedTaskIds,
      autoLoopRounds: autoLoopRounds ?? this.autoLoopRounds,
    );
  }
}

/// 队列执行状态存储服务
/// 注意: Box 在 main.dart 中已预先打开，此处直接同步获取
class QueueStateStorage extends BaseHiveStorage<void> {
  QueueStateStorage()
    : super(boxName: StorageKeys.queueExecutionStateBox, useLazyLoading: false);

  Box<String> get _queueStateBox =>
      Hive.box<String>(StorageKeys.queueExecutionStateBox);

  /// 保存执行状态
  Future<void> saveExecutionState(QueueExecutionStateData state) async {
    final jsonString = jsonEncode(state.toJson());
    await _queueStateBox.put(StorageKeys.queueExecutionStateData, jsonString);
  }

  /// 加载执行状态（同步加载）
  QueueExecutionStateData loadExecutionState() {
    try {
      final jsonString = _queueStateBox.get(
        StorageKeys.queueExecutionStateData,
      );

      if (jsonString == null || jsonString.isEmpty) {
        return const QueueExecutionStateData();
      }

      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      return QueueExecutionStateData.fromJson(json);
    } catch (e) {
      return const QueueExecutionStateData();
    }
  }

  /// 保存失败任务列表
  Future<void> saveFailedTasks(List<ReplicationTask> tasks) async {
    final taskList = ReplicationTaskList(tasks: tasks);
    final jsonString = jsonEncode(taskList.toJson());
    await _queueStateBox.put(StorageKeys.queueFailedTasksData, jsonString);
  }

  /// 加载失败任务列表（同步加载）
  List<ReplicationTask> loadFailedTasks() {
    try {
      final jsonString = _queueStateBox.get(StorageKeys.queueFailedTasksData);

      if (jsonString == null || jsonString.isEmpty) {
        return [];
      }

      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final taskList = ReplicationTaskList.fromJson(json);
      return taskList.tasks;
    } catch (e) {
      return [];
    }
  }
}

/// 队列状态存储服务 Provider
@riverpod
QueueStateStorage queueStateStorage(Ref ref) {
  return QueueStateStorage();
}
