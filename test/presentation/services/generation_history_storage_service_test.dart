import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:image/image.dart' as img;
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/utils/bigman_mod_flags.dart';
import 'package:nai_launcher/data/models/fixed_tag/fixed_tag_entry.dart';
import 'package:nai_launcher/data/models/fixed_tag/fixed_tag_prompt_type.dart';
import 'package:nai_launcher/data/models/fixed_tag/fixed_tag_usage_snapshot.dart';
import 'package:nai_launcher/presentation/providers/generation/generation_models.dart';
import 'package:nai_launcher/presentation/services/generation_history_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveDirectory;
  late Box<dynamic> historyBox;

  setUp(() async {
    hiveDirectory = await Directory.systemTemp.createTemp(
      'generation-history-storage-test-',
    );
    Hive.init(hiveDirectory.path);
    historyBox = await Hive.openBox<dynamic>(StorageKeys.historyBox);
  });

  tearDown(() async {
    await Hive.close();
    if (await hiveDirectory.exists()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  GeneratedImage image(String id, {int byte = 1}) {
    return GeneratedImage(
      id: id,
      bytes: Uint8List.fromList([byte, byte + 1, byte + 2]),
      width: 64,
      height: 96,
      createdAt: DateTime.utc(2026, 8, 26, 12, byte),
      filePath: '/images/$id.png',
      preserveOriginalBytesOnSave: true,
      fixedTagUsageSnapshot: const FixedTagUsageSnapshot(
        entries: [
          FixedTagUsageEntry(
            fixedTagId: 'fixed-a',
            name: 'A',
            content: 'masterpiece',
            weight: 1,
            renderedContent: 'masterpiece',
            position: FixedTagPosition.prefix,
            promptType: FixedTagPromptType.positive,
            order: 0,
          ),
        ],
      ),
    );
  }

  test(
    'persists records independently and restores their requested order',
    () async {
      final service = GenerationHistoryStorageService();
      final first = image('first', byte: 3);
      final second = image('second', byte: 7);

      await service.persistImages(
        changedImages: [first, second],
        order: [second.id, first.id],
      );
      await service.flush();

      final restored = await service.load();
      expect(restored.map((item) => item.id), ['second', 'first']);
      expect(restored.first.bytes, second.bytes);
      expect(restored.first.width, second.width);
      expect(restored.first.height, second.height);
      expect(restored.first.createdAt, second.createdAt);
      expect(restored.first.filePath, second.filePath);
      expect(restored.first.preserveOriginalBytesOnSave, isTrue);
      expect(
        restored.first.fixedTagUsageSnapshot?.entries.single.fixedTagId,
        'fixed-a',
      );
    },
  );

  test('comparison source is not persisted or restored with history', () async {
    final sourceBytes = Uint8List.fromList(
      img.encodePng(img.Image(width: 32, height: 48)),
    );
    final comparisonSource = ImageComparisonSource.fromBytes(sourceBytes);
    final persisted = GeneratedImage(
      id: 'comparison',
      bytes: Uint8List.fromList([1, 2, 3]),
      width: 64,
      height: 96,
      comparisonSource: comparisonSource,
    );
    final service = GenerationHistoryStorageService();

    await service.persistImages(
      changedImages: [persisted],
      order: [persisted.id],
    );
    await service.flush();

    final raw = Map<dynamic, dynamic>.from(
      historyBox.get('generation_history_v1_record_comparison') as Map,
    );
    expect(raw, isNot(contains('comparisonSource')));
    expect(raw, isNot(contains('comparisonSourceBytes')));

    final restored = await GenerationHistoryStorageService().load();
    expect(restored, hasLength(1));
    expect(restored.single.comparisonSource, isNull);
  });

  test('serializes overlapping writes and removes evicted records', () async {
    final service = GenerationHistoryStorageService();
    final first = image('first', byte: 1);
    final second = image('second', byte: 5);

    final initialWrite = service.persistImages(
      changedImages: [first],
      order: [first.id],
    );
    final replacementWrite = service.persistImages(
      changedImages: [second],
      order: [second.id],
    );
    await Future.wait([initialWrite, replacementWrite]);

    expect((await service.load()).map((item) => item.id), ['second']);
    expect(
      historyBox.keys.whereType<String>(),
      isNot(contains('generation_history_v1_record_first')),
    );
  });

  test('drops invalid and orphaned records while loading', () async {
    await historyBox.put('generation_history_v1_order', [
      'valid',
      'missing',
      'invalid',
    ]);
    await historyBox.put('generation_history_v1_record_valid', {
      'bytes': Uint8List.fromList([1, 2, 3]),
      'width': 32,
      'height': 48,
      'createdAt': DateTime.utc(2026, 8, 26).toIso8601String(),
      'kind': GeneratedImageKind.completed.name,
    });
    await historyBox.put('generation_history_v1_record_invalid', {
      'bytes': Uint8List(0),
      'width': 0,
      'height': 0,
    });
    await historyBox.put('generation_history_v1_record_orphan', {
      'bytes': Uint8List.fromList([9]),
      'width': 1,
      'height': 1,
    });

    final restored = await GenerationHistoryStorageService().load();

    expect(restored.map((item) => item.id), ['valid']);
    expect(historyBox.get('generation_history_v1_order'), ['valid']);
    expect(
      historyBox.containsKey('generation_history_v1_record_invalid'),
      isFalse,
    );
    expect(
      historyBox.containsKey('generation_history_v1_record_orphan'),
      isFalse,
    );
  });

  test('disabled storage remains a no-op', () async {
    final service = GenerationHistoryStorageService(enabled: false);

    await service.persistImages(
      changedImages: [image('ignored')],
      order: const ['ignored'],
    );
    await service.clear();

    expect(await service.load(), isEmpty);
    expect(historyBox.keys, isEmpty);
  });

  // 用户要求历史记录可扩到 100 / 150 / 200，且「最大档位也要能正常运转」。
  // 内存侧与落盘侧读的是同一个开关，这里钉住落盘侧的上限与兜底。
  group('历史保留张数档位（胖大叔自用改）', () {
    late Box<dynamic> settingsBox;

    setUp(() async {
      settingsBox = await Hive.openBox<dynamic>(StorageKeys.settingsBox);
    });

    Future<void> setLimit(int? value) async {
      if (value == null) {
        await settingsBox.delete(StorageKeys.bigmanHistoryLimit);
        return;
      }
      await settingsBox.put(StorageKeys.bigmanHistoryLimit, value);
    }

    test('未设置时按默认 50 档', () async {
      expect(GenerationHistoryStorageService.maxEntries, 50);
      expect(BigmanModFlags.historyLimit(), 50);
    });

    test('非法值（手改存储）回落到默认档', () async {
      await setLimit(9999);
      expect(GenerationHistoryStorageService.maxEntries, 50);

      await setLimit(-1);
      expect(GenerationHistoryStorageService.maxEntries, 50);
    });

    for (final option in BigmanModFlags.historyLimitOptions) {
      test('第 $option 档：落盘刚好保留 $option 张，一张不多不少', () async {
        await setLimit(option);
        expect(GenerationHistoryStorageService.maxEntries, option);

        final service = GenerationHistoryStorageService();
        final images = [
          for (var index = 0; index < option; index++)
            image('h$index', byte: index % 200),
        ];
        final order = [for (final item in images) item.id];

        await service.persistImages(changedImages: images, order: order);
        await service.flush();

        final restored = await service.load();
        expect(restored, hasLength(option));
        expect(restored.map((item) => item.id), order);
      });
    }

    test('超出上限时保留最新的 N 张，淘汰最老的记录键', () async {
      await setLimit(50);
      final service = GenerationHistoryStorageService();
      // 按新的在前排列：第 0 个是最新的一张。
      final order = [for (var index = 0; index < 60; index++) 'r$index'];

      await service.persistImages(
        changedImages: [for (final id in order) image(id)],
        order: order,
      );
      await service.flush();

      final restored = await service.load();
      expect(restored, hasLength(50));
      expect(restored.first.id, 'r0');
      expect(restored.last.id, 'r49');
      expect(
        historyBox.containsKey('generation_history_v1_record_r59'),
        isFalse,
      );
    });

    test('从 200 档调回 50 档后，多出来的记录在下次加载时被清掉', () async {
      await setLimit(200);
      final service = GenerationHistoryStorageService();
      final order = [for (var index = 0; index < 120; index++) 's$index'];

      await service.persistImages(
        changedImages: [for (final id in order) image(id)],
        order: order,
      );
      await service.flush();
      expect(await service.load(), hasLength(120));

      await setLimit(50);
      final restored = await GenerationHistoryStorageService().load();

      expect(restored, hasLength(50));
      expect(
        historyBox.containsKey('generation_history_v1_record_s50'),
        isFalse,
      );
    });
  });
}
