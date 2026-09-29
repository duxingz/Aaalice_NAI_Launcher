import 'dart:convert';

import '../../../core/constants/api_constants.dart';
import '../../../data/models/image/image_params.dart';

/// 单个模型大版本记住的生成参数。
///
/// 只包含「跟模型走」的参数：采样器、步数、CFG、尺寸、噪声调度、Variety+、
/// SMEA、CFG Rescale 和 V5 专属的两个开关。提示词、负面词、角色、Vibe、
/// 参考图、种子属于「跟画面走」，一律不在这里换。
class ModelParamProfile {
  const ModelParamProfile({
    required this.sampler,
    required this.steps,
    required this.scale,
    required this.width,
    required this.height,
    required this.smea,
    required this.smeaDyn,
    required this.cfgRescale,
    required this.noiseSchedule,
    required this.varietyPlus,
    required this.transparentBackground,
    required this.e2eUpscale,
  });

  /// 从当前参数里取一份快照。
  factory ModelParamProfile.fromParams(ImageParams params) {
    return ModelParamProfile(
      sampler: params.sampler,
      steps: params.steps,
      scale: params.scale,
      width: params.width,
      height: params.height,
      smea: params.smea,
      smeaDyn: params.smeaDyn,
      cfgRescale: params.cfgRescale,
      noiseSchedule: params.noiseSchedule,
      varietyPlus: params.varietyPlus,
      transparentBackground: params.transparentBackground,
      e2eUpscale: params.e2eUpscale,
    );
  }

  /// 从 JSON 还原；任何字段缺失或类型不对都回退到 [ImageParams] 的默认值。
  static ModelParamProfile? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, dynamic>();
    const fallback = ImageParams();
    // 尺寸单独兜底：存档可能来自别的版本或云同步，0 或负数会画出 0×0 画布。
    final width = (json['width'] as num?)?.toInt() ?? fallback.width;
    final height = (json['height'] as num?)?.toInt() ?? fallback.height;
    return ModelParamProfile(
      sampler: json['sampler'] as String? ?? fallback.sampler,
      steps: (json['steps'] as num?)?.toInt() ?? fallback.steps,
      scale: (json['scale'] as num?)?.toDouble() ?? fallback.scale,
      width: width > 0 ? width : fallback.width,
      height: height > 0 ? height : fallback.height,
      smea: json['smea'] as bool? ?? fallback.smea,
      smeaDyn: json['smea_dyn'] as bool? ?? fallback.smeaDyn,
      cfgRescale: (json['cfg_rescale'] as num?)?.toDouble() ?? fallback.cfgRescale,
      noiseSchedule:
          json['noise_schedule'] as String? ?? fallback.noiseSchedule,
      varietyPlus: json['variety_plus'] as bool? ?? fallback.varietyPlus,
      transparentBackground:
          json['transparent_background'] as bool? ??
          fallback.transparentBackground,
      e2eUpscale: json['e2e_upscale'] as bool? ?? fallback.e2eUpscale,
    );
  }

  final String sampler;
  final int steps;
  final double scale;
  final int width;
  final int height;
  final bool smea;
  final bool smeaDyn;
  final double cfgRescale;
  final String noiseSchedule;
  final bool varietyPlus;
  final bool transparentBackground;
  final bool e2eUpscale;

  Map<String, Object?> toJson() => {
    'sampler': sampler,
    'steps': steps,
    'scale': scale,
    'width': width,
    'height': height,
    'smea': smea,
    'smea_dyn': smeaDyn,
    'cfg_rescale': cfgRescale,
    'noise_schedule': noiseSchedule,
    'variety_plus': varietyPlus,
    'transparent_background': transparentBackground,
    'e2e_upscale': e2eUpscale,
  };

  /// 把记住的参数套到 [params] 上。
  ///
  /// [params] 必须已经带上目标模型（`copyWith(model: …)` 之后），
  /// 因为下面两条纠正要按目标模型的能力位判定。
  ///
  /// 强制纠正与出厂默认跟随保持同一套规则：目标模型上不合法的噪声调度必须
  /// 归一，会静默生效的 Variety+ 必须关掉，否则界面显示的和实际发送的会对不上。
  ImageParams applyTo(ImageParams params) {
    final capabilities = params.capabilities;
    return params.copyWith(
      sampler: sampler,
      steps: steps,
      scale: scale,
      width: width,
      height: height,
      smea: smea,
      smeaDyn: smeaDyn,
      cfgRescale: cfgRescale,
      noiseSchedule: NoiseSchedules.resolve(
        noiseSchedule,
        allowNative: capabilities.allowsNativeNoiseSchedule,
      ),
      varietyPlus: capabilities.retainsVarietyPlus && varietyPlus,
      transparentBackground: transparentBackground,
      e2eUpscale: e2eUpscale,
    );
  }
}

/// 按桶名索引的模型参数记忆。
class ModelParamProfiles {
  const ModelParamProfiles(this._byBucket);

  static const ModelParamProfiles empty = ModelParamProfiles({});

  final Map<String, ModelParamProfile> _byBucket;

  bool get isEmpty => _byBucket.isEmpty;

  ModelParamProfile? operator [](String bucket) => _byBucket[bucket];

  ModelParamProfiles withBucket(String bucket, ModelParamProfile profile) {
    return ModelParamProfiles({..._byBucket, bucket: profile});
  }

  String encode() => jsonEncode({
    for (final entry in _byBucket.entries) entry.key: entry.value.toJson(),
  });

  /// 解析存档；结构损坏、字段缺失、不是对象都按「没有记忆」处理，绝不抛异常。
  ///
  /// 这份数据会经云同步跨设备回灌，必须能容忍别的版本写下的内容。
  static ModelParamProfiles decode(String? source) {
    if (source == null || source.isEmpty) return empty;
    try {
      final raw = jsonDecode(source);
      if (raw is! Map) return empty;
      final byBucket = <String, ModelParamProfile>{};
      raw.forEach((key, value) {
        if (key is! String) return;
        final profile = ModelParamProfile.tryFromJson(value);
        if (profile != null) byBucket[key] = profile;
      });
      return ModelParamProfiles(byBucket);
    } catch (_) {
      return empty;
    }
  }
}
