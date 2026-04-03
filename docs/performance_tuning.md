# Cantaloupe IIIF画像配信 パフォーマンスチューニング記録

日付: 2026-04-03

## 環境

| 項目 | 値 |
|------|------|
| サーバー | AWS EC2 (us-east-1) |
| CPU | 2コア |
| メモリ | 7.6 GB |
| ディスク | 39 GB (使用48%) |
| Cantaloupe | islandora/cantaloupe:2.0.10 (Cantaloupe 5.0.5) |
| ソース | S3Source |
| ドメイン | (省略) |
| リバースプロキシ | Traefik (Let's Encrypt TLS) |

## 問題

IIIF画像の取得に時間がかかる（特に初回アクセス時）。

テスト画像: `clioimg/shyuga.tif` (46825×28127ピクセル)

## 調査結果

### 初期状態の診断

| 項目 | 状態 | 評価 |
|------|------|------|
| CPU使用率 | 1.06% | 余裕あり |
| メモリ (コンテナ) | 768.9 MiB / 2 GiB (37.5%) | 余裕あり |
| JVMヒープ上限 | 512 MB | 少なめ |
| キャッシュ | FilesystemCache 386MB / 13,950ファイル | 稼働中 |
| キャッシュボリューム | 未永続化 (docker-compose.yml使用時) | 要修正 |
| ソース画像形式 | strip形式TIF (ImageMagick convert作成) | 遅延の主因 |
| プロセッサ | Java2dProcessor (TurboJpegはライブラリ互換性問題で使用不可) | 次善策 |

### ボトルネック分析

初回アクセスで8.8秒かかる原因:

1. **ソース画像形式** (最大の問題): strip形式TIFのため、1タイル取得にS3から9チャンク(各2MB)の読み込みが必要
2. **JVMヒープ不足**: 512MBでは大画像処理時にGCが頻発する可能性
3. **キャッシュ消失**: `docker-compose.yml` にボリュームマウントがなく、コンテナ再作成でキャッシュが消失

## 実施した施策

### 1. ソース画像をピラミッドタイルTIFF (ptif) に変換 — 効果: 最大

ImageMagick `convert` で作成したstrip形式TIFを、vipsでピラミッドタイルTIFFに変換。

```bash
vips tiffsave input.tif output.tif --tile --pyramid --tile-width 256 --tile-height 256 --compression jpeg --Q 85
```

- 変換前: 元ファイルサイズ不明（strip形式）
- 変換後: 219MB（Q85, ピラミッド付きタイルTIFF）

**結果:**

| | 変換前 (strip TIF) | 変換後 (ptif Q85) |
|---|---|---|
| 初回タイル (cold) | 8.8秒 | 0.7〜1.3秒 |
| 2回目タイル (cold, 別領域) | 1.7秒 | 0.7秒 |
| キャッシュ済みタイル | 0.04秒 | 0.01秒 |
| S3チャンク読み込み | 9回 | 少数 |
| 画像処理時間 | 1073ms | 510ms |

### 2. JVMヒープ増加 — 効果: 中 (高負荷時に有効)

コンテナのメモリ上限2GBに対してJVMヒープがデフォルト512MBだった。
カスタム起動スクリプト (`cantaloupe-run.sh`) をマウントして1536MBに増加。

```bash
# cantaloupe-run.sh
exec s6-setuidgid cantaloupe java -Xmx1536m -Xms512m \
  -Dcantaloupe.config=/opt/cantaloupe/cantaloupe.properties \
  -jar /opt/cantaloupe/cantaloupe.jar
```

`JAVA_OPTS` 環境変数はこのイメージ (islandora/cantaloupe:2.0.10) では起動スクリプトが参照しないため、直接マウントで対応。

### 3. キャッシュボリュームの永続化 — 効果: 中

`docker-compose.prod.yml` には元から `cantaloupe_cache:/data` が設定されていた。
`docker-compose.yml` で起動していたためキャッシュが消失していた問題を修正。

## 試したが効果がなかった施策

### CacheStrategy への変更

`processor.stream_retrieval_strategy` を `StreamStrategy` → `CacheStrategy` に変更。
ソース画像全体をローカルにダウンロードしてから処理する方式。

**結果:** 初回が逆に遅くなった（4.8秒）。ソースが非タイルTIFの場合、ローカルに持ってきても読み込みが遅いため効果なし。元に戻し済み。

### TurboJpegProcessor の有効化

`processor.ManualSelectionStrategy.tif = TurboJpegProcessor` に設定されているが、実際には `Java2dProcessor` にフォールバックしている。

**原因:** Cantaloupe 5.0.5にバンドルされたJavaバインディングと、OS側のlibjpeg-turbo 2.1.5のAPIバージョン不一致。

```
Failed to initialize TurboJpegProcessor
(error: 'org.libjpegturbo.turbojpeg.TJScalingFactor[] org.libjpegturbo.turbojpeg.TJ.getScalingFactors()')
```

シンボリックリンク (`/opt/libjpeg-turbo/lib/libturbojpeg.so`) の作成で「Can't load library」エラーは解消したが、API互換性の問題は残る。Cantaloupe 6.x系へのアップグレードで解消可能。

### 4. Cantaloupeイメージのアップグレード — 効果: 中

`islandora/cantaloupe:2.0.10` (Cantaloupe 5.0.5) → `islandora/cantaloupe:6.3.12` (Cantaloupe 5.0.7) に更新。

**結果:**

| | 2.0.10 (5.0.5) | 6.3.12 (5.0.7) |
|---|---|---|
| 初回タイル (cold) | 1.3秒 | 0.84秒 |
| 画像処理時間 | 510ms | 302ms |

注: TurboJpegProcessorはTIFソースには対応しておらず、Java2dProcessorが使用される。

### 5. CloudFront (CDN) の導入 — 効果: 大

CloudFrontを導入し、全リクエストをエッジ経由で配信するようにした。

#### アーキテクチャ

```
変更前:  ユーザー (日本) ──146ms往復──→ EC2 (us-east-1) → Cantaloupe → S3
変更後:  ユーザー (日本) ──数ms──→ CloudFront東京エッジ ──→ EC2 (us-east-1) → Cantaloupe → S3
                                    ↑ キャッシュヒット時はここで返す
```

#### ドメイン構成

| ドメイン | 向き先 | 用途 |
|---|---|---|
| `<公開ドメイン>` | CloudFront | ユーザーがアクセスするURL |
| `<オリジンドメイン>` | EC2 | CloudFrontのオリジン |

#### CloudFront設定

| 項目 | 値 |
|---|---|
| Origin | `<オリジンドメイン>:443` (HTTPS) |
| Origin Protocol | https-only (Traefik経由、Let's Encrypt TLS) |
| Cache TTL | MinTTL: 1日, Default: 30日, Max: 1年 |
| Price Class | PriceClass_200 (北米・欧州・アジア) |
| HTTP Version | HTTP/2 + HTTP/3 |
| ACM証明書 | us-east-1で発行 (CloudFrontの要件) |

#### info.json の @id 問題と解決

Cantaloupeはリクエストの`Host`ヘッダから`info.json`の`@id`を生成する。
CloudFront → オリジンのリクエストでは`Host: cantaloupe-origin...`が送られるため、
MiradorがCloudFrontをバイパスしてオリジンに直接アクセスしてしまう問題が発生。

**解決:** `CANTALOUPE_BASE_URI` 環境変数でベースURLをCloudFrontドメインに固定。

```yaml
CANTALOUPE_BASE_URI: "https://<公開ドメイン>"
```

#### ポート8182直接公開 vs Traefik経由

CloudFrontのオリジンにはドメイン名が必要（IPアドレス不可）。
ポート8182を直接公開する方法もあるが、Traefik経由(443)を採用した。

| | 8182直接公開 | Traefik経由 (採用) |
|---|---|---|
| TLS | なし（HTTP平文） | Let's Encrypt TLS |
| セキュリティ | SG開放が必要 | 既存の443のみ |
| CloudFront↔EC2通信 | 暗号化なし | 暗号化あり |

#### 結果 (Mirador並列20タイルシミュレーション)

| シナリオ | 全体完了時間 |
|---|---|
| CloudFront miss (cold) | 6.2秒 |
| **CloudFront hit (cached)** | **1.3秒** (USから測定。日本からは0.1〜0.2秒程度) |
| Direct localhost (cold) | 4.4秒 |

#### AWSリソース

- **ACM証明書** (us-east-1): 公開ドメイン用、dev用
- **CloudFront**: prod用、dev用の2つのディストリビューション
- **Route 53レコード**: オリジンドメイン → A → EC2のIP
- **IAMポリシー**: `CantaloupeCloudFrontSetup` (EC2ロールにアタッチ)

## 試したが効果がなかった施策

### CacheStrategy への変更

`processor.stream_retrieval_strategy` を `StreamStrategy` → `CacheStrategy` に変更。
ソース画像全体をローカルにダウンロードしてから処理する方式。

**結果:** 初回が逆に遅くなった（4.8秒）。ソースが非タイルTIFの場合、ローカルに持ってきても読み込みが遅いため効果なし。元に戻し済み。

### TurboJpegProcessor の有効化 (2.0.10イメージ)

`processor.ManualSelectionStrategy.tif = TurboJpegProcessor` に設定されているが、実際には `Java2dProcessor` にフォールバックしている。

**原因:** Cantaloupe 5.0.5にバンドルされたJavaバインディングと、OS側のlibjpeg-turbo 2.1.5のAPIバージョン不一致。

```
Failed to initialize TurboJpegProcessor
(error: 'org.libjpegturbo.turbojpeg.TJScalingFactor[] org.libjpegturbo.turbojpeg.TJ.getScalingFactors()')
```

6.3.12イメージではライブラリの互換性は解消したが、TurboJpegProcessorはTIFソースに対応していないため、Java2dProcessorが使用される。

## 今後の改善案

### 1. キャッシュのプリウォーム（効果大・簡単）

よくアクセスされる画像のタイルを事前に全生成するスクリプトを用意する。
CloudFrontのキャッシュにも載るため、ユーザーは常にエッジからの高速配信を受けられる。

```bash
# 例: 全タイルを事前リクエスト
for x in $(seq 0 1024 $WIDTH); do
  for y in $(seq 0 1024 $HEIGHT); do
    curl -s -o /dev/null "https://<公開ドメイン>/iiif/2/<image_id>/${x},${y},1024,1024/512,/0/default.jpg" &
  done
  wait
done
```

### 2. サーバースペック増強（効果中・cold時に有効）

現在2コア (t3.large)。Miradorの並列リクエスト時にCPU使用率が122%に達する。
t3.xlarge (4コア/16GB) にすれば、cold時の並列処理が約2倍に改善。

### 3. 東京リージョンへの移行（効果中・大変）

EC2/S3を東京リージョンに移行すれば、CloudFront miss時のオリジン取得も高速化。
ただしCloudFrontのキャッシュヒット率が高ければ効果は限定的。

## 最終構成

### 全体像

```
ユーザー → CloudFront (<公開ドメイン>)
              ↓ miss時のみ
           Traefik (<オリジンドメイン>:443, Let's Encrypt TLS)
              ↓
           Cantaloupe (islandora/cantaloupe:6.3.12, JVM heap 1536MB)
              ↓
           S3 (us-east-1)
```

### docker-compose.prod.yml

変更点:
- イメージ: `islandora/cantaloupe:2.0.10` → `islandora/cantaloupe:6.3.12`
- Traefikルール: `<公開ドメイン>` → `<オリジンドメイン>`
- 環境変数追加: `CANTALOUPE_BASE_URI`, `CANTALOUPE_CACHE_SERVER_DERIVATIVE_ENABLED`, `CANTALOUPE_CACHE_SERVER_DERIVATIVE`
- `./cantaloupe-run.sh` マウント（JVMヒープ増加）

### cantaloupe-run.sh

オリジナルの起動スクリプトに `-Xmx1536m -Xms512m` を追加。

### パフォーマンス改善の総合結果

| 指標 | 改善前 | 改善後 |
|---|---|---|
| 初回タイル (単発, cold) | 8.8秒 | 0.84秒 |
| Mirador並列20タイル (cold) | 測定なし (推定15秒以上) | 6.2秒 (CloudFront miss) |
| キャッシュ済みタイル | 0.04秒 (サーバー経由) | 0.1〜0.2秒 (東京エッジ配信) |
| 日本からの体感 (cached) | 往復292ms + サーバー処理 | エッジから直接配信 |
