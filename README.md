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

TrackStateは即時イベントの種別判定には使わず、`stopped` / `next_train` の定期放送を選ぶためだけに使います。起動直後は `UNKNOWN` で、定期放送は実行しません。

```text
起動直後  -> UNKNOWN
approach   -> PLATFORM
 departure -> IDLE
passing    -> state変更なし
reset      -> IDLE
```

```text
UNKNOWN  -> periodicなし
PLATFORM -> stopped
IDLE     -> next_train
```

これによりapproachパルスを取りこぼしても、次のdepartureパルスをapproachとして誤認して以後の入力解釈がずれ続けることはありません。再起動直後も、状態が確定する前に `next_train` を流しません。

旧設定から更新する場合は `input.bundled.signals.next` / `passing` を `approach` / `departure` に変更し、passingセンサを両信号線へ接続してください。

## MTR / TSC metadata

`config.lua` のAdapterを `mtr` にすると、TSC HTTP APIから列車情報を取得します。

```lua
adapter = {
    module = "mtr",
    cacheTtlMs = 30000,

    mtr = {
        baseUrl = "http://127.0.0.1:8888",
        dimension = 0,
        stationName = "Tomakomai",
        platformName = "1",
        platformIdHex = "",
    },
},
```

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

`announcement_patterns/segments.lua` は直接音声へ解決するsegmentだけを定義します。複数segmentをまとめる `approach_train_arrival`、`train_info`、`stopped_train_info`、`next_train_info` は `announcement_patterns/composites.lua` に定義します。

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

## 停車中の定期案内

`stopped` は `PLATFORM` 状態で定期実行できる放送です。停車中もTSC metadataを取得し、列車種別と行先を使います。

標準パターン:

```lua
stopped = {
    "?stopped_train_info",
}
```

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

既定では定期放送はOFFです。有効化する場合は保持されている `config.lua` を編集します。

```lua
periodic = {
    stopped = {
        enabled = true,
        state = "PLATFORM",
        type = "stopped",
        initialDelayMs = 30000,
        intervalMs = 30000,
    },
}
```

## 次列車案内

標準パターン:

```lua
next_train = {
    "?next_train_info",
}
```

`next_train_info` composite も放送全体を一括で解決します。

```text
audio/next_train/intro.dfpwm
+ audio/track/ni/<track>.dfpwm
+ audio/next_train/train.dfpwm
+ audio/class/<class>.dfpwm
+ audio/destination/desu/<destination>.dfpwm
```

例:

```text
次に / 1番線に / まいります列車は / 普通 / 富田ゆきです。
```

推奨内容:

```text
audio/next_train/intro.dfpwm -> 「次に」
audio/next_train/train.dfpwm -> 「まいります列車は」
```

次列車案内にも簡易放送・generic fallbackを実装しません。必要なmetadataまたは音声が不足する場合は、その回の放送全体をスキップします。

既定では `next_train` の定期放送もOFFです。有効化する場合:

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
100  approach
100  passing
100  departure
 20  stopped
 10  next_train
```

高priority requestは低priority放送を中断できます。

## コード規約

各Lua関数の直前には英語で機能を示すコメントを置きます。

```lua
-- function: Play an ordered list of audio and pause items at one announcement priority.
function Player:playSegments(segments, priority)
    ...
end
```
