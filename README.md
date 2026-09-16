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

## 放送パターン

放送順は `announcement/patterns.lua` に宣言します。

```lua
return {
    approach = {
        "?approach_melody",
        "soon",
        "?track",
        "train_info|train",
        "warning",
        "?arrival_melody",
    },

    departure = {
        "departure_melody",
        "?doors_closing",
    },
}
```

記法は以下の3種類です。

```text
segment
    必須セグメント

?segment
    optional。解決できない場合はskip

primary|fallback
    primaryが再生可能ならprimary、解決できなければfallback
```

`train_info|train` は、種別音声と行先音声を両方解決できる場合だけ詳細放送を使い、
どちらかが不足した場合は `train` の簡易放送へフォールバックします。

## セグメント定義

セグメントIDと実ファイル・動的Resolverの対応は `announcement/segments.lua` に定義します。

固定ファイルの例:

```lua
soon = {
    kind = "file",
    path = "audio/approach/soon.dfpwm",
},
```

設定で有効/無効を切り替えるセグメント:

```lua
arrival_melody = {
    kind = "file",
    path = "audio/arrival/melody.dfpwm",
    enabled = "announcement.approach.arrivalMelodyEnabled",
},
```

動的セグメントの例:

```lua
track = {
    kind = "dynamic",
    resolver = "track",
    directory = "audio/track",
},

train_info = {
    kind = "dynamic",
    resolver = "train_info",
    classDirectory = "audio/class",
    destinationDirectory = "audio/destination",
},
```

`track` は `request.track` から番線音声を解決します。
`train_info` はMetadata Adapterの `class` と `destination` から2ファイルをまとめて解決します。

Composerは物理ファイルパスを直接知りません。

```text
announcement/patterns.lua
        ↓
semantic segment IDs
        ↓
audio/segment.lua
        ↓
DFPWM file paths
        ↓
audio/player.lua
```

## 音声ファイル

デフォルトのセグメント定義では以下の構成を使用します。

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
│  ├─ 1.dfpwm
│  ├─ 2.dfpwm
│  └─ ...
├─ class/
│  ├─ rapid.dfpwm
│  ├─ limited_express.dfpwm
│  └─ ...
└─ destination/
   ├─ central.dfpwm
   └─ ...
```

固定音声のパスを変える場合は `announcement/segments.lua` を編集します。
番線・種別・行先のディレクトリも同ファイルのdynamic segment定義で変更できます。

## 設定

`config.lua` の主な項目:

- `trackNumber`: 番線番号
- `redstone.side`: NEXTパルスを受ける通常Redstone入力面
- `state.autoResetAfterDeparture`: DEPARTURE後に自動でIDLEへ戻す
- `speaker.volume`: Speaker音量
- `adapter.module`: Metadata Adapter名。既定は`none`
- `adapter.cacheTtlMs`: MetadataのRAM cache TTL
- `announcement.approach.melodyEnabled`: 接近メロディ。既定ON
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

Adapterが失敗・未設定の場合、`train_info` が解決できないため、
`train_info|train` により簡易放送へフォールバックします。

### MTR Adapter

`adapter/mtr.lua` はTransport Simulation CoreのSystem Map arrivals APIから、対象ホームの次列車1件を取得します。

使用するMTRフィールド:

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

対応する音声ファイル:

```text
audio/class/rapid.dfpwm
audio/class/limited_express.dfpwm
audio/destination/central.dfpwm
audio/destination/new_town.dfpwm
```

MTR Adapterを使用する場合は `config.lua` を設定します。

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

`platformIdHex` は対象ホームのhex IDです。
HTTP/APIエラー、列車情報なし、英語部分を正規化できない場合はmetadataを返しません。

## 複数Speaker

同一DFPWM chunkを全Speakerへ投入した後、全Speakerの `speaker_audio_empty` を待つバリア方式で次chunkへ進みます。
CC:Tweaked/Minecraft側のバッファやtickによる完全同期は保証しませんが、Speaker間でchunk位置が累積的にずれることを抑える設計です。

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

announcement/
  patterns.lua
  segments.lua

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
