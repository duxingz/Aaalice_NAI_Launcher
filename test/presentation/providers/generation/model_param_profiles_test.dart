import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/constants/api_constants.dart';
import 'package:nai_launcher/data/models/image/image_params.dart';
import 'package:nai_launcher/presentation/providers/generation/model_param_profiles.dart';

void main() {
  group('ModelParamProfile', () {
    test('round-trips the params that follow the model', () {
      const params = ImageParams(
        model: ImageModels.animeDiffusionV45Full,
        sampler: Samplers.kDpmpp2sAncestral,
        steps: 31,
        scale: 6.5,
        width: 1216,
        height: 832,
        smea: false,
        smeaDyn: true,
        cfgRescale: 0.3,
        noiseSchedule: NoiseSchedules.exponential,
        varietyPlus: true,
        transparentBackground: true,
        e2eUpscale: true,
      );

      final profile = ModelParamProfile.fromParams(params);
      final decoded = ModelParamProfile.tryFromJson(profile.toJson());

      expect(decoded, isNotNull);
      expect(decoded!.sampler, Samplers.kDpmpp2sAncestral);
      expect(decoded.steps, 31);
      expect(decoded.scale, 6.5);
      expect(decoded.width, 1216);
      expect(decoded.height, 832);
      expect(decoded.smea, isFalse);
      expect(decoded.smeaDyn, isTrue);
      expect(decoded.cfgRescale, 0.3);
      expect(decoded.noiseSchedule, NoiseSchedules.exponential);
      expect(decoded.varietyPlus, isTrue);
      expect(decoded.transparentBackground, isTrue);
      expect(decoded.e2eUpscale, isTrue);
    });

    test('does not carry prompt, seed or references', () {
      final profile = ModelParamProfile.fromParams(
        const ImageParams(
          prompt: 'a cat',
          negativePrompt: 'lowres',
          model: ImageModels.animeDiffusionV5Full,
        ),
      );

      expect(profile.toJson().keys, isNot(contains('prompt')));
      expect(profile.toJson().keys, isNot(contains('negative_prompt')));
      expect(profile.toJson().keys, isNot(contains('seed')));
    });

    test('restores every remembered field onto the target model', () {
      final profile = ModelParamProfile.fromParams(
        const ImageParams(
          sampler: Samplers.kDpmpp2sAncestral,
          steps: 31,
          scale: 6.5,
          width: 1216,
          height: 832,
          smeaDyn: true,
          cfgRescale: 0.3,
          noiseSchedule: NoiseSchedules.exponential,
        ),
      );

      final restored = profile.applyTo(
        const ImageParams(model: ImageModels.animeDiffusionV45Full),
      );

      expect(restored.sampler, Samplers.kDpmpp2sAncestral);
      expect(restored.steps, 31);
      expect(restored.scale, 6.5);
      expect(restored.width, 1216);
      expect(restored.height, 832);
      expect(restored.smeaDyn, isTrue);
      expect(restored.cfgRescale, 0.3);
      expect(restored.noiseSchedule, NoiseSchedules.exponential);
    });

    test('normalizes a native noise schedule the target model rejects', () {
      const profile = ModelParamProfile(
        sampler: Samplers.kEulerAncestral,
        steps: 28,
        scale: 4.0,
        width: 832,
        height: 1216,
        smea: true,
        smeaDyn: false,
        cfgRescale: 0,
        noiseSchedule: NoiseSchedules.native,
        varietyPlus: false,
        transparentBackground: false,
        e2eUpscale: false,
      );

      final restored = profile.applyTo(
        const ImageParams(model: ImageModels.animeDiffusionV45Full),
      );

      expect(restored.noiseSchedule, NoiseSchedules.karras);
    });

    test('drops Variety+ for a model that does not retain it', () {
      const profile = ModelParamProfile(
        sampler: Samplers.kEulerAncestral,
        steps: 28,
        scale: 4.0,
        width: 832,
        height: 1216,
        smea: true,
        smeaDyn: false,
        cfgRescale: 0,
        noiseSchedule: NoiseSchedules.karras,
        varietyPlus: true,
        transparentBackground: false,
        e2eUpscale: false,
      );

      final restored = profile.applyTo(
        const ImageParams(model: ImageModels.animeDiffusionV5Full),
      );

      expect(restored.varietyPlus, isFalse);
    });

    test('fills missing json fields with the ImageParams defaults', () {
      final decoded = ModelParamProfile.tryFromJson({'scale': 6.0});

      expect(decoded, isNotNull);
      expect(decoded!.scale, 6.0);
      expect(decoded.steps, const ImageParams().steps);
      expect(decoded.sampler, const ImageParams().sampler);
    });

    test('rejects json that is not an object', () {
      expect(ModelParamProfile.tryFromJson('nope'), isNull);
      expect(ModelParamProfile.tryFromJson(const [1, 2]), isNull);
      expect(ModelParamProfile.tryFromJson(null), isNull);
    });

    test('rejects a non-positive stored size instead of a 0x0 canvas', () {
      final decoded = ModelParamProfile.tryFromJson({
        'width': 0,
        'height': -64,
      });

      expect(decoded, isNotNull);
      expect(decoded!.width, const ImageParams().width);
      expect(decoded.height, const ImageParams().height);
    });
  });

  group('ModelParamProfiles', () {
    test('starts empty and stores one profile per bucket', () {
      const profile = ModelParamProfile(
        sampler: Samplers.kEulerAncestral,
        steps: 28,
        scale: 4.0,
        width: 832,
        height: 1216,
        smea: true,
        smeaDyn: false,
        cfgRescale: 0,
        noiseSchedule: NoiseSchedules.karras,
        varietyPlus: false,
        transparentBackground: false,
        e2eUpscale: false,
      );

      expect(ModelParamProfiles.empty.isEmpty, isTrue);
      expect(ModelParamProfiles.empty['v5'], isNull);

      final stored = ModelParamProfiles.empty.withBucket('v5', profile);
      expect(stored['v5']?.steps, 28);
      expect(stored['v45'], isNull);
    });

    test('survives an encode/decode round-trip', () {
      const profile = ModelParamProfile(
        sampler: Samplers.kDpmpp2sAncestral,
        steps: 31,
        scale: 6.5,
        width: 1216,
        height: 832,
        smea: false,
        smeaDyn: true,
        cfgRescale: 0.3,
        noiseSchedule: NoiseSchedules.polyexponential,
        varietyPlus: true,
        transparentBackground: true,
        e2eUpscale: false,
      );

      final decoded = ModelParamProfiles.decode(
        ModelParamProfiles.empty.withBucket('v45', profile).encode(),
      );

      expect(decoded['v45']?.sampler, Samplers.kDpmpp2sAncestral);
      expect(decoded['v45']?.steps, 31);
      expect(decoded['v45']?.transparentBackground, isTrue);
    });

    test('treats missing or broken archives as no memory', () {
      expect(ModelParamProfiles.decode(null).isEmpty, isTrue);
      expect(ModelParamProfiles.decode('').isEmpty, isTrue);
      expect(ModelParamProfiles.decode('{not json').isEmpty, isTrue);
      expect(ModelParamProfiles.decode('[1,2,3]').isEmpty, isTrue);
      expect(ModelParamProfiles.decode('{"v5": 5}').isEmpty, isTrue);
    });

    test('skips only the broken entries of a partly valid archive', () {
      final decoded = ModelParamProfiles.decode(
        '{"v5": {"steps": 28}, "v45": "broken"}',
      );

      expect(decoded['v5']?.steps, 28);
      expect(decoded['v45'], isNull);
    });
  });
}
