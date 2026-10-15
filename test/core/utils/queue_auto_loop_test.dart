// 整批循环的纯逻辑测试（不跑队列、不等时间）。
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/queue_auto_loop.dart';
import 'package:nai_launcher/data/models/queue/replication_task.dart';
import 'package:nai_launcher/data/models/queue/replication_task_status.dart';

void main() {
  group('shouldStartNextRound', () {
    test('总轮数 1（默认）→ 不循环', () {
      expect(
        shouldStartNextRound(
          totalRounds: 1,
          completedRounds: 0,
          batchLength: 5,
        ),
        isFalse,
      );
    });

    test('0（关闭）→ 不循环', () {
      expect(
        shouldStartNextRound(
          totalRounds: 0,
          completedRounds: 0,
          batchLength: 5,
        ),
        isFalse,
      );
    });

    test('空批次 → 不循环（防止空转）', () {
      expect(
        shouldStartNextRound(
          totalRounds: 5,
          completedRounds: 0,
          batchLength: 0,
        ),
        isFalse,
      );
    });

    test('总轮数 3：第 1、2 轮后各续一次，第 3 轮后停', () {
      expect(
        shouldStartNextRound(
          totalRounds: 3,
          completedRounds: 0,
          batchLength: 5,
        ),
        isTrue,
      );
      expect(
        shouldStartNextRound(
          totalRounds: 3,
          completedRounds: 1,
          batchLength: 5,
        ),
        isTrue,
      );
      expect(
        shouldStartNextRound(
          totalRounds: 3,
          completedRounds: 2,
          batchLength: 5,
        ),
        isFalse,
      );
    });
  });

  group('cloneTaskForNewRound', () {
    test('换新 id、状态归零，prompt/参数/种子原样保留', () {
      final original =
          ReplicationTask.create(
            prompt: '1girl, sunset',
            negativePrompt: 'lowres',
            applyNegativePrompt: true,
            seed: 1234,
            width: 1216,
            height: 832,
            characterPrompts: const [],
          ).copyWith(
            status: ReplicationTaskStatus.completed,
            retryCount: 3,
            errorMessage: 'boom',
            startedAt: DateTime(2026),
            completedAt: DateTime(2026),
          );

      final clone = cloneTaskForNewRound(original, id: 'new-id');

      expect(clone.id, 'new-id');
      expect(clone.id, isNot(original.id));
      expect(clone.status, ReplicationTaskStatus.pending);
      expect(clone.retryCount, 0);
      expect(clone.errorMessage, isNull);
      expect(clone.startedAt, isNull);
      expect(clone.completedAt, isNull);
      // 内容一字不变，否则循环出来的就不是同一批图了
      expect(clone.prompt, original.prompt);
      expect(clone.negativePrompt, original.negativePrompt);
      expect(clone.applyNegativePrompt, original.applyNegativePrompt);
      expect(clone.seed, original.seed);
      expect(clone.width, original.width);
      expect(clone.height, original.height);
      expect(clone.characterPrompts, isEmpty);
    });
  });
}
