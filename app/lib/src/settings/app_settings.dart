/// ボットをどこで動かすか。
enum RunMode {
  /// この端末だけで完結させる。サーバーは要らないが、アプリを閉じると止まる。
  local,

  /// Oracle Cloud などに常駐させたサーバーにつなぐ。
  remote,
}

/// 画面の明るさ。Flutter の ThemeMode と同じ並び。
enum AppThemeMode { system, light, dark }

/// アプリ固有の設定 (売買ロジックの設定は mexc_core の StrategyConfig)。
class AppSettings {
  const AppSettings({
    this.mode = RunMode.local,
    this.serverUrl = 'ws://127.0.0.1:8080/ws',
    this.serverToken = '',
    this.autoStartBot = false,
    this.themeMode = AppThemeMode.system,
  });

  final RunMode mode;
  final String serverUrl;
  final String serverToken;

  /// アプリ起動時にボットも起動するか。
  final bool autoStartBot;

  /// 画面の明るさ。端末に合わせるか、明るい / 暗いを選ぶ。
  final AppThemeMode themeMode;

  AppSettings copyWith({
    RunMode? mode,
    String? serverUrl,
    String? serverToken,
    bool? autoStartBot,
    AppThemeMode? themeMode,
  }) => AppSettings(
    mode: mode ?? this.mode,
    serverUrl: serverUrl ?? this.serverUrl,
    serverToken: serverToken ?? this.serverToken,
    autoStartBot: autoStartBot ?? this.autoStartBot,
    themeMode: themeMode ?? this.themeMode,
  );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'serverUrl': serverUrl,
    'serverToken': serverToken,
    'autoStartBot': autoStartBot,
    'themeMode': themeMode.name,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    mode: RunMode.values.firstWhere(
      (e) => e.name == json['mode'],
      orElse: () => RunMode.local,
    ),
    serverUrl: json['serverUrl'] as String? ?? 'ws://127.0.0.1:8080/ws',
    serverToken: json['serverToken'] as String? ?? '',
    autoStartBot: json['autoStartBot'] as bool? ?? false,
    themeMode: AppThemeMode.values.firstWhere(
      (e) => e.name == json['themeMode'],
      orElse: () => AppThemeMode.system,
    ),
  );
}
