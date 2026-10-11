import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/platform/platform_capabilities.dart';
import '../../../core/services/bigman_prompt_inbox.dart';
import '../../../core/services/bigman_queue_bridge.dart';
import '../../../data/models/character/character_prompt.dart';
import '../../../data/models/queue/replication_task.dart';
import '../../adaptive/adaptive_layout.dart';
import '../../providers/bigman/bigman_mod_settings.dart';
import '../../providers/character_prompt_provider.dart';
import '../../providers/generation_layout_mode_provider.dart';
import '../../providers/image_generation_provider.dart';
import '../../providers/layout_state_provider.dart';
import '../../providers/queue_execution_provider.dart';
import '../../providers/replication_queue_provider.dart';
import '../../widgets/common/app_toast.dart';
import '../../widgets/common/owned_scroll_controller.dart';
import '../../widgets/drop/global_drop_handler.dart';
import 'desktop_layout.dart';
import 'mobile_layout.dart';
import 'web_style_layout.dart';
import 'widgets/fixed_tags_sidebar.dart';
import 'widgets/prompt_input_controller.dart';

/// 图像生成页面
class GenerationScreen extends ConsumerStatefulWidget {
  const GenerationScreen({super.key});

  @override
  ConsumerState<GenerationScreen> createState() => _GenerationScreenState();
}

class _GenerationScreenState extends ConsumerState<GenerationScreen> {
  final _historyViewport = OwnedViewportOffset();
  final _webNegativeMode = ValueNotifier<bool>(false);
  final _promptInputKey = GlobalKey(debugLabel: 'generation-prompt-input');
  late final PromptInputController _promptInputController;

  /// 胖大叔自用改：DSH 提示词收件箱。
  ///
  /// 挂在生成页（三种布局的共同父级）而不是某个具体布局里 —— 否则用户
  /// 切换到 Web 风格布局时轮询就不会启动。
  PromptInboxWatcher? _promptInbox;

  /// DSH 队列批次桥：把 `jobs.json` 里的一批任务直接塞进生成队列。
  QueueJobWatcher? _queueBridge;

  @override
  void initState() {
    super.initState();
    final params = ref.read(generationParamsNotifierProvider);
    _promptInputController = PromptInputController(
      prompt: params.prompt,
      negativePrompt: params.negativePrompt,
      negativeModeNotifier: _webNegativeMode,
    );
    _promptInbox =
        PromptInboxWatcher(
          setPrompt: (value) => ref
              .read(generationParamsNotifierProvider.notifier)
              .updatePrompt(value),
          setNegativePrompt: (value) => ref
              .read(generationParamsNotifierProvider.notifier)
              .updateNegativePrompt(value),
          setCharacters: (characters) {
            final notifier = ref.read(
              characterPromptNotifierProvider.notifier,
            );
            notifier.clearAllCharacters();
            for (final character in characters) {
              notifier.addCharacter(
                CharacterGender.female,
                name: character.name,
                prompt: character.prompt,
              );
            }
          },
          isEnabled: () =>
              ref.read(bigmanModSettingsProvider).promptInboxEnabled,
          isBusy: () => ref.read(imageGenerationNotifierProvider).isBusy,
          onApplied: (summary) {
            if (!mounted) return;
            AppToast.info(context, '已从 DSH 填入：$summary');
          },
          // 覆盖前备份：把当前各区拼成同格式文本存盘，误覆盖后能找回。
          snapshotCurrent: () {
            final params = ref.read(generationParamsNotifierProvider);
            final characters = ref
                .read(characterPromptNotifierProvider)
                .characters;
            final buffer = StringBuffer()
              ..writeln('---POSITIVE---')
              ..writeln(params.prompt)
              ..writeln('---NEGATIVE---')
              ..writeln(params.negativePrompt);
            for (final character in characters) {
              buffer
                ..writeln('---CHARACTER:${character.name}---')
                ..writeln(character.prompt);
            }
            return buffer.toString();
          },
        )
          ..start();

    _queueBridge =
        QueueJobWatcher(
          enqueue: _enqueueJobs,
          isEnabled: () =>
              ref.read(bigmanModSettingsProvider).queueBridgeEnabled,
          // 入队不受「正在生成」影响：队列本来就是拿来边出边排的。
          isBusy: () => false,
          statusJson: _queueStatusJson,
          onApplied: (summary) {
            if (!mounted) return;
            AppToast.info(context, '已从 DSH 入队：$summary');
          },
          onRejected: (reason) {
            if (!mounted) return;
            AppToast.warning(context, 'DSH 队列批次：$reason');
          },
        )
          ..start();
  }

  /// 上次「自动开始」的结果（如需要登录 / 队列空），写进状态回执，
  /// 免得自动开始失败时静默无声。
  String? _lastQueueStart;

  /// 把一批任务规格变成队列任务；返回实际入队条数。
  Future<int> _enqueueJobs(
    List<QueueJobSpec> jobs, {
    required bool autoStart,
  }) async {
    var remaining = ref
        .read(replicationQueueNotifierProvider)
        .remainingCapacity;
    final tasks = <ReplicationTask>[];
    for (final job in jobs) {
      final copies = job.count < 1 ? 1 : job.count;
      for (var i = 0; i < copies && remaining > 0; i++) {
        tasks.add(
          ReplicationTask.create(
            prompt: job.positive,
            negativePrompt: job.negative ?? '',
            // 不置 true 的话任务里的负面词会被静默忽略。
            applyNegativePrompt: job.negative != null,
            width: job.width,
            height: job.height,
            seed: job.seed,
            steps: job.steps,
            cfgScale: job.cfgScale,
            model: job.model,
            sampler: job.sampler,
          ),
        );
        remaining--;
      }
      if (remaining <= 0) break;
    }
    if (tasks.isEmpty) return 0;

    final added = await ref
        .read(replicationQueueNotifierProvider.notifier)
        .addAll(tasks);
    if (autoStart && added > 0) {
      final result = await ref
          .read(queueExecutionNotifierProvider.notifier)
          .startQueue();
      _lastQueueStart = switch (result) {
        QueueStartResult.started => 'started',
        QueueStartResult.busy => 'busy',
        QueueStartResult.empty => 'empty',
        QueueStartResult.authRequired => 'authRequired',
      };
    }
    return added;
  }

  /// 状态回执：让 DSH 能读到队列进度与出图情况。
  String? _queueStatusJson() {
    final queue = ref.read(replicationQueueNotifierProvider);
    final execution = ref.read(queueExecutionNotifierProvider);
    return jsonEncode({
      'updatedAt': DateTime.now().toIso8601String(),
      'count': queue.count,
      'remaining': queue.remainingCapacity,
      'completed': queue.completedCount,
      'failed': queue.failedCount,
      'running': execution.isRunning,
      'paused': execution.isPaused,
      if (_lastQueueStart != null) 'lastStart': _lastQueueStart,
    });
  }

  @override
  void dispose() {
    _promptInbox?.stop();
    _queueBridge?.stop();
    _promptInputController.dispose();
    _webNegativeMode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final sizeClass = AdaptiveBreakpoints.classifyWidth(
          constraints.maxWidth,
        );
        if (sizeClass.isExpandedOrWider) {
          final layoutMode = ref.watch(generationLayoutModeNotifierProvider);
          return layoutMode == GenerationLayoutMode.webStyle
              ? WebStyleGenerationLayout(
                  historyViewport: _historyViewport,
                  negativeModeNotifier: _webNegativeMode,
                  promptInputController: _promptInputController,
                  promptInputKey: _promptInputKey,
                )
              : DesktopGenerationLayout(
                  historyViewport: _historyViewport,
                  promptInputController: _promptInputController,
                  promptInputKey: _promptInputKey,
                );
        }

        final layoutState = ref.watch(layoutStateNotifierProvider);
        final mobileLayout = MobileGenerationLayout(
          historyViewport: _historyViewport,
          promptInputController: _promptInputController,
          promptInputKey: _promptInputKey,
        );
        if (!layoutState.fixedTagsSidebarExpanded) {
          return mobileLayout;
        }

        if (constraints.maxWidth < 900) {
          final overlayWidth = math.max(
            160.0,
            math.min(360.0, constraints.maxWidth - 48),
          );
          return Stack(
            children: [
              Positioned.fill(child: mobileLayout),
              Positioned.fill(
                child: ModalBarrier(
                  key: const Key('generation-fixed-tags-barrier'),
                  color: Colors.black.withValues(alpha: 0.24),
                  dismissible: true,
                  onDismiss: () => ref
                      .read(layoutStateNotifierProvider.notifier)
                      .setFixedTagsSidebarExpanded(false),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                bottom: 0,
                width: overlayWidth,
                child: Material(
                  key: const Key('generation-fixed-tags-overlay'),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  elevation: 12,
                  child: const SafeArea(child: FixedTagsSidebar()),
                ),
              ),
            ],
          );
        }

        final maxSidebarWidth = (constraints.maxWidth * 0.45).clamp(
          240.0,
          400.0,
        );
        final sidebarWidth = layoutState.fixedTagsSidebarWidth
            .clamp(240.0, maxSidebarWidth)
            .toDouble();

        return Row(
          children: [
            Expanded(child: mobileLayout),
            Container(
              width: sidebarWidth,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  left: BorderSide(color: Theme.of(context).dividerColor),
                ),
              ),
              child: const FixedTagsSidebar(),
            ),
          ],
        );
      },
    );

    if (!PlatformCapabilities.current.supportsExternalFileDrop) {
      return content;
    }
    return GlobalDropHandler(child: content);
  }
}
