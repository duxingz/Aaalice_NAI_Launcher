import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/utils/bigman_mod_flags.dart';
import '../tools/blur_tool.dart';
import '../tools/brush_tool.dart';
import '../tools/clone_stamp_tool.dart';
import '../tools/color_picker_tool.dart';
import '../tools/eraser_tool.dart';
import '../tools/fill_tool.dart';
import '../tools/magic_wand_tool.dart';
import '../tools/selection/ellipse_selection_tool.dart';
import '../tools/selection/lasso_selection_tool.dart';
import '../tools/selection/rect_selection_tool.dart';
import '../tools/tool_base.dart';
import 'tool_settings_manager.dart';

/// 工具管理器
/// 负责工具的注册、切换和状态管理
class ToolManager extends ChangeNotifier {
  /// 工具设置管理器
  final ToolSettingsManager settingsManager = ToolSettingsManager();

  /// 可用工具列表
  final List<EditorTool> _tools;

  /// 当前工具
  EditorTool? _currentTool;
  EditorTool? get currentTool => _currentTool;

  /// 上一个工具（用于普通切换时切回）
  EditorTool? _previousTool;

  /// 临时拾色器模式前的工具（与 _previousTool 独立）
  EditorTool? _toolBeforeTemporaryColorPicker;

  /// 是否处于临时拾色器模式
  bool _isTemporaryColorPickerMode = false;
  bool get isTemporaryColorPickerMode => _isTemporaryColorPickerMode;

  /// 工具切换通知器（轻量级，仅工具相关 UI 监听）
  /// 使用 ValueNotifier 避免触发全局重建
  final ValueNotifier<String?> toolNotifier = ValueNotifier(null);

  int _batchDepth = 0;
  bool _pendingToolNotification = false;
  String? _pendingToolId;

  /// 是否暂停持久化画笔设置。
  ///
  /// 局部重绘会临时把笔刷改成适合画蒙版的参数，这套参数只属于本次会话，
  /// 一旦落盘就会永久顶掉用户自己调好的笔刷，因此蒙版模式期间挂起画笔写入。
  /// 只拦画笔：橡皮、魔棒等其它工具在这期间照常保存。
  bool _brushPersistSuspended = false;

  bool get _isBatching => _batchDepth > 0;

  /// 构造函数
  ToolManager() : _tools = _createTools() {
    // 初始化时选中第一个工具
    if (_tools.isNotEmpty) {
      _currentTool = _tools.first;
      toolNotifier.value = _currentTool?.id;
    }
    // 异步加载持久化设置
    _loadSettingsAsync();
  }

  /// 异步加载持久化设置
  Future<void> _loadSettingsAsync() async {
    await settingsManager.load();
    _repairMaskClobberedBrush();
    // 恢复所有工具的设置。
    //
    // 不能只恢复此刻的 _currentTool：加载是异步的，界面可能在它完成前就切走了
    // 工具（例如进入局部重绘时切到选区），那样被切走的工具这一整轮都拿不到
    // 已保存的参数，随后还会以默认值被写回。
    for (final tool in _tools) {
      _restoreToolSettings(tool);
    }
  }

  /// 一次性修掉旧版留下的「笔刷被蒙版预设覆盖」。
  ///
  /// 旧版每次进局部重绘都会把笔刷写成 55% 不透明度 / 100% 硬度并落盘，用户
  /// 自己调好的笔刷就此被永久顶掉，而且界面高亮的预设和实际数值还对不上。
  /// 这里只还原**不透明度与硬度**（按当前预设；预设无效时用默认值），
  /// **保留用户自己的笔刷大小**——那一次覆盖本来就没动大小。
  ///
  /// 判定签名 `opacity == 0.55 && hardness == 1.0`：内置 8 个预设没有任何一个是
  /// 这组值，所以它只可能来自那次覆盖。整件事只做一次（存储标志记住），否则
  /// 用户故意把不透明度设成 0.55 会被每次启动重置。
  void _repairMaskClobberedBrush() {
    if (BigmanModFlags.brushMaskClobberRepaired()) return;

    final settings = settingsManager.getToolSettings('brush');
    if (settings == null) return;
    final raw = settings['settings'];
    if (raw is! Map<String, dynamic>) return;

    final opacity = (raw['opacity'] as num?)?.toDouble();
    final hardness = (raw['hardness'] as num?)?.toDouble();
    final clobbered =
        opacity != null &&
        hardness != null &&
        (opacity - 0.55).abs() < 0.0005 &&
        (hardness - 1.0).abs() < 0.0005;

    if (clobbered) {
      final presetIndex = settings['presetIndex'];
      final preset =
          presetIndex is int &&
              presetIndex >= 0 &&
              presetIndex < defaultBrushPresets.length
          ? defaultBrushPresets[presetIndex]
          : null;
      const fallback = BrushSettings();
      settingsManager.setSetting('brush', 'settings', {
        ...raw,
        'opacity': preset?.opacity ?? fallback.opacity,
        'hardness': preset?.hardness ?? fallback.hardness,
      });
      unawaited(settingsManager.save());
    }

    // 无论是否命中都打标志：这是「已检查过」而不是「已修过」，避免每次启动重扫。
    unawaited(BigmanModFlags.markBrushMaskClobberRepaired());
  }

  /// 挂起/恢复画笔设置的持久化写入。
  void setBrushSettingsPersistSuspended(bool value) {
    _brushPersistSuspended = value;
  }

  /// 获取所有工具（只读）
  List<EditorTool> get tools => List.unmodifiable(_tools);

  /// 设置当前工具
  void setTool(EditorTool tool) {
    if (_currentTool != tool) {
      // 保存当前工具设置
      if (_currentTool != null) {
        _saveToolSettings(_currentTool!);
      }

      _previousTool = _currentTool;
      _currentTool = tool;

      // 恢复新工具设置
      _restoreToolSettings(tool);

      // 只通知工具切换，不触发画布重绘
      _setToolNotifierValue(tool.id);
    }
  }

  /// 保存工具设置
  void _saveToolSettings(EditorTool tool) {
    // 蒙版模式期间不落盘画笔，避免临时覆盖写坏用户自己的笔刷参数。
    if (_brushPersistSuspended && tool is BrushTool) return;

    if (tool is BrushTool) {
      settingsManager.setSetting(tool.id, 'settings', tool.settings.toJson());
      settingsManager.setSetting(
        tool.id,
        'presetIndex',
        tool.selectedPresetIndex,
      );
    } else if (tool is EraserTool) {
      settingsManager.setSetting(tool.id, 'size', tool.size);
      settingsManager.setSetting(tool.id, 'hardness', tool.hardness);
    } else if (tool is MagicWandTool) {
      settingsManager.setSetting(tool.id, 'tolerance', tool.tolerance);
      settingsManager.setSetting(tool.id, 'invert', tool.invert);
    }
    // 异步保存到本地存储
    settingsManager.save();
  }

  /// 恢复工具设置
  void _restoreToolSettings(EditorTool tool) {
    final settings = settingsManager.getToolSettings(tool.id);
    if (settings == null) return;

    if (tool is BrushTool) {
      final brushSettings = settings['settings'];
      if (brushSettings is Map<String, dynamic>) {
        tool.updateSettings(BrushSettings.fromJson(brushSettings));
      }
      final presetIndex = settings['presetIndex'];
      if (presetIndex is int) {
        // 直接设置预设索引，不触发额外操作
        tool.setSelectedPresetIndex(presetIndex);
      }
    } else if (tool is EraserTool) {
      final size = settings['size'];
      if (size is num) {
        tool.setSize(size.toDouble());
      }
      final hardness = settings['hardness'];
      if (hardness is num) {
        tool.setHardness(hardness.toDouble());
      }
    } else if (tool is MagicWandTool) {
      final tolerance = settings['tolerance'];
      if (tolerance is num) {
        tool.setTolerance(tolerance.round());
      }
      final invert = settings['invert'];
      if (invert is bool) {
        tool.setInvert(invert);
      }
    }
  }

  /// 通过ID设置工具
  void setToolById(String toolId) {
    final tool = _tools.firstWhere(
      (t) => t.id == toolId,
      orElse: () => _tools.first,
    );
    setTool(tool);
  }

  /// 切回上一个工具
  void switchToPreviousTool() {
    if (_previousTool != null) {
      final temp = _currentTool;
      _currentTool = _previousTool;
      _previousTool = temp;
      // 只通知工具切换，不触发画布重绘
      _setToolNotifierValue(_currentTool?.id);
    }
  }

  /// 进入临时拾色器模式（Alt 按下）
  void enterTemporaryColorPicker() {
    if (_isTemporaryColorPickerMode) return; // 防止重复进入

    _isTemporaryColorPickerMode = true;
    _toolBeforeTemporaryColorPicker = _currentTool;

    // 切换到拾色器
    final colorPicker = getToolById('color_picker');
    if (colorPicker != null) {
      _currentTool = colorPicker;
      _setToolNotifierValue(colorPicker.id);
    }
  }

  /// 退出临时拾色器模式（Alt 松开）
  void exitTemporaryColorPicker() {
    if (!_isTemporaryColorPickerMode) return;

    _isTemporaryColorPickerMode = false;

    // 切回之前的工具
    if (_toolBeforeTemporaryColorPicker != null) {
      _currentTool = _toolBeforeTemporaryColorPicker;
      _setToolNotifierValue(_currentTool?.id);
      _toolBeforeTemporaryColorPicker = null;
    }
  }

  void beginBatch() {
    _batchDepth++;
  }

  void endBatch() {
    if (_batchDepth == 0) {
      return;
    }

    _batchDepth--;
    if (_batchDepth > 0 || !_pendingToolNotification) {
      return;
    }

    _pendingToolNotification = false;
    toolNotifier.value = _pendingToolId;
    _pendingToolId = null;
  }

  T runBatch<T>(T Function() body) {
    beginBatch();
    try {
      return body();
    } finally {
      endBatch();
    }
  }

  void _setToolNotifierValue(String? toolId) {
    if (_isBatching) {
      _pendingToolNotification = true;
      _pendingToolId = toolId;
      return;
    }

    toolNotifier.value = toolId;
  }

  /// 通过ID获取工具
  EditorTool? getToolById(String id) {
    try {
      return _tools.firstWhere((t) => t.id == id);
    } catch (e) {
      return null;
    }
  }

  /// 创建所有工具实例
  static List<EditorTool> _createTools() {
    return [
      BrushTool(),
      EraserTool(),
      FillTool(),
      MagicWandTool(),
      BlurTool(),
      CloneStampTool(),
      RectSelectionTool(),
      EllipseSelectionTool(),
      LassoSelectionTool(),
      ColorPickerTool(),
    ];
  }

  @override
  void dispose() {
    // 保存当前工具设置
    if (_currentTool != null) {
      _saveToolSettings(_currentTool!);
    }
    toolNotifier.dispose();
    super.dispose();
  }
}
