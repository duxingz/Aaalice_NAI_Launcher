import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/services/bigman_queue_bridge.dart';

/// DSH 队列批次桥的纯逻辑检查：解析 + 一次性消费。
///
/// 全程用临时目录，**绝不碰真实的桥目录**（否则会污染用户正在用的文件）。
void main() {
  group('QueueJobBatch.parse', () {
    test('完整字段都认', () {
      final batch = QueueJobBatch.parse('''
{"autoStart": true, "jobs": [
  {"positive": "1girl, solo", "negative": "lowres",
   "width": 832, "height": 1216, "count": 3, "seed": 42,
   "steps": 28, "cfgScale": 5.5, "model": "nai-diffusion-4-5-full",
   "sampler": "k_euler_ancestral"}
]}''')!;

      expect(batch.autoStart, isTrue);
      expect(batch.jobs, hasLength(1));
      final job = batch.jobs.single;
      expect(job.positive, '1girl, solo');
      expect(job.negative, 'lowres');
      expect(job.width, 832);
      expect(job.height, 1216);
      expect(job.count, 3);
      expect(job.seed, 42);
      expect(job.steps, 28);
      expect(job.cfgScale, 5.5);
      expect(job.model, 'nai-diffusion-4-5-full');
      expect(job.sampler, 'k_euler_ancestral');
    });

    test('没写的字段保持 null（＝沿用界面当前参数）', () {
      final batch = QueueJobBatch.parse(
        '{"jobs":[{"positive":"cat"}]}',
      )!;
      final job = batch.jobs.single;
      expect(job.negative, isNull);
      expect(job.width, isNull);
      expect(job.height, isNull);
      expect(job.seed, isNull);
      expect(job.steps, isNull);
      expect(job.cfgScale, isNull);
      expect(job.model, isNull);
      expect(job.sampler, isNull);
      expect(job.count, 1);
      // autoStart 缺省必须是 false —— 不能默认自动花钱。
      expect(batch.autoStart, isFalse);
    });

    test('positive 为空的条目被丢掉，全空则整批无效', () {
      final batch = QueueJobBatch.parse(
        '{"jobs":[{"positive":"   "},{"positive":"ok"},{"negative":"x"}]}',
      )!;
      expect(batch.jobs, hasLength(1));
      expect(batch.jobs.single.positive, 'ok');

      expect(QueueJobBatch.parse('{"jobs":[{"positive":""}]}'), isNull);
    });

    test('也允许单条任务直接写在顶层', () {
      final batch = QueueJobBatch.parse('{"positive":"solo tag"}')!;
      expect(batch.jobs.single.positive, 'solo tag');
    });

    test('prompt / negativePrompt 别名同样认', () {
      final batch = QueueJobBatch.parse(
        '{"jobs":[{"prompt":"a","negativePrompt":"b"}]}',
      )!;
      expect(batch.jobs.single.positive, 'a');
      expect(batch.jobs.single.negative, 'b');
    });

    test('坏 JSON 返回 null 而不是抛异常', () {
      expect(QueueJobBatch.parse('not json'), isNull);
      expect(QueueJobBatch.parse('[]'), isNull);
      expect(QueueJobBatch.parse('{}'), isNull);
    });

    test('超过上限的批次被截断', () {
      final jobs = List.generate(
        QueueJobBatch.maxJobs + 5,
        (i) => '{"positive":"t$i"}',
      ).join(',');
      final batch = QueueJobBatch.parse('{"jobs":[$jobs]}')!;
      expect(batch.jobs, hasLength(QueueJobBatch.maxJobs));
    });
  });

  group('一次性消费', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('queue-bridge-'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('consume 把 jobs.json 搬走，下一轮不会再读到', () async {
      final path = BigmanQueueBridge.jobsPath(temp.path);
      File(path).writeAsStringSync('{"jobs":[{"positive":"cat"}]}');
      expect(await BigmanQueueBridge.readFile(path), isNotNull);

      final moved = await BigmanQueueBridge.consume(path);

      expect(moved, isNotNull);
      expect(File(path).existsSync(), isFalse, reason: '原文件必须已搬走');
      expect(File(moved!).existsSync(), isTrue, reason: '内容要留在 .done 文件里');
      expect(await BigmanQueueBridge.readFile(path), isNull);
    });

    test('读不到文件返回 null 而不是抛异常', () async {
      expect(
        await BigmanQueueBridge.readFile(
          BigmanQueueBridge.jobsPath(temp.path),
        ),
        isNull,
      );
      expect(await BigmanQueueBridge.consume('${temp.path}/nope.json'), isNull);
    });

    test('写状态回执是原子的（不会留下 .tmp）', () async {
      await BigmanQueueBridge.writeStatus(temp.path, '{"running":true}');
      final status = File(BigmanQueueBridge.statusPath(temp.path));
      expect(status.existsSync(), isTrue);
      expect(status.readAsStringSync(), '{"running":true}');
      expect(File('${status.path}.tmp').existsSync(), isFalse);
    });
  });
}
