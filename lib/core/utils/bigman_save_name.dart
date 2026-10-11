import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import '../constants/storage_keys.dart';

/// 胖大叔自用改：保存文件名规则。
///
/// 该工具直接从本地设置读取用户配置，因此所有保存入口无需改动调用签名；
/// 模板为空（未启用）时 [read] 返回 null，保存行为与上游完全一致。
class BigmanSaveName {
  BigmanSaveName._();

  /// 扫描模式的遍历上限，按**总条目数**计（不是只数 PNG）。
  ///
  /// 必须按总条目计数：`list(recursive: true)` 会走完整个子树，只数 PNG 的话，
  /// 混放目录（保存根目录指向「图片和其它文件混在一起」的文件夹、桌面或网盘
  /// 同步目录）里 PNG 很少却有大量其它文件，上限永远不触发，每次保存都要把
  /// 整棵树走一遍 —— 表现就是「点保存后卡住」。
  ///
  /// ponytail: 上限内是文件系统顺序，超出后可能低估最大编号；真要处理
  /// 十万级图库时应改为按目录名倒序只扫最近若干天。
  static const int maxScanEntries = 50000;

  static Box? settingsBox() {
    try {
      if (!Hive.isBoxOpen(StorageKeys.settingsBox)) return null;
      return Hive.box(StorageKeys.settingsBox);
    } catch (_) {
      return null;
    }
  }

  /// 读取当前保存命名配置；存储未就绪时返回 null。
  ///
  /// 从没设置过时使用默认模板 `{n}`；用户显式清空模板表示关闭自定义命名。
  static BigmanSaveNameConfig? read() {
    final box = settingsBox();
    if (box == null) return null;
    final rawTemplate = box.get(StorageKeys.bigmanSaveNameTemplate);
    final template = rawTemplate == null
        ? '{n}'
        : (rawTemplate as String).trim();
    if (template.isEmpty) return null;
    final padding = (box.get(StorageKeys.bigmanSaveNamePadding) as int?) ?? 0;
    final start = (box.get(StorageKeys.bigmanSaveNameStart) as int?) ?? 1;
    final counterMode =
        (box.get(StorageKeys.bigmanSaveNameCounterMode) as int?) ?? 0;
    final autoDateFolder =
        (box.get(StorageKeys.bigmanAutoDateFolder) as bool?) ?? false;
    return BigmanSaveNameConfig(
      template: template,
      padding: padding.clamp(0, 8),
      start: start < 0 ? 0 : start,
      scanMode: counterMode == 1,
      autoDateFolder: autoDateFolder,
    );
  }

  /// 只读「自动新建日期文件夹」开关。
  ///
  /// 与命名模板相互独立：模板清空（关闭自定义命名）时它仍然生效，
  /// 否则用户就没办法在保留原名命名的同时关掉日期文件夹。
  static bool readAutoDateFolder() {
    try {
      final box = settingsBox();
      if (box == null) return false;
      return (box.get(StorageKeys.bigmanAutoDateFolder) as bool?) ?? false;
    } catch (_) {
      return false;
    }
  }
}

/// 自定义保存命名的解析结果。
class BigmanSaveNameConfig {
  const BigmanSaveNameConfig({
    required this.template,
    required this.padding,
    required this.start,
    required this.scanMode,
    required this.autoDateFolder,
  });

  final String template;
  final int padding;
  final int start;
  final bool scanMode;
  final bool autoDateFolder;

  bool get hasIndex => template.contains('{n}');

  static String _two(int value) => value.toString().padLeft(2, '0');

  /// 按模板渲染文件名主干（不含扩展名）。
  String formatName(int index, {int? seed, DateTime? time}) {
    final moment = time ?? DateTime.now();
    final digits = padding <= 0
        ? '$index'
        : index.toString().padLeft(padding, '0');
    var name = template
        .replaceAll('{n}', digits)
        .replaceAll('{seed}', seed != null && seed >= 0 ? '$seed' : '')
        .replaceAll(
          '{date}',
          '${moment.year}-${_two(moment.month)}-${_two(moment.day)}',
        )
        .replaceAll(
          '{time}',
          '${_two(moment.hour)}-${_two(moment.minute)}-${_two(moment.second)}',
        );
    name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    return name.isEmpty ? digits : name;
  }

  /// 取下一次要使用的序号。
  ///
  /// [entryLimit] 是扫描模式的安全上限（遍历的总条目数），默认
  /// [BigmanSaveName.maxScanEntries]；给个可调入口是为了能对「上限是否按总条目
  /// 计数」写回归测试。
  Future<int> resolveNextIndex(
    String rootPath, {
    int entryLimit = BigmanSaveName.maxScanEntries,
  }) async {
    if (!scanMode) {
      final box = BigmanSaveName.settingsBox();
      final current = (box?.get(StorageKeys.bigmanSaveNameCounterValue) as int?);
      final value = current ?? start;
      return value < start ? start : value;
    }
    final maxUsed = await _scanMaxIndex(rootPath, entryLimit);
    return maxUsed < start - 1 ? start : maxUsed + 1;
  }

  /// 记录本次实际使用的序号，让下一次从它继续。
  Future<void> commitIndex(int usedIndex) async {
    final box = BigmanSaveName.settingsBox();
    if (box == null) return;
    await box.put(StorageKeys.bigmanSaveNameCounterValue, usedIndex + 1);
  }

  Future<int> _scanMaxIndex(String rootPath, int entryLimit) async {
    final root = Directory(rootPath);
    if (!await root.exists()) return start - 1;
    final pattern = _namePattern();
    if (pattern == null) return start - 1;
    var max = start - 1;
    var visited = 0;
    try {
      await for (final entity in root.list(recursive: true, followLinks: false)) {
        // 先计数再筛选：遍历代价由「看过的条目数」决定，与是不是 PNG 无关。
        visited++;
        if (visited > entryLimit) break;
        if (entity is! File) continue;
        if (p.extension(entity.path).toLowerCase() != '.png') continue;
        final match = pattern.firstMatch(
          p.basenameWithoutExtension(entity.path),
        );
        if (match == null) continue;
        final value = int.tryParse(match.group(1) ?? '');
        if (value != null && value > max) max = value;
      }
    } catch (_) {
      // 目录不可读时退回起始序号，保存仍会靠冲突后缀保证不覆盖。
      return start - 1;
    }
    return max;
  }

  /// 只匹配 `{n}` 位置为数字的文件名；模板没有 `{n}` 时返回 null。
  RegExp? _namePattern() {
    if (!hasIndex) return null;
    final buffer = StringBuffer('^');
    var index = 0;
    while (index < template.length) {
      if (template.startsWith('{n}', index)) {
        buffer.write(r'(\d+)');
        index += 3;
        continue;
      }
      buffer.write(RegExp.escape(template[index]));
      index++;
    }
    buffer.write(r'$');
    return RegExp(buffer.toString());
  }
}
