import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nai_launcher/presentation/widgets/image_editor/core/tool_manager.dart';
import 'package:nai_launcher/presentation/widgets/image_editor/tools/brush_tool.dart';
import 'package:nai_launcher/presentation/widgets/image_editor/tools/eraser_tool.dart';

/// 用户报告的「进图生图丢笔刷」回归。
///
/// 局部重绘会把笔刷临时改成蒙版专用参数（55% 不透明度、100% 硬度），
/// 这套参数过去会在关闭编辑器时被写进 SharedPreferences，永久顶掉用户
/// 自己调好的笔刷。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 造一个「上一轮会话已经把笔刷调成 42px / 25% / 30% 硬」的存档。
  Future<void> seedSavedBrush() async {
    final session = ToolManager();
    await pumpEventQueue();
    final brush = session.getToolById('brush')! as BrushTool;
    brush.setSize(42);
    brush.setOpacity(0.25);
    brush.setHardness(0.3);
    session.setToolById('eraser'); // 切工具会触发一次保存
    await session.settingsManager.save();
    session.dispose();
  }

  BrushTool brushOf(ToolManager manager) =>
      manager.getToolById('brush')! as BrushTool;

  test('restores the saved brush into a new session', () async {
    await seedSavedBrush();

    final session = ToolManager();
    await pumpEventQueue();

    expect(brushOf(session).settings.size, 42);
    expect(brushOf(session).settings.opacity, 0.25);
    expect(brushOf(session).settings.hardness, 0.3);
  });

  test('still restores the brush when the tool moved before the load', () async {
    await seedSavedBrush();

    // 加载是异步的，界面可能在它完成前就切走了工具（进入局部重绘且开着
    // 聚焦重绘时会切到矩形选区）。画笔这一轮必须照样拿到已保存的参数。
    final session = ToolManager();
    session.setToolById('rect_selection');
    await pumpEventQueue();

    expect(brushOf(session).settings.size, 42);
    expect(brushOf(session).settings.opacity, 0.25);
  });

  test('keeps the mask brush override out of storage', () async {
    await seedSavedBrush();

    // 进入局部重绘：先挂起画笔写入，再套用蒙版专用参数。
    final maskSession = ToolManager();
    maskSession.setBrushSettingsPersistSuspended(true);
    await pumpEventQueue();
    expect(brushOf(maskSession).settings.size, 42);

    brushOf(maskSession).setOpacity(0.55);
    brushOf(maskSession).setHardness(1.0);
    maskSession.setToolById('eraser');
    await maskSession.settingsManager.save();
    maskSession.dispose(); // 关闭编辑器，旧实现会在这里把覆盖值写盘
    await pumpEventQueue();

    // 下一个会话（普通编辑模式）拿到的仍是用户自己的笔刷。
    final next = ToolManager();
    await pumpEventQueue();
    expect(brushOf(next).settings.opacity, 0.25);
    expect(brushOf(next).settings.hardness, 0.3);
    expect(brushOf(next).settings.size, 42);
  });

  test('suspension only covers the brush, not other tools', () async {
    final session = ToolManager();
    session.setBrushSettingsPersistSuspended(true);
    await pumpEventQueue();

    session.setToolById('eraser');
    (session.getToolById('eraser')! as EraserTool).setSize(77);
    // 切走橡皮会触发一次保存；此时画笔那侧仍处于挂起状态。
    session.setToolById('brush');
    await session.settingsManager.save();
    session.dispose();
    await pumpEventQueue();

    final next = ToolManager();
    await pumpEventQueue();
    expect((next.getToolById('eraser')! as EraserTool).size, 77);
  });

  test('restores the selected brush preset too', () async {
    final session = ToolManager();
    await pumpEventQueue();
    final brush = brushOf(session);
    brush.applyPreset(defaultBrushPresets[5], 5);
    session.setToolById('eraser');
    await session.settingsManager.save();
    session.dispose();
    await pumpEventQueue();

    final next = ToolManager();
    await pumpEventQueue();
    expect(brushOf(next).selectedPresetIndex, 5);
    expect(brushOf(next).settings.size, defaultBrushPresets[5].size);
  });
}
