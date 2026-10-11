import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/presentation/utils/dropped_file_reader.dart';
import 'package:nai_launcher/presentation/widgets/drop/global_drop_controller.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class _Event extends Mock implements PerformDropEvent {}

void main() {
  test(
    'native drop waits for acquisition but returns before destination dialog',
    () async {
      final acquired = Completer<List<DroppedFileData>>();
      final processing = Completer<void>();
      var processingStarted = false;
      var nativeCompleted = false;
      final controller = GlobalDropController(
        readDrop: (_) => acquired.future,
        processFile: (_) {
          processingStarted = true;
          return processing.future;
        },
      );
      addTearDown(controller.dispose);
      final native = controller
          .onPerformDrop(_Event())
          .then((_) => nativeCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(nativeCompleted, isFalse);
      acquired.complete([
        DroppedFileData(fileName: 'image.png', bytes: Uint8List(1)),
      ]);
      await native;
      expect(processingStarted, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(processingStarted, isTrue);
      expect(controller.isProcessing, isTrue);
      processing.complete();
      await Future<void>.delayed(Duration.zero);
      expect(controller.isProcessing, isFalse);
    },
  );

  test('reader failure is reported and releases processing state', () async {
    final controller = GlobalDropController(
      readDrop: (_) async => throw StateError('reader disposed'),
      processFile: (_) async {},
    );
    addTearDown(controller.dispose);

    // 不再向上抛：异常若逃进原生拖放层，只会被 super_drag_and_drop 的
    // handleError 当成「未处理错误」上报（在 logs/crash_diagnostics 留下转储），
    // 而原生侧拿到的返回值一样是 null。所以改成就地上报。
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previousOnError);

    await controller.onPerformDrop(_Event());

    expect(reported, hasLength(1));
    expect(reported.single.exception, isA<StateError>());
    expect(controller.isProcessing, isFalse);
  });
}
