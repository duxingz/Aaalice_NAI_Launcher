import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/utils/nai_prompt_formatter.dart';

/// 标签格式有两个方向，两个都要钉住：
/// - **下划线格式**（本改版默认，与官方一致）：标签内空格 → 下划线
/// - **空格格式**：标签内下划线 → 空格
///
/// 两种模式都保护表情类标签，也都不动花括号 / 竖线 / 尖括号旁与内部的空格。
String underscore(String input) =>
    NaiPromptFormatter.format(input, useUnderscores: true);

String space(String input) =>
    NaiPromptFormatter.format(input, useUnderscores: false);

void main() {
  test('本机没有设置时按默认走：下划线格式', () {
    expect(
      NaiPromptFormatter.format('long hair, blue eyes'),
      'long_hair, blue_eyes',
    );
  });

  group('下划线格式（默认）', () {
    test('标签内的空格换成下划线', () {
      expect(
        underscore('soft dramatic lighting, blue eyes'),
        'soft_dramatic_lighting, blue_eyes',
      );
      expect(underscore('au ra, h&k g11'), 'au_ra, h&k_g11');
    });

    test('权重语法照旧，只换标签内部的空格', () {
      expect(
        underscore('1.2::soft volumetric lighting::, solo'),
        '1.2::soft_volumetric_lighting::, solo',
      );
    });

    // 用户报的场景：danbooru 的消歧后缀里，括号属于标签本身，
    // 权重壳里的 `hong (white_spider)` 必须连成 `hong_(white_spider)`。
    test('括号属于标签本身，前面的空格也要连起来', () {
      expect(
        underscore('0.75::hong (white_spider)::, 0.7::loong (loong_blo)::'),
        '0.75::hong_(white_spider)::, 0.7::loong_(loong_blo)::',
      );
      expect(
        underscore('0.8::greatodoggo (rokudaime)::'),
        '0.8::greatodoggo_(rokudaime)::',
      );
      // 括号内部、以及括号在前的写法同样连起来
      expect(underscore('hong (white spider)'), 'hong_(white_spider)');
      expect(underscore('(white_spider) hong'), '(white_spider)_hong');
    });

    test('花括号、竖线、尖括号旁边与内部的空格保留', () {
      // `}` 紧邻的空格受保护，尖括号内部整段不动
      expect(underscore('{red|blue} hair'), '{red|blue} hair');
      expect(underscore('<alias name>, solo'), '<alias name>, solo');
      // 普通标签仍然转换
      expect(underscore('red hair, {a|b} c'), 'red_hair, {a|b} c');
    });

    test('冒号旁边的空格保留（text: 与权重壳写法）', () {
      expect(underscore('text: hello'), 'text: hello');
      expect(underscore('long hair ::, solo'), 'long_hair ::, solo');
      // 冒号后面紧跟内容时照旧连接
      expect(underscore('text:hello world'), 'text:hello_world');
    });

    test('已经写成下划线的标签保持原样', () {
      expect(underscore('long_hair, blue_eyes'), 'long_hair, blue_eyes');
    });

    test('前缀语法本身不动，只换它后面的词组', () {
      expect(underscore('text:hello world'), 'text:hello_world');
      expect(underscore('artist:foo bar, solo'), 'artist:foo_bar, solo');
      expect(underscore('1girl, rating:general'), '1girl, rating:general');
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
          underscore(face),
          face,
          reason: '表情标签 $face 不应被改写',
        );
        expect(space(face), face, reason: '空格格式也不该改写 $face');
      }
      expect(underscore('girl, x_x, blue_hair'), 'girl, x_x, blue_hair');
    });

    test('中文逗号、多余空格、行首缩进与换行都照旧整理', () {
      expect(
        underscore('quality   tags， best quality,\n\n  blue hair, red eyes'),
        'quality_tags, best_quality,\n\n  blue_hair, red_eyes',
      );
      expect(
        underscore('subject tag,\r\nclothing tag,\r\nbackground tag'),
        'subject_tag,\r\nclothing_tag,\r\nbackground_tag',
      );
      expect(underscore('first tag\n  \nsecond tag'), 'first_tag\n  \nsecond_tag');
    });

    test('禁用片段内部不格式化，边界逗号保留', () {
      const source = 'cat, /*disabled:long hair*/, /*disabled:blue eyes*/, dog';
      var formatted = source;
      for (var i = 0; i < 5; i++) {
        formatted = underscore(formatted);
        expect(formatted, source);
      }
      expect(
        underscore('/*disabled:cat*/, blue hair'),
        '/*disabled:cat*/, blue_hair',
      );
    });
  });

  group('空格格式（可选）', () {
    test('标签内部保留空格，并把下划线换成空格', () {
      expect(
        space('soft dramatic lighting, blue eyes'),
        'soft dramatic lighting, blue eyes',
      );
      expect(
        space('1.2::soft volumetric lighting::, solo'),
        '1.2::soft volumetric lighting::, solo',
      );
      expect(
        space('soft_dramatic_lighting, blue_hair'),
        'soft dramatic lighting, blue hair',
      );
      expect(space('au_ra, h&k_g11'), 'au ra, h&k g11');
    });

    test('表情类标签与混排', () {
      expect(space('girl, x_x, blue_hair'), 'girl, x_x, blue hair');
    });

    test('格式化标签时保留换行、空行和行首缩进', () {
      const prompt = 'quality   tags， best quality,\n\n  blue hair, red eyes';
      expect(space(prompt), 'quality tags, best quality,\n\n  blue hair, red eyes');
    });

    test('保留 CRLF 与各分组行末逗号', () {
      const prompt = 'subject tag,\r\nclothing tag,\r\nbackground tag';
      expect(space(prompt), 'subject tag,\r\nclothing tag,\r\nbackground tag');
    });

    test('纯空白分隔行保持原样', () {
      const prompt = 'first tag\n  \nsecond tag';
      expect(space(prompt), 'first tag\n  \nsecond tag');
    });

    test('格式化正负标签但不破坏 negative 块边界', () {
      const prompt =
          r'girl, alice \(wonderland\), negative(red hair, 1.2::blue eyes::)';
      expect(
        space(prompt),
        r'girl, alice \(wonderland\), negative(red hair, 1.2::blue eyes::)',
      );
    });

    test('禁用片段边界在空格格式下同样保留', () {
      const source = 'cat, /*disabled:long hair*/, /*disabled:blue eyes*/, dog';
      expect(space(source), source);
    });
  });

  test('formatTag 与 format 用同一套规则', () {
    expect(
      NaiPromptFormatter.formatTag('soft lighting', useUnderscores: true),
      'soft_lighting',
    );
    expect(
      NaiPromptFormatter.formatTag('soft_lighting', useUnderscores: false),
      'soft lighting',
    );
    expect(NaiPromptFormatter.formatTag('x_x', useUnderscores: true), 'x_x');
  });

  // 设置真能驱动格式化方向 —— 移植时最容易丢的就是这种「接线」。
  group('本机设置驱动格式化方向', () {
    late Directory hiveDirectory;
    late Box<dynamic> settings;

    setUp(() async {
      hiveDirectory = await Directory.systemTemp.createTemp('tag-format-');
      Hive.init(hiveDirectory.path);
      settings = await Hive.openBox(StorageKeys.settingsBox);
    });

    tearDown(() async {
      await Hive.close();
      await hiveDirectory.delete(recursive: true);
    });

    test('选「空格」时把下划线换成空格', () async {
      await settings.put(StorageKeys.bigmanPromptTagFormat, 'space');
      expect(
        NaiPromptFormatter.format('soft_dramatic_lighting, blue_hair'),
        'soft dramatic lighting, blue hair',
      );
    });

    test('选「下划线」时把空格换成下划线', () async {
      await settings.put(StorageKeys.bigmanPromptTagFormat, 'underscore');
      expect(
        NaiPromptFormatter.format('soft dramatic lighting, blue hair'),
        'soft_dramatic_lighting, blue_hair',
      );
    });

    test('设置缺失（老用户首次启动）时按默认下划线', () async {
      expect(
        NaiPromptFormatter.format('soft dramatic lighting'),
        'soft_dramatic_lighting',
      );
    });

    test('存储里是意料之外的值也退回下划线', () async {
      await settings.put(StorageKeys.bigmanPromptTagFormat, 'whatever');
      expect(
        NaiPromptFormatter.format('soft dramatic lighting'),
        'soft_dramatic_lighting',
      );
    });
  });
}
