import 'character_prompt_block_parser.dart';
import 'prompt_edit_document.dart';

/// NAI 提示词格式化工具
///
/// - 中文逗号 → 英文逗号
/// - 标签之间统一成「逗号 + 空格」
/// - 去掉多余的首尾空白
/// - 标签内部的下划线 → 空格（表情类标签如 `x_x` / `^_^` 保持原样）
class NaiPromptFormatter {
  static final RegExp _alphanumericPattern = RegExp(r'[A-Za-z0-9]');
  static final RegExp _lineBreakPattern = RegExp(r'\r\n|\r|\n');
  static final RegExp _horizontalWhitespacePattern = RegExp(r'[ \t\f\u00a0]+');
  static final RegExp _leadingHorizontalWhitespacePattern = RegExp(r'^[ \t]*');
  static final RegExp _trailingHorizontalWhitespacePattern = RegExp(r'[ \t]*$');

  /// 规范化单个标签：统一空白，并把下划线换成空格（表情类标签除外）。
  static String formatTag(String tag) =>
      _normalizeTag(_normalizeHorizontalWhitespace(tag));

  /// 格式化整个提示词
  /// - 将中文逗号转换为英文逗号
  /// - 将标签中的空格转换为下划线（保留逗号后的空格和尖括号内的空格）
  /// - 保留用户用于分组的换行、空行和行首缩进
  static String format(String prompt) {
    var followsDisabled = false;
    return PromptEditDocument.mapActiveText(prompt, (fragment) {
      // A leading comma after an opaque disabled fragment separates tags;
      // formatting that fragment alone would treat it as an empty first tag.
      final separator = followsDisabled
          ? RegExp(r'^[ \t]*[,，][ \t]*').firstMatch(fragment)
          : null;
      followsDisabled = true;
      if (separator == null) return _formatActive(fragment);
      return '${separator.group(0)!.replaceAll('，', ',')}'
          '${_formatActive(fragment.substring(separator.end))}';
    });
  }

  static String _formatActive(String prompt) {
    if (prompt.isEmpty) return prompt;

    // Format block contents through the same path as positive tags while the
    // shared parser protects the reserved keyword and matching boundaries.
    var prepared = prompt;
    final parsed = CharacterPromptBlockParser.parse(prompt);
    for (final block in parsed.blocks.reversed) {
      final content = prepared.substring(
        block.contentRange.start,
        block.contentRange.end,
      );
      prepared = prepared.replaceRange(
        block.contentRange.start,
        block.contentRange.end,
        _formatPromptText(content),
      );
    }

    return _formatPromptText(prepared);
  }

  static String _formatPromptText(String prompt) {
    return prompt.splitMapJoin(
      _lineBreakPattern,
      onMatch: (match) => match.group(0)!,
      onNonMatch: _formatLine,
    );
  }

  static String _formatLine(String line) {
    if (line.isEmpty) return line;

    final leadingWhitespace =
        _leadingHorizontalWhitespacePattern.firstMatch(line)?.group(0) ?? '';
    final trailingWhitespace =
        _trailingHorizontalWhitespacePattern.firstMatch(line)?.group(0) ?? '';
    final contentEnd = line.length - trailingWhitespace.length;
    if (leadingWhitespace.length >= contentEnd) {
      return line;
    }

    var content = line.substring(leadingWhitespace.length, contentEnd);
    content = _normalizeHorizontalWhitespace(content).replaceAll('，', ',');
    final keepsTrailingComma = content.endsWith(',');

    // 胖大叔自用改：不再把空格转成下划线，反而把下划线换成空格。
    // 表情类标签（x_x / o_o / ^_^ / >_< / <o>_<o>）保持原样。
    final tags = content
        .split(',')
        .map(_normalizeTag)
        .where((tag) => tag.isNotEmpty)
        .toList();

    var formatted = tags.join(', ');
    if (keepsTrailingComma && formatted.isNotEmpty) {
      formatted = '$formatted,';
    }

    return '$leadingWhitespace$formatted$trailingWhitespace';
  }

  /// 统一行内空白字符，不跨越或删除换行。
  static String _normalizeHorizontalWhitespace(String text) {
    var result = text.replaceAll('　', ' ');
    result = result.replaceAll(_horizontalWhitespacePattern, ' ');
    return result;
  }

  /// 单个标签的规范化：下划线换空格，表情类标签除外。
  ///
  /// `soft_dramatic_lighting` → `soft dramatic lighting`
  /// 而 `x_x`、`o_o`、`^_^`、`>_<`、`<o>_<o>` 保持不变。
  static String _normalizeTag(String tag) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty || !trimmed.contains('_')) return trimmed;
    if (_isFaceLikeTag(trimmed)) return trimmed;
    return trimmed.replaceAll('_', ' ');
  }

  /// 判断是否为「表情类」标签 —— 其中的下划线是符号本身，不能换成空格。
  ///
  /// 规则一：下划线两侧完全相同（忽略大小写）
  ///         `x_x` `o_o` `O_o` `0_0` `T_T` `+_+` `._.` `^_^` `|_|` `<o>_<o>`
  /// 规则二：整串很短且至少一侧不是字母数字
  ///         `>_<` `>_o` `;_;`
  static bool _isFaceLikeTag(String tag) {
    if (tag.length > 8) return false;
    final parts = tag.split('_');
    if (parts.length < 2) return false;
    final first = parts.first.toLowerCase();
    if (parts.every((part) => part.toLowerCase() == first)) return true;
    if (tag.length <= 5 &&
        parts.any(
          (part) => part.isNotEmpty && !_alphanumericPattern.hasMatch(part),
        )) {
      return true;
    }
    return false;
  }
}
