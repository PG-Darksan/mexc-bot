#!/usr/bin/env bash
# Oracle Cloud (Ubuntu 22.04 / 24.04, arm64 または x86_64) でボットを常駐させる。
#
#   curl や git でこのリポジトリを /opt/mexc-bot-src に置いてから
#   sudo bash deploy/setup.sh
#
# 途中で止まっても何度でもやり直せるように書いてある。
set -euo pipefail

SRC_DIR="${SRC_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
APP_DIR=/opt/mexc-bot
DATA_DIR=/var/lib/mexc-bot
LOG_DIR=/var/log/mexc-bot
ENV_DIR=/etc/mexc-bot
SERVICE_USER=mexcbot

if [[ $EUID -ne 0 ]]; then
  echo "root で実行してください (sudo bash deploy/setup.sh)" >&2
  exit 1
fi

echo "==> 必要なパッケージを入れる"
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg unzip

if ! command -v dart >/dev/null 2>&1; then
  echo "==> Dart SDK を入れる"
  # arm64 (Ampere A1) でも x86_64 でも同じ手順で入る。
  curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub \
    | gpg --dearmor -o /usr/share/keyrings/dart.gpg
  echo "deb [signed-by=/usr/share/keyrings/dart.gpg arch=$(dpkg --print-architecture)] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main" \
    > /etc/apt/sources.list.d/dart_stable.list
  apt-get update -qq
  apt-get install -y -qq dart
fi
export PATH="$PATH:/usr/lib/dart/bin"

echo "==> 実行用ユーザーを作る"
id -u "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"

echo "==> ディレクトリを用意する"
mkdir -p "$APP_DIR" "$DATA_DIR" "$LOG_DIR" "$ENV_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$DATA_DIR" "$LOG_DIR"
chmod 700 "$ENV_DIR"

echo "==> ビルドする"
cd "$SRC_DIR/packages/mexc_core" && dart pub get
cd "$SRC_DIR/packages/mexc_server" && dart pub get
dart compile exe bin/server.dart -o "$APP_DIR/mexc-bot-server"
chmod 755 "$APP_DIR/mexc-bot-server"

if [[ ! -f "$ENV_DIR/env" ]]; then
  echo "==> 環境変数ファイルのひな形を作る"
  TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
  cat > "$ENV_DIR/env" <<EOF
# MEXC のAPIキー (先物の発注権限が要る。IPホワイトリスト登録を推奨)
MEXC_API_KEY=
MEXC_API_SECRET=

# アプリからの接続に使うトークン。アプリの設定にも同じ値を入れる。
BOT_TOKEN=$TOKEN

# 起動と同時にボットを動かさないなら 0
BOT_AUTOSTART=1
EOF
  chmod 600 "$ENV_DIR/env"
  chown root:root "$ENV_DIR/env"
  echo
  echo "    接続トークンを生成しました: $TOKEN"
  echo "    $ENV_DIR/env にAPIキーを書き足してください。"
  echo
fi

echo "==> systemd に登録する"
# Tailscale が入っていればそのアドレスで待ち受ける。外の回線には出ない。
# 無ければ Caddy などを前に置く前提で、自分の中 (127.0.0.1) だけで待つ。
BIND_HOST=127.0.0.1
if command -v tailscale >/dev/null 2>&1; then
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
  if [[ -n "${TS_IP:-}" ]]; then
    BIND_HOST="$TS_IP"
  fi
fi
sed "s/--host 127.0.0.1/--host $BIND_HOST/" "$SRC_DIR/deploy/mexc-bot.service" \
  > /etc/systemd/system/mexc-bot.service
systemctl daemon-reload
systemctl enable mexc-bot
systemctl restart mexc-bot

echo "==> ログローテーションを設定する"
cat > /etc/logrotate.d/mexc-bot <<'EOF'
/var/log/mexc-bot/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    copytruncate
}
EOF

echo
echo "完了しました。"
echo "  状態確認: systemctl status mexc-bot"
echo "  ログ:     tail -f $LOG_DIR/server.log"
echo "  疎通:     curl http://$BIND_HOST:8080/health"
echo
echo "  アプリの「サーバーのURL」には次を入れてください:"
echo "    ws://$BIND_HOST:8080/ws"
echo "  接続トークンは: grep BOT_TOKEN $ENV_DIR/env"
echo
echo "このあと deploy/README.md の「外から繋げるようにする」を読んでください。"
