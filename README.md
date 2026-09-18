# CCtweaked-RailwayAnnouncementSystem

CC:Tweaked向けの鉄道自動放送システムです。

「1線 = 1 Computer」を基本に、ProjectRed等のBundled Redstone入力、MTR / Transport Simulation Core (TSC) metadata、DFPWM音声、優先度付き放送、Route別追加放送を分離して扱います。

## インストール / 更新

通常のインストール・runtime更新:

```text
wget run https://raw.githubusercontent.com/sankaku789/CCtweaked-RailwayAnnouncementSystem/main/install.lua
```

既存の `config.lua`、`announcement_patterns/`、Route別設定、DFPWM音声は保持されます。

標準の `announcement_patterns/main.lua` と `announcement_patterns/segments.lua` も最新版へ更新したい場合:

```text
wget run https://raw.githubusercontent.com/sankaku789/CCtweaked-RailwayAnnouncementSystem/main/install.lua --refresh-patterns
```

`--refresh-patterns` でも `config.lua`、`announcement_patterns/route_options.lua`、DFPWM音声は保持されます。

## 音声パック

公開リポジトリにはDFPWM本体を置きません。`audio/` 以下の `.dfpwm` は `.gitignore` 対象です。

PC側で `audio/` の**中身**をUSTARとして固めます。

```powershell
tar --format=ustar -cf audio_pack.tar -C audio .
```

CC:Tweaked側:

```text
import_audio
```

その後 `audio_pack.tar` をComputer画面へドラッグ＆ドロップします。

## 入力

既定例:

```text
Bundled Cable (top)
├─ red  : NEXT
└─ blue : PASSING

Normal Redstone (back)
└─ RESET
```

`NEXT` は停車列車の状態を進め、`PASSING` は状態を変えず通過放送をQueueへ投入します。

```text
IDLE --approach--> PLATFORM --departure--> IDLE
```

1列車につき既定では2回の `NEXT` パルスです。

## MTR / TSC metadata

TSC HTTP APIを使う場合は `config.lua` のAdapterを `mtr` にします。

Platform IDを手入力しなくても、**Station名 + Platform名の完全一致**で対象ホームを決められます。

```lua
adapter = {
    module = "mtr",
    cacheTtlMs = 30000,

    mtr = {
        baseUrl = "http://127.0.0.1:8888",
        dimension = 0,

        stationName = "Tomakomai",
        platformName = "1",

        -- Optional direct override.
        platformIdHex = "",
    },
},
```

処理:

```text
GET /mtr/api/map/stations-and-routes
  -> stationName完全一致
  -> station hex IDをRAM cache

POST /mtr/api/map/arrivals
  -> stationIdsHexで駅全体を問い合わせ
  -> platformName完全一致
  -> そのホームで最も早いArrivalResponseを使用
```

TSC名が `日本語|English` 形式なら、設定値は右側のEnglish名で一致できます。

```text
苫小牧|Tomakomai -> stationName = "Tomakomai"
1                 -> platformName = "1"
```

大文字小文字を含め**完全一致**です。

`platformIdHex` が空でなければ、従来どおりそのPlatform IDを直接使用し、`stationName` / `platformName` は無視します。

### 取得するmetadata

ArrivalResponseから以下を使います。

```text
routeNumber   -> class
destination   -> destination
isTerminating -> terminating
routeId       -> routeId (exact decimal string)
```

名称はEnglish部分を音声asset IDへ正規化します。

```text
快速|Rapid           -> rapid
特急|Limited Express -> limited_express
札幌|Sapporo         -> sapporo
```

metadata取得成功時は次のようにログが出ます。

```text
[12:34 PM] : Metadata -> routeId=1234567890123456789 class=rapid destination=sapporo
```

Route IDがない場合も `routeId=-` としてmetadata取得自体はログされます。

## 行先音声の方針

行先は、細かい助詞単位で分割せず、用途に応じた自然な発話単位を3種類持ちます。

```text
audio/approach_destination/tomita.dfpwm
→ 「富田行きが到着いたします。」

audio/destination_sentence/tomita.dfpwm
→ 「富田行きです。」

audio/station/tomita.dfpwm
→ 「富田」
```

同じmetadataの `destination = tomita` に対して、放送用途ごとに同じファイル名 `tomita.dfpwm` を各ディレクトリから引きます。

旧 `audio/destination/` は標準パターンでは使用しません。既存ファイルはinstallerでも削除しません。

## 接近放送

標準パターン:

```lua
approach = {
    "?approach_melody",
    "soon",
    "?track",
    "approach_train_arrival|train",
    "warning",
    "?arrival_melody",
    "?route_options",
}
```

MTR metadataと対応音声が揃っている場合、`approach_train_arrival` は次の2ファイルへ解決します。

```text
class + approach_destination
```

例:

```text
audio/class/local.dfpwm                    = 「普通」
audio/approach_destination/tomita.dfpwm   = 「富田行きが到着いたします。」
audio/approach/warning.dfpwm              = 「危険ですので、黄色い点字ブロックまでお下がりください」
```

この場合の接近放送は次の構成です。

```text
まもなく / 1番線に / 普通 / 富田行きが到着いたします。 / 危険ですので…
```

行先から到着語尾までを1ファイルにまとめるため、接近放送ではクロスフェードやオーバーラップ再生を使用しません。

回送列車も接近文を1ファイルにまとめます。

```text
audio/approach/out_of_service_train.dfpwm
= 「回送列車が到着いたします。」
```

対応するclass / approach_destination音声が揃わない場合は `train.dfpwm` へfallbackします。

```text
audio/approach/train.dfpwm = 「列車がまいります。」
```

fallback後も共通の `warning.dfpwm` を続けます。

## 次列車案内

`next_train` の `train_info` は次の2ファイルへ解決します。

```text
class + destination_sentence
```

例:

```text
audio/class/local.dfpwm                   = 「普通」
audio/destination_sentence/tomita.dfpwm  = 「富田行きです。」
```

したがって `next_train/intro.dfpwm` を「次の列車は」のような文にすれば、

```text
次の列車は / 普通 / 富田行きです。
```

のように構成できます。

`station_name`、`destination_sentence`、`approach_destination` はそれぞれ動的segmentとして定義してあり、今後のmetadata対応パターンから単独でも利用できます。

## 音声ファイル

```text
audio/
├─ approach/
│  ├─ melody.dfpwm
│  ├─ soon.dfpwm
│  ├─ train.dfpwm
│  ├─ out_of_service_train.dfpwm
│  └─ warning.dfpwm
├─ approach_destination/
│  └─ <destination>.dfpwm
├─ destination_sentence/
│  └─ <destination>.dfpwm
├─ station/
│  └─ <destination>.dfpwm
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
└─ options/
```

推奨DFPWMは mono / 48 kHzです。

例:

```bash
ffmpeg -i input.wav -ac 1 -ar 48000 -c:a dfpwm output.dfpwm
```

## セグメント間の連続再生

通常セグメント間には人工的な待機を入れません。

Playerは隣接するDFPWMをファイル単位で再生終了させず、各ファイルを**別々のDFPWM decoderでPCM化した後、PCMを1本の連続streamへ結合**します。

```text
local.dfpwm                         --decode--\
approach_destination/tomita.dfpwm --decode---+-> continuous PCM -> Speaker
warning.dfpwm                       --decode--/
```

DFPWM decoderはファイルごとに作り直すためstream stateを混ぜません。一方、Speakerへ渡すPCMはファイル境界を跨いで最大 `128 * 1024` samplesまでまとめます。

明示的に間を入れたい場合だけ、パターンで以下を使えます。

```text
@pause:0.3
```

## Route別オプション放送

`announcement_patterns/route_options.lua` にRoute IDと追加segment IDを設定します。

```lua
return {
    ["1234567890123456789"] = {
        approach = {
            "airport_access",
        },
    },
}
```

実ファイルは `announcement_patterns/segments.lua` に定義します。

```lua
airport_access = {
    kind = "file",
    path = "audio/options/airport_access.dfpwm",
},
```

## 優先度 / 割り込み

既定priority:

```text
100  approach
100  passing
100  departure
 20  stopped
 10  next_train
```

高priority requestが来た場合、低priority放送はSpeakerを停止して中断します。明示pause中も割り込み可能です。

## コード規約

各Lua関数の直前には英語で機能を示すコメントを置きます。

```lua
-- function: Play an ordered list of audio and pause items at one announcement priority.
function Player:playSegments(segments, priority)
    ...
end
```
