import 'dart:async';

import '../constants/storage_keys.dart';
import '../storage/local_storage_service.dart';

/// 胖大叔自用改：记住上次在拖入图片对话框里勾选的导入项。
///
/// 走项目自带的 [LocalStorageService]（SharedPreferences 后端）：读取是同步的，
/// 写入异步刷盘且不持有文件句柄 —— 不引入新的 Hive 使用者，避免测试清理
/// 阶段的「文件被占用」失败。
class BigmanImportPrefs {
  BigmanImportPrefs._();

  static bool? _readBool(LocalStorageService storage, String key) =>
      storage.getSetting<bool>(key);

  /// 读取上次的选择；任一开关缺失都视为「没有记录」。
  static BigmanImportPrefsValue? read(LocalStorageService? storage) {
    if (storage == null) return null;
    final prompt = _readBool(storage, StorageKeys.bigmanImportPrompt);
    final negative = _readBool(storage, StorageKeys.bigmanImportNegative);
    final characters = _readBool(storage, StorageKeys.bigmanImportCharacters);
    final settings = _readBool(storage, StorageKeys.bigmanImportSettings);
    final seed = _readBool(storage, StorageKeys.bigmanImportSeed);
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

  /// 保存本次选择；不等待写入完成，失败也不影响本次导入。
  static void save(
    LocalStorageService? storage,
    BigmanImportPrefsValue value,
  ) {
    if (storage == null) return;
    unawaited(
      storage.setSettings({
        StorageKeys.bigmanImportPrompt: value.prompt,
        StorageKeys.bigmanImportNegative: value.negative,
        StorageKeys.bigmanImportCharacters: value.characters,
        StorageKeys.bigmanImportSettings: value.settings,
        StorageKeys.bigmanImportSeed: value.seed,
      }),
    );
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
