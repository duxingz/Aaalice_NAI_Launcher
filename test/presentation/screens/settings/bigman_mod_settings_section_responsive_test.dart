// 「胖大叔自用改」设置板块的窄屏 / 大字号回归。
//
// 起因：设置行把分段按钮放在 ListTile.trailing 上时，trailing 会被撑到整行
// 宽度，直接命中 ListTile 的断言（"Trailing widget consumes the entire tile
// width"）—— 本项目此前没有任何测试打开过这个板块，所以一直没被发现。
// 项目规范要求新增界面必须覆盖 320 / 600 / 840 / 1180 / 1600 宽度与 3x 文本。
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

  Future<void> pumpModSection(
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
          home: const SettingsScreen(initialSection: SettingsSection.bigmanMod),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 窄屏按安卓（触屏）、宽屏按桌面铺开，贴近真实使用。
  ///
  /// `debugDefaultTargetPlatformOverride` 是 foundation 调试变量：测试收尾的
  /// 不变量校验**早于** tearDown，所以必须在用例体内还原，不能用 addTearDown
  /// 代替（否则报「The value of a foundation debug variable was changed」）。
  Future<void> openModSection(
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
    await pumpModSection(tester, width: width, textScale: textScale);
    // 先还原再断言：断言失败时也不会把调试变量漏给下一个用例。
    debugDefaultTargetPlatformOverride = null;
  }

  for (final width in widths) {
    testWidgets('自用改板块在 ${width.toInt()}px 宽不溢出', (tester) async {
      await openModSection(tester, width: width, textScale: 1);

      expect(tester.takeException(), isNull);
      expect(find.text('界面与历史'), findsOneWidget);
    });

    testWidgets('自用改板块在 ${width.toInt()}px 宽 + 3x 字号不溢出', (tester) async {
      await openModSection(tester, width: width, textScale: 3);

      expect(tester.takeException(), isNull);
      expect(find.text('界面与历史'), findsOneWidget);
    });
  }

  testWidgets('历史四档与精简开关都能点，点完不报错', (tester) async {
    await openModSection(tester, width: 1180, textScale: 1);

    expect(find.text('历史记录保留数量'), findsOneWidget);
    for (final option in const ['50', '100', '150', '200']) {
      expect(find.text(option), findsOneWidget);
    }
    expect(find.text('精简快捷编辑'), findsOneWidget);

    await tester.tap(find.text('200'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('精简快捷编辑'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
