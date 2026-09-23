/// MEXC API がエラーを返したときの例外。
///
/// HTTP が 200 でも `success:false` で業務エラーが返るため、
/// ステータスコードではなく [code] を見る必要がある。
class MexcApiException implements Exception {
  MexcApiException({
    required this.code,
    required this.message,
    this.endpoint,
    this.httpStatus,
  });

  /// MEXC の業務コード。510=レート超過, 602=署名不一致, 600=パラメータ不正 など。
  final int code;
  final String message;
  final String? endpoint;
  final int? httpStatus;

  /// レート制限に当たったか。
  bool get isRateLimited => code == 510 || httpStatus == 429;

  /// 署名・認証まわりの失敗か。
  bool get isAuthError =>
      code == 506 || code == 511 || code == 602 || code == 513;

  /// 再試行する価値があるか。
  bool get isRetryable =>
      isRateLimited || code == 500 || code == 501 || code == 601;

  /// 人間向けの日本語説明。
  String get description => switch (code) {
    500 => 'MEXC内部エラー。再送前に処理が通っていないか確認してください。',
    501 => 'MEXC側が混雑しています。',
    506 => 'リクエスト元が不明です。ヘッダの設定を確認してください。',
    510 => 'レート制限を超えました。',
    511 => 'このAPIキーに権限がありません (先物権限・KYCを確認)。',
    513 => 'リクエストが不正です (パラメーターか署名)。',
    600 => 'パラメーターエラーです。',
    601 => 'データの解析に失敗しました。',
    602 => '署名の検証に失敗しました。端末の時刻ずれも確認してください。',
    603 => 'リクエストが重複しています。',
    1000 => '先物口座が開設されていません。',
    1001 => 'その銘柄は存在しません。',
    1002 => 'その銘柄は取引が有効になっていません。',
    2009 => '対象のポジションは存在しないか決済済みです。',
    2011 => '注文数量が不正です (最小数量・刻みを確認)。',
    2027 => '同じ方向でクロスと分離は同時に持てません。',
    2040 => 'その注文は存在しません。',
    2041 => 'その注文は取消できない状態です。',
    _ => message,
  };

  @override
  String toString() =>
      'MexcApiException(code=$code, endpoint=$endpoint): $description';
}

/// 通信そのものが失敗したとき。
class MexcNetworkException implements Exception {
  MexcNetworkException(this.message, {this.endpoint});

  final String message;
  final String? endpoint;

  @override
  String toString() => 'MexcNetworkException($endpoint): $message';
}
