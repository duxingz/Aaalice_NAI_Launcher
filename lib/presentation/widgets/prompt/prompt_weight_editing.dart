import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/utils/character_prompt_block_parser.dart';
import '../../../core/utils/prompt_edit_document.dart';
import 'nai_syntax_controller.dart';

/// 权重解析结果
class PromptWeightValue {
  final String baseText;
  final double weight;

  const PromptWeightValue({required this.baseText, required this.weight});
}

class PromptWeightEditing {
  static bool protectNegativeBlockSyntax(TextEditingController controller) {
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return false;

    final parsed = CharacterPromptBlockParser.parse(controller.text);
    for (final block in parsed.blocks) {
      final overlapsBlock =
          selection.start < block.range.end &&
          selection.end > block.range.start;
      if (!overlapsBlock) continue;

      final insideContent =
          selection.start >= block.contentRange.start &&
          selection.end <= block.contentRange.end;
      final containsWholeBlock =
          selection.start == block.range.start &&
          selection.end == block.range.end;
      if (!insideContent && !containsWholeBlock) return false;

      final start = selection.start.clamp(
        block.contentRange.start,
        block.contentRange.end,
      );
      final end = selection.end.clamp(
        block.contentRange.start,
        block.contentRange.end,
      );
      if (start >= end) return false;
      if (start != selection.start || end != selection.end) {
        controller.selection = TextSelection(
          baseOffset: start,
          extentOffset: end,
        );
      }
      return true;
    }
    return true;
  }

  static bool hasSelection(TextEditingController controller) {
    final selection = controller.selection;
    return selection.isValid &&
        selection.start != selection.end &&
        selection.start >= 0 &&
        selection.end <= controller.text.length;
  }

  static PromptWeightValue parseSelection(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;
    final start = selection.start;
    final end = selection.end;

    if (start < 0 || end > text.length || start >= end) {
      return const PromptWeightValue(baseText: '', weight: 1.0);
    }

    final selectedText = text.substring(start, end);
    return parseWeightSyntax(selectedText);
  }

  static PromptWeightValue parseWeightSyntax(String text) {
    text = PromptEditDocument.decodeDisabled(text);
    var baseText = text;
    var weight = 1.0;

    final trimmed = text.trim();

    // NAI 数值权重语法: weight::text:: 或 weight::text
    final naiWeightMatch = RegExp(
      r'^(-?\d+\.?\d*)::(.+?)(?:::$|$)',
      // Selections can span paragraphs; subsequent edits must replace this shell.
      dotAll: true,
    ).firstMatch(trimmed);

    if (naiWeightMatch != null) {
      final weightValue = double.tryParse(naiWeightMatch.group(1)!);
      if (weightValue != null) {
        weight = weightValue;
        baseText = naiWeightMatch.group(2)!.trim();
        return PromptWeightValue(baseText: baseText, weight: weight);
      }
    }

    // Peel only complete enclosing shells; edge brackets may belong to
    // different tags (for example `{cat}, {dog}`) and must stay intact.
    final spans = PromptEditDocument.parse(trimmed);
    if (spans.length == 1) {
      final span = spans.single;
      final prefix = span.prefix;
      if (prefix.isNotEmpty && RegExp(r'^[\{\[]+$').hasMatch(prefix)) {
        final exponent = prefix
            .split('')
            .fold<int>(0, (value, char) => value + (char == '{' ? 1 : -1));
        weight = math.pow(1.05, exponent).toDouble();
        baseText = span.label;
      }
    }
    return PromptWeightValue(baseText: baseText.trim(), weight: weight);
  }

  static bool applyWeight(TextEditingController controller, double newWeight) {
    final result = parseSelection(controller);
    final baseText = result.baseText;

    if (baseText.isEmpty) return false;

    final selectedText = controller.selection.textInside(controller.text);
    final newText = withWeight(
      selectedText,
      newWeight,
      numericEmphasisEnabled:
          controller is! NaiSyntaxController ||
          controller.numericEmphasisEnabled,
    );

    final text = controller.text;
    final selection = controller.selection;
    final newTextValue =
        text.substring(0, selection.start) +
        newText +
        text.substring(selection.end);

    controller.text = newTextValue;

    final newSelectionEnd = selection.start + newText.length;
    controller.selection = TextSelection(
      baseOffset: selection.start,
      extentOffset: newSelectionEnd,
    );

    return true;
  }

  static String withWeight(
    String source,
    double weight, {
    bool numericEmphasisEnabled = true,
  }) {
    final spans = PromptEditDocument.parse(source);
    final disabled = spans.length == 1 && spans.single.disabled;
    final parsed = parseWeightSyntax(source);
    final value = weight.clamp(0.1, 3.0);
    String text;
    if ((value - 1).abs() < 0.00001) {
      text = parsed.baseText;
    } else if (numericEmphasisEnabled) {
      text = '${value.toStringAsFixed(2)}::${parsed.baseText}::';
    } else {
      final depth = (math.log(value).abs() / math.log(1.05)).round();
      final opening = value > 1 ? '{' : '[';
      final closing = value > 1 ? '}' : ']';
      text = '${opening * depth}${parsed.baseText}${closing * depth}';
    }
    return disabled ? PromptEditDocument.disable(text) : text;
  }

  /// 胖大叔自用改：定位光标（或选区）所在的标签。
  ///
  /// 已有选区且正好覆盖一个完整标签时直接使用它；否则按光标偏移在解析
  /// 树里找到最内层叶子。返回 null 表示当前位置没有可操作的标签。
  static PromptEditSpan? spanAtCursor(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;
    if (!selection.isValid || text.isEmpty) return null;

    if (!selection.isCollapsed) {
      return PromptEditDocument.singleSelected(
        text,
        selection.start,
        selection.end,
      );
    }

    final offset = selection.extentOffset;
    if (offset < 0 || offset > text.length) return null;
    for (final root in PromptEditDocument.parse(text)) {
      final hit = _locateLeaf(root, offset);
      if (hit != null) return hit;
    }
    return null;
  }

  static PromptEditSpan? _locateLeaf(PromptEditSpan span, int offset) {
    if (offset < span.start || offset > span.end) return null;
    if (span.children.isEmpty) return span.complete ? span : null;
    for (final child in span.children) {
      final hit = _locateLeaf(child, offset);
      if (hit != null) return hit;
    }
    // 光标落在权重壳上（例如 `1.5::` 的数字里）时，整段仍算命中。
    return span.children.length == 1 && span.complete
        ? span.children.single
        : null;
  }

  /// 胖大叔自用改：按光标所在标签调整权重。
  ///
  /// 步进由调用方给出；权重回到 1.0 时 [withWeight] 会自动去掉权重语法。
  /// 返回 false 表示没有可调整的标签，调用方应把按键交回默认处理。
  static bool adjustWeightAtCursor(
    TextEditingController controller,
    double step, {
    bool numericEmphasisEnabled = true,
  }) {
    final span = spanAtCursor(controller);
    if (span == null || span.disabled) return false;
    final current = parseWeightSyntax(span.raw).weight;
    final next = (current + step).clamp(0.1, 3.0);
    if ((next - current).abs() < 0.00001) return false;
    final replacement = withWeight(
      span.raw,
      next,
      numericEmphasisEnabled: numericEmphasisEnabled,
    );
    if (replacement == span.raw) return false;
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(span.start, span.end, replacement),
      selection: TextSelection(
        baseOffset: span.start,
        extentOffset: span.start + replacement.length,
      ),
    );
    return true;
  }

  /// 胖大叔自用改：与相邻标签交换位置。
  ///
  /// 只在同一层级内交换；当前标签所在组只有一个子项时，整组作为移动单位，
  /// 避免权重组在移动中被拆散。返回 false 表示已经到边界。
  static bool moveTagAtCursor(TextEditingController controller, int direction) {
    if (direction != -1 && direction != 1) return false;
    final text = controller.text;
    final selection = controller.selection;
    if (!selection.isValid || text.isEmpty) return false;
    final anchorStart = selection.isCollapsed
        ? selection.extentOffset
        : selection.start;
    final anchorEnd = selection.isCollapsed
        ? selection.extentOffset
        : selection.end;
    final located = _locateSiblings(
      PromptEditDocument.parse(text),
      anchorStart,
      anchorEnd,
    );
    if (located == null) return false;

    final siblings = located.siblings;
    final target = located.index + direction;
    if (target < 0 || target >= siblings.length) return false;

    final moving = siblings[located.index];
    final other = siblings[target];
    final left = direction < 0 ? other : moving;
    final right = direction < 0 ? moving : other;

    final updated =
        text.substring(0, left.start) +
        right.raw +
        text.substring(left.end, right.start) +
        left.raw +
        text.substring(right.end);

    final newRightStart = left.start;
    final newLeftStart =
        left.start + right.raw.length + (right.start - left.end);
    final newMovingStart = identical(moving, left)
        ? newLeftStart
        : newRightStart;
    controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: newMovingStart,
        extentOffset: newMovingStart + moving.raw.length,
      ),
    );
    return true;
  }

  static ({List<PromptEditSpan> siblings, int index})? _locateSiblings(
    List<PromptEditSpan> spans,
    int start,
    int end,
  ) {
    for (var index = 0; index < spans.length; index++) {
      final span = spans[index];
      if (start < span.start || end > span.end) continue;
      if (span.children.isNotEmpty) {
        final inner = _locateSiblings(span.children, start, end);
        if (inner != null) {
          // 单子项组整体移动，与父层兄弟交换位置。
          if (span.children.length == 1) {
            return (siblings: spans, index: index);
          }
          return inner;
        }
      }
      return (siblings: spans, index: index);
    }
    return null;
  }
}
