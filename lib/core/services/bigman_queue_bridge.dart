/// 胖大叔自用改：DSH 队列批次桥。
///
/// [bigman_prompt_inbox] 解决的是「DSH 把一份提示词填进输入框」；这里解决的是
/// 「DSH 一次喂一批任务、直接进生成队列」，于是提示词可以反复利用、按批出图。
///
/// 约定文件 `jobs.json` 放在桥目录里（与 `prompt.txt` 同目录，目录可配置）：
///
/// ```json
/// {
///   "autoStart": false,
///   "jobs": [
///     {"positive": "1girl, ...", "negative": "lowres, ...",
///      "width": 1024, "height": 1536, "count": 4,
///      "seed": null, "steps": null, "cfgScale": null,
///      "model": null, "sampler": null}
///   ]
/// }
/// ```
///
/// **未写或写 null 的字段一律沿用界面当前参数**（因为队列任务模型的这些字段
/// 本身就是可空的），所以「只覆盖想覆盖的」是天然行为，不需要额外快照逻辑。
///
/// `count` 表示同一份提示词出几张（展开成多条队列任务）。
/// `autoStart` 默认 false —— 只入队、不自动开始，避免无人值守地消耗 Anlas。
///
/// **一次性消费**：处理成功后把 `jobs.json` 改名为 `jobs.done.<时间戳>.json`。
/// 轮询是按内容摘要去重的，但队列不能靠去重防重（重复入队就是重复出图），
/// 所以必须「处理完就搬走」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive/hive.dart';

import '../constants/storage_keys.dart';
import '../utils/app_logger.dart';
import 'bigman_prompt_inbox.dart';

/// 一条队列任务规格。
class QueueJobSpec {
  const QueueJobSpec({
    required this.positive,
    this.negative,
    this.width,
    this.height,
    this.count = 1,
    this.seed,
    this.steps,
    this.cfgScale,
    this.model,
    this.sampler,
  });

  final String positive;
  final String? negative;
  final int? width;
  final int? height;
  final int count;
  final int? seed;
  final int? steps;
  final double? cfgScale;
  final String? model;
  final String? sampler;

  /// 解析单条任务；`positive` 为空视为无效（返回 null）。
  static QueueJobSpec? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, dynamic>();
    final positive = (map['positive'] ?? map['prompt'] ?? '').toString().trim();
    if (positive.isEmpty) return null;

    final negative = (map['negative'] ?? map['negativePrompt'])
        ?.toString()
        .trim();
    final count = _asInt(map['count']) ?? 1;

    return QueueJobSpec(
      positive: positive,
      negative: (negative == null || negative.isEmpty) ? null : negative,
      width: _asInt(map['width']),
      height: _asInt(map['height']),
      count: count < 1 ? 1 : count,
      seed: _asInt(map['seed']),
      steps: _asInt(map['steps']),
      cfgScale: _asDouble(map['cfgScale'] ?? map['cfg_scale']),
      model: _asString(map['model']),
      sampler: _asString(map['sampler']),
    );
  }

  static int? _asInt(Object? v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('${v ?? ''}'));
  static double? _asDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
  static String? _asString(Object? v) {
    final s = v?.toString().trim();
    return (s == null || s.isEmpty) ? null : s;
  }
}

/// 一批任务 + 是否自动开始。
class QueueJobBatch {
  const QueueJobBatch({required this.jobs, required this.autoStart});

  final List<QueueJobSpec> jobs;
  final bool autoStart;

  bool get isEmpty => jobs.isEmpty;

  /// 一批最多入队的任务数，防止一次写错文件把队列灌满。
  /// 队列本身上限 50，这里留出余量由调用方按剩余容量再裁。
  static const int maxJobs = 50;

  /// 解析 `jobs.json`；无法解析返回 null（不抛异常，避免轮询里反复报错）。
  static QueueJobBatch? parse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();
      final list = map['jobs'];
      final jobs = <QueueJobSpec>[];
      if (list is List) {
        for (final item in list) {
          final spec = QueueJobSpec.fromJson(item);
          if (spec != null) jobs.add(spec);
        }
      } else {
        // 也允许「单条任务直接写在顶层」，省得为一条也套一层 jobs 数组。
        final single = QueueJobSpec.fromJson(map);
        if (single != null) jobs.add(single);
      }
      if (jobs.isEmpty) return null;
      return QueueJobBatch(
        jobs: jobs.length > maxJobs ? jobs.sublist(0, maxJobs) : jobs,
        autoStart: map['autoStart'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 队列批次桥：路径、读写、一次性消费。
class BigmanQueueBridge {
  BigmanQueueBridge._();

  static const String jobsFileName = 'jobs.json';
  static const String statusFileName = 'status.json';

  /// 单次读取上限，防止误写大文件。
  static const int maxBytes = 256 * 1024;

  /// 桥目录：设置里可改；没设置时与提示词收件箱同目录。
  static String defaultDir() {
    final configured = _readBridgeDir();
    if (configured != null && configured.isNotEmpty) return configured;
    const inbox = BigmanPromptInbox.defaultPath;
    final cut = inbox.lastIndexOf(RegExp(r'[\\/]'));
    return cut <= 0 ? inbox : inbox.substring(0, cut);
  }

  static String jobsPath(String dir) => '$dir${Platform.pathSeparator}$jobsFileName';
  static String statusPath(String dir) =>
      '$dir${Platform.pathSeparator}$statusFileName';

  static String? _readBridgeDir() {
    try {
      if (!Hive.isBoxOpen(StorageKeys.settingsBox)) return null;
      return Hive.box(StorageKeys.settingsBox).get(StorageKeys.bigmanBridgeDir)
          as String?;
    } catch (_) {
      return null;
    }
  }

  /// 读取文本文件；读不到返回 null（不抛异常）。
  static Future<String?> readFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length == 0 || length > maxBytes) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  /// 处理后把 `jobs.json` 搬走，避免下一轮重复入队。
  ///
  /// 返回搬走后的路径；失败返回 null（调用方应据此放弃这一轮）。
  static Future<String?> consume(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final done = '$path.done-$stamp';
      await file.rename(done);
      return done;
    } catch (error) {
      AppLogger.w('队列批次：处理完成后搬走文件失败：$error');
      return null;
    }
  }

  /// 写状态回执（原子替换：先写临时文件再改名）。
  static Future<void> writeStatus(String dir, String json) async {
    try {
      final target = File(statusPath(dir));
      final temp = File('${statusPath(dir)}.tmp');
      await temp.writeAsString(json, flush: true);
      await temp.rename(target.path);
    } catch (error) {
      AppLogger.w('队列批次：写状态回执失败：$error');
    }
  }
}

/// 轮询 `jobs.json` 的监听器。
///
/// 与 [PromptInboxWatcher] 一样把「真正做事」的部分做成回调注入：服务本身只负责
/// 读文件、去重、调用入队、搬走文件、写回执。这样它既能脱开 Riverpod 单测，
/// 也不会在测试里碰到用户正在用的目录。
class QueueJobWatcher {
  QueueJobWatcher({
    required this.enqueue,
    required this.isEnabled,
    required this.isBusy,
    this.statusJson,
    this.dir,
    this.onApplied,
    this.onRejected,
  });

  /// 真正入队；返回**实际入队条数**，抛异常表示这一轮失败（不搬走文件）。
  final Future<int> Function(List<QueueJobSpec> jobs, {required bool autoStart})
  enqueue;

  final bool Function() isEnabled;

  /// 正在生成时不要打断，延后到下一轮再入队。
  final bool Function() isBusy;

  /// 回执内容（由调用方决定写什么）；返回 null 表示这一轮不写。
  final String? Function()? statusJson;

  /// 桥目录；默认取 [BigmanQueueBridge.defaultDir]。
  final String? dir;

  final void Function(String summary)? onApplied;
  final void Function(String reason)? onRejected;

  Timer? _timer;
  String? _lastDigest;
  String? _lastStatusDigest;
  bool _running = false;

  String get _dir => dir ?? BigmanQueueBridge.defaultDir();

  void start() {
    stop();
    // 启动时先读一次：可以先让 DSH 写好，再启动本程序。
    unawaited(_tick());
    _timer = Timer.periodic(
      BigmanPromptInbox.pollInterval,
      (_) => _tick(),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (_running) return;
    _running = true;
    try {
      if (!isEnabled()) return;
      await _flushStatus();
      if (isBusy()) return;

      final path = BigmanQueueBridge.jobsPath(_dir);
      final raw = await BigmanQueueBridge.readFile(path);
      if (raw == null) return;

      final digest = BigmanPromptInbox.digestOf(raw);
      if (digest == _lastDigest) return;

      final batch = QueueJobBatch.parse(raw);
      if (batch == null) {
        // 记下摘要，避免同一份坏文件每 1.5 秒报一次。
        _lastDigest = digest;
        onRejected?.call('jobs.json 无法解析或没有有效任务');
        return;
      }

      final queued = await enqueue(batch.jobs, autoStart: batch.autoStart);
      if (queued <= 0) {
        _lastDigest = digest;
        onRejected?.call('队列已满或没有可入队的任务');
        return;
      }

      final moved = await BigmanQueueBridge.consume(path);
      if (moved == null) {
        // 搬不走就不能记摘要，否则下一轮不会再试。
        onRejected?.call('任务已入队但文件搬不走，请手动移开 jobs.json');
        return;
      }
      _lastDigest = digest;
      onApplied?.call('已入队 $queued 条（${batch.jobs.length} 条规格）');
    } catch (error) {
      AppLogger.w('队列批次：这一轮入队失败：$error');
      onRejected?.call('入队失败：$error');
    } finally {
      _running = false;
    }
  }

  Future<void> _flushStatus() async {
    final builder = statusJson;
    if (builder == null) return;
    final json = builder();
    if (json == null) return;
    // 内容没变就不写盘：轮询是 1.5 秒一次，无脑重写既浪费又伤盘。
    final digest = BigmanPromptInbox.digestOf(json);
    if (digest == _lastStatusDigest) return;
    _lastStatusDigest = digest;
    await BigmanQueueBridge.writeStatus(_dir, json);
  }
}
