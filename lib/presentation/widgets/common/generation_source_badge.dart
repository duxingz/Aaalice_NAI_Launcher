import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../core/utils/localization_extension.dart';
import '../../../data/models/gallery/nai_image_metadata.dart';

/// 胖大叔自用改：缩略图右下角的「生成来源」文字角标。
///
/// 依据 NAI 元数据里的 `request_type` 判断这张图是怎么来的：
/// 图生图 / 局部重绘 / 放大。三者可以同时出现。
class GenerationSourceBadge extends StatelessWidget {
  const GenerationSourceBadge({
    super.key,
    this.metadata,
    this.requestType,
  });

  final NaiImageMetadata? metadata;

  /// 历史记录里的图是内存态、[metadata] 为 null，但生成时记下了来源。
  /// 两个来源二选一，优先用显式传入的 [requestType]。
  final String? requestType;

  /// 该图需要显示的角标文字；没有可识别来源时返回空列表。
  static List<String> labelsFor(
    NaiImageMetadata? metadata,
    AppLocalizations l10n, {
    String? requestType,
  }) {
    final type = requestType ?? metadata?.requestType;
    final labels = <String>[];
    final isImg2Img =
        metadata?.isImg2ImgSource == true || type == 'Img2ImgRequest';
    final isInpaint = type == 'NativeInfillingRequest';
    final isUpscaled =
        metadata?.isUpscaledSource == true ||
        (type != null && type.toLowerCase().contains('upscale'));
    if (isImg2Img) labels.add(l10n.bigmanMod_badgeImg2Img);
    if (isInpaint) labels.add(l10n.bigmanMod_badgeInpaint);
    if (isUpscaled) labels.add(l10n.bigmanMod_badgeUpscale);
    return labels;
  }

  @override
  Widget build(BuildContext context) {
    final labels = labelsFor(
      metadata,
      context.l10n,
      requestType: requestType,
    );
    if (labels.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final label in labels)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: _SourceBadgeChip(label: label),
            ),
        ],
      ),
    );
  }
}

class _SourceBadgeChip extends StatelessWidget {
  const _SourceBadgeChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 9, height: 1.2, color: Colors.white),
      ),
    );
  }
}
