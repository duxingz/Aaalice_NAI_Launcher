import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/nai_prompt_formatter.dart';

void main() {
  test('formatting preserves separators around consecutive disabled tags', () {
    const source = 'cat, /*disabled:long hair*/, /*disabled:blue eyes*/, dog';
    var formatted = source;
    for (var i = 0; i < 5; i++) {
      formatted = NaiPromptFormatter.format(formatted);
      expect(formatted, source);
    }
    expect(
      NaiPromptFormatter.format('/*disabled:cat*/, blue hair'),
      '/*disabled:cat*/, blue hair',
    );
  });

  group('NaiPromptFormatter.format', () {
    test('标签内部保留空格，并把下划线换成空格', () {
      expect(
        NaiPromptFormatter.format('soft dramatic lighting, blue eyes'),
        'soft dramatic lighting, blue eyes',
      );
      expect(
        NaiPromptFormatter.format('1.2::soft volumetric lighting::, solo'),
        '1.2::soft volumetric lighting::, solo',
      );
      expect(
        NaiPromptFormatter.format('soft_dramatic_lighting, blue_hair'),
        'soft dramatic lighting, blue hair',
      );
      expect(
        NaiPromptFormatter.format('au_ra, h&k_g11'),
        'au ra, h&k g11',
      );
    });

    test('表情类标签的下划线保持原样', () {
      const faces = [
        'x_x',
        'o_o',
        'O_o',
        '0_0',
        'T_T',
        '+_+',
        '._.',
        '^_^',
        '|_|',
        '@_@',
        '-_-',
        '>_<',
        '>_o',
        ';_;',
        '<o>_<o>',
      ];
      for (final face in faces) {
        expect(
          NaiPromptFormatter.format(face),
          face,
          reason: '表情标签 $face 不应被改写',
        );
      }
      // 混在正常标签里也要保护
      expect(
        NaiPromptFormatter.format('girl, x_x, blue_hair'),
        'girl, x_x, blue hair',
      );
    });

    test('格式化标签时保留换行、空行和行首缩进', () {
      const prompt = 'quality   tags， best quality,\n\n  blue hair, red eyes';

      expect(
        NaiPromptFormatter.format(prompt),
        'quality tags, best quality,\n\n  blue hair, red eyes',
      );
    });

    test('保留 CRLF 与各分组行末逗号', () {
      const prompt = 'subject tag,\r\nclothing tag,\r\nbackground tag';

      expect(
        NaiPromptFormatter.format(prompt),
        'subject tag,\r\nclothing tag,\r\nbackground tag',
      );
    });

    test('纯空白分隔行保持原样', () {
      const prompt = 'first tag\n  \nsecond tag';

      expect(NaiPromptFormatter.format(prompt), 'first tag\n  \nsecond tag');
    });

    test('格式化正负标签但不破坏 negative 块边界', () {
      const prompt =
          r'girl, alice \(wonderland\), negative(red hair, 1.2::blue eyes::)';

      expect(
        NaiPromptFormatter.format(prompt),
        r'girl, alice \(wonderland\), negative(red hair, 1.2::blue eyes::)',
      );
    });
  });
}
