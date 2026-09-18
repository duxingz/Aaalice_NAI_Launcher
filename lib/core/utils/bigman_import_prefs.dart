import 'package:hive/hive.dart';

import '../constants/storage_keys.dart';

/// 胖大叔自用改：记住上次在拖入图片对话框里勾选的导入项。
///
/// 只记忆对话框暴露的五个开关；其余字段继续沿用 `MetadataImportOptions.all`
/// 的默认值。存储未就绪或从未保存过时 [read] 返回 null，调用方回退到全选。
class BigmanImportPrefs {
  BigmanImportPrefs._();

  static bool? _readBool(String key) {
    try {
      if (!Hive.isBoxOpen(StorageKeys.settingsBox)) return null;
      return Hive.box(StorageKeys.settingsBox).get(key) as bool?;
    } catch (_) {
      return null;
    }
  }

  /// 读取上次的选择；任一开关缺失都视为「没有记录」。
  static BigmanImportPrefsValue? read() {
    final prompt = _readBool(StorageKeys.bigmanImportPrompt);
    final negative = _readBool(StorageKeys.bigmanImportNegative);
    final characters = _readBool(StorageKeys.bigmanImportCharacters);
    final settings = _readBool(StorageKeys.bigmanImportSettings);
    final seed = _readBool(StorageKeys.bigmanImportSeed);
    if (prompt == null ||
        negative == null ||
        characters == null ||
        settings == null ||
        seed == null) {
      return null;
    }
    return BigmanImportPrefsValue(
      prompt: prompt,
      negative: negative,
      characters: characters,
      settings: settings,
      seed: seed,
    );
  }

  /// 保存本次选择；失败只影响记忆，不影响本次导入。
  static Future<void> save(BigmanImportPrefsValue value) async {
    try {
      if (!Hive.isBoxOpen(StorageKeys.settingsBox)) return;
      await Hive.box(StorageKeys.settingsBox).putAll({
        StorageKeys.bigmanImportPrompt: value.prompt,
        StorageKeys.bigmanImportNegative: value.negative,
        StorageKeys.bigmanImportCharacters: value.characters,
        StorageKeys.bigmanImportSettings: value.settings,
        StorageKeys.bigmanImportSeed: value.seed,
      });
    } catch (_) {
      // 记忆失败不影响本次导入。
    }
  }
}

/// 拖入图片对话框记忆下来的五个导入开关。
class BigmanImportPrefsValue {
  const BigmanImportPrefsValue({
    required this.prompt,
    required this.negative,
    required this.characters,
    required this.settings,
    required this.seed,
  });

  final bool prompt;
  final bool negative;
  final bool characters;
  final bool settings;
  final bool seed;
}
