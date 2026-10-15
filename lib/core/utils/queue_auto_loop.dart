// 「整批循环」的纯逻辑：跑完一批后要不要再来一轮、以及新一轮的任务怎么造。
//
// 语义：[kMaxQueueAutoLoopRounds] 是总轮数上限；[shouldStartNextRound] 里的
// totalRounds 是**总轮数**（1 = 只跑一遍，0 = 关闭）。每跑完一轮，用同一批任务
// 造一份**全新 id、状态归零**的副本再入队，直到跑满总轮数。这样 50 条上限的
// 队列也能无人值守跑 500 张（10 轮）。
import '../../data/models/queue/replication_task.dart';
import '../../data/models/queue/replication_task_status.dart';

/// 总轮数的允许上限。
const int kMaxQueueAutoLoopRounds = 20;

/// 跑完一轮后是否还要再来一轮。
bool shouldStartNextRound({
  required int totalRounds,
  required int completedRounds,
  required int batchLength,
}) {
  if (totalRounds <= 1) return false;
  if (batchLength <= 0) return false;
  return completedRounds + 1 < totalRounds;
}

/// 造下一轮用的任务：**换新 id**、状态回 pending、重试与错误与时间戳全部清空；
/// prompt / 参数快照 / 角色 / 尺寸 / 种子等一律原样保留。
///
/// 必须换 id：队列按 id 去重与定位，沿用旧 id 会撞上已完成池里的同名任务。
ReplicationTask cloneTaskForNewRound(
  ReplicationTask task, {
  required String id,
}) => task.copyWith(
  id: id,
  status: ReplicationTaskStatus.pending,
  retryCount: 0,
  errorMessage: null,
  startedAt: null,
  completedAt: null,
);
