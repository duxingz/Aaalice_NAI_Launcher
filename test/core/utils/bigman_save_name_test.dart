import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/bigman_save_name.dart';
import 'package:path/path.dart' as p;

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

  group('扫描序号的上限按总条目计数（胖大叔自用改）', () {
    // 从前上限只数 PNG：保存根目录指向混放目录（图片和其它文件在一起、
    // 或网盘同步目录）时，上限永远不触发，每次保存都要把整棵树走一遍，
    // 表现就是「点保存后卡住」。
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bigman_scan_cap_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('预算耗尽后连 PNG 都不再检查', () async {
      // 目录里只有一个条目，而且它正是能吃满编号的 PNG。
      await File(p.join(dir.path, '5.png')).writeAsBytes(const [0]);

      // 上限 0 → 第一个条目就把预算用光，PNG 不会被读取。
      // 旧实现只数 PNG，这条会得到 6；按总条目计数才会得到起始序号。
      final capped = await config(scanMode: true).resolveNextIndex(
        dir.path,
        entryLimit: 0,
      );
      expect(capped, 1);

      // 预算充足时同一个目录能取到最大编号，证明 PNG 是可被识别的。
      final full = await config(scanMode: true).resolveNextIndex(dir.path);
      expect(full, 6);
    });

    test('目录不存在时退回起始序号', () async {
      final missing = p.join(dir.path, 'nope');
      final value = await config(scanMode: true).resolveNextIndex(missing);
      expect(value, 1);
    });
  });
}
