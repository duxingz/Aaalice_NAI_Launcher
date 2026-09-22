import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/presentation/widgets/prompt/prompt_weight_editing.dart';

void main() {
  TextEditingController cursorIn(String text, int offset, {int? extent}) {
    final controller = TextEditingController(text: text);
    controller.selection = TextSelection(
      baseOffset: offset,
      extentOffset: extent ?? offset,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  group('spanAtCursor', () {
    test('按光标定位所在标签', () {
      final span = PromptWeightEditing.spanAtCursor(cursorIn('cat, dog', 1));
      expect(span, isNotNull);
      expect(span!.raw, 'cat');
    });

    test('光标落在权重壳上仍命中整段', () {
      final span = PromptWeightEditing.spanAtCursor(
        cursorIn('1.50::cat::, dog', 2),
      );
      expect(span, isNotNull);
      expect(span!.raw, '1.50::cat::');
    });

    test('划词只选中标签一部分也能命中（取选区中点）', () {
      final span = PromptWeightEditing.spanAtCursor(
        cursorIn('blue hair, dog', 1, extent: 5),
      );
      expect(span, isNotNull);
      expect(span!.raw, 'blue hair');
    });

    test('选区落在分隔符上仍按中点命中邻居标签', () {
      final span = PromptWeightEditing.spanAtCursor(
        cursorIn('cat, dog', 3, extent: 4),
      );
      expect(span, isNotNull);
      expect(span!.raw, 'cat');
    });
  });

  group('adjustWeightAtCursor', () {
    test('给裸标签加权并使用数值语法', () {
      final controller = cursorIn('cat, dog', 1);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '1.05::cat::, dog');
    });

    test('权重回到 1.0 时去掉权重语法', () {
      final controller = cursorIn('1.05::cat::, dog', 2);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, 'cat, dog');
    });

    test('只影响光标所在标签', () {
      final controller = cursorIn('cat, dog', 7);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, 'cat, 1.05::dog::');
    });

    test('划词选到标签一部分也能调整', () {
      final controller = cursorIn('blue_hair, dog', 2, extent: 6);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '1.05::blue_hair::, dog');
    });

    test('选区跨多个标签时逐个调整', () {
      final controller = cursorIn('cat, dog, bird', 0, extent: 13);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '1.05::cat::, 1.05::dog::, 1.05::bird::');
    });

    test('多选批量时先加权再整体减权可回到原样', () {
      final controller = cursorIn('cat, dog, bird', 0, extent: 13);
      PromptWeightEditing.adjustWeightAtCursor(controller, 0.05);
      expect(controller.text, '1.05::cat::, 1.05::dog::, 1.05::bird::');
      // 调整后仍保持选中，直接再减一次即可回到裸标签
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, 'cat, dog, bird');
    });

    test('可以一路减到负权重', () {
      final controller = cursorIn('cat, dog', 1);
      for (var i = 0; i < 21; i++) {
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05);
      }
      expect(controller.text, '-0.05::cat::, dog');
    });

    test('-1.0 保留权重语法，不会被当成裸标签', () {
      final controller = cursorIn('-1.00::cat::, dog', 3);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '-0.95::cat::, dog');
    });

    test('权重到达上限 10 后不再变化', () {
      final controller = cursorIn('10.00::cat::, dog', 4);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isFalse,
      );
    });

    test('权重到达下限 -10 后不再变化', () {
      final controller = cursorIn('-10.00::cat::, dog', 4);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isFalse,
      );
    });

    test('被禁用的标签不参与调整', () {
      final controller = cursorIn('/*disabled:cat*/, dog', 19);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '/*disabled:cat*/, 1.05::dog::');
    });
  });

  group('moveTagAtCursor', () {
    test('与右邻居交换位置', () {
      final controller = cursorIn('cat, dog', 1);
      expect(PromptWeightEditing.moveTagAtCursor(controller, 1), isTrue);
      expect(controller.text, 'dog, cat');
    });

    test('与左邻居交换位置', () {
      final controller = cursorIn('cat, dog', 7);
      expect(PromptWeightEditing.moveTagAtCursor(controller, -1), isTrue);
      expect(controller.text, 'dog, cat');
    });

    test('划词一部分也能移动所在标签', () {
      // 选中 "do"（dog 的一部分）后左移，与 cat 交换
      final controller = cursorIn('cat, dog', 5, extent: 7);
      expect(PromptWeightEditing.moveTagAtCursor(controller, -1), isTrue);
      expect(controller.text, 'dog, cat');
    });

    test('已在边界时返回 false', () {
      final controller = cursorIn('cat, dog', 1);
      expect(PromptWeightEditing.moveTagAtCursor(controller, -1), isFalse);
      expect(controller.text, 'cat, dog');
    });

    test('权重组内的标签在组内交换', () {
      final controller = cursorIn('1.50::cat, dog::', 8);
      expect(PromptWeightEditing.moveTagAtCursor(controller, 1), isTrue);
      expect(controller.text, '1.50::dog, cat::');
    });
  });
}
