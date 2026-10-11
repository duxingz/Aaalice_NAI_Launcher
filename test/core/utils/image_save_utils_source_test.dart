import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/utils/image_save_utils.dart';
import 'package:nai_launcher/data/models/gallery/nai_image_metadata.dart';
import 'package:nai_launcher/data/models/image/image_params.dart';

void main() {
  Map<String, dynamic> commentFor(ImageParams params) =>
      ImageSaveUtils.buildCommentJson(params: params, actualSeed: 123);

  ImageParams imageParams({
    ImageGenerationAction action = ImageGenerationAction.generate,
    bool withSource = false,
    bool withMask = false,
    bool upscaledEnhance = false,
  }) {
    return ImageParams(
      action: action,
      sourceImage: withSource ? Uint8List(4) : null,
      maskImage: withMask ? Uint8List(4) : null,
      upscaledEnhance: upscaledEnhance,
    );
  }

  group('生成来源写进元数据（胖大叔自用改）', () {
    test('普通文生图 -> PromptGenerateRequest', () {
      expect(commentFor(imageParams())['request_type'], 'PromptGenerateRequest');
    });

    test('图生图 -> Img2ImgRequest', () {
      final json = commentFor(
        imageParams(action: ImageGenerationAction.img2img, withSource: true),
      );
      expect(json['request_type'], 'Img2ImgRequest');
    });

    test('局部重绘 -> NativeInfillingRequest', () {
      final json = commentFor(
        imageParams(
          action: ImageGenerationAction.infill,
          withSource: true,
          withMask: true,
        ),
      );
      expect(json['request_type'], 'NativeInfillingRequest');
    });

    test('放大 -> UpscaleRequest 且带 upscaled_enhance', () {
      final json = commentFor(imageParams(upscaledEnhance: true));
      expect(json['request_type'], 'UpscaleRequest');
      expect(json['upscaled_enhance'], isNotNull);
    });

    test('写出的元数据能被角标判据读回来', () {
      final json = commentFor(
        imageParams(
          action: ImageGenerationAction.infill,
          withSource: true,
          withMask: true,
        ),
      );
      final meta = NaiImageMetadata(rawJson: jsonEncode(json));
      expect(meta.requestType, 'NativeInfillingRequest');
      expect(meta.isInpaintSource, isTrue);
      expect(meta.isImg2ImgSource, isFalse);
    });

    test('图生图的元数据同样能读回来', () {
      final json = commentFor(
        imageParams(action: ImageGenerationAction.img2img, withSource: true),
      );
      final meta = NaiImageMetadata(rawJson: jsonEncode(json));
      expect(meta.isImg2ImgSource, isTrue);
      expect(meta.isInpaintSource, isFalse);
    });
  });
}
