import 'image_card_frame.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import 'image_viewport_surface.dart';
import '../../adaptive/interaction_policy.dart';
import '../../../core/utils/localization_extension.dart';
import '../../themes/theme_extension.dart';
import 'animated_favorite_button.dart';
import 'card_action_buttons.dart';
import 'decoded_memory_image.dart';
import 'image_card_actions.dart';
import 'image_card_action_dispatch.dart';
import 'image_card_controller.dart';
import 'image_card_effects.dart';
import 'image_card_models.dart';
import 'image_card_stream_preview.dart';

class ImageCardSurface extends StatelessWidget {
  const ImageCardSurface({
    super.key,
    required this.data,
    required this.capabilities,
    required this.controller,
    required this.actions,
    required this.onShowContextMenu,
    required this.onWarmShareCache,
  });

  final ImageCardViewData data;
  final ImageCardCapabilities capabilities;
  final ImageCardController controller;
  final List<ImageCardAction> actions;
  final Future<void> Function(Offset position) onShowContextMenu;
  final VoidCallback onWarmShareCache;

  @override
  Widget build(BuildContext context) {
    if (data.imageBytes == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => _buildSurface(context),
    );
  }

  Widget _buildSurface(BuildContext context) {
    final theme = Theme.of(context);
    final motion = theme.appTheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final interaction = context.interactionPolicy;
    final pinnedIds = capabilities.pinnedHoverActions;
    final hoverActions = capabilities.showHoverActionBar
        ? actions
              .where(
                (action) =>
                    action.showOnHover && !pinnedIds.contains(action.id),
              )
              .toList()
        : const <ImageCardAction>[];
    final showHoverBar =
        controller.isHovering &&
        hoverActions.isNotEmpty &&
        !capabilities.selectionMode;
    final pinnedActions =
        controller.isHovering && !interaction.usesTouchActionMenu
        ? [
            for (final id in pinnedIds)
              ...actions.where((action) => action.id == id && action.visible),
          ]
        : const <ImageCardAction>[];
    final showIndexBadge =
        data.dragPreparationReady &&
        controller.showPreparedIndexBadge &&
        data.showIndex &&
        data.index != null &&
        !controller.isHovering;

    return MouseRegion(
      onEnter: (_) => controller.hoverEnter(warmShareCache: onWarmShareCache),
      onExit: (_) => controller.hoverExit(),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: capabilities.onDoubleTap == null
            ? controller.handleLegacyTap
            : null,
        onTapUp: capabilities.onDoubleTap != null
            ? controller.handleLinkedTapUp
            : null,
        onLongPressStart:
            capabilities.onLongPress != null || capabilities.enableContextMenu
            ? (details) {
                controller.clearPendingDoubleTap();
                if (capabilities.onLongPress != null) {
                  capabilities.onLongPress!.call();
                } else {
                  unawaited(onShowContextMenu(details.globalPosition));
                }
              }
            : null,
        // 必须抬起后弹菜单：按住时 push 会合成 touch 取消事件，令 DraggableWidget 整批重建闪烁
        onSecondaryTapUp: capabilities.enableContextMenu
            ? (details) => unawaited(onShowContextMenu(details.globalPosition))
            : null,
        child: ImageCardFrame(
          hovered: controller.isHovering,
          selected: data.isSelected,
          previewActive: data.isPreviewActive,
          restingShadow: true,
          hoverScaleEnabled: capabilities.enableHoverScale,
          animate: capabilities.hoverEffectsEnabled,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (data.imageContent != null && data.underlay != null)
                data.underlay!,
              RepaintBoundary(
                child: data.imageContent ?? _completedImage(theme),
              ),
              _DragPreparationOverlay(data: data, controller: controller),
              if (controller.isHovering && capabilities.enableGlossEffect)
                Positioned.fill(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: reducedMotion
                        ? Duration.zero
                        : motion.fastDuration,
                    curve: motion.standardCurve,
                    builder: (context, glowIntensity, _) => AnimatedBuilder(
                      animation: controller.glossAnimation,
                      builder: (context, _) => ImageCardEffects(
                        glowColor: theme.colorScheme.primary,
                        glowIntensity: glowIntensity,
                        glossProgress: controller.glossAnimation.value,
                      ),
                    ),
                  ),
                ),
              if (controller.isHovering || data.isSelected)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.center,
                        colors: [
                          Colors.black.withValues(alpha: 0.4),
                          Colors.transparent,
                        ],
                      ),
                    ),
                  ),
                ),
              if (data.statusBadgeLabel != null)
                Positioned(top: 8, left: 8, child: _StatusBadge(data: data)),
              if (capabilities.enableSelection &&
                  data.statusBadgeLabel == null &&
                  (capabilities.selectionMode ||
                      (capabilities.showSelectionOnHover &&
                          controller.isHovering) ||
                      data.isSelected))
                Positioned(
                  top: 8,
                  left: 8,
                  child: _SelectionCheckbox(
                    selected: data.isSelected,
                    onChanged: capabilities.onSelectionChanged,
                  ),
                ),
              if (!capabilities.selectionMode &&
                  (capabilities.onFavoriteToggle != null ||
                      pinnedActions.isNotEmpty))
                Positioned(
                  top: 8,
                  right: 8,
                  child: ImageCardCornerActionRail(
                    pinnedActions: pinnedActions,
                    favorite: capabilities.onFavoriteToggle == null
                        ? null
                        : CardFavoriteButton(
                            isFavorite: data.isFavorite,
                            onToggle: () => unawaited(
                              dispatchImageCardAction(
                                context,
                                actions.firstWhere(
                                  (a) => a.id == ImageCardActionId.favorite,
                                ),
                              ),
                            ),
                            size: 16,
                            borderRadius: 999,
                          ),
                  ),
                ),
              if (showHoverBar)
                Positioned(
                  bottom: 12,
                  left: 0,
                  right: 0,
                  child: ImageCardHoverActionBar(actions: hoverActions),
                ),
              Positioned(
                bottom: 8,
                left: 8,
                child: Offstage(
                  key: const ValueKey('selectable-image-index-badge-offstage'),
                  offstage: !showIndexBadge,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      data.index == null ? '' : '${data.index! + 1}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
              if (data.isSelected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              // 悬停条在触屏菜单模式下自带「更多」，不显示悬停条时这里必须补上入口。
              if (interaction.usesTouchActionMenu &&
                  (!showHoverBar || interaction.prefersTouchPresentation) &&
                  capabilities.enableContextMenu &&
                  actions.isNotEmpty)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: IconButton(
                    onPressed: () => unawaited(onShowContextMenu(Offset.zero)),
                    tooltip: context.l10n.common_moreActions,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    style: ImageOverlayControlStyle.iconButton(
                      context,
                      extent: 48,
                    ),
                    icon: const Icon(Icons.more_horiz_rounded),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _completedImage(ThemeData theme) {
    return DecodedMemoryImage(
      key: const ValueKey('selectable-image-content'),
      bytes: data.imageBytes!,
      fit: BoxFit.cover,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
          _composeCompletedImage(
            theme: theme,
            ready: frame != null || wasSynchronouslyLoaded,
            child: controller.completedImageFrameBuilder(
              context,
              child,
              frame,
              wasSynchronouslyLoaded,
            ),
          ),
      errorBuilder: (context, _, _) => const SizedBox.shrink(),
    );
  }

  /// 首帧之前继续画生成中卡片的最后一帧，不铺底层，避免闪出棋盘格。
  Widget _composeCompletedImage({
    required ThemeData theme,
    required bool ready,
    required Widget child,
  }) {
    // 换源会把 frame 归零，但旧帧仍在 gapless 画，此时藏底层会让透明区闪一下。
    final showsImage = ready || controller.hasPaintedCompletedImage;
    final holdover = controller.effectiveCompletionPreview;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (!showsImage) ...[
          if (holdover != null)
            ImageCardStreamPreview(
              previewBytes: holdover.bytes,
              placement: holdover.placement,
            )
          // 只有铺了底层的卡片需要兜底色遮住它，其余卡片首帧前保持原本的空白。
          else if (data.underlay != null)
            const ColoredBox(color: ImageViewportSurface.background),
        ],
        if (showsImage && data.underlay != null) data.underlay!,
        child,
      ],
    );
  }
}

class ImageCardHoverActionBar extends StatelessWidget {
  const ImageCardHoverActionBar({super.key, required this.actions});
  final List<ImageCardAction> actions;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      key: const ValueKey('image-card-hover-action-bar-surface'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ImageOverlayControlStyle.toolbarSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ImageOverlayControlStyle.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CardActionButtons(
        buttons: actions,
        visible: true,
        pointerExtent: 40,
      ),
    ),
  );
}

/// 右上角操作轨：悬停动作按顺序排在常驻收藏左侧，收藏位置不随悬停移动。
///
/// 卡片过窄时按优先级少显示：轨道靠右锚定，放不下就会画到卡片外、或压住
/// 左上角的多选框，所以宁可少一个。舍弃顺序（越靠前越先丢）：
/// 图生图 → 保存 → 复制；**删除与收藏始终保留**。
class ImageCardCornerActionRail extends StatelessWidget {
  const ImageCardCornerActionRail({
    super.key,
    required this.pinnedActions,
    this.favorite,
  });

  static const _extent = 40.0;
  static const _spacing = 4.0;

  /// 左侧要避开的宽度：多选框 40 + 左内边距 8 + 与轨道的间隙 8。
  static const _leadingReserve = 56.0;

  /// 常驻收藏的预留宽度（触屏命中区 48 是它的最大值）。
  static const _favoriteReserve = 48.0;

  /// 放不下时最先舍弃的动作，越靠前越先丢。
  static const _dropOrder = <ImageCardActionId>[
    ImageCardActionId.imageToImage,
    ImageCardActionId.save,
    ImageCardActionId.copy,
  ];

  final List<ImageCardAction> pinnedActions;
  final Widget? favorite;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      key: const ValueKey('image-card-corner-action-rail'),
      mainAxisSize: MainAxisSize.min,
      spacing: _spacing,
      children: [
        for (final action in _fitting(constraints.maxWidth))
          ImageCardOverlayActionButton(config: action, extent: _extent),
        if (favorite case final favorite?) favorite,
      ],
    ),
  );

  /// 当前宽度放得下的那些固定动作（保持原有顺序）。
  List<ImageCardAction> _fitting(double maxWidth) {
    if (maxWidth.isInfinite) return pinnedActions;
    final reserved =
        _leadingReserve + (favorite == null ? 0 : _favoriteReserve);
    final available = maxWidth - reserved;
    final visible = List<ImageCardAction>.of(pinnedActions);
    while (visible.isNotEmpty) {
      final needed =
          visible.length * _extent +
          (visible.length - 1) * _spacing +
          (favorite == null ? 0 : _spacing);
      if (needed <= available) break;
      final victim = _dropOrder.firstWhere(
        (id) => visible.any((action) => action.id == id),
        orElse: () => visible.last.id,
      );
      visible.removeWhere((action) => action.id == victim);
    }
    return visible;
  }
}

class _DragPreparationOverlay extends StatelessWidget {
  const _DragPreparationOverlay({required this.data, required this.controller});
  final ImageCardViewData data;
  final ImageCardController controller;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          key: const ValueKey('drag-preparation-preview-overlay-opacity'),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : ImageCardController.dragPreparationOverlayFadeDuration,
          curve: Theme.of(context).appTheme.standardCurve,
          opacity: data.dragPreparationReady ? 0 : 1,
          onEnd: controller.markPreparedIndexBadgeVisible,
          child: Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Theme.of(
                        context,
                      ).colorScheme.scrim.withValues(alpha: 0.38),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        key: const ValueKey(
                          'drag-preparation-preview-progress-ring',
                        ),
                        value: ImageCardController.dragPreparationProgressValue,
                        strokeWidth: 2,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.onInverseSurface.withValues(alpha: 0.2),
                        color: Theme.of(context).colorScheme.onInverseSurface,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${(ImageCardController.dragPreparationProgressValue * 100).toInt()}%',
                      key: const ValueKey(
                        'drag-preparation-preview-progress-percent',
                      ),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onInverseSurface,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.data});
  final ImageCardViewData data;

  @override
  Widget build(BuildContext context) {
    final label = data.statusBadgeLabel!;
    return Tooltip(
      message: data.statusBadgeTooltip ?? label,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 120),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Theme.of(
            context,
          ).colorScheme.inverseSurface.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onInverseSurface,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _SelectionCheckbox extends StatelessWidget {
  const _SelectionCheckbox({required this.selected, required this.onChanged});
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: 40,
      child: Checkbox(
        value: selected,
        onChanged: onChanged == null
            ? null
            : (value) {
                if (value != null) onChanged!(value);
              },
        shape: const CircleBorder(),
        side: WidgetStateBorderSide.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? theme.colorScheme.primary
                : theme.colorScheme.onInverseSurface.withValues(alpha: 0.7),
            width: 1.5,
          ),
        ),
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? theme.colorScheme.primary
              : theme.colorScheme.inverseSurface.withValues(alpha: 0.72),
        ),
        checkColor: theme.colorScheme.onPrimary,
      ),
    );
  }
}
