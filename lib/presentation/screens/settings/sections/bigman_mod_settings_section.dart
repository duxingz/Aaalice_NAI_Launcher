import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/localization_extension.dart';
import '../../../providers/bigman/bigman_mod_settings.dart';
import '../../../providers/generation/generation_settings_notifiers.dart';
import '../widgets/settings_card.dart';
import '../widgets/settings_page_layout.dart';

/// 胖大叔自用改设置板块。
///
/// 自用改造的统一入口：提示词编辑快捷键、被停用的上游功能、保存命名规则。
/// 后续新增的自用功能都加在这里，不散落到其他设置板块。
class BigmanModSettingsSection extends ConsumerStatefulWidget {
  const BigmanModSettingsSection({super.key});

  @override
  ConsumerState<BigmanModSettingsSection> createState() =>
      _BigmanModSettingsSectionState();
}

class _BigmanModSettingsSectionState
    extends ConsumerState<BigmanModSettingsSection> {
  late final TextEditingController _templateController;
  late final TextEditingController _paddingController;
  late final TextEditingController _startController;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(bigmanModSettingsProvider);
    _templateController = TextEditingController(
      text: settings.saveNameTemplate,
    );
    _paddingController = TextEditingController(
      text: '${settings.saveNamePadding}',
    );
    _startController = TextEditingController(text: '${settings.saveNameStart}');
  }

  @override
  void dispose() {
    _templateController.dispose();
    _paddingController.dispose();
    _startController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settings = ref.watch(bigmanModSettingsProvider);
    final notifier = ref.read(bigmanModSettingsProvider.notifier);
    final autoFormatEnabled = ref.watch(autoFormatPromptSettingsProvider);

    return SettingsPageLayout(
      title: l10n.bigmanMod_settingsTitle,
      children: [
        SettingsCard(
          title: l10n.bigmanMod_promptSectionTitle,
          description: l10n.bigmanMod_promptSectionDescription,
          icon: Icons.keyboard_alt_outlined,
          child: Column(
            children: [
              SwitchListTile(
                title: Text(l10n.bigmanMod_promptWeightShortcut),
                subtitle: Text(l10n.bigmanMod_promptWeightShortcutSubtitle),
                value: settings.promptWeightShortcut,
                onChanged: (value) =>
                    notifier.setPromptWeightShortcut(value),
              ),
              SwitchListTile(
                title: Text(l10n.bigmanMod_promptMoveShortcut),
                subtitle: Text(l10n.bigmanMod_promptMoveShortcutSubtitle),
                value: settings.promptMoveShortcut,
                onChanged: (value) => notifier.setPromptMoveShortcut(value),
              ),
              SwitchListTile(
                title: Text(l10n.bigmanMod_autoFormat),
                subtitle: Text(l10n.bigmanMod_autoFormatSubtitle),
                value: autoFormatEnabled,
                onChanged: (value) => ref
                    .read(autoFormatPromptSettingsProvider.notifier)
                    .set(value),
              ),
            ],
          ),
        ),
        SettingsCard(
          title: l10n.bigmanMod_disableSectionTitle,
          description: l10n.bigmanMod_disableSectionDescription,
          icon: Icons.block_outlined,
          child: Column(
            children: [
              SwitchListTile(
                title: Text(l10n.bigmanMod_qualityPreset),
                subtitle: Text(l10n.bigmanMod_qualityPresetSubtitle),
                value: settings.qualityPresetEnabled,
                onChanged: (value) =>
                    notifier.setQualityPresetEnabled(value),
              ),
              SwitchListTile(
                title: Text(l10n.bigmanMod_ucPreset),
                subtitle: Text(l10n.bigmanMod_ucPresetSubtitle),
                value: settings.ucPresetEnabled,
                onChanged: (value) => notifier.setUcPresetEnabled(value),
              ),
              SwitchListTile(
                title: Text(l10n.bigmanMod_randomPrompt),
                subtitle: Text(l10n.bigmanMod_randomPromptSubtitle),
                value: settings.randomPromptEnabled,
                onChanged: (value) => notifier.setRandomPromptEnabled(value),
              ),
            ],
          ),
        ),
        SettingsCard(
          title: l10n.bigmanMod_saveNameSectionTitle,
          description: l10n.bigmanMod_saveNameSectionDescription,
          icon: Icons.drive_file_rename_outline,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  key: const ValueKey('bigman-save-name-template'),
                  controller: _templateController,
                  onChanged: notifier.setSaveNameTemplate,
                  decoration: InputDecoration(
                    labelText: l10n.bigmanMod_saveNameTemplate,
                    // 大括号在 ARB 里是占位符语法，字面量只能从调用侧传入。
                    hintText: l10n.bigmanMod_saveNameTemplateHint('{n}'),
                    helperText: l10n.bigmanMod_saveNameVariables(
                      '{n}',
                      '{seed}',
                      '{date}',
                      '{time}',
                    ),
                    helperMaxLines: 2,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                title: Text(l10n.bigmanMod_saveNameCounterMode),
                subtitle: Text(
                  settings.saveNameCounterMode ==
                          BigmanSaveNameCounterMode.scan
                      ? l10n.bigmanMod_saveNameCounterScan
                      : l10n.bigmanMod_saveNameCounterGlobal,
                ),
                trailing: SegmentedButton<BigmanSaveNameCounterMode>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(
                      value: BigmanSaveNameCounterMode.global,
                      label: Text(l10n.bigmanMod_saveNameCounterGlobal),
                    ),
                    ButtonSegment(
                      value: BigmanSaveNameCounterMode.scan,
                      label: Text(l10n.bigmanMod_saveNameCounterScan),
                    ),
                  ],
                  selected: {settings.saveNameCounterMode},
                  onSelectionChanged: (value) =>
                      notifier.setSaveNameCounterMode(value.first),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('bigman-save-name-padding'),
                        controller: _paddingController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (value) => notifier.setSaveNamePadding(
                          int.tryParse(value) ?? 0,
                        ),
                        decoration: InputDecoration(
                          labelText: l10n.bigmanMod_saveNamePadding,
                          hintText: l10n.bigmanMod_saveNamePaddingHint,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('bigman-save-name-start'),
                        controller: _startController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (value) =>
                            notifier.setSaveNameStart(int.tryParse(value) ?? 1),
                        decoration: InputDecoration(
                          labelText: l10n.bigmanMod_saveNameStart,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SwitchListTile(
                title: Text(l10n.bigmanMod_autoDateFolder),
                subtitle: Text(l10n.bigmanMod_autoDateFolderSubtitle),
                value: settings.autoDateFolder,
                onChanged: (value) => notifier.setAutoDateFolder(value),
              ),
              SwitchListTile(
                title: Text(l10n.bigmanMod_promptInbox),
                subtitle: Text(l10n.bigmanMod_promptInboxSubtitle),
                value: settings.promptInboxEnabled,
                onChanged: (value) => notifier.setPromptInboxEnabled(value),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
