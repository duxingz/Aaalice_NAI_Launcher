import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../../data/models/image/image_params.dart';

enum GenerationPreparationKind { generate, queue }

enum GenerationPreparationStatus { prepared, submitted, cancelled }

enum GenerationSavePathSource { caller, galleryOriginal }

extension GenerationSavePathSourceWire on GenerationSavePathSource {
  /// 模型侧键值统一 snake_case，不跟随 Dart 枚举名。
  String get wireName => switch (this) {
    GenerationSavePathSource.caller => 'caller',
    GenerationSavePathSource.galleryOriginal => 'gallery_original',
  };
}

class GenerationPreparation {
  GenerationPreparation({
    required this.kind,
    required this.baseParams,
    required this.params,
    required this.batchSize,
    required this.count,
    required this.autoStart,
    required this.estimatedAnlas,
    required this.arguments,
    this.charactersInherited = 0,
    this.savePath,
    this.savePathSource,
    this.sourceImage,
    this.maskImage,
  }) : id = const Uuid().v4(),
       createdAt = DateTime.now();

  final String id;
  final DateTime createdAt;
  final GenerationPreparationKind kind;
  final ImageParams baseParams;
  final ImageParams params;
  final int batchSize;
  final int count;
  final bool autoStart;
  final int estimatedAnlas;
  final Map<String, dynamic> arguments;

  /// 从编辑器继承来的角色数。>0 说明这次「省略 characters」被解释成了继承 ——
  /// 队列批量最容易踩（一批图全跑成别的角色）。显式传 characters 或
  /// `inherit_characters: false` 时是 0。
  final int charactersInherited;
  final String? savePath;

  /// null 表示这次既不落盘也不引用原图。
  final GenerationSavePathSource? savePathSource;
  final Uint8List? sourceImage;
  final Uint8List? maskImage;
  GenerationPreparationStatus status = GenerationPreparationStatus.prepared;

  Map<String, dynamic> toJson() {
    // 回显实际会发送的参数：模型固定的步数、采样器与负面词以覆盖后为准。
    final request = params.resolveFixedSettings();
    return {
      'ok': true,
      'preparation_id': id,
      'status': status.name,
      'operation': kind.name,
      'estimated_anlas': estimatedAnlas,
      // 0 是**真实估算**（多半是订阅覆盖了该模型）；算不出来走 invalid_cost
      // 错误，不会伪装成 0。没有这句话时调用方无法区分这两件事。
      if (estimatedAnlas == 0)
        'anlas_note':
            'computed_zero (subscription may cover this model; an '
            'uncomputable estimate is reported as invalid_cost instead)',
      'count': count,
      'batch_size': batchSize,
      'auto_start': autoStart,
      // 永远回显：>0 表示这次「省略 characters」其实是继承了编辑器里的角色。
      'characters_inherited': charactersInherited,
      if (savePath != null) 'save_path': savePath,
      if (savePathSource != null) 'save_path_source': savePathSource!.wireName,
      'parameters': {
        'prompt': request.prompt,
        'negative_prompt': request.negativePrompt,
        'model': request.model,
        'width': request.width,
        'height': request.height,
        'steps': request.steps,
        'sampler': request.sampler,
        'scale': request.scale,
        'seed': request.seed,
        'action': request.action.value,
        'character_layout_mode': request.useCoords ? 'custom' : 'ai_choice',
        'character_count': request.characters.length,
        'characters': [
          for (var index = 0; index < request.characters.length; index++)
            {
              'order': index,
              'prompt': request.characters[index].prompt,
              'negative_prompt': request.characters[index].negativePrompt,
              if (request.useCoords)
                'center': {
                  'x': request.characters[index].positionX,
                  'y': request.characters[index].positionY,
                },
            },
        ],
        if (sourceImage != null) 'has_source_image': true,
        if (maskImage != null) 'has_mask_image': true,
      },
      'confirmation_required':
          status == GenerationPreparationStatus.prepared && estimatedAnlas != 0,
    };
  }
}

/// In-memory transaction store owned by the Agent runtime, not by a tool list.
/// Rebuilding tools therefore cannot discard an outstanding confirmation.
class GenerationPreparationRuntime {
  final Map<String, GenerationPreparation> _preparations = {};

  GenerationPreparation add(GenerationPreparation preparation) {
    _preparations[preparation.id] = preparation;
    return preparation;
  }

  GenerationPreparation? get(String id) => _preparations[id];

  bool cancel(String id) {
    final preparation = _preparations[id];
    if (preparation == null ||
        preparation.status != GenerationPreparationStatus.prepared) {
      return false;
    }
    preparation.status = GenerationPreparationStatus.cancelled;
    return true;
  }
}
