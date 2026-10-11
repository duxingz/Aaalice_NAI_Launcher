import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/utils/bigman_save_name.dart';
import 'package:nai_launcher/presentation/providers/bigman/bigman_mod_settings.dart';
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

  // 用户报「每次扫描目录取最大号好像有问题」。根因：扫描用的正则只把 `{n}`
  // 换成了数字，其它占位符与非法字符都按**字面**匹配，于是模板一旦含
  // `{seed}` / `{date}` / `{time}` 或 `:` 这类会被净化的字符，就永远匹配不上，
  // 每次保存都从起始序号重来，文件靠 -2 -3 后缀叠起来。
  group('扫描模式要按模板实际写出来的样子匹配', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('bigman_scan_match_');
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> touch(String relative) async {
      final file = File(p.join(dir.path, relative));
      await file.parent.create(recursive: true);
      await file.writeAsBytes(const [0]);
    }

    BigmanSaveNameConfig config({
      String template = '{n}',
      int padding = 0,
      int start = 1,
    }) => BigmanSaveNameConfig(
      template: template,
      padding: padding,
      start: start,
      scanMode: true,
      autoDateFolder: false,
    );

    test('{n}：取整棵树（含日期子目录）里的最大号 +1', () async {
      await touch('1.png');
      await touch('2.png');
      await touch('5.png');
      await touch('2026-10-11/7.png');
      await touch('note.txt'); // 非 PNG 不参与
      await touch('12.jpg');

      expect(await config().resolveNextIndex(dir.path), 8);
    });

    test('{date}_{n}：按当天写出来的文件名匹配', () async {
      await touch('2026-10-11_3.png');
      await touch('2026-10-12_9.png');
      await touch('3.png'); // 不带日期的旧文件不该被算进去

      expect(
        await config(template: '{date}_{n}').resolveNextIndex(dir.path),
        10,
      );
    });

    test('{time}_{n}：按写出来的时间样式匹配', () async {
      await touch('21-30-05_4.png');
      await touch('09-00-00_6.png');

      expect(
        await config(template: '{time}_{n}').resolveNextIndex(dir.path),
        7,
      );
    });

    test('{n}_{seed}：种子有值取数字，解析不到时是空串', () async {
      await touch('1_12345.png');
      await touch('2_.png');

      expect(
        await config(template: '{n}_{seed}').resolveNextIndex(dir.path),
        3,
      );
    });

    test('{seed}_{n}：种子在前也能匹配', () async {
      await touch('12345_3.png');
      await touch('_4.png');

      expect(
        await config(template: '{seed}_{n}').resolveNextIndex(dir.path),
        5,
      );
    });

    test('模板里的非法字符按净化后的样子匹配', () async {
      // 渲染时 `:` 会变成 `_`，所以实际文件叫 a_b_20.png。
      await touch('a_b_20.png');
      await touch('a:b_99.png'); // 手写的非法名字不该被算进去

      expect(
        await config(template: 'a:b_{n}').resolveNextIndex(dir.path),
        21,
      );
    });

    test('前缀不匹配的文件不算数，退回起始序号', () async {
      await touch('1.png');
      await touch('99.png');

      expect(
        await config(template: '胖大叔_{n}').resolveNextIndex(dir.path),
        1,
      );

      await touch('胖大叔_9.png');
      expect(
        await config(template: '胖大叔_{n}').resolveNextIndex(dir.path),
        10,
      );
    });

    test('补零与起始序号照旧生效', () async {
      await touch('007.png');
      expect(await config(padding: 3).resolveNextIndex(dir.path), 8);

      await touch('3.png');
      expect(await config(start: 50).resolveNextIndex(dir.path), 50);
    });
  });

  // 2026-10-11 起「序号来源」默认是扫描（删掉号会被回收）：接收方期望的正是
  // 这个行为，而读取端与设置 provider 必须用同一个默认值，否则会再次出现
  // 「设置写着扫描、实际按全局计数走」的错位。
  group('序号来源的默认值', () {
    late Directory hiveDir;
    late Box<dynamic> settings;

    setUp(() async {
      hiveDir = await Directory.systemTemp.createTemp('counter-mode-hive-');
      Hive.init(hiveDir.path);
      settings = await Hive.openBox(StorageKeys.settingsBox);
    });

    tearDown(() async {
      await Hive.close();
      await hiveDir.delete(recursive: true);
    });

    test('没设置过时按扫描模式（与设置 provider 的默认一致）', () {
      final config = BigmanSaveName.read();
      expect(config, isNotNull);
      expect(config!.scanMode, isTrue);
      expect(
        const BigmanModSettings().saveNameCounterMode,
        BigmanSaveNameCounterMode.scan,
      );
    });

    test('显式选全局计数时按全局走', () async {
      await settings.put(
        StorageKeys.bigmanSaveNameCounterMode,
        BigmanSaveName.globalCounterMode,
      );
      expect(BigmanSaveName.read()!.scanMode, isFalse);
    });

    test('显式选扫描时按扫描走', () async {
      await settings.put(
        StorageKeys.bigmanSaveNameCounterMode,
        BigmanSaveName.scanCounterMode,
      );
      expect(BigmanSaveName.read()!.scanMode, isTrue);
    });
  });
}
