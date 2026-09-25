import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

/// 收件箱里解析出来的一个角色块。
@immutable
class PromptInboxCharacter {
  const PromptInboxCharacter({required this.name, required this.prompt});

  final String name;
  final String prompt;
}

/// 收件箱文件的解析结果。
@immutable
class PromptInboxPayload {
  const PromptInboxPayload({
    this.positive,
    this.negative,
    this.characters = const [],
  });

  /// 正面提示词（无标记模式下就是整份内容）。
  final String? positive;

  /// 负面提示词；文件里没有 `NEGATIVE` 段时为 null（表示"不要动原来的"）。
  final String? negative;

  /// 角色分区；文件里没有 `CHARACTER` 段时为空（表示"不要动原来的"）。
  final List<PromptInboxCharacter> characters;

  bool get isEmpty =>
      (positive == null || positive!.trim().isEmpty) &&
      (negative == null || negative!.trim().isEmpty) &&
      characters.isEmpty;
}

/// 胖大叔自用改：DSH 提示词收件箱。
///
/// DSH 把写好的提示词写进一个约定文件，这里轮询该文件并填进启动器的
/// 提示词框，省掉手动复制粘贴。
///
/// 文件格式两种模式**自动识别**：
///
/// 1. 无标记 —— 整份内容填进正面提示词框（tag 串 + 画面描述）。
/// 2. 有标记 —— 按区分别填：
///    ```
///    ---POSITIVE---
///    1girl, blue hair
///    ---NEGATIVE---
///    lowres, bad anatomy
///    ---CHARACTER:艾玛---
///    girl, sakuraba ema
///    ---CHARACTER---
///    boy, fat man
///    ```
///    只填给出了标记的区，没给的区保持原样（不误删用户内容）。
class BigmanPromptInbox {
  BigmanPromptInbox._();

  /// 收件箱文件路径（DSH 侧往这里写）。
  static const String defaultPath = r'D:\workwork\nai-launcher-bridge\prompt.txt';

  /// 单次读取上限，防止误写大文件。
  static const int maxBytes = 256 * 1024;

  /// 轮询间隔。
  static const Duration pollInterval = Duration(milliseconds: 1500);

  /// 把文件内容解析成各区的值。纯函数，便于测试。
  static PromptInboxPayload parse(String raw) {
    var text = raw;
    // 容忍 BOM。
    if (text.startsWith('\uFEFF')) text = text.substring(1);

    final markerPattern = RegExp(
      r'^[ \t]*---[ \t]*([A-Za-z]+)(?:[ \t]*:[ \t]*(.*?))?[ \t]*---[ \t]*$',
      multiLine: true,
    );

    final matches = markerPattern.allMatches(text).toList();
    if (matches.isEmpty) {
      final trimmed = text.trim();
      return PromptInboxPayload(
        positive: trimmed.isEmpty ? null : trimmed,
      );
    }

    String? positive;
    String? negative;
    final characters = <PromptInboxCharacter>[];
    var autoIndex = 0;

    for (var i = 0; i < matches.length; i++) {
      final match = matches[i];
      final kind = match.group(1)!.toUpperCase();
      final label = (match.group(2) ?? '').trim();
      final bodyStart = match.end;
      final bodyEnd = i + 1 < matches.length ? matches[i + 1].start : text.length;
      final body = text.substring(bodyStart, bodyEnd).trim();

      switch (kind) {
        case 'POSITIVE':
        case 'DESCRIPTION':
          // DESCRIPTION 也归到正面（无标记模式本来就是两段一起进正面框）。
          positive = positive == null || positive.isEmpty
              ? body
              : '$positive\n\n$body';
        case 'NEGATIVE':
          negative = body;
        case 'CHARACTER':
          autoIndex++;
          characters.add(
            PromptInboxCharacter(
              name: label.isNotEmpty ? label : '角色 $autoIndex',
              prompt: body,
            ),
          );
        default:
          // 不认识的标记当作普通内容，忽略其标记本身。
          if (body.isNotEmpty) {
            positive = positive == null || positive.isEmpty
                ? body
                : '$positive\n\n$body';
          }
      }
    }

    return PromptInboxPayload(
      positive: positive,
      negative: negative,
      characters: characters,
    );
  }

  /// 只读文件（含大小上限与编码容错）；文件不存在或读不动时返回 null。
  @visibleForTesting
  static Future<String?> readFile(String path, {File? override}) async {
    try {
      final file = override ?? File(path);
      if (!await file.exists()) return null;
      final length = await file.length();
      if (length == 0 || length > maxBytes) return null;
      final bytes = await file.readAsBytes();
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// 算内容摘要，用于去重（不能用 mtime —— 同一秒内的两次写入时间戳相同）。
  static String digestOf(String content) =>
      sha256.convert(utf8.encode(content)).toString();
}

/// 收件箱轮询器。纯 IO + 回调，不直接依赖任何 provider，便于测试。
class PromptInboxWatcher {
  PromptInboxWatcher({
    required this.setPrompt,
    required this.setNegativePrompt,
    required this.setCharacters,
    required this.isEnabled,
    required this.isBusy,
    this.path = BigmanPromptInbox.defaultPath,
    this.onApplied,
    this.snapshotCurrent,
    this.onBackup,
  });

  final String path;
  final void Function(String value) setPrompt;
  final void Function(String value) setNegativePrompt;
  final void Function(List<PromptInboxCharacter> characters) setCharacters;
  final bool Function() isEnabled;

  /// 正在生成时不要打断，延后到下一轮再填。
  final bool Function() isBusy;
  final void Function(String summary)? onApplied;

  /// 返回当前各区的值（用于覆盖前备份）；返回 null 表示拿不到。
  final String? Function()? snapshotCurrent;

  /// 备份成功后的通知（参数是备份文件路径）。
  final void Function(String backupPath)? onBackup;

  Timer? _timer;
  String? _lastDigest;
  PromptInboxPayload? _pending;
  bool _running = false;

  void start() {
    stop();
    // 启动时先读一次：可以先让 DSH 写好，再启动本程序。
    unawaited(_tick());
    _timer = Timer.periodic(BigmanPromptInbox.pollInterval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  /// 覆盖前先备份旧值，避免误覆盖后找不回来。
  ///
  /// 只备份「本次会被改动的区」，文件名带时间戳，落在收件箱同目录。
  Future<void> _backupBeforeApply(PromptInboxPayload payload) async {
    try {
      final wouldOverwrite =
          (payload.positive?.trim().isNotEmpty ?? false) ||
          (payload.negative?.trim().isNotEmpty ?? false) ||
          payload.characters.isNotEmpty;
      if (!wouldOverwrite) return;
      final previous = snapshotCurrent?.call();
      if (previous == null || previous.trim().isEmpty) return;
      final dir = File(path).parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .split('.')
          .first;
      final backup = File('${dir.path}${Platform.pathSeparator}'
          'backup-before-overwrite-$stamp.txt');
      await backup.writeAsString(previous, flush: true);
      onBackup?.call(backup.path);
    } catch (_) {
      // 备份失败不阻断填写。
    }
  }

  Future<void> _tick() async {
    if (_running) return;
    _running = true;
    try {
      if (!isEnabled()) return;
      final raw = await BigmanPromptInbox.readFile(path);
      if (raw == null) return;
      final digest = BigmanPromptInbox.digestOf(raw);
      if (digest == _lastDigest) {
        // 内容没变：如果上一轮因为正在生成被押后，这里再试一次。
        if (_pending != null && !isBusy()) {
          await _backupBeforeApply(_pending!);
          _apply(_pending!);
          _pending = null;
        }
        return;
      }
      _lastDigest = digest;
      final payload = BigmanPromptInbox.parse(raw);
      if (payload.isEmpty) return;
      if (isBusy()) {
        _pending = payload;
        return;
      }
      await _backupBeforeApply(payload);
      _apply(payload);
    } finally {
      _running = false;
    }
  }

  void _apply(PromptInboxPayload payload) {
    final parts = <String>[];
    final positive = payload.positive;
    if (positive != null && positive.trim().isNotEmpty) {
      setPrompt(positive);
      parts.add('正面');
    }
    final negative = payload.negative;
    if (negative != null && negative.trim().isNotEmpty) {
      setNegativePrompt(negative);
      parts.add('负面');
    }
    if (payload.characters.isNotEmpty) {
      setCharacters(payload.characters);
      parts.add('角色 ${payload.characters.length}');
    }
    if (parts.isNotEmpty) {
      onApplied?.call(parts.join(' / '));
    }
  }
}
