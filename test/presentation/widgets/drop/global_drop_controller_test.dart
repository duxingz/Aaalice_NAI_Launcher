import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/presentation/utils/dropped_file_reader.dart';
import 'package:nai_launcher/presentation/widgets/drop/global_drop_controller.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class _Event extends Mock implements PerformDropEvent {}

void main() {
  test('native drop issues the read and returns before acquisition', () async {
    final acquired = Completer<List<DroppedFileData>>();
    final processing = Completer<void>();
    var readIssued = false;
    var processingStarted = false;
    final controller = GlobalDropController(
      readDrop: (_) {
        readIssued = true;
        return acquired.future;
      },
      processFile: (_) {
        processingStarted = true;
        return processing.future;
      },
    );
    addTearDown(controller.dispose);

    final native = controller.onPerformDrop(_Event());
    expect(readIssued, isTrue);
    // 本改版：先把原生拖放会话里的数据取完再返回，否则会话结束后读不到；
    // 但真正的处理要放到事件循环之后，避免在拖放回调里开对话框。
    await Future<void>.delayed(Duration.zero);
    expect(controller.isProcessing, isTrue);
    expect(processingStarted, isFalse);

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
  });

  test('reader failure is reported and releases processing state', () async {
    final reported = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = reported.add;
    addTearDown(() => FlutterError.onError = previousOnError);
    final controller = GlobalDropController(
      readDrop: (_) async => throw StateError('reader disposed'),
      processFile: (_) async {},
    );
    addTearDown(controller.dispose);

    // 不再向上抛：异常若逃进原生拖放层，只会被 super_drag_and_drop 的
    // handleError 当成「未处理错误」上报（在 logs/crash_diagnostics 留下转储），
    // 而原生侧拿到的返回值一样是 null。所以改成就地上报。

    await controller.onPerformDrop(_Event());

    expect(reported, hasLength(1));
    expect(reported.single.exception, isA<StateError>());
    expect(controller.isProcessing, isFalse);
    expect(reported.single.exception, isA<StateError>());
    expect(reported.single.library, 'GlobalDropController');
  });
}