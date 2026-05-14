# 次セッション開始用プロンプト

次セッションの最初に Claude にコピペで投げるための簡潔プロンプト。詳細 hand-off は同ディレクトリの `2026-05-14-handoff-mac-comm-and-refactor.md` 側。

---

```
stackchan-picoruby の続き。bring-up smoke (LED + face + heartbeat) は CoreS3 実機で確認済み、`feature/stackchan-display-bringup` ブランチ tip = `f50780e`、working tree clean。

次の目的は **Mac との通信 (BLE か WiFi) を立ち上げて、その過程で全体設計を見直す** こと。

詳細な状況・守るべきルール・決めなあかん事 (BLE vs WiFi、リファクタ範囲) は `docs/superpowers/specs/2026-05-14-handoff-mac-comm-and-refactor.md` に全部書いてある。**まずそれを Read して、Q1 (BLE/WiFi) と Q2 (リファクタスコープ) について自分の推奨を出してから、わたしに確認をください**。
```

---

## 補足

- 上の prompt は 1 メッセージで投げる
- Claude 側は handoff doc を Read → memory も自動で照会される (MEMORY.md は load 済み) → Q1/Q2 の推奨を提示する流れ
- BLE/WiFi の事前調査 (PicoRuby on R2P2-ESP32 の対応 gem 有無) は handoff doc の TODO 1 にある。これも推奨と合わせて報告してくれるはず
