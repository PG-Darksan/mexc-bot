# Oracle Cloud にボットを常駐させる

アプリを閉じてもボットを動かし続けるための手順です。上から順にやれば終わります。

所要時間の目安は、Oracle のサインアップと格上げ申請で 30 分、格上げの完了待ちで
1〜2 日、インスタンス作成からボット稼働までで 1 時間ほどです。

---

## 先に知っておくこと

**1. Always Free の Ampere A1 は 2026年6月に半減しました。**
4 OCPU / 24GB ではなく **2 OCPU / 12GB** が上限です (月 1,500 OCPU時間 /
9,000 GB時間)。このボットは 1 OCPU / 6GB あれば足ります。

**2. Always Free のままだと止められます。**
無料テナンシーには、7日間つづけて低負荷 (CPU の 95パーセンタイルが 20% 未満、
かつネットワークが 20% 未満、A1 はメモリも) のインスタンスを停止する仕組みが
あります。WebSocket で待っているだけのボットは、この条件をそのまま満たします。

公式の回避策は **Pay As You Go (従量課金) への格上げ** です。格上げしても
Always Free 枠に収まっていれば課金されません
([公式記述](https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/changingpaymentmethod.htm))。
24時間動かすなら必須の手順だと考えてください。

**3. ホームリージョンは後から変えられません。**
サインアップ画面で **Japan East (Tokyo)** を選びます。間違えるとアカウントを
作り直すしかありません。

**4. 東京リージョンは可用性ドメインが1つだけです。**
キャパシティ不足に当たったとき「別の可用性ドメインを試す」という定番の回避策が
使えません。OCPU を減らす、時間をおいて再試行する、で対応します。

---

## 手順1: Oracle アカウントを作る

**開く: https://signup.oraclecloud.com/**

入力するもの:

| 項目 | 内容 |
| --- | --- |
| Country/Territory | Japan |
| 氏名・メールアドレス | 有効なもの |
| パスワード | 8文字以上、小文字/大文字/数字/記号を各1つ以上 |
| **Cloud Account Name** | テナンシー名。**以後ログインのたびに入力するので必ず控える** |
| **Home Region** | **Japan East (Tokyo)** ← 後から変更不可 |

続いて住所・電話番号 (SMS/音声で本人確認)・クレジットカードを登録します。
カードは本人確認のためで、
[公式に](https://docs.oracle.com/en-us/iaas/Content/GSG/Tasks/signingup_topic-Sign_Up_for_Free_Oracle_Cloud_Promotion.htm)
「格上げを選ばない限り課金されない」と明記されています (一時的な与信が立って
自動解除されます)。JCB等のロゴがあり暗証番号不要なデビットカードも使えます。

> カードが弾かれる場合は、3Dセキュア (本人認証サービス) が有効になっているか
> 確認してください。

参考: [Sign Up for the Free Oracle Cloud Promotion](https://docs.oracle.com/en-us/iaas/Content/GSG/Tasks/signingup_topic-Sign_Up_for_Free_Oracle_Cloud_Promotion.htm)

## 手順2: コンソールにログインする

**開く: https://cloud.oracle.com/**

Cloud Account Name (手順1で控えたテナンシー名) → メールアドレスとパスワードの
順に入力します。

ログインしたら **画面右上のリージョンが Japan East (Tokyo) になっているか**
必ず確認してください。違うリージョンで作ると Always Free の対象外になります。

## 手順3: Pay As You Go へ格上げを申請する

ナビゲーションメニュー → **Billing & Cost Management** → **Upgrade and Manage Payment**

支払い方法と Individual / Corporate を確認し、規約に同意して
**Upgrade your account** → **Next** → **Upgrade account**。

完了まで **1〜2日かかることがあります**。完了するとメールが届きます。
インスタンス作成を待たずに、ここで先に申請してしまうのが得策です。

手順: [Managing Account Upgrades and Payment Method](https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/changingpaymentmethod.htm)

## 手順4: 予算アラートを作る (格上げしたら必ず)

ナビゲーションメニュー → **Billing & Cost Management** → **Budgets** → **Create Budget**

| 項目 | 値 |
| --- | --- |
| Budget Scope | Compartment |
| Target Compartment | ルートコンパートメント |
| Schedule | Monthly |
| Budget Amount | 1 (最小値) |
| Threshold Metric | Actual Spend |
| Threshold Type | Percentage of Budget |
| Threshold % | 100 |
| Email Recipients | 自分のメールアドレス |

これで枠を超えた瞬間にメールが飛びます。メニューで見つからなければ、コンソール
上部の検索窓に `budgets` と入れてください。

手順: [Creating a Budget](https://docs.oracle.com/en-us/iaas/Content/Billing/Tasks/create-budget.htm)

## 手順5: インスタンスを作る

ナビゲーションメニュー → **Compute** → **Instances** → **Create instance**

### 名前と配置

- **Name**: `mexc-bot` など
- **Compartment**: ルートのまま
- **Placement**: 東京は Availability domain が1つなので既定のまま。
  **Fault Domain は指定しない** (指定するとキャパシティ不足が出やすくなります)

### Image and shape

1. **Change image** → Platform Images → **Ubuntu** → OS version **24.04**
2. **Change shape** → **Browse all shapes** → Instance type: Virtual machine →
   Shape series: **Ampere** → **VM.Standard.A1.Flex**
3. OCPU とメモリをスライダーで **1 OCPU / 6 GB** に → **Select shape**

「Always Free Eligible」のラベルが出ていることを確認してください。

> 無料枠いっぱい (2 OCPU / 12 GB) にすると、もう1台作る余地がなくなります。

### Networking

- **Create new virtual cloud network** を選ぶ
- New subnet は **public** を選ぶ (private だとパブリックIPが付かずSSHできません)
- CIDR block は `10.0.0.0/24` のまま
- **Assign a public IPv4 address** にチェック

> Always Free テナンシーは VCN を 2 個までしか作れません。試行錯誤で量産しないこと。

### Add SSH keys

**Generate a key pair for me** を選び、**秘密鍵と公開鍵の両方をダウンロード**します。

> **秘密鍵はこの画面を離れると二度と取得できません。** 必ずこの場で保存し、
> OneDrive の同期フォルダーではなくローカルの安全な場所に置いてください。
> 無くすとインスタンスに入れなくなり、作り直しになります。

### Boot volume

既定 (47〜50 GB) のままで十分です。最後に **Create**。

State が RUNNING になり、詳細ページに **Public IP address** が表示されます。

全項目の解説: [Creating an Instance](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/launchinginstance.htm)

### Out of host capacity と出たら

公式の対処は「シェイプを変える」「フォールトドメインを変える」「可用性ドメインを
変える」「フォールトドメインを指定しない」の4つですが、東京は可用性ドメインが
1つなので実質は次のどれかです。

- OCPU / メモリを減らす (1 OCPU / 6 GB → 1 OCPU / 4 GB など)
- 時間をおいて **Create** を押し直す (空きは動的に変動します)
- Pay As You Go の格上げ完了後に再試行する

参考: [Resolving Out of Host Capacity error](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/troubleshooting-out-of-host-capacity.htm)

## 手順6: IPを予約済みに差し替える

インスタンス作成画面では予約済みIPを選べないので、**作成後に差し替えます**。
エフェメラルIPは stop/start で変わってしまい、MEXC の IPホワイトリスト登録が
無効になるためです。

### 6-1. 予約済みIPを作る

ナビゲーションメニュー → **Networking** → **IP management** →
**Reserved public IPs** → **Reserve public IP address**

名前を付けて (後から変更可)、そのまま **Reserve public IP address**。

手順: [Creating a Reserved Public IP](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-create.htm)

### 6-2. インスタンスに割り当てる

**Compute** → **Instances** → 対象インスタンス → **Networking** タブ →
**Attached VNICs** → VNIC名 → **IP administration** タブ

プライベートIPの行の **Actions (三点メニュー)** → **Edit** →
Public IP type で **Reserved public IP** → 先に作ったIPを選ぶ → **Update**

既にエフェメラルIPが付いている場合は、先に解除する必要があります。

> エフェメラルIPを予約済みIPに「変換」することはできません。差し替えると
> **IPアドレスの数字が変わります**。MEXC の APIキーのホワイトリスト登録は、
> この差し替えが終わった後のIPで行ってください。

手順: [Assigning a Reserved Public IP](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-assign.htm)

## 手順7: SSH で接続する

Ubuntu イメージの既定ユーザー名は **`ubuntu`** です (Oracle Linux は `opc`)。

Windows の PowerShell から:

```powershell
# 秘密鍵の権限を自分だけに絞る (エクスプローラーでも可)
icacls "C:\path\to\ssh-key.key" /inheritance:r /grant:r "$($env:USERNAME):(R)"

ssh -i "C:\path\to\ssh-key.key" ubuntu@<パブリックIP>
```

Git Bash なら `chmod 400 ssh-key.key` でも構いません。

繋がらないときは、**鍵の権限** → **ユーザー名 (`ubuntu`)** → **IPアドレス** →
**セキュリティリストの22番** の順に確認してください。

手順: [Connecting to a Linux Instance](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/connect-to-linux-instance.htm)

---

## 手順8: Tailscale で繋げるようにする (推奨)

ポート開放も証明書も不要になります。手間が段違いなのでこちらを勧めます。

### 8-1. Tailscale アカウントを作る

**開く: https://login.tailscale.com/start**

Google / Microsoft / GitHub / Apple のいずれかでサインアップします
(Tailscale 独自のパスワードは存在しません)。用途は **Personal use** を選びます。

2026年9月現在、無料の Personal プランは **6ユーザーまで・デバイス数は無制限**
です (2026年4月の改定で拡大)。クレジットカードは不要です。

### 8-2. サーバーに入れる

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

ターミナルに `https://login.tailscale.com/a/xxxxxxxx` という認証URLが1行出ます。
**手元のPCのブラウザでそのURLを開き**、8-1のアカウントで承認してください。

### 8-3. サーバーのアドレスを確認する

```bash
tailscale ip -4
```

`100.x.y.z` 形式のアドレスが返ります。これがアプリに入れる接続先です。
**回線が変わってもサーバーを再起動しても変わりません。**

### 8-4. key expiry を無効化する (無人運用では必須)

**開く: https://login.tailscale.com/admin/machines**

サーバーの行の右端メニュー (…) → **Disable Key Expiry**

> 既定では **180日で認証鍵が失効し、通信が止まります。** 何もしていないのに
> 半年後に突然繋がらなくなる形で表面化します。導入直後に必ず実施してください。

解説: [Key expiry](https://tailscale.com/docs/features/access-control/key-expiry)

### 8-5. 手元の端末にも入れる

- Windows: https://tailscale.com/download/windows
  → インストール後、タスクトレイのアイコンを右クリック → **Log in**
- Android: https://tailscale.com/download/android
  → **Get Started** → VPN構成を許可 → 同じアカウントでサインイン

**必ず 8-1 と同じアカウントでサインインしてください。** 別アカウントだと別の
ネットワークになり、サーバーが見えません。

### 8-6. 繋がったか確認する

```bash
tailscale status          # 3台が並ぶ
ping 100.x.y.z           # サーバーへ疎通
```

`relay` と表示されても繋がってはいます (中継経由)。`direct` の方が速いだけです。

参考: [Tailscale quickstart](https://tailscale.com/docs/how-to/quickstart) /
[Install on Linux](https://tailscale.com/docs/install/linux) /
[Run unattended](https://tailscale.com/docs/how-to/run-unattended)

---

## 手順9: ボットを設置する

手元のPCから転送します。

```bash
scp -i <秘密鍵> -r "C:/Users/Study/OneDrive/デスクトップ/mexc" ubuntu@<IP>:/tmp/mexc
```

サーバー側で:

```bash
sudo mv /tmp/mexc /opt/mexc-bot-src
cd /opt/mexc-bot-src
sudo bash deploy/setup.sh
```

Dart SDK の導入・ビルド・systemd 登録・ログローテーションまで自動で終わります。
最後に **接続トークン** が表示されるので控えてください。

APIキーを書き込んで起動します。

```bash
sudo nano /etc/mexc-bot/env     # MEXC_API_KEY と MEXC_API_SECRET を入れる
sudo systemctl restart mexc-bot
sudo systemctl status mexc-bot
curl http://127.0.0.1:8080/health
```

状態を端末から見るには:

```bash
cd /opt/mexc-bot-src/packages/mexc_server
BOT_TOKEN=<トークン> dart run bin/status.dart --url ws://127.0.0.1:8080/ws
```

### メモリが 1GB のインスタンスの場合

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

## 手順10: アプリから繋ぐ

1. 設定タブ → 動かし方 → **サーバー接続**
2. サーバーのURL: `ws://100.x.y.z:8080/ws` (Tailscale のIP。`setup.sh` の最後にも出ます)
3. 接続トークン: `setup.sh` が表示した値 (`sudo grep BOT_TOKEN /etc/mexc-bot/env` で見返せます)
4. 保存 → 右上の **開始**

残高を端末で直接見たいときは、アプリ側にも MEXC のAPIキーを入れてください。
注文はサーバー側の鍵で出し、端末の鍵は残高の取得にだけ使います。

`setup.sh` は Tailscale が入っていればそのアドレスで待ち受けるように
systemd を書きます。**先に Tailscale (手順8) を済ませてから `setup.sh` を
流してください。** 順番が逆だと `127.0.0.1` だけで待つ形になり、アプリから
繋がりません。その場合は `sudo bash deploy/setup.sh` をもう一度流すか、
`/etc/systemd/system/mexc-bot.service` の `--host` を Tailscale のIPに
書き換えて `sudo systemctl daemon-reload && sudo systemctl restart mexc-bot`
としてください。

## ConoHa VPS の場合

手順は Oracle と同じで、違うのは次の点だけです。

| 項目 | 値 |
| --- | --- |
| OS | Ubuntu 24.04 (22.04 でも可) |
| プラン | メモリ 1GB 以上 (512MB だとビルドが落ちます。1GB なら上の swap を作ってください) |
| SSH のユーザー | `root` (Oracle の `ubuntu` ではありません。`scp` と `ssh` の宛先を `root@<IP>` にします) |
| セキュリティグループ | **既定のままで構いません。** Tailscale は外向きの通信で繋がるので、8080 を開ける必要はありません。SSH (22) だけ通れば足ります |
| サーバーのURL | `ws://<tailscale ip -4 の値>:8080/ws` |
| 接続トークン | `sudo grep BOT_TOKEN /etc/mexc-bot/env` の値 |
| 自己署名証明書を許可 | オフ (`ws://` なので関係ありません) |

ConoHa の公開IPをそのままアプリに入れても繋がりません。ボットは Tailscale の
アドレスでしか待ち受けていないためです (公開IPで待たせると、誰でも叩ける
状態になるので避けています)。

---

## Tailscale を使わない場合のポート開放

DuckDNS + Caddy で正規のTLSを張る方法もあります。この場合、**2か所**を開ける
必要があります。片方だけでは絶対に通りません。

### クラウド側

**Networking** → **Virtual cloud networks** → 対象VCN → **Security Lists** →
**Default Security List** → **Security rules** タブ → **Add Ingress Rules**

| 項目 | 値 |
| --- | --- |
| Source Type | CIDR |
| Source CIDR | 0.0.0.0/0 |
| IP Protocol | TCP |
| Destination Port Range | 443 |

### OS側

**Ubuntu イメージで `ufw enable` を実行してはいけません。** 有効化すると
インスタンスが再起動に失敗する既知問題があります
([Known Issues for Compute](https://docs.oracle.com/en-us/iaas/Content/Compute/known-issues.htm))。

`/etc/iptables/rules.v4` を編集し、**末尾の REJECT 行より前**に追記します。

```bash
sudo nano /etc/iptables/rules.v4
# -A INPUT -j REJECT --reject-with icmp-host-prohibited の行より上に
# -A INPUT -p tcp --dport 443 -j ACCEPT を追記

sudo su -
iptables-restore < /etc/iptables/rules.v4
```

REJECT より後に書いたルールは効きません。

### Caddy を入れる

```bash
sudo apt install -y caddy
sudo cp /opt/mexc-bot-src/deploy/Caddyfile /etc/caddy/Caddyfile
sudo nano /etc/caddy/Caddyfile   # ドメイン名を書き換える
sudo systemctl restart caddy
```

アプリの設定には `wss://<あなたの名前>.duckdns.org/ws` を入れます。

> 自己署名証明書は勧めません。Dart の `WebSocket.connect` は証明書の扱いが
> 面倒で、アプリ側で検証を無効にすることになり、盗聴・改ざんに無防備になります。

---

## 運用のこつ

- **ログ**: `tail -f /var/log/mexc-bot/server.log`
- **再起動**: `sudo systemctl restart mexc-bot`
- **自動再起動**: systemd が10秒後に立ち上げ直します (5分で5回失敗したら止まります)
- **Tailscale の自動起動確認**: `systemctl is-enabled tailscaled` が `enabled`
- **APIキーの失効**: IPホワイトリスト未登録のキーは90日で失効します。
  手順6で確定した予約済みIPを MEXC 側に登録してください
- **MEXC への疎通確認**: データセンターのIPが WAF で弾かれる事例があります。
  本番前に `curl -s https://api.mexc.com/api/v1/contract/ping` で確認してください
- **A1 インスタンスは terminate しない**: 容量不足で作り直せないことがあります。
  OS の入れ替えやサイズ変更でも、既存インスタンスを活かす方針にしてください
- **無料枠の仕様変更**: Oracle は2026年6月の半減を事前告知なしに実施した前例が
  あります。設定 (`/var/lib/mexc-bot/`) とAPIキー (`/etc/mexc-bot/env`) を
  控えておけば、別の場所へすぐ移せます

## 参考リンク

| 内容 | URL |
| --- | --- |
| Always Free の現行リソース一覧 | https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm |
| アイドル回収の条件 | https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm |
| インスタンス作成の全項目 | https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/launchinginstance.htm |
| セキュリティリストの編集 | https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/update-securitylist.htm |
| OSファイアウォールも必要な根拠 | https://docs.oracle.com/en-us/iaas/Content/Network/Concepts/securityrules.htm |
| Tailscale とは | https://tailscale.com/kb/1151/what-is-tailscale |
| Tailscale の仕組み | https://tailscale.com/blog/how-tailscale-works |
| Tailscale 料金 | https://tailscale.com/pricing |
