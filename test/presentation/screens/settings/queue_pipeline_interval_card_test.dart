// 生成设置页新增的「流水线间隔」卡片的窄屏 / 大字号回归。
//
// 上次「界面与历史」卡片就是栽在没验窄屏上（分段按钮塞 ListTile.trailing），
// 所以凡新增设置 UI 都按项目规范覆盖 320/600/840/1180/1600 宽度与 3x 文本。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/agent/skill_catalog.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/core/storage/secure_storage_service.dart';
import 'package:nai_launcher/data/models/user/user_subscription.dart';
import 'package:nai_launcher/data/services/account_manager_provider.dart';
import 'package:nai_launcher/data/services/auth_provider.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/agent_settings/providers/agent_settings_provider.dart';
import 'package:nai_launcher/presentation/providers/subscription_provider.dart';
import 'package:nai_launcher/presentation/screens/settings/settings_screen.dart';
import 'package:nai_launcher/presentation/screens/settings/settings_section.dart';

class _MemoryLocalStorage extends LocalStorageService {
  final Map<String, Object?> _values = {};

  @override
  T? getSetting<T>(String key, {T? defaultValue}) =>
      (_values[key] as T?) ?? defaultValue;

  @override
  Future<void> setSetting<T>(String key, T value) async {
    _values[key] = value;
  }

  @override
  Future<void> setSettings(Map<String, Object?> values) async {
    _values.addAll(values);
  }

  @override
  Future<void> deleteSetting(String key) async {
    _values.remove(key);
  }
}

class _MemorySecureStorage extends SecureStorageService {
  @override
  Future<String?> getAgentWebAccessExaApiKey() async => null;

  @override
  Future<String?> getPromptAssistantApiKey(String providerId) async => null;
}

class _EmptySkillCatalogService extends SkillCatalogService {
  const _EmptySkillCatalogService();

  @override
  Future<SkillCatalogSnapshot> scan({
    required List<SkillRoot> roots,
    Map<String, bool> skillEnabledOverrides = const {},
  }) async => const SkillCatalogSnapshot();
}

class _FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthState(status: AuthStatus.unauthenticated);
}

class _FakeAccountManagerNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() => const AccountManagerState();
}

class _FakeSubscriptionNotifier extends SubscriptionNotifier {
  @override
  SubscriptionState build() => const SubscriptionStateInitial();
}

void main() {
  const widths = <double>[320, 600, 840, 1180, 1600];

  Future<void> pumpGenerationSection(
    WidgetTester tester, {
    required double width,
    required double textScale,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 900));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localStorageServiceProvider.overrideWithValue(_MemoryLocalStorage()),
          secureStorageServiceProvider.overrideWithValue(
            _MemorySecureStorage(),
          ),
          agentSettingsProvider.overrideWith(
            (ref) => AgentSettingsNotifier(
              ref,
              supportDirectory: Directory.systemTemp,
              workspaceDirectory: Directory.systemTemp,
              environment: const {},
              skillCatalogService: const _EmptySkillCatalogService(),
            ),
          ),
          authNotifierProvider.overrideWith(_FakeAuthNotifier.new),
          accountManagerNotifierProvider.overrideWith(
            _FakeAccountManagerNotifier.new,
          ),
          subscriptionNotifierProvider.overrideWith(
            _FakeSubscriptionNotifier.new,
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const SettingsScreen(initialSection: SettingsSection.generation),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// `debugDefaultTargetPlatformOverride` 必须在**用例体内**还原：
  /// 收尾的不变量校验早于 tearDown，用 addTearDown 不够。
  Future<void> openGenerationSection(
    WidgetTester tester, {
    required double width,
    required double textScale,
  }) async {
    debugDefaultTargetPlatformOverride = width < 840
        ? TargetPlatform.android
        : TargetPlatform.windows;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      tester.binding.setSurfaceSize(null);
    });
    await pumpGenerationSection(
      tester,
      width: width,
      textScale: textScale,
    );
    debugDefaultTargetPlatformOverride = null;
  }

  for (final width in widths) {
    testWidgets('流水线间隔卡片在 ${width.toInt()}px 宽不溢出', (tester) async {
      await openGenerationSection(tester, width: width, textScale: 1);

      expect(tester.takeException(), isNull);
      expect(find.text('流水线间隔（仅队列生效）'), findsOneWidget);
    });

    testWidgets('流水线间隔卡片在 ${width.toInt()}px 宽 + 3x 字号不溢出', (tester) async {
      await openGenerationSection(tester, width: width, textScale: 3);

      expect(tester.takeException(), isNull);
      expect(find.text('流水线间隔（仅队列生效）'), findsOneWidget);
    });
  }

  testWidgets('两个输入都在，默认 12 / 24 秒', (tester) async {
    await openGenerationSection(tester, width: 1180, textScale: 1);

    expect(find.text('最小秒数'), findsOneWidget);
    expect(find.text('最大秒数'), findsOneWidget);
    expect(find.text('12 秒'), findsWidgets);
    expect(find.text('24 秒'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
