# stackchan-picoruby

StackChan を PicoRuby（[R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)）で動かすための個人プロジェクト。隣ディレクトリ `../StackChan` にある M5Stack 公式ファームウェアは参照のみ、絶対に変更しない。

## esa保存先

このプロジェクトに関連する記事・WIPメモ・進捗記録・spec共有は、すべて以下に保存する。

- esa team: `ksbrb`
- カテゴリ: `ｽﾀｯｸﾁｬﾝ` 配下

`mcp__esa__esa_create_post` を呼ぶときは `team_name=ksbrb`、`category` に上記パスを指定。

## 対象ハードウェア（実機）

- 製品: [M5 StackChan AI デスクトップロボット (Switch Science 11129)](https://www.switch-science.com/products/11129)
- SoC: ESP32-S3 デュアルコア LX7 240MHz / 16MB Flash / 8MB Quad PSRAM
- 通信: WiFi 802.11 b/g/n、Bluetooth 5 LE、赤外線TX/RX
- ディスプレイ: 2.0" IPS LCD 320×240 65536色、静電容量マルチタッチ
- IMU: **BMI270 + BMM150**（加速度・ジャイロはBMI270、磁気はBMM150）
- 環境センサ: LTR-553ALS-WA（近接・環境光）
- カメラ: GC0308 0.3MP (640×480)
- アクチュエータ: フィードバックサーボ2個（首振り360°連続回転、チルト90°）
- LED: 12個 RGB
- 頭タッチ: 3ゾーン（Si12T 系）
- マイク: デュアル / スピーカー1W
- その他: NFCモジュール、microSD、PCF8563 RTC、PY32 IO Expander、550mAhバッテリー、USB-C

公式ファームウェア (`../StackChan/firmware/main/hal/board/`、`../StackChan/firmware/main/hal/drivers/`) のC++実装はピン配置・初期化シーケンスの参照に使う。

## 関連リポジトリ

- 公式ファームウェア（参照のみ）: `../StackChan`
- PicoRuby on ESP32: [picoruby/R2P2-ESP32](https://github.com/picoruby/R2P2-ESP32)
- 参考になる自作 PicoRuby ドライバー（バッシュさん本人作）:
  - `/Users/bash/dev/src/github.com/bash0C7/picoruby-mpu6886`（IMU、構造が近い）
  - `/Users/bash/dev/src/github.com/bash0C7/picoruby-vl53l0x`
- PC側AI: `/Users/bash/dev/src/github.com/bash0C7/rb-foundation-model-mac`（Apple Foundation Model のRubyバインディング）
- PicoRuby本体（仕様確認用）: `/Users/bash/dev/src/github.com/picoruby/picoruby`

## アーキテクチャ方針

PC連携アバターパターン：

- **StackChan側**：R2P2-ESP32 + PicoRuby スクリプト。I/O 端末として動作。センサ値を読んでシリアルで送信、PCからのコマンドでサーボ/LED/表情を駆動
- **PC側**：Ruby (rb-foundation-model-mac) でローカルAI判断。BLE-serial（USB-serialでも可）でStackChanとプロトコル通信

## PicoRubyの制約・互換性の調べ方

固定リストに頼らない。以下の順で確認する。

1. `chiebukuro-mcp` の Ruby/PicoRuby ナレッジDB (`chiebukuro_query_ruby_knowledge` / `chiebukuro_semantic_search_ruby_knowledge`)
2. 答えが無い・根拠が必要なら `/Users/bash/dev/src/github.com/picoruby/picoruby` を Explore subagent で調査
3. 仕様確認できないまま「禁止メソッド」前提で書かない

## 開発ルール

- ドライバー開発は基本 https://picoruby.org/terminal で実装・実機検証
- C拡張のmrbgemsが必要な場合のみ R2P2-ESP32 のビルドツリーに組み込む
- PicoRubyドライバーの構成は picoruby-mpu6886 / picoruby-vl53l0x のレイアウトを踏襲
- 公式 `../StackChan` には書き込まない。ピン配置や初期化シーケンスは読み取って参考にするだけ
- spec / plan は `docs/superpowers/specs/` `docs/superpowers/plans/` に置く
