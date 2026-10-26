import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error/app_exception.dart';
import '../core/logger/app_logger.dart';
import '../data/models/game_account.dart';
import '../services/account/microsoft_auth.dart';
import '../services/launch/argument_builder.dart';
import 'settings_provider.dart';

/// 账户列表状态
class AccountsState {
  final List<GameAccount> accounts;
  final String currentId;
  final bool busy;

  const AccountsState({
    this.accounts = const [],
    this.currentId = '',
    this.busy = false,
  });

  GameAccount? get current {
    if (accounts.isEmpty) return null;
    return accounts.where((a) => a.id == currentId).firstOrNull ??
        accounts.first;
  }

  AccountsState copyWith({
    List<GameAccount>? accounts,
    String? currentId,
    bool? busy,
  }) {
    return AccountsState(
      accounts: accounts ?? this.accounts,
      currentId: currentId ?? this.currentId,
      busy: busy ?? this.busy,
    );
  }
}

class AccountsNotifier extends Notifier<AccountsState> {
  @override
  AccountsState build() {
    _load();
    return const AccountsState();
  }

  static const String _storageKey = 'fmcl.accounts';
  static const String _currentKey = 'fmcl.current_account';

  Future<void> _load() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List<dynamic>)
            .map((e) => GameAccount.fromJson(e as Map<String, dynamic>))
            .toList();
        final current = prefs.getString(_currentKey) ?? '';
        state = state.copyWith(accounts: list, currentId: current);
      } catch (e) {
        AppLogger.warn('Accounts', '账户数据损坏: $e');
      }
    }
  }

  Future<void> _persist() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(
      _storageKey,
      jsonEncode(state.accounts.map((a) => a.toJson()).toList()),
    );
    await prefs.setString(_currentKey, state.currentId);
  }

  /// 添加离线账户
  Future<GameAccount> addOfflineAccount(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const AuthException('玩家名不能为空');
    }
    if (trimmed.length > 16) {
      throw const AuthException('离线玩家名不能超过 16 个字符');
    }
    final uuid = LaunchArgumentsBuilder.offlineUuid(trimmed);
    final account = GameAccount(
      id: 'offline_$uuid',
      type: AccountType.offline,
      name: trimmed,
      accessToken: '0',
      uuid: uuid,
    );
    await _upsert(account);
    return account;
  }

  /// 添加微软账户（由 MicrosoftAuthService 完成认证后调用）
  Future<void> addMicrosoftAccount(GameAccount account) async {
    await _upsert(account);
  }

  /// 添加 Yggdrasil 外置账户
  Future<void> addYggdrasilAccount({
    required String serverUrl,
    required String name,
    required String accessToken,
    required String uuid,
    required String profileId,
    required int expiresAt,
  }) async {
    final account = GameAccount(
      id: 'yggdrasil_${profileId.isNotEmpty ? profileId : uuid}',
      type: AccountType.yggdrasil,
      name: name,
      accessToken: accessToken,
      uuid: uuid,
      yggdrasilServer: serverUrl,
      profileId: profileId,
      expiresAt: expiresAt,
    );
    await _upsert(account);
  }

  Future<void> _upsert(GameAccount account) async {
    final accounts = [...state.accounts]
      ..removeWhere((a) => a.id == account.id);
    accounts.insert(0, account);
    state = state.copyWith(accounts: accounts, currentId: account.id);
    await _persist();
  }

  Future<void> select(String id) async {
    state = state.copyWith(currentId: id);
    await _persist();
  }

  Future<void> remove(String id) async {
    final accounts = [...state.accounts]..removeWhere((a) => a.id == id);
    final currentId =
        state.currentId == id ? (accounts.firstOrNull?.id ?? '') : state.currentId;
    state = state.copyWith(accounts: accounts, currentId: currentId);
    await _persist();
  }

  /// 刷新微软令牌（启动前调用）
  Future<void> refreshIfNeeded() async {
    final current = state.current;
    if (current == null || !current.isTokenExpired) return;
    if (current.type != AccountType.microsoft || current.refreshToken == null) {
      return;
    }
    state = state.copyWith(busy: true);
    try {
      final refreshed = await MicrosoftAuthHelper.refresh(
        current.refreshToken!,
        current.name,
        current.uuid,
      );
      await _upsert(refreshed);
    } finally {
      state = state.copyWith(busy: false);
    }
  }
}

final accountsProvider = NotifierProvider<AccountsNotifier, AccountsState>(
  AccountsNotifier.new,
);

/// 当前账户
final currentAccountProvider = Provider<GameAccount?>((ref) {
  return ref.watch(accountsProvider).current;
});

/// 微软认证辅助（设备码流程的封装入口）
///
/// 完整的 MSA 设备码流程需要 Azure 应用 Client ID。
/// FMCL 将 client_id 留空，用户可在设置中填入自己的 Azure 应用 ID
/// （详见 README「微软登录配置」章节）。
class MicrosoftAuthHelper {
  MicrosoftAuthHelper._();

  static String? _clientId;

  static void configure({required String clientId}) {
    _clientId = clientId;
  }

  static Future<GameAccount> loginWithDeviceCode() async {
    final clientId = _clientId;
    if (clientId == null || clientId.isEmpty) {
      throw const AuthException(
        '尚未配置微软登录的 Azure Client ID',
        suggestions: [
          FixSuggestion(
            '了解如何配置',
            '请在设置 → 账户 中填入你的 Azure 应用 Client ID，配置步骤见项目 README 的「微软登录配置」章节。',
          ),
        ],
      );
    }
    // 完整设备码流程实现位于 services/account/microsoft_auth.dart，
    // 由 UI 层调用并展示设备码页面。此处仅做配置校验兜底。
    throw const AuthException('请使用账户页面的「微软登录」入口完成设备码认证');
  }

  /// 令牌刷新（委托给 microsoft_auth.dart 的实现）
  static Future<GameAccount> refresh(
    String refreshToken,
    String name,
    String uuid,
  ) async {
    return MicrosoftAuthService.refreshAccessToken(
      refreshToken: refreshToken,
      prevName: name,
      prevUuid: uuid,
    );
  }
}
