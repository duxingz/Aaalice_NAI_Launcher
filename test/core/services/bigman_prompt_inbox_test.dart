import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/services/bigman_prompt_inbox.dart';

void main() {
  group('无标记 → 整份进正面', () {
    test('两段内容都填正面', () {
      final payload = BigmanPromptInbox.parse('1girl, blue hair\n\nShe stands.');
      expect(payload.positive, '1girl, blue hair\n\nShe stands.');
      expect(payload.negative, isNull);
      expect(payload.characters, isEmpty);
    });

    test('容忍 BOM', () {
      expect(BigmanPromptInbox.parse('\uFEFF1girl').positive, '1girl');
    });

    test('空白内容视为空', () {
      expect(BigmanPromptInbox.parse('   \n  ').isEmpty, isTrue);
    });
  });

  group('有标记 → 按区分别填', () {
    test('正面与负面分开', () {
      final payload = BigmanPromptInbox.parse(
        '---POSITIVE---\n1girl, blue hair\n---NEGATIVE---\nlowres\n',
      );
      expect(payload.positive, '1girl, blue hair');
      expect(payload.negative, 'lowres');
      expect(payload.characters, isEmpty);
    });

    test('角色块可以带名字', () {
      final payload = BigmanPromptInbox.parse(
        '---CHARACTER:艾玛---\ngirl, sakuraba ema\n'
        '---CHARACTER:胖大叔---\nboy, fat man\n',
      );
      expect(payload.characters.length, 2);
      expect(payload.characters[0].name, '艾玛');
      expect(payload.characters[0].prompt, 'girl, sakuraba ema');
      expect(payload.characters[1].name, '胖大叔');
      expect(payload.characters[1].prompt, 'boy, fat man');
    });

    test('角色块不带名字时自动命名', () {
      final payload = BigmanPromptInbox.parse('---CHARACTER---\ngirl');
      expect(payload.characters.single.name, '角色 1');
    });

    test('DESCRIPTION 归入正面', () {
      final payload = BigmanPromptInbox.parse(
        '---POSITIVE---\n1girl\n---DESCRIPTION---\nShe stands.\n',
      );
      expect(payload.positive, '1girl\n\nShe stands.');
    });

    test('只给正面时不动负面与角色（返回 null/空）', () {
      final payload = BigmanPromptInbox.parse('---POSITIVE---\n1girl');
      expect(payload.positive, '1girl');
      expect(payload.negative, isNull);
      expect(payload.characters, isEmpty);
    });

    test('标记大小写不敏感', () {
      expect(
        BigmanPromptInbox.parse('---positive---\n1girl').positive,
        '1girl',
      );
      expect(
        BigmanPromptInbox.parse('---Negative---\nlowres').negative,
        'lowres',
      );
    });

    test('标记两侧容忍空白', () {
      final payload = BigmanPromptInbox.parse(
        '  ---POSITIVE---  \n1girl\n',
      );
      expect(payload.positive, '1girl');
    });

    test('完整分区示例', () {
      final payload = BigmanPromptInbox.parse('''
---POSITIVE---
1girl, sakuraba ema, blue hair

---NEGATIVE---
lowres, bad anatomy

---CHARACTER:艾玛---
girl, sakuraba ema, blue hair

---CHARACTER---
boy, fat man
''');
      expect(payload.positive, '1girl, sakuraba ema, blue hair');
      expect(payload.negative, 'lowres, bad anatomy');
      expect(payload.characters.length, 2);
      expect(payload.characters[0].name, '艾玛');
      expect(payload.characters[1].name, '角色 2');
    });
  });

  test('digestOf 对相同内容稳定、不同内容不同', () {
    expect(
      BigmanPromptInbox.digestOf('abc'),
      BigmanPromptInbox.digestOf('abc'),
    );
    expect(
      BigmanPromptInbox.digestOf('abc'),
      isNot(BigmanPromptInbox.digestOf('abd')),
    );
  });

  test('readFile 读不到时返回 null 而不是抛异常', () async {
    expect(
      await BigmanPromptInbox.readFile(
        r'D:\workwork\_naitmp\__not_exist__.txt',
      ),
      isNull,
    );
  });
}
