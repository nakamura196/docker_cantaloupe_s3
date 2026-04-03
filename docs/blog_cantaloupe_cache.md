---
title: "Cantaloupe IIIFサーバーのキャッシュ最適化で画像配信を最大7.6倍高速化した"
emoji: "🚀"
type: "tech"
topics: ["IIIF", "Cantaloupe", "Docker", "パフォーマンス", "S3"]
published: false
---

## はじめに

IIIFに対応した画像サーバーである[Cantaloupe](https://cantaloupe-project.github.io/)を、S3をソースとしたDocker環境で運用しています。IIIFビューア（Mirador, OpenSeadragonなど）では、ズームやパンの操作のたびに数十〜数百のタイルリクエストが同時に発生します。

今回、キャッシュ設定の見直しとパラメータチューニングにより、**タイル配信速度を最大7.6倍高速化**できたので、その手法と効果を共有します。

## 環境

- **サーバー**: AWS EC2（2 vCPU, 7.6GB RAM）
- **Cantaloupe**: `islandora/cantaloupe:2.0.10`（Cantaloupe 5.0.7ベース）
- **画像ソース**: Amazon S3（`S3Source`）
- **テスト画像**: 25167×12483px のTIFF画像（512×512タイル）
- **リバースプロキシ**: Traefik v3.2
- **構成**: Docker Compose

## 問題：デフォルト設定ではキャッシュが無効

`islandora/cantaloupe` イメージのデフォルト設定を調査したところ、以下の状態でした。

| キャッシュ種別 | デフォルト | 説明 |
|---|---|---|
| Derivative Cache（加工済み画像） | **無効** | 同じリクエストでも毎回画像変換が発生 |
| Source Cache（元画像のローカルコピー） | 有効（FilesystemCache） | S3から取得した元画像をローカルに保持 |
| Info Cache（画像メタデータ） | 有効（メモリ内） | 画像の寸法・タイル情報を保持 |
| Client Cache（HTTPヘッダ） | 有効（max-age 30日） | ブラウザ側のキャッシュ制御 |

**最大の問題は Derivative Cache が無効であること**です。IIIFビューアが同じタイルを再度リクエストした場合でも、毎回 S3 → ダウンロード → 画像変換 → レスポンス という処理が走ります。

## ベンチマーク方法

### 単純なタイル一括テスト

まず基本的な性能測定として、以下の条件で一括タイルベンチマークを行いました。

- **タイル数**: 91タイル（zoom level 4、scaleFactor=4の全タイル）
- **同時接続数**: 10（ブラウザの一般的な同時接続数）
- **ツール**: `curl` + `xargs -P`による並列リクエスト

```bash
# タイルURLを生成し、10並列で同時リクエスト
xargs -a tile_urls.txt -P 10 -I {} \
  curl -s -o /dev/null -w "%{time_total}\n" "{}"
```

### Miradorシミュレーション

単純なタイル一括テストに加え、IIIFビューア（Mirador）の実際の操作フローを再現したベンチマークも行いました。Miradorでは、ユーザーが画像を開くと以下のリクエストが短時間に発生します。

| フェーズ | 内容 | 同時接続数 |
|---|---|---|
| Phase 1 | `info.json` + サムネイル取得 | 2 |
| Phase 2 | 初期ビューポートのタイル読み込み（28タイル、scaleFactor=8） | 6 |
| Phase 3 | ズームイン操作（50タイル、scaleFactor=2） | 6 |
| Phase 4 | 複数ユーザー同時アクセス（3ユーザー×異なる領域、計24タイル） | 18 |

同時接続数はChromeのデフォルト（1ホストあたり6接続）に合わせています。

## Step 1: キャッシュの有効化

### 変更内容

`.env` に以下を追加しました。

```env
# Derivative Cache（加工済み画像のキャッシュ）
CANTALOUPE_CACHE_SERVER_DERIVATIVE_ENABLED=true
CANTALOUPE_CACHE_SERVER_DERIVATIVE=FilesystemCache
CANTALOUPE_CACHE_SERVER_DERIVATIVE_TTL_SECONDS=2592000

# Source Cache（元画像のローカルキャッシュ）
CANTALOUPE_CACHE_SERVER_SOURCE=FilesystemCache
CANTALOUPE_CACHE_SERVER_SOURCE_TTL_SECONDS=2592000

# Cache Worker（期限切れキャッシュの自動削除、24時間間隔）
CANTALOUPE_CACHE_SERVER_WORKER_ENABLED=true
CANTALOUPE_CACHE_SERVER_WORKER_INTERVAL=86400

# FilesystemCacheの保存先
CANTALOUPE_FILESYSTEMCACHE_PATHNAME=/data
```

`docker-compose.prod.yml` には、キャッシュの永続化とメモリ増量を追加しました。

```yaml
services:
  cantaloupe:
    deploy:
      resources:
        limits:
          memory: 2G   # 1G → 2G に増量
        reservations:
          memory: 1G   # 512M → 1G に増量
    volumes:
      - cantaloupe_cache:/data  # キャッシュの永続化

volumes:
  cantaloupe_cache:
```

### 結果

| シナリオ | 総時間（91タイル） | 平均/タイル | P95 |
|---|---|---|---|
| **変更前**（キャッシュなし） | 12,240ms | 1.277s | 2.769s |
| 変更後・初回（キャッシュ書込み） | 38,557ms | 4.132s | 10.420s |
| **変更後・2回目以降（キャッシュヒット）** | **1,991ms** | **0.156s** | **0.248s** |

初回アクセスはキャッシュ書き込みのオーバーヘッドで遅くなりますが、**2回目以降は約6倍高速**になりました。

## Step 2: S3チャンキング・プロセッサ・JVMの最適化

### 変更内容

`.env` にさらに以下を追加しました。

```env
# S3チャンキング最適化（S3からの読み込みバッファ）
CANTALOUPE_S3SOURCE_CHUNKING_ENABLED=true
CANTALOUPE_S3SOURCE_CHUNKING_CHUNK_SIZE=2M        # 512K → 2M
CANTALOUPE_S3SOURCE_CHUNKING_CACHE_ENABLED=true
CANTALOUPE_S3SOURCE_CHUNKING_CACHE_MAX_SIZE=50M    # 5M → 50M

# TIF処理をTurboJpegProcessor に変更（ネイティブライブラリで高速）
CANTALOUPE_PROCESSOR_MANUALSELECTIONSTRATEGY_TIF=TurboJpegProcessor
CANTALOUPE_PROCESSOR_SELECTION_STRATEGY=ManualSelectionStrategy

# JVMヒープチューニング
JAVA_OPTS=-Xmx1280m -Xms512m -XX:+UseG1GC
```

各設定の狙いは以下の通りです。

| 設定 | 変更前 | 変更後 | 狙い |
|---|---|---|---|
| チャンクサイズ | 512KB | 2MB | S3へのリクエスト回数を約1/4に削減 |
| チャンキングキャッシュ | 5MB | 50MB | メモリ内にソースデータを保持し、再ダウンロードを回避 |
| TIFプロセッサ | Java2dProcessor | TurboJpegProcessor | ネイティブライブラリによるJPEG出力高速化 |
| JVM GC | デフォルト | G1GC + ヒープ1280MB | GC頻度の低減と安定化 |

### 結果

| シナリオ | 総時間（91タイル） | 平均/タイル | P95 |
|---|---|---|---|
| コールド（初回、完全にキャッシュなし） | **3,338ms** | 0.321s | 1.004s |
| セミウォーム（ディスクキャッシュなし、メモリキャッシュあり） | **1,602ms** | 0.114s | 0.192s |
| ウォーム（キャッシュヒット） | **1,896ms** | 0.140s | 0.229s |

Step 1 でのコールドアクセス（38.6秒）と比較して、**コールドアクセスが約11.5倍高速化**されました。

## 全体の比較

| フェーズ | コールド | ウォーム |
|---|---|---|
| 初期状態（キャッシュ無効） | 12,240ms | —（毎回同じ） |
| Step 1: キャッシュ有効化 | 38,557ms | **1,991ms** |
| Step 2: + チューニング | **3,338ms** | **1,602ms**（セミウォーム） |

**最終的な改善率:**

- **ウォーム時: 約7.6倍高速**（12.2秒 → 1.6秒）
- **コールド時のStep1→Step2: 約11.5倍高速**（38.6秒 → 3.3秒）
- **タイルあたり平均: 約9倍高速**（1.28秒 → 0.14秒）

## リソース使用量

最適化後も、CPU・メモリの使用量に大きな変化はありませんでした。

| 状態 | CPU | メモリ |
|---|---|---|
| アイドル時 | 0.1% | 656MB / 2GB（32%） |
| 負荷時（91タイル同時） | 5% | 657MB / 2GB（32%） |

FilesystemCacheはディスクベースのため、メモリ消費が増えないのが利点です。

## 注意点

### キャッシュのディスク容量

FilesystemCacheには**サイズ上限の設定がありません**。TTL（30日）とCache Worker（24時間間隔の自動削除）で管理されますが、画像数が多い場合はディスク容量を圧迫する可能性があります。定期的に `docker exec <container> du -sh /data` で確認することを推奨します。

### キャッシュの永続化

`docker-compose.yml` で `volumes` を設定しないと、コンテナの再起動でキャッシュがすべて失われます。named volume (`cantaloupe_cache:/data`) の設定を忘れないようにしましょう。

## 今後の取り組み

### Nginx リバースプロキシキャッシュの導入

現在使用しているTraefik v3.2にはネイティブなHTTPレスポンスキャッシュ機能がありません。Cantaloupeの前段にNginxのリバースプロキシキャッシュを追加することで、Cantaloupeに到達する前にキャッシュからレスポンスを返すことが可能になります。

```
Client → Traefik → Nginx (cache) → Cantaloupe → S3
```

これにより、キャッシュヒット時はCantaloupeプロセスに一切負荷がかからなくなり、さらなる高速化と同時接続数の向上が期待できます。特に、同一画像へのアクセスが集中するような公開コレクションでは大きな効果が見込まれます。

## まとめ

Cantaloupeのデフォルト設定では Derivative Cache が無効であり、S3ソースの場合は毎回ダウンロードと画像変換が発生するため、非常に非効率です。以下の2ステップの最適化により、大幅なパフォーマンス改善を実現できました。

1. **キャッシュの有効化**（Derivative Cache + Source Cache + Cache Worker）
2. **パラメータのチューニング**（S3チャンキング増量 + TurboJpegProcessor + JVMヒープ調整）

IIIFビューアでの体感としては、初回表示が3秒程度、2回目以降のズーム・パンは**ほぼ瞬時**に応答するようになりました。
