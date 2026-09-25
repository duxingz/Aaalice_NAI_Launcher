import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/storage_keys.dart';
import '../../../core/storage/local_storage_service.dart';

/// 保存文件名的序号来源。
enum BigmanSaveNameCounterMode {
  /// 全局连续计数：本机保存一个计数器，跨日期目录持续递增。
  global,

  /// 每次保存扫描保存目录里已有的最大编号后 +1。
  scan,
}

/// 胖大叔自用改的全部开关与参数。
///
/// 默认值遵循自用改的需求：提示词快捷键默认开启；质量词预设、负面预设与
/// 随机提示词工具默认关闭；保存命名默认用 {n} 连续编号；日期文件夹默认不新建。
class BigmanModSettings {
  const BigmanModSettings({
    this.promptWeightShortcut = true,
    this.promptMoveShortcut = true,
    this.qualityPresetEnabled = false,
    this.ucPresetEnabled = false,
    this.randomPromptEnabled = false,
    this.autoDateFolder = false,
    this.saveNameTemplate = '{n}',
    this.saveNameCounterMode = BigmanSaveNameCounterMode.global,
    this.saveNamePadding = 0,
    this.saveNameStart = 1,
    this.promptInboxEnabled = true,
  });

  /// Ctrl+↑/↓ 调整光标所在标签的权重。
  final bool promptWeightShortcut;

  /// Ctrl+←/→ 移动光标所在标签的位置。
  final bool promptMoveShortcut;

  /// 是否启用质量词预设（关闭时按钮保留但不响应，且生成不再注入）。
  final bool qualityPresetEnabled;

  /// 是否启用负面提示词预设（关闭时同上）。
  final bool ucPresetEnabled;

  /// 是否启用随机提示词工具（关闭时按钮保留但不响应，快捷键与抽卡模式同时停用）。
  final bool randomPromptEnabled;

  /// 是否按日期自动新建子文件夹；关闭时直接保存到目标目录。
  final bool autoDateFolder;

  /// 保存文件名模板，支持 {n} {seed} {date} {time}；留空表示保持原样。
  final String saveNameTemplate;

  /// 自定义命名时序号的来源。
  final BigmanSaveNameCounterMode saveNameCounterMode;

  /// 序号补零位数，0 表示不补零。
  final int saveNamePadding;

  /// 自定义命名时序号的起始值。
  final int saveNameStart;

  /// 是否启用「DSH 提示词收件箱」：轮询约定文件，把 DSH 写好的提示词
  /// 自动填进输入框（省掉手动复制粘贴）。桌面上默认开启。
  final bool promptInboxEnabled;

  bool get hasCustomSaveName => saveNameTemplate.trim().isNotEmpty;

  BigmanModSettings copyWith({
    bool? promptWeightShortcut,
    bool? promptMoveShortcut,
    bool? qualityPresetEnabled,
    bool? ucPresetEnabled,
    bool? randomPromptEnabled,
    bool? autoDateFolder,
    String? saveNameTemplate,
    BigmanSaveNameCounterMode? saveNameCounterMode,
    int? saveNamePadding,
    int? saveNameStart,
    bool? promptInboxEnabled,
  }) {
    return BigmanModSettings(
      promptWeightShortcut: promptWeightShortcut ?? this.promptWeightShortcut,
      promptMoveShortcut: promptMoveShortcut ?? this.promptMoveShortcut,
      qualityPresetEnabled: qualityPresetEnabled ?? this.qualityPresetEnabled,
      ucPresetEnabled: ucPresetEnabled ?? this.ucPresetEnabled,
      randomPromptEnabled: randomPromptEnabled ?? this.randomPromptEnabled,
      autoDateFolder: autoDateFolder ?? this.autoDateFolder,
      saveNameTemplate: saveNameTemplate ?? this.saveNameTemplate,
      saveNameCounterMode: saveNameCounterMode ?? this.saveNameCounterMode,
      saveNamePadding: saveNamePadding ?? this.saveNamePadding,
      saveNameStart: saveNameStart ?? this.saveNameStart,
      promptInboxEnabled: promptInboxEnabled ?? this.promptInboxEnabled,
    );
  }
}

class BigmanModSettingsNotifier extends StateNotifier<BigmanModSettings> {
  BigmanModSettingsNotifier(this._storage) : super(_load(_storage));

  final LocalStorageService _storage;

  static bool _readBool(
    LocalStorageService storage,
    String key,
    bool fallback,
  ) => storage.getSetting<bool>(key, defaultValue: fallback) ?? fallback;

  static int _readInt(LocalStorageService storage, String key, int fallback) =>
      storage.getSetting<int>(key, defaultValue: fallback) ?? fallback;

  static BigmanModSettings _load(LocalStorageService storage) {
    return BigmanModSettings(
      promptWeightShortcut: _readBool(
        storage,
        StorageKeys.bigmanPromptWeightShortcut,
        true,
      ),
      promptMoveShortcut: _readBool(
        storage,
        StorageKeys.bigmanPromptMoveShortcut,
        true,
      ),
      qualityPresetEnabled: _readBool(
        storage,
        StorageKeys.bigmanQualityPresetEnabled,
        false,
      ),
      ucPresetEnabled: _readBool(
        storage,
        StorageKeys.bigmanUcPresetEnabled,
        false,
      ),
      randomPromptEnabled: _readBool(
        storage,
        StorageKeys.bigmanRandomPromptEnabled,
        false,
      ),
      autoDateFolder: _readBool(
        storage,
        StorageKeys.bigmanAutoDateFolder,
        false,
      ),
      saveNameTemplate:
          storage.getSetting<String>(StorageKeys.bigmanSaveNameTemplate) ??
          '{n}',
      saveNameCounterMode:
          _readInt(storage, StorageKeys.bigmanSaveNameCounterMode, 0) == 1
          ? BigmanSaveNameCounterMode.scan
          : BigmanSaveNameCounterMode.global,
      saveNamePadding: _readInt(storage, StorageKeys.bigmanSaveNamePadding, 0),
      saveNameStart: _readInt(storage, StorageKeys.bigmanSaveNameStart, 1),
      promptInboxEnabled: _readBool(
        storage,
        StorageKeys.bigmanPromptInboxEnabled,
        true,
      ),
    );
  }

  Future<void> _write(BigmanModSettings next, Map<String, Object?> values) async {
    state = next;
    await _storage.setSettings(values);
  }

  Future<void> setPromptWeightShortcut(bool value) => _write(
    state.copyWith(promptWeightShortcut: value),
    {StorageKeys.bigmanPromptWeightShortcut: value},
  );

  Future<void> setPromptMoveShortcut(bool value) => _write(
    state.copyWith(promptMoveShortcut: value),
    {StorageKeys.bigmanPromptMoveShortcut: value},
  );

  Future<void> setQualityPresetEnabled(bool value) => _write(
    state.copyWith(qualityPresetEnabled: value),
    {StorageKeys.bigmanQualityPresetEnabled: value},
  );

  Future<void> setUcPresetEnabled(bool value) => _write(
    state.copyWith(ucPresetEnabled: value),
    {StorageKeys.bigmanUcPresetEnabled: value},
  );

  Future<void> setRandomPromptEnabled(bool value) => _write(
    state.copyWith(randomPromptEnabled: value),
    {StorageKeys.bigmanRandomPromptEnabled: value},
  );

  Future<void> setAutoDateFolder(bool value) => _write(
    state.copyWith(autoDateFolder: value),
    {StorageKeys.bigmanAutoDateFolder: value},
  );

  Future<void> setSaveNameTemplate(String value) => _write(
    state.copyWith(saveNameTemplate: value),
    {StorageKeys.bigmanSaveNameTemplate: value},
  );

  Future<void> setSaveNameCounterMode(BigmanSaveNameCounterMode value) => _write(
    state.copyWith(saveNameCounterMode: value),
    {StorageKeys.bigmanSaveNameCounterMode: value == BigmanSaveNameCounterMode.scan ? 1 : 0},
  );

  Future<void> setSaveNamePadding(int value) => _write(
    state.copyWith(saveNamePadding: value.clamp(0, 8)),
    {StorageKeys.bigmanSaveNamePadding: value.clamp(0, 8)},
  );

  Future<void> setSaveNameStart(int value) => _write(
    state.copyWith(saveNameStart: value < 0 ? 0 : value),
    {StorageKeys.bigmanSaveNameStart: value < 0 ? 0 : value},
  );

  /// 开关「DSH 提示词收件箱」。
  Future<void> setPromptInboxEnabled(bool value) => _write(
    state.copyWith(promptInboxEnabled: value),
    {StorageKeys.bigmanPromptInboxEnabled: value},
  );

  /// 读取当前自定义命名的计数值；未初始化时返回 [BigmanModSettings.saveNameStart]。
  int readCounter() =>
      _storage.getSetting<int>(StorageKeys.bigmanSaveNameCounterValue) ??
      state.saveNameStart;

  Future<void> writeCounter(int value) =>
      _storage.setSetting(StorageKeys.bigmanSaveNameCounterValue, value);
}

final bigmanModSettingsProvider =
    StateNotifierProvider<BigmanModSettingsNotifier, BigmanModSettings>((ref) {
      return BigmanModSettingsNotifier(ref.read(localStorageServiceProvider));
    });
