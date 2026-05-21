# pc/stackchan-ble-client 規律

## Mac CoreBluetooth quirks

- **GATT cache trap**: macOS は CoreBluetooth で GATT structure を peripheral address ごとに**永続キャッシュ**。一度「0 services」が cache されると Bluetooth module reset でもクリアされず、deviceが正しい services を advertise しても Mac 側は 0 services のまま見続ける。Mac 側開発と並行して **iPhone nRF Connect 等の外部 scanner で device の GATT を必ず検証**して、Mac の cache 状態と device-side bug を切り分ける。
- **GAP/GATT filter**: Apple (Mac/iOS) は `CBPeripheral.discoverServices(nil)` の結果から GAP (0x1800) と GATT (0x1801) を**自動 filter**して返す。0x2A00 (Device Name characteristic) を探す道は塞がれてるので、device 名は **scan response advertisement の name** から取る。application-level services のみが discovered list に出る前提で書く。
- **Device name 切り詰め**: Mac CoreBluetooth は long device name の suffix を切り詰め/cache する。base name を短く固定し、`--name-prefix` で prefix match する設計が安全 (epoch suffix で個体識別する design は機能しない)。

## Wire format quirks

- **色は HSB packed (0xHHSSBB) で送る**、RGB ではない。`H=255°, S=0, B=0` を含む値 (e.g. `0xFF0000` を RGB のつもりで渡す) は HSB として解釈されて黒になる。CLI / SDK 側で named symbol から HSB packed への変換を必ず通す。
- **Wire char L/R は StackChan の左右と逆**: device firmware は wire 上 "L" = operator から見て右手 = StackChan の左手 という変換を内部で吸収する。SDK 側 `SIDE_TO_CHAR` (client.rb) で `:left` → `"L"` / `:right` → `"R"` に正規化済み。外から触る場合はこのレイヤーを通すこと。
