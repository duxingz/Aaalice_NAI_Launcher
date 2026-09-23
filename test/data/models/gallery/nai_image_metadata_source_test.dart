import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/gallery/nai_image_metadata.dart';

void main() {
  NaiImageMetadata withRaw(String raw) => NaiImageMetadata(rawJson: raw);

  group('生成来源判据（胖大叔自用改）', () {
    test('文生图：三种来源标记都为假', () {
      final meta = withRaw('{"request_type":"PromptGenerateRequest"}');
      expect(meta.isImg2ImgSource, isFalse);
      expect(meta.isInpaintSource, isFalse);
      expect(meta.isUpscaledSource, isFalse);
    });

    test('图生图：request_type 为 Img2ImgRequest', () {
      final meta = withRaw('{"request_type":"Img2ImgRequest"}');
      expect(meta.isImg2ImgSource, isTrue);
      expect(meta.isInpaintSource, isFalse);
    });

    test('局部重绘：request_type 为 NativeInfillingRequest', () {
      final meta = withRaw('{"request_type":"NativeInfillingRequest"}');
      expect(meta.isInpaintSource, isTrue);
      expect(meta.isImg2ImgSource, isFalse);
    });

    test('放大：request_type 含 upscale', () {
      final meta = withRaw('{"request_type":"UpscaleRequest"}');
      expect(meta.isUpscaledSource, isTrue);
    });

    test('放大：upscaled_enhance 为非空值', () {
      final meta = withRaw(
        '{"request_type":"Img2ImgRequest","upscaled_enhance":2}',
      );
      expect(meta.isUpscaledSource, isTrue);
      expect(meta.isImg2ImgSource, isTrue);
    });

    test('upscaled_enhance 为 null 时不算放大', () {
      final meta = withRaw(
        '{"request_type":"Img2ImgRequest","upscaled_enhance":null}',
      );
      expect(meta.isUpscaledSource, isFalse);
    });

    test('request_type 嵌在 Comment 里也能读到', () {
      final meta = withRaw(
        '{"Comment":"{\\"request_type\\":\\"NativeInfillingRequest\\"}"}',
      );
      expect(meta.requestType, 'NativeInfillingRequest');
      expect(meta.isInpaintSource, isTrue);
    });

    test('rawJson 缺失或损坏时安全返回假', () {
      expect(const NaiImageMetadata().requestType, isNull);
      expect(withRaw('').requestType, isNull);
      expect(withRaw('not json').requestType, isNull);
      expect(withRaw('not json').isImg2ImgSource, isFalse);
      expect(withRaw('{}').isUpscaledSource, isFalse);
    });

    test('旧字段 isImg2Img 仍算作图生图', () {
      expect(const NaiImageMetadata(isImg2Img: true).isImg2ImgSource, isTrue);
    });
  });
}
