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
  });

  group('adjustWeightAtCursor', () {
    test('给裸标签加权并使用数值语法', () {
      final controller = cursorIn('cat, dog', 1);
      expect(PromptWeightEditing.adjustWeightAtCursor(controller, 0.05), isTrue);
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
      expect(PromptWeightEditing.adjustWeightAtCursor(controller, 0.05), isTrue);
      expect(controller.text, 'cat, 1.05::dog::');
    });

    test('权重到达上限后不再变化', () {
      final controller = cursorIn('3.00::cat::, dog', 2);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isFalse,
      );
    });

    test('选区覆盖整段权重组时调整该组', () {
      final controller = cursorIn('1.50::cat::, dog', 0, extent: 11);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '1.55::cat::, dog');
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
