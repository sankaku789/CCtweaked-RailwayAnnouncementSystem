# CCtweaked-RailwayAnnouncementSystem

CC:Tweaked向けの鉄道自動放送システムです。

「1線 = 1 Computer」を前提に、停車列車の状態管理、通過列車、MTR metadata、定期放送、複数Speaker再生を分離して扱います。

## 入力

既定ではProjectRed等のBundled CableをCC:Tweakedのbundled redstone inputとして使用します。

```text
Bundled Cable (top)
├─ lime   : NEXT
└─ orange : PASSING

Normal Redstone (back)
└─ RESET button
```

`NEXT` は停車列車用の状態機械を1段進めます。
`PASSING` は状態を変更せず、通過放送を直接Queueへ投入します。
`RESET` はComputerへ直付けした通常Redstone buttonの立ち上がりで、状態を `IDLE` に戻します。

色と面は `config.lua` の `input` で変更できます。

## 停車列車の状態遷移

`NEXT` の立ち上がりごとに以下の順で進みます。

```text
IDLE
  -> APPROACH
  -> PLATFORM
  -> DEPARTURE
  -> IDLE
```

デフォルトではDEPARTUREイベント生成後に自動でIDLEへ戻るため、1列車あたり3パルスです。

- 1パルス目: 接近放送
- 2パルス目: PLATFORM状態へ遷移
- 3パルス目: 発車放送、その後IDLEへ自動復帰

`PASSING` はこの状態遷移には入りません。

## 優先度と割り込み

QueueはFIFOではなく、`priority` の高いrequestを先に処理します。同一priorityでは古いrequestが先です。

既定priority:

```text
100  approach
100  passing
100  departure
 20  stopped
 10  next_train
```

`queue.preemptPriority` 以上のrequestが来た場合、低priorityの待機中requestを破棄し、低priority放送を再生中ならSpeakerを停止して高priority放送へ切り替えます。

中断された定期放送は途中から再開しません。次の周期まで待ちます。

## 定期放送

`config.lua` の `periodic` で状態別の定期放送を設定できます。

既定では音声アセット未配置時の連続警告を避けるためOFFです。

```lua
periodic = {
    checkIntervalSeconds = 1,

    stopped = {
        enabled = false,
        state = "PLATFORM",
        type = "stopped",
        initialDelayMs = 30000,
        intervalMs = 30000,
    },

    nextTrain = {
        enabled = false,
        state = "IDLE",
        type = "next_train",
        initialDelayMs = 60000,
        intervalMs = 60000,
    },
}
```

`stopped` は `PLATFORM` 中、`next_train` は `IDLE` 中だけ繰り返します。状態が変わると待機中の定期放送は破棄され、タイマーも新しい状態用にリセットされます。

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

    approach_out_of_service = {
        "?approach_melody",
        "soon",
        "?track",
        "out_of_service_train",
        "warning",
        "?arrival_melody",
    },

    passing = {
        "passing_warning",
    },

    departure = {
        "departure_melody",
        "?doors_closing",
    },

    stopped = {
        "stopped_notice",
    },

    next_train = {
        "next_train_intro",
        "train_info|next_train_generic",
    },
}
```

記法:

```text
segment
    必須セグメント

?segment
    optional。解決できない場合はskip

primary|fallback
    primaryが再生可能ならprimary、解決できなければfallback
```

## 回送列車

MTR AdapterはTransport Simulation CoreのArrivalResponseにある `isTerminating` を `metadata.terminating` として返します。

```lua
{
    class = "rapid",
    destination = "sapporo",
    terminating = true,
}
```

通常の `approach` requestでも `terminating == true` ならComposerが `approach_out_of_service` を選択します。

これは `JR_Hokkaido_like_PIDS` と同じく「当駅止まり (`terminating`) を回送扱いする」判定です。

## 通過列車

通過列車はMTR arrivals APIから推測せず、遠方Sensor等からの専用Bundled signal `PASSING` で検知します。

```text
Remote train/redstone sensor
        ↓
Bundled PASSING signal
        ↓
CC Computer
        ↓
{ type = "passing", priority = 100 }
        ↓
passing announcement
```

通過信号は停車列車の `IDLE -> APPROACH -> PLATFORM -> DEPARTURE` 状態を変更しません。

## セグメント定義

セグメントIDと実ファイル・動的Resolverの対応は `announcement/segments.lua` に定義します。

固定ファイル:

```lua
passing_warning = {
    kind = "file",
    path = "audio/passing/warning.dfpwm",
},
```

動的セグメント:

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

`train_info` は種別と行先の両ファイルが存在するときだけ2ファイルを返します。

## 音声ファイル

既定の構成:

```text
audio/
├─ approach/
│  ├─ melody.dfpwm
│  ├─ soon.dfpwm
│  ├─ train.dfpwm
│  ├─ out_of_service_train.dfpwm
│  └─ warning.dfpwm
├─ arrival/
│  └─ melody.dfpwm
├─ passing/
│  └─ warning.dfpwm
├─ departure/
│  ├─ melody.dfpwm
│  └─ doors_closing.dfpwm
├─ stopped/
│  └─ notice.dfpwm
├─ next_train/
│  ├─ intro.dfpwm
│  └─ generic.dfpwm
├─ track/
│  ├─ 1.dfpwm
│  ├─ 2.dfpwm
│  └─ ...
├─ class/
│  ├─ rapid.dfpwm
│  ├─ limited_express.dfpwm
│  └─ ...
└─ destination/
   ├─ sapporo.dfpwm
   └─ ...
```

## Metadata Adapter

CoreはMTR/Create固有APIを直接参照しません。

MTR Adapterは `/mtr/api/map/arrivals` から対象ホームの次列車1件を取得し、以下を使用します。

```text
routeNumber   -> class
destination   -> destination
isTerminating -> terminating
```

MTR側の名称は `日本語|English` の右側を使用し、小文字化して英数字以外の連続文字を `_` に正規化します。

```text
快速|Rapid           -> rapid
特急|Limited Express -> limited_express
札幌|SAPPORO         -> sapporo
```

MTR Adapter設定例:

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

DEPARTUREまたは手動RESET時にはtrack metadata cacheを無効化し、その後の次列車案内が前列車のcacheを使い続けないようにします。

## 複数Speakerと割り込み

同一DFPWM chunkを全Speakerへ投入した後、全Speakerの `speaker_audio_empty` を待つバリア方式です。

高priority requestによる割り込み時は全Speakerを `stop()` し、Playerの待機を専用eventで解除します。stop/retry後に残る古い `speaker_audio_empty` が次のchunk barrierへ混ざりにくいよう、再開前にeventをdrainします。

Minecraft/CC:Tweaked側を含むsample単位の完全同期は保証しません。

## コード規約

各Lua関数の直前には、旧コードと同様に英語で機能を示すコメントを付けます。

```lua
-- function: Play an ordered list of audio segment files at one announcement priority.
function Player:playSegments(segments, priority)
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
  railway_input.lua
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
