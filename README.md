# CCtweaked-RailwayAnnouncementSystem

CC:Tweaked向けの鉄道自動放送システムです。

「1線 = 1 Computer」を前提に、停車列車の状態管理、通過列車、MTR metadata、Route別オプション放送、定期放送、複数Speaker再生を分離して扱います。

## インストール

リポジトリをpublicにした後、CC:Tweaked上で次を実行します。

```text
wget run https://raw.githubusercontent.com/sankaku789/CCtweaked-RailwayAnnouncementSystem/main/install.lua
```

同じコマンドを再実行するとruntime sourceを更新します。既存の `config.lua`、`data/`、DFPWM音声ファイルは保持します。

旧レイアウトから更新した場合は、新しい `src/` を配置した後に旧 `adapter/`、`core/`、`hardware/` などのcode directoryを削除します。

## ディレクトリ構成

```text
startup.lua
config.lua
install.lua

data/
  patterns.lua
  segments.lua
  route_options.lua

src/
  app.lua
  adapter/
    none.lua
    mtr.lua
  audio/
    player.lua
    segment.lua
  core/
    track_state.lua
    announcement_queue.lua
    composer.lua
    scheduler.lua
  hardware/
    railway_input.lua
    redstone_input.lua
    speakers.lua
  metadata/
    cache.lua
    provider.lua
  util/
    log.lua

audio/
  approach/
  arrival/
  departure/
  passing/
  stopped/
  next_train/
  track/
  class/
  destination/
  options/
```

役割:

```text
config.lua  -> このComputer固有の設定
data/       -> 放送定義とRoute別設定
src/        -> 実行ロジック
audio/      -> DFPWM音声アセット
```

`startup.lua` が `/src/?.lua` を `package.path` に追加するため、`src/` 内部では従来通り `require("core.scheduler")` のように参照できます。

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
`RESET` は状態を `IDLE` に戻します。

色と面は `config.lua` の `input` で変更できます。

## 停車列車の状態遷移

```text
IDLE
  -> APPROACH
  -> PLATFORM
  -> DEPARTURE
  -> IDLE
```

デフォルトでは1列車あたり3回の `NEXT` パルスです。

- 1パルス目: 接近放送
- 2パルス目: PLATFORM状態へ遷移
- 3パルス目: 発車放送、その後IDLEへ自動復帰

`PASSING` はこの状態遷移には入りません。

## 優先度と割り込み

既定priority:

```text
100  approach
100  passing
100  departure
 20  stopped
 10  next_train
```

`queue.preemptPriority` 以上のrequestが来た場合、低priorityの待機中requestを破棄し、低priority放送を再生中ならSpeakerを停止して高priority放送へ切り替えます。

中断された定期放送は途中から再開しません。

## 定期放送

`config.lua` の `periodic` で設定します。既定では音声アセット未配置時の連続警告を避けるためOFFです。

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

## 放送パターン

放送順は `data/patterns.lua` に宣言します。

```lua
return {
    approach = {
        "?approach_melody",
        "soon",
        "?track",
        "train_info|train",
        "?route_options",
        "warning",
        "?arrival_melody",
    },

    next_train = {
        "next_train_intro",
        "train_info|next_train_generic",
        "?route_options",
    },
}
```

記法:

```text
segment          必須セグメント
?segment         optional。解決できない場合はskip
primary|fallback primaryが解決できなければfallback
```

## セグメント定義

セグメントIDと実ファイル・dynamic resolverの対応は `data/segments.lua` に定義します。

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

route_options = {
    kind = "dynamic",
    resolver = "route_options",
},
```

Route別に使う追加音声も通常のセグメントとして `data/segments.lua` に定義します。

```lua
airport_access = {
    kind = "file",
    path = "audio/options/airport_access.dfpwm",
},
```

## Route別オプション放送

MTR AdapterはTSC ArrivalResponseの `routeId` をmetadataへ追加します。

```lua
{
    class = "rapid",
    destination = "new_chitose_airport",
    terminating = false,
    routeId = "1234567890123456789",
}
```

TSCのRoute IDは64bit整数なので、MTR AdapterはJSON decode前に `routeId` をdecimal stringへ変換し、Lua numberの精度損失を避けます。

Routeごとの追加放送は `data/route_options.lua` にセグメントIDだけを書きます。

```lua
return {
    ["1234567890123456789"] = {
        approach = {
            "airport_access",
            "reserved_seat",
        },

        next_train = {
            "airport_access",
        },
    },
}
```

処理順:

```text
MTR ArrivalResponse
  -> routeIdを文字列で保持
  -> data/route_options.lua[routeId]
  -> request.type (approach / next_train / ...)
  -> segment ID一覧
  -> data/segments.lua
  -> DFPWM file
```

`?route_options` なので、Route IDがない、未登録、対象放送種別の設定がない場合は何も追加せずskipします。

MTR metadataを新規取得したときはRoute ID確認用に次の形式でログを出します。

```text
[12:34 PM] : Metadata -> routeId=1234567890123456789 class=rapid destination=new_chitose_airport
```

## 回送列車

MTR AdapterはTSC ArrivalResponseの `isTerminating` を `metadata.terminating` として返します。

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
├─ class/
├─ destination/
└─ options/
```

`audio/options/` はRoute別追加放送などのユーザー定義セグメント向けです。

## Metadata Adapter

CoreはMTR固有APIを直接参照しません。

MTR Adapterは `/mtr/api/map/arrivals` から対象ホームの次列車1件を取得し、以下を使用します。

```text
routeNumber   -> class
destination   -> destination
isTerminating -> terminating
routeId       -> routeId (decimal string)
```

名称は `日本語|English` の右側を使用し、小文字化して英数字以外の連続文字を `_` に正規化します。

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

DEPARTUREまたは手動RESET時にはtrack metadata cacheを無効化します。

## 複数Speakerと割り込み

同一DFPWM chunkを全Speakerへ投入した後、全Speakerの `speaker_audio_empty` を待つバリア方式です。

高priority requestによる割り込み時は全Speakerを `stop()` し、Playerの待機を専用eventで解除します。Minecraft/CC:Tweaked側を含むsample単位の完全同期は保証しません。

## コード規約

各Lua関数の直前には英語で機能を示すコメントを付けます。

```lua
-- function: Play an ordered list of audio segment files at one announcement priority.
function Player:playSegments(segments, priority)
    ...
end
```
