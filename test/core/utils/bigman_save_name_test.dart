import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/bigman_save_name.dart';

void main() {
  BigmanSaveNameConfig config({
    String template = '{n}',
    int padding = 0,
    int start = 1,
    bool scanMode = false,
    bool autoDateFolder = true,
  }) {
    return BigmanSaveNameConfig(
      template: template,
      padding: padding,
      start: start,
      scanMode: scanMode,
      autoDateFolder: autoDateFolder,
    );
  }

  group('BigmanSaveNameConfig.formatName', () {
    test('纯序号模板按序号渲染', () {
      final value = config();
      expect(value.formatName(1), '1');
      expect(value.formatName(42), '42');
    });

    test('补零位数生效', () {
      final value = config(padding: 5);
      expect(value.formatName(1), '00001');
      expect(value.formatName(10000), '10000');
    });

    test('前缀与日期变量参与拼接', () {
      expect(config(template: '胖大叔_{n}').formatName(7), '胖大叔_7');
      expect(
        config(template: '{date}_{n}').formatName(3, time: DateTime(2026, 9, 17)),
        '2026-09-17_3',
      );
    });

    test('种子变量缺失时留空', () {
      final value = config(template: '{seed}_{n}');
      expect(value.formatName(1, seed: 12345), '12345_1');
      expect(value.formatName(1), '_1');
    });

    test('非法文件名字符被替换为下划线', () {
      expect(config(template: 'a/b:{n}').formatName(1), 'a_b_1');
    });

    test('模板不含序号时不参与扫描命名', () {
      expect(config(template: 'fixed').hasIndex, isFalse);
      expect(config().hasIndex, isTrue);
    });
  });

  group('BigmanSaveName.read', () {
    test('存储未就绪时返回 null，保持上游命名行为', () {
      expect(BigmanSaveName.read(), isNull);
    });
  });
}
