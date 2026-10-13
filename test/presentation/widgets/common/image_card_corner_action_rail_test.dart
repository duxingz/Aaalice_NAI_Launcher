// 右上角操作轨的宽度自适应。
//
// 历史记录缩略图的轨道现在固定显示「保存 · 图生图 · 复制 · 删除」+ 常驻收藏，
// 一共五个 40px 圆钮。轨道靠右锚定，卡片太窄时如果照排就会画到卡片外、
// 或者压住左上角的多选框（40px @ left:8），所以按优先级少显示：
// 图生图 → 保存 → 复制 依次被舍弃，删除与收藏始终保留。
//
// 这里直接对轨道本身下断言（它是公开组件），宽度是唯一变量、可精确计算：
//   可用宽度 = 轨道宽 - 56（左侧多选框与间隙）- 48（收藏预留）
//   需要宽度 = 44 × 个数   （40 圆钮 + 4 间距，另加与收藏之间的一处间距）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/widgets/common/image_card_action.dart';
import 'package:nai_launcher/presentation/widgets/common/image_card_surface.dart';

const _labels = <ImageCardActionId, String>{
  ImageCardActionId.save: '保存',
  ImageCardActionId.imageToImage: '图生图',
  ImageCardActionId.copy: '复制',
  ImageCardActionId.delete: '删除',
};

List<ImageCardAction> _railActions() => [
  for (final entry in _labels.entries)
    ImageCardAction(
      id: entry.key,
      icon: Icons.circle,
      label: entry.value,
      invoke: () {},
    ),
];

Future<void> _pumpRail(WidgetTester tester, double width) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: width,
            height: 60,
            child: Align(
              alignment: Alignment.topRight,
              child: ImageCardCornerActionRail(
                pinnedActions: _railActions(),
                favorite: const SizedBox.square(dimension: 48),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 轨道里画出来的按钮，按从左到右顺序（tooltip 就是标签）。
List<String> _visibleLabels(WidgetTester tester) => tester
    .widgetList<IconButton>(
      find.descendant(
        of: find.byType(ImageCardCornerActionRail),
        matching: find.byType(IconButton),
      ),
    )
    .map((button) => button.tooltip ?? '')
    .toList();

void main() {
  testWidgets('够宽时五个都在，顺序固定', (tester) async {
    await _pumpRail(tester, 400);

    expect(_visibleLabels(tester), const ['保存', '图生图', '复制', '删除']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('刚好够宽（约 280）时仍是五个', (tester) async {
    // 可用 = 280 - 104 = 176；需要 = 44 × 4 = 176 → 正好放下。
    await _pumpRail(tester, 280);

    expect(_visibleLabels(tester), const ['保存', '图生图', '复制', '删除']);
  });

  testWidgets('窄到 200 时先丢图生图与保存，只留复制和删除', (tester) async {
    // 可用 = 200 - 104 = 96；44 × 3 = 132 > 96，44 × 2 = 88 ≤ 96。
    await _pumpRail(tester, 200);

    expect(_visibleLabels(tester), const ['复制', '删除']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('再窄到 160 时只剩删除', (tester) async {
    // 可用 = 160 - 104 = 56；44 × 2 = 88 > 56，44 × 1 = 44 ≤ 56。
    await _pumpRail(tester, 160);

    expect(_visibleLabels(tester), const ['删除']);
  });

  testWidgets('极窄时清空固定动作，收藏仍保留', (tester) async {
    await _pumpRail(tester, 120);

    expect(_visibleLabels(tester), isEmpty);
    expect(
      find.descendant(
        of: find.byType(ImageCardCornerActionRail),
        matching: find.byType(SizedBox),
      ),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });
}
