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

  TextEditingController selectedAll(String text) =>
      cursorIn(text, 0, extent: text.length);

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

    test('选区跨多个标签时合并成一个权重块', () {
      final controller = cursorIn('cat, dog, bird', 0, extent: 13);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '1.05::cat, dog, bird::');
    });

    test('关掉开关时保留旧行为：每个标签各自套权重', () {
      final controller = cursorIn('cat, dog, bird', 0, extent: 13);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(
          controller,
          0.05,
          mergeMultiSelectWeight: false,
        ),
        isTrue,
      );
      expect(controller.text, '1.05::cat::, 1.05::dog::, 1.05::bird::');
    });

    test('多选批量时先加权再整体减权可回到原样', () {
      final controller = cursorIn('cat, dog, bird', 0, extent: 13);
      PromptWeightEditing.adjustWeightAtCursor(controller, 0.05);
      expect(controller.text, '1.05::cat, dog, bird::');
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

  group('多选合并成一个权重块（胖大叔自用改）', () {
    test('三个标签调成一个共享块', () {
      final controller = selectedAll('1boy, 1girl, pov');
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, '0.95::1boy, 1girl, pov::');
    });

    test('块内调权重改的是整块，不会嵌套', () {
      final controller = cursorIn('0.95::1boy, 1girl, pov::', 12);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, '0.9::1boy, 1girl, pov::');
    });

    test('整段选中已有的块只替换那个数字', () {
      final controller = selectedAll('0.90::cat, dog::');
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, '0.85::cat, dog::');
    });

    test('段内各自带权重的标签会被并入块', () {
      final controller = selectedAll('cat, 1.5::dog::');
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, '0.95::cat, dog::');
    });

    test('块与相邻标签一起选中时整体压平', () {
      final controller = selectedAll('0.9::cat, dog::, bird');
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, '0.95::cat, dog, bird::');
    });

    test('单标签行为不受开关影响', () {
      final controller = cursorIn('cat, dog', 1);
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, 0.05),
        isTrue,
      );
      expect(controller.text, '1.05::cat::, dog');
    });
  });

  group('权重数值写法（胖大叔自用改）', () {
    test('去掉结尾多余的 0', () {
      expect(PromptWeightEditing.formatWeight(0.90), '0.9');
      expect(PromptWeightEditing.formatWeight(0.80), '0.8');
      expect(PromptWeightEditing.formatWeight(2.00), '2');
      expect(PromptWeightEditing.formatWeight(-1.00), '-1');
      expect(PromptWeightEditing.formatWeight(0.95), '0.95');
      expect(PromptWeightEditing.formatWeight(-0.05), '-0.05');
    });

    test('连续减权不会写出 0.90 这种形式', () {
      final controller = cursorIn('cat', 1);
      PromptWeightEditing.adjustWeightAtCursor(controller, -0.05);
      expect(controller.text, '0.95::cat::');
      PromptWeightEditing.adjustWeightAtCursor(controller, -0.05);
      expect(controller.text, '0.9::cat::');
    });

    test('标签以数字结尾时补保护逗号', () {
      final controller = selectedAll('shikisokuzeku76');
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      expect(controller.text, '0.95::shikisokuzeku76, ::');
    });

    test('保护逗号是幂等的（连按不会越加越多）', () {
      final controller = selectedAll('shikisokuzeku76');
      PromptWeightEditing.adjustWeightAtCursor(controller, -0.05);
      expect(controller.text, '0.95::shikisokuzeku76, ::');
      PromptWeightEditing.adjustWeightAtCursor(controller, -0.05);
      expect(controller.text, '0.9::shikisokuzeku76, ::');
      PromptWeightEditing.adjustWeightAtCursor(controller, -0.05);
      expect(controller.text, '0.85::shikisokuzeku76, ::');
    });

    test('减回 1.0 时保护逗号一并清掉', () {
      final controller = selectedAll('0.95::a76, ::');
      PromptWeightEditing.adjustWeightAtCursor(controller, -0.05);
      expect(controller.text, '0.9::a76, ::');
      PromptWeightEditing.adjustWeightAtCursor(controller, 0.05);
      expect(controller.text, '0.95::a76, ::');
      PromptWeightEditing.adjustWeightAtCursor(controller, 0.05);
      expect(controller.text, 'a76');
    });

    test('块尾是数字时，重调整块仍保留规范的保护逗号', () {
      final controller = selectedAll('0.95::cat, dog76, ::');
      expect(
        PromptWeightEditing.adjustWeightAtCursor(controller, -0.05),
        isTrue,
      );
      // 不能退化成 `dog76,::`（少了空格）或丢掉逗号。
      expect(controller.text, '0.9::cat, dog76, ::');
    });
  });
}
