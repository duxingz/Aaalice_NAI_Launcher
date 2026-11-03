import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nai_launcher/core/constants/api_constants.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/data/models/prompt/prompt_preset_mode.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_settings_notifiers.dart';
import 'package:nai_launcher/presentation/providers/quality_preset_provider.dart';
import 'package:nai_launcher/presentation/providers/uc_preset_provider.dart';

/// 胖大叔自用改「功能停用」三项的接线回归。
///
/// 移植到官方 v4.3.0 时，这三处的 provider 级门控整段丢了：UI 里的按钮还是
/// 亮着能点，生成请求也照旧带上质量词 / 负面预设 / 抽卡模式。用户就是照着
/// 「我明明关闭了质量词标签，那个按钮还是点的了」报上来的。
///
/// 用真实 Hive 存储（不覆盖 localStorageServiceProvider）：开关同时被
/// `bigmanModSettingsProvider`（走 LocalStorageService）与 `BigmanModFlags`
/// （直接读 Hive）读取，两者必须看到同一份数据，这里就按真实链路验。
void main() {
  late Directory hiveDirectory;
  late Box<dynamic> settings;
  late ProviderContainer container;

  setUp(() async {
    hiveDirectory = await Directory.systemTemp.createTemp('bigman-disabled-');
    Hive.init(hiveDirectory.path);
    settings = await Hive.openBox(StorageKeys.settingsBox);
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    await Hive.close();
    await hiveDirectory.delete(recursive: true);
  });

  group('功能停用：质量词预设', () {
    test('关闭时对全体消费者表现为「无」，按钮与请求都停下', () async {
      // 存储里明明是「NAI 默认 + 添加质量词」，停用后必须一律按无处理。
      await settings.put(StorageKeys.addQualityTags, true);
      await settings.put(StorageKeys.bigmanQualityPresetEnabled, false);

      final state = container.read(qualityPresetNotifierProvider);
      expect(state.mode, PromptPresetMode.none);
      expect(state.isEnabled, isFalse, reason: '按钮据此渲染为未启用');
      expect(
        container
            .read(qualityPresetNotifierProvider.notifier)
            .getEffectiveContent(ImageModels.animeDiffusionV45Full),
        isNull,
        reason: '请求侧也不得再注入质量词',
      );
    });

    test('打开后按存储的模式生效', () async {
      await settings.put(StorageKeys.addQualityTags, true);
      await settings.put(StorageKeys.bigmanQualityPresetEnabled, true);

      expect(
        container.read(qualityPresetNotifierProvider).mode,
        PromptPresetMode.naiDefault,
      );
      expect(
        container
            .read(qualityPresetNotifierProvider.notifier)
            .getEffectiveContent(ImageModels.animeDiffusionV45Full),
        isNotNull,
      );
    });
  });

  group('功能停用：负面预设', () {
    test('关闭时一律按「不添加预设」处理', () async {
      await settings.put(StorageKeys.ucPresetType, UcPresets.heavyApiValue);
      await settings.put(StorageKeys.bigmanUcPresetEnabled, false);

      final state = container.read(ucPresetNotifierProvider);
      expect(state.presetType, UcPresetType.none);
      expect(state.isPresetEnabled, isFalse);
      expect(
        container
            .read(ucPresetNotifierProvider.notifier)
            .getEffectiveContent(ImageModels.animeDiffusionV45Full),
        isNull,
      );
    });

    test('打开后按存储的预设生效', () async {
      await settings.put(StorageKeys.ucPresetType, UcPresets.heavyApiValue);
      await settings.put(StorageKeys.bigmanUcPresetEnabled, true);

      expect(
        container.read(ucPresetNotifierProvider).presetType,
        UcPresetType.heavy,
      );
      expect(
        container
            .read(ucPresetNotifierProvider.notifier)
            .getEffectiveContent(ImageModels.animeDiffusionV45Full),
        isNotNull,
      );
    });
  });

  group('功能停用：随机提示词工具', () {
    test('关闭时抽卡模式一律视为关闭，历史遗留的开启状态不再生效', () async {
      await settings.put(StorageKeys.randomPromptMode, true);
      await settings.put(StorageKeys.bigmanRandomPromptEnabled, false);

      expect(container.read(randomPromptModeProvider), isFalse);
    });

    test('打开后按存储值生效', () async {
      await settings.put(StorageKeys.randomPromptMode, true);
      await settings.put(StorageKeys.bigmanRandomPromptEnabled, true);

      expect(container.read(randomPromptModeProvider), isTrue);
    });
  });
}
