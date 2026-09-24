# CCtweaked-RailwayAnnouncementSystem

CC:Tweaked向けの鉄道自動放送システムです。

「1線 = 1 Computer」を基本に、Bundled Redstone入力、MTR / Transport Simulation Core (TSC) metadata、DFPWM音声、優先度付き放送、Route別追加放送を分離して扱います。

## インストール / 更新

通常のruntime更新:

```text
wget run https://raw.githubusercontent.com/sankaku789/CCtweaked-RailwayAnnouncementSystem/main/install.lua
```

既存の `config.lua`、`announcement_patterns/`、Route別設定、DFPWM音声は保持されます。

標準の `announcement_patterns/main.lua`、`announcement_patterns/composites.lua`、`announcement_patterns/segments.lua` も更新する場合:

```text
wget run https://raw.githubusercontent.com/sankaku789/CCtweaked-RailwayAnnouncementSystem/main/install.lua --refresh-patterns
```

`--refresh-patterns` でも `config.lua`、`announcement_patterns/route_options.lua`、DFPWM音声は保持されます。

## 入力と状態

既定例:

```text
Bundled Cable (top)
├─ red  : APPROACH pulse
└─ blue : DEPARTURE pulse

PASSING sensor
└─ red + blue を同時にpulse

Normal Redstone (back)
└─ RESET
```

2本のbundled signalは状態値ではなく、放送種別を表すパルスコードとして読みます。

```text
APPROACH=OFF  DEPARTURE=OFF -> 00 -> idle / re-arm
APPROACH=ON   DEPARTURE=OFF -> 01 -> approach
APPROACH=OFF  DEPARTURE=ON  -> 10 -> departure
APPROACH=ON   DEPARTURE=ON  -> 11 -> passing
```

`passing` 用センサはAPPROACH線とDEPARTURE線の両方へ接続します。最初の非0入力を検出した後、`input.bundled.syncDelaySeconds` の同期窓の間に観測したAPPROACH/DEPARTURE bitをORで蓄積してイベント種別を確定します。既定値は `0.05` 秒です。これにより、2線の立ち上がりにわずかな時間差があっても `11` としてpassingを判定できます。

同じパルスを複数回処理しないよう、一度非0コードを受け付けた後は `00` に戻るまで再武装しません。

TrackStateは定期放送と盲導鈴の抑止状態を管理します。起動直後は `IDLE` です。

```text
起動直後              -> IDLE
approach               -> APPROACH
departure予約          -> PLATFORM
departure放送完了      -> IDLE
passing                -> state変更なし
reset                  -> IDLE
```

定期放送は次の状態で有効になります。

```text
APPROACH -> periodicなし
PLATFORM -> stopped_train
IDLE     -> next_train
```

接近から発車放送完了までは盲導鈴をholdし、発車放送完了後に設定された待ち時間を経て再開します。

旧設定から更新する場合は `input.bundled.signals.next` / `passing` を `approach` / `departure` に変更し、passingセンサを両信号線へ接続してください。

## MTR / TSC metadata

`config.lua` のAdapterを `mtr` にすると、TSC HTTP APIから列車情報を取得します。

```lua
trackNumber = 1,

adapter = {
    module = "mtr",
    cacheTtlMs = 30000,

    mtr = {
        baseUrl = "http://127.0.0.1:8888",
        dimension = 0,
        stationName = "Tomakomai",
        platformIdHex = "",
    },
},
```

`stationName` とトップレベルの `trackNumber` でホームを特定します。`platformIdHex` を設定した場合は直接指定が優先されます。

ArrivalResponseから主に以下を使います。

```text
routeNumber   -> class
destination   -> destination
isTerminating -> terminating
routeId       -> routeId
```

名称はEnglish部分を音声asset IDへ正規化します。

```text
快速|Rapid           -> rapid
特急|Limited Express -> limited_express
札幌|Sapporo         -> sapporo
```

## 音声ディレクトリ

```text
audio/
├─ melody/
│  ├─ approach.dfpwm
│  ├─ arrival.dfpwm
│  └─ departure.dfpwm
├─ approach/
│  ├─ soon.dfpwm
│  ├─ train.dfpwm
│  ├─ out_of_service_train.dfpwm
│  ├─ passing_train.dfpwm
│  └─ warning.dfpwm
├─ destination/
│  ├─ desu/
│  │  └─ <destination>.dfpwm
│  └─ mairimasu/
│     └─ <destination>.dfpwm
├─ station/
│  └─ <destination>.dfpwm
├─ track/
│  ├─ ni/
│  │  └─ <track>.dfpwm
│  └─ wo/
│     └─ <track>.dfpwm
├─ class/
│  └─ <class>.dfpwm
├─ stopped/
│  └─ train.dfpwm
├─ next_train/
│  ├─ intro.dfpwm
│  └─ train.dfpwm
├─ departure/
│  └─ doors_closing.dfpwm
└─ options/
```

### 行先音声

行先は用途ごとの自然な発話単位で持ちます。

```text
audio/destination/mairimasu/tomita.dfpwm
→ 接近放送用。「富田ゆきがまいります。」など

audio/destination/desu/tomita.dfpwm
→ 列車情報用。「富田ゆきです。」

audio/station/tomita.dfpwm
→ 駅名単独。「富田」
```

`announcement_patterns/segments.lua` は直接音声へ解決するsegmentだけを定義します。複数segmentをまとめる `approach_train_arrival`、`train_info`、`stopped_train_info`、`next_train_info`、`next_train_announcement` は `announcement_patterns/composites.lua` に定義します。

### 番線音声

番線音声は放送用途ではなく助詞で分けます。

```text
audio/track/ni/1.dfpwm -> 「1番線に」
audio/track/wo/1.dfpwm -> 「1番線を」
```

標準segmentは `track_ni` / `track_wo` です。

## 接近放送

標準パターン:

```lua
approach = {
    "?approach_melody",
    "soon",
    "?track_ni",
    "approach_train_arrival|train",
    "warning",
    "?car_count_info",
    "?arrival_melody",
    "route:sample",
}
```

例:

```text
まもなく / 1番線に / 普通 / 富田ゆきがまいります。 / 危険ですので…
```

metadata用音声が揃わない場合は `audio/approach/train.dfpwm` へfallbackします。接近放送だけは簡易放送へのfallbackを持ちます。

## 通過放送

標準パターン:

```lua
passing = {
    "soon",
    "?track_wo",
    "passing_train",
    "warning",
}
```

例:

```text
まもなく / 1番線を / 列車が通過いたします。 / 危険ですので…
```

```text
audio/approach/passing_train.dfpwm
→ 「列車が通過いたします。」

audio/approach/warning.dfpwm
→ 接近・通過共通の警告文
```

## 発車放送

標準パターン:

```lua
departure = {
    "departure_melody",
    "?doors_closing",
}
```

`departure` は発車メロディーを含む一連の発車放送全体として扱います。`doorsClosingEnabled = true` の場合は `audio/departure/doors_closing.dfpwm` も後続して再生します。

```lua
announcement = {
    departure = {
        doorsClosingEnabled = false,
        departureEndLeadSeconds = 5,
    },
},
```

停車時間を取得できる場合、発車放送の開始時刻は発車放送全体の再生時間を使って逆算します。音声間の `@pause` も再生時間に含まれます。

```text
開始待ち時間 = max(0, 停車時間 - departure全体時間 - departureEndLeadSeconds)
```

時間軸は次の扱いです。

```text
departure開始
  -> 発車メロディー
  -> 戸閉め放送など
  -> departure全体終了
  -> departureEndLeadSeconds
  -> 想定発車時刻
```

盲導鈴は発車放送の実再生終了を基準に、次の待ち時間後に再開します。

```text
departureEndLeadSeconds + guidanceBell.initialDelaySeconds
```

旧設定の `melodyEndLeadSeconds` は互換用に読み込みますが、新規設定では `departureEndLeadSeconds` を使用します。

## 停車中の定期案内

`stopped_train` は `PLATFORM` 状態で定期実行する放送です。停車中もTSC metadataを取得し、列車種別と行先を使います。

標準パターン:

```lua
stopped_train = {
    "?stopped_train_info",
}
```

旧 `stopped` は保存済み設定との互換用aliasとして残しています。

`stopped_train_info` composite は放送全体を一括で解決します。

```text
audio/track/ni/<track>.dfpwm
+ audio/stopped/train.dfpwm
+ audio/class/<class>.dfpwm
+ audio/destination/desu/<destination>.dfpwm
```

例:

```text
1番線に / 停車中の列車は / 普通 / 富田ゆきです。
```

推奨内容:

```text
audio/stopped/train.dfpwm -> 「停車中の列車は」
```

停車中案内には簡易放送・generic fallbackを実装しません。metadata、番線、固定文、列車種別、行先音声のどれかが不足する場合は、不完全な文を流さずその回の放送をスキップします。

既定設定では有効で、`PLATFORM` 移行から30秒後、その後30秒間隔です。

```lua
periodic = {
    stopped = {
        enabled = true,
        state = "PLATFORM",
        type = "stopped_train",
        initialDelayMs = 30000,
        intervalMs = 30000,
    },
}
```

## 次列車案内

標準パターン:

```lua
next_train = {
    "?next_train_announcement",
}
```

`next_train_announcement` は任意の次列車メロディーと `next_train_info` をまとめます。

```lua
next_train_announcement = {
    "?next_train_melody",
    "next_train_info",
}
```

`next_train_info` は次の要素から構成されます。

```text
next_train_prefix
+ audio/track/ni/<track>.dfpwm
+ next_train_intro
+ audio/class/<class>.dfpwm
+ audio/destination/desu/<destination>.dfpwm
+ 任意の両数案内
```

例:

```text
次に / 1番線に / まいります列車は / 普通 / 富田ゆきです。
```

次列車案内にも簡易放送・generic fallbackを実装しません。必要なmetadataまたは音声が不足する場合は、その回の放送全体をスキップします。

既定設定では有効で、`IDLE` 移行から60秒後、その後60秒間隔です。

```lua
periodic = {
    nextTrain = {
        enabled = true,
        state = "IDLE",
        type = "next_train",
        initialDelayMs = 60000,
        intervalMs = 60000,
    },
}
```

次列車案内の後の盲導鈴は、実際の次列車案内終了から `guidanceBell.initialDelaySeconds` 後に再開します。

旧 `audio/stopped/generic.dfpwm` と `audio/next_train/generic.dfpwm` がローカルに残っていても、標準パターンでは使用しません。installerは既存音声を削除しません。

## 旧音声の自動移行

installerは移行先に同名ファイルがない場合だけ旧配置を移動します。

```text
audio/approach/melody.dfpwm         -> audio/melody/approach.dfpwm
audio/arrival/melody.dfpwm          -> audio/melody/arrival.dfpwm
audio/departure/melody.dfpwm        -> audio/melody/departure.dfpwm
audio/approach/passing.dfpwm        -> audio/approach/passing_train.dfpwm

audio/approach/destination/*.dfpwm  -> audio/destination/mairimasu/*.dfpwm
audio/approach_destination/*.dfpwm  -> audio/destination/mairimasu/*.dfpwm
audio/destination/*.dfpwm           -> audio/destination/desu/*.dfpwm
audio/destination_sentence/*.dfpwm  -> audio/destination/desu/*.dfpwm

audio/track/*.dfpwm                 -> audio/track/ni/*.dfpwm
audio/track/approach/*.dfpwm        -> audio/track/ni/*.dfpwm
audio/track/passing/*.dfpwm         -> audio/track/wo/*.dfpwm
```

`audio/stopped/notice.dfpwm` は内容が不明なため `train.dfpwm` へ自動移行しません。必要なら手動で録音・配置してください。

## 音声パック

公開リポジトリにはDFPWM本体を置きません。`audio/` 以下の `.dfpwm` は `.gitignore` 対象です。

PC側で `audio/` の中身をUSTARとして固めます。

```powershell
tar --format=ustar -cf audio_pack.tar -C audio .
```

CC:Tweaked側:

```text
import_audio
```

推奨DFPWMは mono / 48 kHzです。

```bash
ffmpeg -i input.wav -ac 1 -ar 48000 -c:a dfpwm output.dfpwm
```

## Route別オプション放送

`main.lua` または `composites.lua` に `route:<slot>` を置くと、その位置にRoute別のDSL断片を挿入できます。slot名は任意です。標準パターンでは `route:sample` を用意しています。

```lua
approach = {
    "?approach_melody",
    "soon",
    "?track_ni",
    "approach_train_arrival|train",
    "warning",
    "?car_count_info",
    "?arrival_melody",
    "route:sample",
}
```

`announcement_patterns/route_options.lua` ではRoute IDの直下にslot名と内容を定義します。

```lua
return {
    ["1234567890123456789"] = {
        sample = {
            "airport_access",
        },
    },
}
```

slotが未定義の場合は何も挿入しません。slot内では通常のDSL entryと同じく `?`、`|`、compositeを利用できます。同じslot名を複数の放送パターンで使う場合は同じ内容が挿入されるため、内容を分けたい場合は別のslot名を使用します。

## 優先度 / 割り込み

既定priority:

```text
3   departure
2   approach
2   passing
1   stopped_train
0   next_train
-1  guidance_bell
```

`queue.preemptPriority` の既定値は `2` です。高priority requestは低priorityの再生を中断し、`preemptPriority` 以上では低priorityの待機queueも整理します。

## コード規約

各Lua関数の直前には英語で機能を示すコメントを置きます。

```lua
-- function: Play an ordered list of audio and pause items at one announcement priority.
function Player:playSegments(segments, priority)
    ...
end
```
