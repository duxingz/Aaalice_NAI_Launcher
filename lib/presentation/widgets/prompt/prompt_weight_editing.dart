import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/utils/bigman_mod_flags.dart';
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
        // 末尾的「保护性逗号」属于**写回时才生成**的定界符，不进解析状态：
        // 否则它会被当成内容的一部分，反复调整会越积越多。
        baseText = stripTrailingNumericGuard(naiWeightMatch.group(2)!);
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
    // 胖大叔自用改：范围放宽到 ±10，允许负权重压制（如 -1::sweat::）。
    final value = weight.clamp(minWeight, maxWeight);
    String text;
    if ((value - 1).abs() < 0.00001) {
      text = parsed.baseText;
    } else if (numericEmphasisEnabled || value <= 0) {
      // 负权重只能用数字语法：{} / [] 表达不了负数，log 也取不到负值。
      text =
          '${formatWeight(value)}::'
          '${withTrailingNumericGuard(parsed.baseText)}::';
    } else {
      final depth = (math.log(value).abs() / math.log(1.05)).round();
      final opening = value > 1 ? '{' : '[';
      final closing = value > 1 ? '}' : ']';
      text = '${opening * depth}${parsed.baseText}${closing * depth}';
    }
    return disabled ? PromptEditDocument.disable(text) : text;
  }

  /// 权重数值的标准写法：两位精度，**去掉结尾多余的 0**。
  ///
  /// `0.90` → `0.9`、`0.80` → `0.8`、`2.00` → `2`；`0.95`、`-0.05` 原样。
  static String formatWeight(double value) {
    var text = value.toStringAsFixed(2);
    if (text.contains('.')) {
      text = text.replaceFirst(RegExp(r'0+$'), '');
      if (text.endsWith('.')) {
        text = text.substring(0, text.length - 1);
      }
    }
    return text;
  }

  /// 去掉权重块内容末尾的「保护性逗号」（含其后的空白）。
  ///
  /// 与 [withTrailingNumericGuard] 配对使用：写回时补上，解析时剥掉，
  /// 这样反复调整权重不会让逗号越积越多。
  static String stripTrailingNumericGuard(String text) {
    var result = text.trim();
    while (result.endsWith(',')) {
      result = result.substring(0, result.length - 1).trimRight();
    }
    return result;
  }

  /// 内容以数字结尾时补一个「保护性逗号」。
  ///
  /// 标签以数字结尾时（如 `shikisokuzeku76`），收尾的 `::` 会和数字粘在一起
  /// 让权重语法歧义；用户实测 `0.80::shikisokuzeku76, ::` 才是能用的形式。
  static String withTrailingNumericGuard(String body) {
    final trimmedRight = body.trimRight();
    if (trimmedRight.isEmpty) return body;
    if (!RegExp(r'\d$').hasMatch(trimmedRight)) return body;
    return '$trimmedRight, ';
  }

  /// 胖大叔自用改：定位光标（或选区中点）所在的标签。
  ///
  /// 有选区时取**中点**定位 —— 这样「划到标签一半」也能命中，
  /// 不再要求选区精确等于整个标签（对齐 NovelAI Prompt Helper 的做法）。
  ///
  /// 命中权重块内部的标签时返回**整个块**而不是内层标签：块是一个整体，
  /// 只改内层标签会套出嵌套的权重语法（NAI 那边解析会混乱）。
  /// 返回 null 表示当前位置没有可操作的标签。
  static PromptEditSpan? spanAtCursor(TextEditingController controller) {
    final text = controller.text;
    final selection = controller.selection;
    if (!selection.isValid || text.isEmpty) return null;

    final offset = selection.isCollapsed
        ? selection.extentOffset
        : (selection.start + selection.end) ~/ 2;
    if (offset < 0 || offset > text.length) return null;
    final shell = _enclosingWeightShell(text, offset, offset);
    if (shell != null) return shell;
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

  /// 权重可调范围（胖大叔自用改：放宽到 ±10，方便做负权重抑制）。
  static const double minWeight = -10.0;
  static const double maxWeight = 10.0;

  /// 胖大叔自用改：调整光标（或选区）内标签的权重。
  ///
  /// - 无选区：调光标所在的那一个标签（命中权重块时调**整个块**）
  /// - 有选区且命中多个标签：
  ///   - [mergeMultiSelectWeight] 为 true（默认，读自用改开关）：把整段当作
  ///     **一个权重块** → `0.95::1boy, 1girl, pov::`
  ///   - 关掉开关：保持旧行为，逐个标签各自套权重
  ///
  /// 步进由调用方给出；权重回到 1.0 时 [withWeight] 会自动去掉权重语法。
  /// 返回 false 表示没有可调整的标签，调用方应把按键交回默认处理。
  static bool adjustWeightAtCursor(
    TextEditingController controller,
    double step, {
    bool numericEmphasisEnabled = true,
    bool? mergeMultiSelectWeight,
  }) {
    final text = controller.text;
    final selection = controller.selection;
    if (!selection.isValid || text.isEmpty) return false;

    final mergeSelection =
        mergeMultiSelectWeight ?? BigmanModFlags.mergeMultiSelectWeight();

    final List<PromptEditSpan> leaves;
    if (selection.isCollapsed) {
      final single = spanAtCursor(controller);
      leaves = single == null ? const <PromptEditSpan>[] : [single];
    } else {
      leaves = leavesInRange(text, selection.start, selection.end);
      if (leaves.length >= 2 && mergeSelection) {
        return _adjustWeightAsBlock(
          controller,
          leaves,
          step,
          numericEmphasisEnabled: numericEmphasisEnabled,
        );
      }
    }
    if (leaves.isEmpty) return false;

    var updated = text;
    var changed = false;
    var selStart = -1;
    var lastOriginalEnd = -1;
    // 从后往前替换，前面标签的偏移不受影响。
    for (final span in leaves.reversed) {
      if (span.disabled) continue;
      final current = parseWeightSyntax(span.raw).weight;
      final next = (current + step).clamp(minWeight, maxWeight);
      if ((next - current).abs() < 0.00001) continue;
      final replacement = withWeight(
        span.raw,
        next,
        numericEmphasisEnabled: numericEmphasisEnabled,
      );
      if (replacement == span.raw) continue;
      updated = updated.replaceRange(span.start, span.end, replacement);
      selStart = span.start;
      if (lastOriginalEnd < 0) lastOriginalEnd = span.end;
      changed = true;
    }
    if (!changed) return false;
    // 尾部未改动的长度是固定的，据此反推调整后选区的终点，
    // 这样多选批量后选区仍完整覆盖这批标签。
    final tailLength = text.length - lastOriginalEnd;
    final selEnd = updated.length - tailLength;
    controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection(baseOffset: selStart, extentOffset: selEnd),
    );
    return true;
  }

  /// 胖大叔自用改：找出与 [start, end] 相交的所有可编辑叶子标签。
  static List<PromptEditSpan> leavesInRange(String text, int start, int end) {
    final result = <PromptEditSpan>[];
    void visit(PromptEditSpan span) {
      if (span.end <= start || span.start >= end) return;
      if (span.children.isEmpty) {
        if (span.complete) result.add(span);
        return;
      }
      for (final child in span.children) {
        visit(child);
      }
    }

    for (final root in PromptEditDocument.parse(text)) {
      visit(root);
    }
    return result;
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
    // 选区取中点定位，方便「划到一半」时也能命中。
    final anchor = selection.isCollapsed
        ? selection.extentOffset
        : (selection.start + selection.end) ~/ 2;
    final located = _locateSiblings(
      PromptEditDocument.parse(text),
      anchor,
      anchor,
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

  /// 是否为「数字权重壳」（`0.95::` 这种前缀）。
  ///
  /// 只认数字壳：`{`、`[`、`negative(`、`||…||` 都不是权重块。
  static bool _isNumericWeightShell(PromptEditSpan span) =>
      RegExp(r'^-?(?:\d+(?:\.\d*)?|\.\d+)::$').hasMatch(span.prefix);

  /// 找出完整覆盖 [start, end] 的最内层数字权重壳；没有则返回 null。
  static PromptEditSpan? _enclosingWeightShell(
    String text,
    int start,
    int end,
  ) {
    PromptEditSpan? found;
    void visit(PromptEditSpan span) {
      if (span.editStart > start || span.editEnd < end) return;
      if (_isNumericWeightShell(span)) found = span;
      for (final child in span.children) {
        visit(child);
      }
    }

    for (final root in PromptEditDocument.parse(text)) {
      visit(root);
    }
    return found;
  }

  /// 把整段选中的标签当作**一个权重块**调整。
  ///
  /// 目标形态 `0.95::1boy, 1girl, pov::`；段内原本各自带权重的标签会被并入块
  /// （用户裁决：统一成块的权重）。段本身就是权重块时只替换那个数字，不嵌套。
  static bool _adjustWeightAsBlock(
    TextEditingController controller,
    List<PromptEditSpan> leaves,
    double step, {
    required bool numericEmphasisEnabled,
  }) {
    final text = controller.text;
    final first = leaves.first;
    final last = leaves.last;
    // 选区可能只覆盖某个权重块的一部分（例如「块 + 相邻标签」一起选中）。
    // 这时必须把被部分覆盖的块壳也纳入替换范围，否则壳会留在替换范围外，
    // 生成 `0.9::0.95::…::` 这种嵌套。
    final firstShell = _enclosingWeightShell(text, first.start, first.end);
    final lastShell = _enclosingWeightShell(text, last.start, last.end);
    final wholeShell =
        firstShell != null &&
        lastShell != null &&
        firstShell.start == lastShell.start &&
        firstShell.end == lastShell.end;

    final outerStart = firstShell?.start ?? first.start;
    final outerEnd = lastShell?.end ?? last.end;
    final contentStart = firstShell?.editStart ?? first.start;
    final contentEnd = lastShell?.editEnd ?? last.end;
    // 整段本来就是一个块时用块里的当前权重；否则按裸内容从 1.0 起算
    // （与标签编辑模式的多选基准一致）。
    final current = wholeShell ? parseWeightSyntax(firstShell.raw).weight : 1.0;
    final next = (current + step).clamp(minWeight, maxWeight);
    if ((next - current).abs() < 0.00001) return false;

    // 段尾可能残留上一个块的保护逗号（`…dog76, ::` 的 `, ` 落在最后一个叶子
    // 之后），先剥掉，交给 withWeight 按规则重新生成，保证输出是规范形态。
    final body = stripTrailingNumericGuard(
      _flattenRun(text, leaves, contentStart, contentEnd),
    );
    final replacement = withWeight(
      body,
      next,
      numericEmphasisEnabled: numericEmphasisEnabled,
    );
    final updated = text.replaceRange(outerStart, outerEnd, replacement);
    if (updated == text) return false;
    controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection(
        baseOffset: outerStart,
        extentOffset: outerStart + replacement.length,
      ),
    );
    return true;
  }

  /// 压平 [runStart, runEnd)：保留标签之间的分隔符，剥掉数字权重壳的定界符，
  /// 每个叶子只留内容。
  ///
  /// 这是「整段套一个块」的前提：段里原本各自带权重的标签若不去壳，再套一层
  /// 就会变成嵌套的权重语法，NAI 那边解析会混乱。
  static String _flattenRun(
    String text,
    List<PromptEditSpan> leaves,
    int runStart,
    int runEnd,
  ) {
    // 要删掉的权重定界符（外壳的 `0.95::` 与其收尾 `::`）。
    final cuts = <(int, int)>[];
    void collect(PromptEditSpan span) {
      if (span.end <= runStart || span.start >= runEnd) return;
      if (_isNumericWeightShell(span)) {
        cuts.add((span.start, span.editStart));
        if (span.editEnd < span.end) cuts.add((span.editEnd, span.end));
      }
      for (final child in span.children) {
        collect(child);
      }
    }

    for (final root in PromptEditDocument.parse(text)) {
      collect(root);
    }
    cuts.sort((a, b) => a.$1.compareTo(b.$1));

    final leafByStart = <int, PromptEditSpan>{
      for (final leaf in leaves)
        if (leaf.start >= runStart && leaf.end <= runEnd) leaf.start: leaf,
    };

    final buffer = StringBuffer();
    var cursor = runStart;
    var cutIndex = 0;
    while (cursor < runEnd) {
      // 整叶优先：叶子若还含着自己的权重壳（`1.5::dog::`），由它整体替换，
      // 壳前后的定界符不再单独处理。
      final leaf = leafByStart[cursor];
      if (leaf != null) {
        buffer.write(parseWeightSyntax(leaf.raw).baseText);
        cursor = leaf.end;
        while (cutIndex < cuts.length && cuts[cutIndex].$1 < cursor) {
          cutIndex++;
        }
        continue;
      }
      if (cutIndex < cuts.length && cuts[cutIndex].$1 <= cursor) {
        final cut = cuts[cutIndex];
        if (cut.$2 > cursor) cursor = cut.$2;
        cutIndex++;
        continue;
      }
      buffer.write(text[cursor]);
      cursor++;
    }
    return buffer.toString();
  }
}
