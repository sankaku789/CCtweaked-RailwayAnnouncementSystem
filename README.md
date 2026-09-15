# CCtweaked-RailwayAnnouncementSystem

CC:Tweaked向けの鉄道自動放送システムです。

MVPでは「1線 = 1 Computer」を前提に、通常Redstone入力1本のNEXTパルスで内部状態を進めます。
MTR/Createなどの鉄道MOD固有情報はMetadata Adapterから任意で取得し、取得できない場合でも簡易放送を継続します。

## 状態遷移

通常Redstone入力の立ち上がりごとに以下の順で状態を進めます。

```text
IDLE
  -> APPROACH
  -> PLATFORM
  -> DEPARTURE
  -> IDLE
```

デフォルトではDEPARTUREイベント生成後に自動でIDLEへ戻るため、1列車あたり3パルスです。

- 1パルス目: 接近放送
- 2パルス目: PLATFORM状態へ遷移（MVPでは放送なし）
- 3パルス目: 発車放送、その後IDLEへ自動復帰

## 接近放送

以下の順でセグメントを合成します。

```text
[接近メロディ]         optional
「まもなく、」
[n番線に、]            ファイルがあれば再生

Adapterから種別/行先を実際に再生できる場合:
  [種別]
  [行先]
  ※「列車が」は省略

情報がない場合:
  「列車が、」

「まいります。危険ですので、黄色い点字ブロックまで、お下がりください。」
[到着メロディ]         optional / default OFF
```

発車時は発車メロディを再生し、`doorsClosingEnabled = true` の場合のみドア閉め放送を追加します。

## 音声ファイル

デフォルト設定では以下のパスを使用します。

```text
audio/
├─ approach/
│  ├─ melody.dfpwm
│  ├─ soon.dfpwm
│  ├─ train.dfpwm
│  └─ warning.dfpwm
├─ arrival/
│  └─ melody.dfpwm
├─ departure/
│  ├─ melody.dfpwm
│  └─ doors_closing.dfpwm
├─ track/
│  └─ 1.dfpwm
├─ class/
│  └─ <class-id>.dfpwm
└─ destination/
   └─ <destination-id>.dfpwm
```

`track`、`class`、`destination`、各optional melodyはファイルが無ければskipします。
固定文のファイルが無い場合は警告を出して、そのセグメントだけskipします。

## 設定

`config.lua` を編集します。

主な項目:

- `trackNumber`: 番線番号
- `redstone.side`: NEXTパルスを受ける通常Redstone入力面
- `state.autoResetAfterDeparture`: DEPARTURE後に自動でIDLEへ戻す
- `speaker.volume`: Speaker音量
- `adapter.module`: Metadata Adapter名。既定は`none`
- `adapter.cacheTtlMs`: MetadataのRAM cache TTL
- `announcement.approach.arrivalMelodyEnabled`: 到着メロディ。既定OFF
- `announcement.departure.doorsClosingEnabled`: ドア閉め放送。既定OFF

## Metadata Adapter

CoreはMTR/CreateのAPIを直接参照しません。

Adapterはセグメント合成に必要な情報だけを返します。

```lua
{
    class = "rapid",
    destination = "central",
}
```

Adapterが失敗・未設定の場合、接近放送は自動的に「列車が」を使う簡易放送になります。

### MTR Adapter

`adapter/mtr.lua` はTransport Simulation CoreのSystem Map arrivals APIから、対象ホームの次列車1件を取得します。

使用するMTRフィールドは以下です。

```text
routeNumber -> class
destination -> destination
```

MTR側の名称は `日本語|English` を前提とし、`|` の右側の英語部分を音声IDへ変換します。
大文字小文字は区別せず、英数字以外の連続文字は `_` に正規化します。

```text
快速|Rapid              -> rapid
特急|Limited Express    -> limited_express
中央|Central            -> central
New Town                -> new_town
```

そのため、音声ファイルは正規化後のIDをそのままファイル名にします。

```text
audio/class/rapid.dfpwm
audio/class/limited_express.dfpwm
audio/destination/central.dfpwm
audio/destination/new_town.dfpwm
```

MTR Adapterを使用する場合は、`config.lua` を設定します。

```lua
adapter = {
    module = "mtr",
    cacheTtlMs = 30000,

    mtr = {
        baseUrl = "http://localhost:8888",
        dimension = 0,
        platformIdHex = "<platform-id-hex>",
    },
}
```

`baseUrl` はTSCのHTTP APIアドレスです。TSC単体の既定Webserver portは`8888`ですが、
実際のMTR環境で別ポートを使用している場合はその値へ変更してください。

`platformIdHex` は対象ホームのhex IDです。
Adapterは以下のrequest相当を `/mtr/api/map/arrivals?dimension=<n>` へ送ります。

```json
{
  "platformIdsHex": ["<platform-id-hex>"],
  "maxCountPerPlatform": 1,
  "maxCountTotal": 1
}
```

HTTP/APIエラー、列車情報なし、英語部分を正規化できない場合はmetadataを返さず、
Coreは簡易放送へフォールバックします。

## 複数Speaker

旧実装のSpeakerごとの独立進行をやめ、同一DFPWM chunkを全Speakerへ投入した後、
全Speakerの`speaker_audio_empty`を待つバリア方式で次chunkへ進みます。

CC:Tweaked/Minecraft側のバッファやtickによる完全同期は保証できませんが、
Speaker間でchunk位置が累積的にずれることを抑える設計です。

## コード規約

各Lua関数の直前には、旧コードと同様に英語で機能を示すコメントを付けます。

```lua
-- function: Play an ordered list of audio segment files.
function Player:playSegments(segments)
    ...
end
```

## モジュール

```text
startup.lua
app.lua
config.lua

core/
  track_state.lua
  announcement_queue.lua
  composer.lua
  scheduler.lua

hardware/
  redstone_input.lua
  speakers.lua

audio/
  player.lua
  segment.lua

metadata/
  cache.lua
  provider.lua

adapter/
  none.lua
  mtr.lua

util/
  log.lua
```
