import 'package:hive/hive.dart';

import '../constants/storage_keys.dart';

/// 胖大叔自用改：非 UI 层读取开关。
///
/// UI 层用 `bigmanModSettingsProvider` 以获得响应式刷新；provider、
/// 快捷键回调等拿不到 Riverpod 容器的地方用这里的静态读取，两者读同一
/// 份存储键，取值一致。存储未就绪时一律返回关闭默认值。
class BigmanModFlags {
  BigmanModFlags._();

  static bool? _readBool(String key) {
    try {
      if (!Hive.isBoxOpen(StorageKeys.settingsBox)) return null;
      return Hive.box(StorageKeys.settingsBox).get(key) as bool?;
    } catch (_) {
      return null;
    }
  }

  /// 质量词预设是否启用；默认关闭（不注入官方质量词）。
  static bool qualityPresetEnabled() =>
      _readBool(StorageKeys.bigmanQualityPresetEnabled) ?? false;

  /// 负面提示词预设是否启用；默认关闭（不注入负面预设）。
  static bool ucPresetEnabled() =>
      _readBool(StorageKeys.bigmanUcPresetEnabled) ?? false;

  /// 随机提示词工具是否启用；默认关闭。
  static bool randomPromptEnabled() =>
      _readBool(StorageKeys.bigmanRandomPromptEnabled) ?? false;

  /// 多选调权重时是否把整段合并成**一个权重块**（`0.95::a, b, c::`）。
  ///
  /// 默认开启＝新的合并行为；关闭后回到旧行为：选中的每个标签各自套权重
  /// （`0.95::a::, 0.95::b::`）。每次按键都会重新读取，改设置立即生效。
  static bool mergeMultiSelectWeight() =>
      _readBool(StorageKeys.bigmanMergeMultiSelectWeight) ?? true;
}
