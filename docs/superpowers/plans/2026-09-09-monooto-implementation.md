# MonoOto Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SPECの段階Aとして、通常モノラルと音色手がかり付き再生を比較できるmacOSアプリを作り、工学的な成立と当事者の音楽体験を別々に検証する。

**Architecture（タスク6まで実装済み、統合実機ゲートは未完了）:** 音声のデコード・DSP・レート変換は制御されたワーカー上で処理し、最終ピーク制限済みPCMを有界キューへ渡す。AVAudioSourceNodeのコールバックは事前確保されたPCMの取り出しと片耳への出力に限定する。DSPをオフラインテストとアプリで共有し、システム音声取得は知覚評価後の別段階とする。

**Tech Stack:** Swift、SwiftUI、Swift Package Manager、XCTest、AVFAudio、Core Audio。リアルタイム境界の有界キューと原子的な停止フラグのみタスク5で独立C11実装済み。タスク6でC render境界と再生workerを接続済み。

**Spec:** [SPEC.md](../../../SPEC.md)、[AGENTS.md](../../../AGENTS.md)。本書は仕様の変更ではなく、実装順序と検証手順の具体化である。

## 現在の進捗（2026-09-11、実装コミット `88b6ddd`）

日付付きの個別実装記録は当時の履歴として残す。現在の進捗は本節と検証記録の最新状況を参照する。

タスク1〜6の実装とタスク6レビュー指摘3件の修正をmainへマージ・push済み。アプリは明示操作でファイル再生・処理状態を保持するpause・stop・seek・共通経路の確認音を提供する。マージ後のSwiftPM 157テストとReleaseパッケージビルドが成功し、レビュー修正後のTSanはworker／Controller 47テスト、Xcode Releaseアプリビルドも成功した。作業ブランチと専用worktreeは削除済み。タスク6の実機受け入れは未完了で、タスク7以降・知覚評価・段階Bは未着手。過去のタスク4の無音機器検証やタスク5の60分合成負荷を、今回の統合音楽経路の実機合格へ代用しない。詳細は[段階A検証記録](../../verification/stage-a.md)を参照。

以下の日付付き実装・レビュー記録は当時の状態を保存している。「未完了」「未検証」などの記述を現在の進捗として読まない。各タスクのチェックリストと本節が現在の進捗を示す。

## タスク1〜3の実装・レビュー対応記録（2026-09-09、履歴）

タスク1〜3は実装済み。今回の修正後、macOS 26.6.2（25G83）/ arm64 / Swift 6.3.3でXCTest **39件・失敗0件**（約10.03秒）、Releaseビルド終了コード0を確認した。初回実装時の34件成功と区別し、以下を今回の検証記録とする。タスク4以降のチェックは未完了のまま維持する。

- EncoderTests: 14件。独立式・周波数応答・相殺窓の回復・平滑化に加え、係数キャッシュと6500サンプルの逐次参照が完全一致。境界テストはFloat量子化後の実際のRMS/ratioを計算して不等号を検証する。
- OutputGuardTests: 12件。両レート/両符号のピークと直後のリリース、単調減少信号によるキュー容量・折り返し、クリップを含まない独立参照を確認。
- AudioFilePipelineTests: 13件。24形式、4通りのレート変換と全モード、EOF/seek/非有限値に加え、読み出し途中の相殺警告、20 msゲイン遷移、RIFF途中チャンクのパディングを確認。resetなしのnilミュートも、既存240フレームの先読み後に厳密にゼロになることを確認。テストのprintとサンプル値出力を削除。
- 相殺警告・ゲイン遷移の追加2テストは修正前に失敗を確認し、修正後に成功。警告は「直近のreadで一度でも成立したか」を返し、次のreadで現在条件へ戻す。通常ゲインは960サンプルで線形補間し、nilミュートは次のDSP境界で即時反映。seek/resetは選択値を維持し開始フェードをやり直す。
- 既存の公開境界は引数拒否のためEncoder/OutputGuardのinit、Encoder.setParameters、Pipeline.setがthrows。gainDBはFloat?、nilがミュート。アプリ自体は未作成であり、macOS 14.2はPackageのデプロイ下限のみ確認済み。

実行コマンド（書き込み可能な一時キャッシュを明示。環境変数は各コマンドに付与）:

```sh
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/monooto-task123/module-cache CLANG_MODULE_CACHE_PATH=/private/tmp/monooto-task123/clang-cache swift test --disable-sandbox --cache-path /private/tmp/monooto-task123/spm-cache --config-path /private/tmp/monooto-task123/spm-config --security-path /private/tmp/monooto-task123/spm-security
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/monooto-task123/module-cache CLANG_MODULE_CACHE_PATH=/private/tmp/monooto-task123/clang-cache swift build -c release --disable-sandbox --cache-path /private/tmp/monooto-task123/spm-cache --config-path /private/tmp/monooto-task123/spm-config --security-path /private/tmp/monooto-task123/spm-security
```

### Claude指摘14件の採否

| 指摘 | 判断・対応・根拠 |
| --- | --- |
| OutputGuard先読み窓の1サンプルずれ | **不成立**。出力計算後に期限切れピークを除去するため、計算時の窓は `[n-L,n]`。本体アルゴリズムは維持。一時コピーで提案の期限−1/容量L+2を適用すると、直後の小信号のリリースが1サンプル遅れて4アサーション失敗。別の一時コピーでハードクリップを無効化しても12テスト成功。説明コメントと回帰を強化した。 |
| 状態クリアと故障解除の混在 | **修正**。clearProcessingStateは故障ラッチを変更せず、正しいseek/resetだけが明示的に解除する。無効seekで故障が解除されないことも確認。従来の実行障害ではなく順序依存の保守性改善。 |
| decodeの0要求による正常ファイル停止 | **未再現・変更なし**。現在の全レート・短音源・空入力・EOFで正常停止の再現なし。ゼロ要求が正常経路で生じる条件は未確認のため、不正要求をエラーにする防御を維持。将来の対象OS/SDKで再現する場合は入力ブロックの状態契約から修正する。 |
| ブロック内の警告消失 | **修正**。直近read内で成立した警告を集約し、現在状態とは分けて保持。成立・解除が同じ1024フレーム内にある実ファイルで修正前失敗/修正後成功。 |
| 途中の奇数長チャンクでpad必須 | **仕様どおり・維持**。RIFFのデータはWORD境界へパディングする。適正な途中JUNKチャンクを受理し、pad欠損を拒否するテストを追加。Apple生成ファイルで実測済みの最終pad省略の受理は維持。[Microsoft RIFF仕様](https://learn.microsoft.com/en-us/windows/win32/xaudio2/resource-interchange-file-format--riff-)。 |
| ゲイン即時切替 | **修正**。通常ゲインの20 ms線形補間を追加。SPECが明記するmode/strength/cutoffに加え、手動ゲイン変更の不連続を避ける。最終制限器前で実施し、nilミュートと異常時停止を遅延ランプにしない。 |
| バッファ上限1024の重複 | **修正**。確保・変換・読み出し・有限値検査をmaximumReadFramesへ統一。 |
| 毎サンプルのexp | **修正**。init/resetと実際のcutoff変化時だけ再計算し、定常時は係数を再利用。性能向上率は未測定。 |
| 3本のエネルギー木・未使用葉 | **変更なし**。固定容量の2の冪木は巨大有限入力後の減算残差を避けるため採用。木統合の効果は未測定で、今回の実バグ修正に不要。 |
| @inlinable/ベクトル化 | **変更なし**。PipelineとDSPは同一モジュールで、再生callbackは後続タスクのCキュー。モジュール外のサンプル呼出しを前提に公開実装を増やす必要性は未実測。 |
| HearingEarの公開 | **計画どおり・維持**。タスク1の公開型として明記されており、削除しない。 |
| 閾値テストの不等号 | **テスト表現を修正、閾値は維持**。nominal ratio=0.1から生成するFloat L/Rは実比が0.1未満、Float(0.001)は数学的0.001より大きい。量子化後の値が閾値のどちら側かを直接assertして期待値の理由を明確にした。 |
| テストprint/音声値出力 | **削除**。成否はXCTestアサーションで確認し、音声サンプル値を標準出力へ流さない。 |
| 完了・検証の文書不足 | **修正**。本節とタスク1〜3のチェックを更新し、未実装段階と区別した。 |

実機再生・機器切断・選択耳配線・macOS 14.2上の実行・知覚効果・AVAudioConverterネイティブNSErrorの強制注入は未検証。数値検証を音圧安全性やステレオ知覚の実証とは扱わない。

## Global Constraints

- macOS 14.2以上、Apple Siliconを初期の実機検証対象とする。
- 初期用途は音楽、初期出力は有線のステレオヘッドホン／イヤホン。
- 起動時は停止。通常モノラルを初期モードとする。OSや外部機器の音量は変更しない。
- DSPは48 kHz Float32。`a=0〜0.6`、初期`0.35`。`fc=800〜4000 Hz`、初期`1500 Hz`。
- 強さ、周波数、モードの変更は20 ms以上で平滑化し、開始は100 msでフェードインする。
- 初期ゲインは−18 dB、調整範囲はミュート〜0 dB。出力レートで5 ms先読み、100 msリリースの制限器を使用する。
- アプリ最終出力サンプルの絶対値は `10^(-3/20)` 以下。すべてのレート変換・ゲイン処理の後で保証する。
- 聞こえる耳が左なら `(y,0)`、右なら `(0,y)`。出力耳と入力L/Rの音色符号を独立させる。
- 機器切断・耳／機器変更・スリープ時は停止する。旧世代の音声や非同期完了で再生を再開しない。
- コールバックでメモリ確保・解放、ロック待ち、I/O、ログ、UI操作、Task生成をしない。
- 通常利用の音声は保存・送信しない。評価JSONは本人の明示操作まで永続保存しない。
- 自然なステレオ聴覚、正確な方位、聴力回復、耳元の安全音圧を保証しない。
- 段階B、HRTF、頭部追跡、AI分離、仮想ドライバ、配布・公開は段階Aの実装に含めない。
- 各タスクで意味のある失敗テスト→最小実装→再検証を行う。コミットは利用者が許可している場合に限る。

---

## 1. 現状と難易度

計画作成時（2026-09-09）の作業フォルダには `AGENTS.md` と `SPEC.md` があり、ソース、テスト、Gitリポジトリはない。環境確認ではmacOS 26.6.2 / arm64、Xcode 26.6、Swift 6.3.3が応答した。XcodeコマンドにFSEventsの警告が出ているため、バージョン取得成功をビルド成功とは扱わない。macOS 14.2実機の用意も確認できていない。

| 項目 | 難易度 | 不確実性を減らす手順 |
| --- | --- | --- |
| M/Sによる音色符号化 | 中 | 式、周波数応答、相殺例を音を出さず検証 |
| 制限器・レート変換・有限値保証 | 高 | 最終出力境界で過大入力・不正値・全対応レートを試す |
| リアルタイム再生・停止・機器変更 | 高 | 最小の出力ホストで世代管理と切断挙動を先に実証 |
| 広がり・楽しさの改善 | 最も不確実 | 当事者による通常モノラルとの比較。コードの正しさと分離 |
| 他アプリの音声置換 | 高 | 段階Aの効果確認後にtap、原音ミュート、復旧を独立検証 |

工数の日数は現段階では固定しない。タスク4の機器固定とタスク10の知覚評価が、後続作業量を左右するためである。

## 2. 段階と進行条件

| 段階 | タスク | 到達点 | 次に進む条件 |
| --- | --- | --- | --- |
| A1 | 1〜3 | 無音で検証できるDSP・ファイル処理 | 数値・上限・相殺・変換の検証が通る |
| A2 | 4〜6 | 選択機器にだけ出力する小さな再生ホスト | 停止、旧音声破棄、機器消失、キュー上限が実機で成立 |
| A3 | 7〜9 | 比較・評価に必要な段階Aアプリ | T1〜T9、アクセシビリティ、評価データの検証が通る |
| A4 | 10 | 当事者の比較結果と継続判断 | SPEC 7.2〜7.3の音楽体験基準に従う |
| B | 本書末尾の条件付き工程 | 他アプリ音声の取得・置換 | A4の結果と新しい実装範囲を確認して着手 |

タスク1→2→3を先に完了する。タスク4→5→6の出力経路が成立してから音を出す。タスク7と8は共通経路が安定すれば別担当に分けられるが、最初から大量の並行編集はしない。

## 3. ファイル構成と境界

以下は段階A全体の構成。現在はタスク1〜4のPackage・DSP・ファイル経路・機器出力境界・無音ホスト・対応テストを実装済み。タスク5のCキュー・SwiftPM専用試験・テスト補助Cも追加済み。タスク6の再生worker・制御・C render境界と最小UIも追加済み。タスク7以降は計画であり、各タスクで必要なものだけ追加する。

| ファイル | 責務・導入タスク |
| --- | --- |
| `Package.swift` | ローカルライブラリとテストの定義。1で開始し4・5で拡張 |
| `Sources/MonoOtoCore/Encoder.swift` | M/S、フィルタ、平滑化、相殺指標。1 |
| `Sources/MonoOtoCore/OutputGuard.swift` | 出力レートでの制限器、有限値、リセット。2 |
| `Sources/MonoOtoCore/AudioFilePipeline.swift` | 形式検証、デコード、変換、共通処理。3 |
| `Sources/MonoOtoCore/PlaybackState.swift` | 状態遷移と再生世代。4 |
| `Sources/MonoOtoAudio/DeviceOutput.swift` | 機器UID、出力形式、AVAudioEngine接続、通知。4 |
| `Sources/MonoOtoRealtime/include/FrameQueue.h`、`Sources/MonoOtoRealtime/FrameQueue.c` | C11の有界キュー、原子的無音化、PCM出力。5 |
| `Sources/MonoOtoAudio/PlaybackController.swift` | ワーカー、キュー、再生位置、ライフサイクルの統合。6 |
| `MonoOto.xcodeproj/project.pbxproj`、`MonoOto.xcodeproj/xcshareddata/xcschemes/MonoOto.xcscheme` | ローカルPackageを参照するアプリ／テスト。4 |
| `App/MonoOtoApp.swift`、`App/PlayerView.swift`、`App/Info.plist` | 無音起動ホストを4で導入、プレーヤーUIを7で完成 |
| `Sources/MonoOtoCore/Settings.swift` | 型と範囲を検証する設定。7 |
| `Sources/MonoOtoCore/EvaluationSession.swift`、`App/EvaluationView.swift` | 比較順序、回答、集計、明示JSON書き出し。8 |
| `Tests/MonoOtoCoreTests/EncoderTests.swift`、`OutputGuardTests.swift`、`AudioFilePipelineTests.swift`、`PlaybackStateTests.swift`、`SettingsTests.swift`、`EvaluationSessionTests.swift` | 対応する純粋処理のテスト。1〜8 |
| `Tests/MonoOtoAudioTests/DeviceOutputTests.swift`、`FrameQueueTests.swift`、`PlaybackControllerTests.swift` | モックとバッファを使う入出力・寿命のテスト。4〜6 |
| `Tests/MonoOtoAppTests/PlayerUITests.swift` | アプリUIの検証。7 |
| `docs/verification/stage-a.md` | 実施条件、実行済み／未検証、レビュー、実機結果。4から追記 |

テスト素材はテスト内で合成し、一時ディレクトリにWAV/AIFFを生成する。音楽をリポジトリへ無断追加しない。`README`、`GOAL.md`、配布用設定をこの計画のためだけに追加しない。

### 共通の設計判断

- `MonoOtoCore` はDSPと純粋な状態・評価処理。`MonoOtoAudio` がOSとの境界、アプリがUIを担当する。
- DSPの大部分はSwiftのままワーカー上で動かす。C11はコールバックでSwiftの配列コピーや参照解放、ロック待ちを起こさず、停止状態を読み取るための小さい境界に限定する。
- 初期の段階Aキューは最大4096 mono frames。これは48 kHzで約85 ms分の上限であり、段階Bの30 ms目標を満たす設計値ではない。段階Bでは実測に基づく短縮・クロック調整が必要。
- キューは常に最終制限後のmono PCMを保持する。再生世代ごとに耳と出力形式を固定する。耳・機器変更は停止・キュー破棄・再準備で扱う。
- 非対応出力形式を黙って通さない。初期の必須出力レートは44.1/48 kHz、検証を通した2チャンネル機器とする。それ以外は停止状態で非対応を表示する。対応を増やす際は同じ最終出力テストを追加する。

## 4. タスク別の実装手順

コード片は実装契約と最初の回帰テストであり、アプリの全コードを先に作る指示ではない。各タスクのチェック項目を小さい変更に分け、テストが通った時点で差分を自己監査する。

### タスク1: 音色符号化をオフラインで成立させる

**対象:** `Package.swift`、`Encoder.swift`、`EncoderTests.swift`。対応: T1〜T4、SPEC 4.2〜4.3。

**インターフェース:**

```swift
enum ListeningMode: String, Codable { case mono, cue, leftOnly, rightOnly }
enum HearingEar: String, Codable { case left, right }
struct EncoderParameters { var strength: Float; var cutoffHz: Float }
struct EncodedSample { let mono: Float; let cancellationWarning: Bool }
// Encoderは呼出元ワーカーだけが所有。sampleRateは48000に固定する。
// init(parameters:), setParameters(_:), setMode(_:), reset()
// process(left: Float, right: Float) -> EncodedSample
```

- [x] 上記の型と空の公開境界を置く最小Packageを作る。新規テストターゲットは`MonoOtoCoreTests`。PackageのmacOS下限とアプリ下限を14.2にそろえる。
- [x] 次の通常モノラル・中央成分のテストを先に追加して、未実装で失敗することを確認する。

```swift
func testCenterIsUnchanged() {
    let e = Encoder(parameters: .init(strength: 0.6, cutoffHz: 1500))
    e.setMode(.cue)
    for x in [Float(0), 0.25, -0.5, 1, -1] {
        XCTAssertEqual(e.process(left: x, right: x).mono, x, accuracy: 1e-6)
    }
}
func testZeroStrengthEqualsMono() {
    let e = Encoder(parameters: .init(strength: 0, cutoffHz: 1500))
    e.setMode(.cue)
    XCTAssertEqual(e.process(left: 0.8, right: -0.2).mono, 0.3, accuracy: 1e-6)
}
```

- [x] 独立した参照式をテスト側に書き、L/R単独インパルス、左右交換、ブロック分割、周波数応答を検証する。平滑化後の値と過渡状態は分けて比較する。
- [x] 以下の式を実装する。`p`は内部状態、係数・強さ・モードの目標値変更は960 samples以上かけて平滑化する。モードは出力間の線形クロスフェードとし、単独確認も同じ経路へ入れる。

```swift
let mid = (left + right) * 0.5
let side = (left - right) * 0.5
let c = Float(exp(-2 * Double.pi * Double(cutoffHz) / 48000))
p = (1 - c) * side + c * p
let cue = mid + strength * (side - p)
```

- [x] 相殺指標を4800 samples窓で計算し、閾値0.1／500 ms／−60 dBFSをテストする。警告だけを返し、自動増幅しない。逆相と狭帯域で本方式でも情報が消えるテストを残す。
- [x] `swift test --filter EncoderTests` を実行する。T1/T2最大誤差≤1e-6、参照式一致、入力耳と出力耳の混同がないことを確認する。

**完了条件:** 人に音を聞かせず、式・既知の限界・平滑化を再現できる。

### タスク2: 共通出力制限器を実装する

**対象:** `OutputGuard.swift`、`OutputGuardTests.swift`。対応: T5、SPEC 4.4。

**インターフェース:** `OutputGuard(sampleRate: Double)`、`process(_ x: Float) -> Float`、`reset()`、`private(set) var faulted: Bool`。`faulted`後はresetまでゼロを返す。設定は固定上限−3 dBFS、5 ms先読み、100 msリリース。

- [x] 44.1/48 kHzの各レートで、インパルス、±4、NaN/Inf、無音、末尾フラッシュ、resetの失敗テストを追加する。

```swift
func testInvalidInputLatchesSilence() {
    let guarder = OutputGuard(sampleRate: 48000)
    _ = guarder.process(.nan)
    XCTAssertTrue(guarder.faulted)
    for _ in 0..<1000 { XCTAssertEqual(guarder.process(0.5), 0) }
    guarder.reset()
    XCTAssertFalse(guarder.faulted)
}
```

- [x] `swift test --filter OutputGuardTests` で赤を確認する。
- [x] `ceil(fs×0.005)` samplesの遅延と有界なピーク検出を実装する。先読み窓を毎sample全走査せず、固定容量の単調dequeなどで窓内最大値を管理する。候補ゲインは`min(1, ceiling/peak)`、下げるときは即時、戻すときは100 msで平滑化し、出力直前にも有限値・絶対値上限を保証する。

```swift
let required = peak > 0 ? min(Float(1), ceiling / peak) : 1
gain = required < gain ? required : release * gain + (1 - release) * required
let y = delayedSample * gain
let bounded = min(ceiling, max(-ceiling, y))
```

- [x] NaN/Infは上式へ流す前に検出し、出力と遅延状態を無音化する。入力インパルスが遅延窓を抜ける瞬間のピーク取り逃しを専用テストで確認する。
- [x] 全テストを再実行し、先読み時間、上限、通常レベルでの不要な波形変更がないことを確認する。

**完了条件:** レベル上限と異常時無音を数値で確認できる。これを耳元の音圧保証とは呼ばない。

### タスク3: ファイルから最終PCMまで共通経路を作る

**対象:** `AudioFilePipeline.swift`、`AudioFilePipelineTests.swift`。対応: T1〜T5、入力形式、共通処理。

**インターフェース:** `AudioFilePipeline(url: URL, outputRate: Double) throws`、`read(maxFrames: Int) throws -> [Float]`、`seek(sourceFrame: Int64) throws`、`set(mode: ListeningMode, parameters: EncoderParameters, gainDB: Float)`、`reset()`。返す配列は制限後mono。配列確保はワーカー側だけ。Floatの非有限値や範囲外設定はエラーにする。

- [x] 合成したWAV/AIFFで対応形式を試す。1/2ch、44.1/48 kHz、16/24bitとFloat32の実際に読める組合せを確認し、壊れたヘッダ、3ch、非対応レートは再生準備前に拒否する。
- [x] テスト内でAVAudioFileを使って一時ファイルを生成し、同じ入力に対するオフライン参照値と`read`の連結結果を比較する。L=Rではmonoに一致し、L/R単独も制限器を通ることを確認する。
- [x] 経路を次の順序で実装する。AVAudioConverterはワーカーから呼び、再生コールバックでは呼ばない。

```text
形式検証 → 有界デコード → 48 kHzへ変換 → Encoder
→ 共通ゲインと100 ms開始フェード → 出力レートへ変換
→ OutputGuard → monoブロック
```

- [x] 変換前後の有限値チェック、形式変換のエラー通知、EOFで変換器と制限器の残りを一度だけ排出する処理を作る。シークでは残音を捨て、新位置で状態を初期化する。
- [x] リミッター後のピークを、44.1/48 kHz両出力で検証する。サンプル数・時間の誤差、先読み遅延、分割位置による音声欠落を測る。
- [x] `swift test --filter AudioFilePipelineTests` とタスク1・2を実行する。音声ファイルを自動でプレーヤーに開かない。

**完了条件:** 再生機器なしで、実際のファイルから上限を守るPCMを生成できる。

### タスク4: 無音のホストで機器固定と再生世代を確かめる

**対象:** `PlaybackState.swift`、`DeviceOutput.swift`、対応テスト、`Package.swift`、Xcodeプロジェクト／共有scheme、`App/MonoOtoApp.swift`、`App/PlayerView.swift`、`App/Info.plist`、`docs/verification/stage-a.md`。対応: T6/T9。

**インターフェース:**

```swift
enum PlaybackPhase: Equatable { case stopped, preparing, running, paused, stopping, error }
struct PlaybackTicket: Equatable { let generation: UInt64 }
// PlaybackState: beginPreparation() -> PlaybackTicket
// finishPreparation(_ ticket: PlaybackTicket) -> Bool
// start(_ ticket: PlaybackTicket) -> Bool：現在世代かつ準備済みだけをrunningへ移す
// stop(), pause(), private(set) var phase: PlaybackPhase
// DeviceOutput: prepare(uid: String, sampleRate: Double) async throws
// startSilence() throws, stop(), dispose()
```

- [x] 純粋な状態テストを先に追加する。停止後の古い準備完了は拒否され、新しい再生を止めたり再開したりしないことを確認する。

```swift
func testLatePreparationCannotRestartPlayback() {
    let state = PlaybackState()
    let old = state.beginPreparation()
    state.stop()
    XCTAssertFalse(state.finishPreparation(old))
    XCTAssertEqual(state.phase, .stopped)
}
```

- [x] 世代番号は制御側の直列実行で更新する。準備成功だけで`running`にはせず、現在世代と出力準備完了を再確認した開始操作だけが遷移させる。
- [x] SwiftUIの小さいホストと共有schemeを作る。起動時は音声グラフを開始せず、画面には機器選択と明示的な無音経路テスト操作だけを置く。
- [x] 機器UIDをAudioObjectIDへ解決し、AVAudioEngineの出力AudioUnitに選択機器を設定する手順を、対象SDKと実機で確認する。戻り値と実際の出力形式を読み戻し、既定機器の暗黙利用を避ける。
- [x] 機器存在、2chの配置、レート、接続通知を確認する。指定UIDが消えたら停止し、既定出力の変更で勝手に追従しないことを無音のコールバック計数と機器IDで確認する。
- [x] `swift test --filter PlaybackStateTests`、`swift test --filter DeviceOutputTests`、共有schemeのビルド／テストを行い、機器固定と無音停止の実機結果を記録する。

**判定:** AVAudioEngineで選択機器固定・切断時停止を満たせない場合は、このタスクで停止する。原因と必要な音声出力境界の変更を提示し、動くと仮定してUIを作り進めない。

**2026-09-09 実装記録:** 状態・機器制御・無音ホストを実装。自動検証と制約は[段階A検証記録](../../verification/stage-a.md)を参照。実行環境のCoreAudio列挙は出力機器0件であり、機器固定・切断時停止の実機条件は未検証。タスク4は未完了、タスク5・6は判定条件待ちで未着手。

**2026-09-09 追試:** 現在の環境では3台を列挙でき、USB・48 kHzの無音開始・停止と最適化した本番音声境界の5回反復を確認した。SwiftPM/Xcode各60テストとReleaseビルドも成功。切断・既定出力変更・44.1 kHz／レート変更・スリープ等は引き続き未検証であり、上の実機条件のチェックは未完了のままとする。過去の機器0件という結果を現在の制約とは扱わない。

**続く利用者協力による追試:** Debug・USB・48 kHzで、動作中の切断による自動停止、再接続後の停止維持、実スリープ・復帰後の停止維持を各1回確認した。切断を伴わない既定出力変更、44.1 kHz／レート変更、Releaseプロファイル等は残っているため、タスク4全体のチェックは未完了のままとする。詳細は段階A検証記録の末尾を参照。

**異レート切替修正後:** 旧実装で既定出力変更・レート変更の停止を確認した後、異レートの機器へ初期切替すると遅延構成通知で再開できない問題を再現した。prepareをasync化し、未開始の初期設定中に一回だけ通知を待ち、2秒の期限と世代・キャンセル検証を追加した。SwiftPM/Xcode各70テスト、Release build、既定USB44.1→選択HDMI48とUSB44.1で各5回の開始停止を確認済み。監視登録を移したため、修正版での実機停止条件とプロファイルの再確認を残す。タスク4全体は未完了。

#### タスク4追補: リアルタイム処理と破棄順序の検証計画

対象は無音ホストのT6/T8/T9境界。タスク5以降、音楽再生、OS設定変更は含めない。既存の未コミット変更を維持する。

事実は、現行renderが固定の診断状態を参照し、disposeがstop後にdetachし、診断状態を次のprepareまで保持すること。仮説は、初回を含むrenderに確保・解放・待ちがなく、最後の状態解放がcallback終了後の制御スレッドで起きること。初回のSwift metadata/witness解決、renderスタック下のmalloc/free/待ち、stop後の計数増加、callback中または制御側以外での状態解放が観測されたら合格を棄却する。

変更対象: この既存計画、`docs/verification/stage-a.md`、`docs/verification/Task4RealtimeProbe.swift`、`docs/verification/instrument-task4.py`。不具合を確認した場合に限り`DeviceOutput.swift`と対応テストを最小修正し、修正前後を比較する。

- [x] 現行ソースのハッシュと環境を保存し、`swiftc -swift-version 6 -target arm64-apple-macosx14.2 -O -whole-module-optimization -emit-sil`および`-emit-ir`でSourceNode closureから外部overlayまで追跡する。初回metadata解決も対象とする。
- [x] 本番ソースをそのまま最適化コンパイルする実機プローブを追加する。機器名の明示指定が必須。準備中計数0、開始後計数増加とID一致、stop/dispose後の1秒不変、再準備、runningで所有者解放を確認する。UID・音声を記録しない。
- [x] 初回開始前からAllocationsとTime Profilerを記録し、renderスレッドと確保スタックを照合する。記録開始前の確保やサンプルがないrenderを「違反なし」の根拠にしない。
- [x] 一時コピーにのみ固定サイズのactive counterと制御側の寿命マーカーを挿入する。stop復帰・detach後・engine解放後・state deinitでactive=0、deinitがmain thread、detachより後であることをassertする。render内にログを追加しない。このビルドで時間性能を判定しない。
- [x] `swift test`と共有schemeのtest/Release buildを実行する。診断追加だけで製品の振る舞いを変えない場合は不要なモックテストを増やさない。製品修正が必要なら先に実行可能な再現条件を固定する。
- [x] ソース経路と実測を別観点で再監査し、検証記録へ条件・件数・失敗・残る制約・再実行手順を記す。完了範囲をSPECと整合させる。証拠が欠ける項目は未検証とする。

**実行結果:** 2026-09-09、USB-A・48 kHzで本番ソースの最適化プローブと寿命診断を実行。SwiftPM／Xcode各70テストとRelease build成功。状態8個のmain thread解放、render本体の入口／出口計数一致を確認した。thunkにはARCが存在する。音声トレースの通常区間では待機を観測せず、停止末尾にはCoreAudioのSmart Routingによる同期IPC・ロック待ちを観測した。詳細と証拠は[段階A検証記録](../../verification/stage-a.md)の同日追加記録を参照。上のチェックは48 kHzでの追補計画の実行を示し、44.1 kHzでの同じプロファイル、全OSの保証、段階AのT8全体の完了を意味しない。タスク4全体は44.1 kHz追試待ちとし、タスク5・6は開始しない。

**44.1 kHz追試後の最終判定:** 利用者によるUSB-Aのレート変更後、同じ本番ソースでAllocations／Time Profiler／Audio System Trace／寿命診断を各8反復実行した。状態8個のmain解放、render本体1,379回の入口／出口一致、通常IOProc最大143.625 µs、client cycle全1,397区間Normalを確認した。48 kHz同様、停止末尾にはOSの同期待ちがある。これまでの修正版の機器固定・変更時停止と今回の両レートの検証により、現行macOS／arm64／USB-Aでタスク4を完了とする。14.2実機、60分負荷、音楽経路を含むT8全体の合格ではない。タスク5・6は未着手。

**2026-09-10 レビュー修正後:** `645ac38`でキャンセル済み準備の旧出力停止、UI旧Task排除、待機タイムアウトとのキャンセル競合、所有者解放時の停止漏れを修正した。メインスレッドでの最後の解放は同期破棄し、別スレッド解放はMainActor待ちを残すが、その間に配送された障害通知も専有backendを停止する。SwiftPM／Xcode各75テスト、Releaseビルド、USB 48 kHz・4周期の計装寿命検証が成功。初期通知は1件のみ消費し、追加通知と2秒タイムアウトで停止する方針は維持する。

### タスク5: 有界キューと即時無音化を作る

**実装・単体検証完了（2026-09-10）:** 独立C11ターゲットとSwiftPM専用19テストを追加した。基点HEAD `2929fa6`＋作業差分。60分合成負荷でC render最大218 µs／p99 3 µs、5.33 ms以内を確認。実行証拠は[段階A検証記録](../../verification/stage-a.md)のタスク5節を参照。

**対象:** `Sources/MonoOtoRealtime/include/FrameQueue.h`、`FrameQueue.c`、`Tests/MonoOtoRealtimeTests/FrameQueueTests.swift`、`Tests/MonoOtoRealtimeTestSupport/FrameQueueTestSupport.c`とヘッダー、`Package.swift`。対応: T5/T7/T8のキュー単体境界。

**実装API:** `ear=0`は左、`1`は右。出力はnon-interleaved Float32、2ch。容量は1〜4,096の2のべき乗、render上限は16,384。生成・破棄はコールバック外。

```c
typedef struct MOFrameQueue MOFrameQueue;
typedef struct { float *data; uint32_t capacity; } MOFloatBuffer;
typedef enum { MO_RENDER_OK, MO_RENDER_UNDERRUN,
               MO_RENDER_SILENCED, MO_RENDER_FAULT } MORenderResult;
typedef struct {
    uint64_t underruns, invalid_samples, invalid_buffers, rendered_frames;
    uint32_t high_water_frames;
    bool silenced, faulted;
} MOQueueStats;
MOFrameQueue *mo_queue_create(uint32_t capacity, unsigned ear);
void mo_queue_destroy(MOFrameQueue *q);
uint32_t mo_queue_push(MOFrameQueue *q, const float *input, uint32_t count);
MORenderResult mo_queue_render(MOFrameQueue *q, MOFloatBuffer left,
                              MOFloatBuffer right, uint32_t count);
void mo_queue_silence(MOFrameQueue *q);
MOQueueStats mo_queue_read_stats(const MOFrameQueue *q);
```

- [x] 満杯・部分受理・空・wrap・count=0・要求上限・左右容量・canary・反対耳ゼロを検証。未受理PCMは呼出し元が保持して再送する。
- [x] SPSCのrelease/acquire公開と全11 atomicのlock-free確認。固定storageと所有者別診断を使用し、renderに確保・待機・ログを入れない。
- [x] 有限値／最終上限検査、異常push全拒否、格納済み異常PCMのrender防御、sticky faultとsilenceを検証。正常PCMは再加工しない。
- [x] 別シンボルのテスト版で無音化3競合点と整数wrapを検証。silenceはjoinではなく、終端確認済みrenderを取り消さない。
- [x] pthreadの両耳各110万frames順序、意図的枯渇／満杯、1,000周期の全利用者join後破棄、ASan/TSan/UBSanを確認。
- [x] 非計装60分合成負荷のC render性能ゲートを確認。44.1 kHz相当10分と最大frames 60秒も成功。OSの周期遅れ・不足は別計数し、実音声経路のT8合格とはしない。

`rendered_frames`は正常に返した元PCMの累積数であり、OS再生位置ではない。統計は各項目独立のatomic snapshot。Task 6でバッファ検証、部分push再送、EOF/pause、世代・停止・全利用者終了後破棄を接続する。新しいキュー試験はSwiftPMのみで、Xcodeの既存75件には含まれない。

### タスク6: 共通経路と最小再生を統合する

**2026-09-11 実装記録:** 再生統合と最小UIを実装。自動検証結果と実機の未完了条件は[段階A検証記録](../../verification/stage-a.md)を参照。以下の実機を含む項目は未完了のままとする。

**対象:** `PlaybackController.swift`、`PlaybackWorker.swift`、`DeviceOutput.swift`、C `RenderContext`、最小`PlayerView.swift`と対応テスト。対応: T5〜T9。

**インターフェース:** `PlaybackController`は制御側で直列化する。`open(url:) async throws`、`play() async throws`、`pause()`、`stop()`、`seek(seconds:) async throws`、`selectOutput(uid:ear:)`、`set(mode:parameters:gainDB:)`。公開状態は`PlaybackPhase`、再生位置・長さ、チャンネル数、選択機器・耳、設定値、シーク可否、相殺警告、エラー。再生ワーカーとUIは同じEncoderを直接共有しない。

- [x] 出力先をモックにして、準備中stop、open A→open B→Aの完了、seek中stop、切断直後の再開始、デコード失敗を再現するテストを先に追加する。
- [x] ワーカーで`AudioFilePipeline`からキュー空き容量まで読み出す。キューへの部分書き込みをデータ欠落にしない。制御要求はブロック境界で適用し、DSP値を本試験中固定する仕組みもここに置く。
- [x] SourceNodeのclosureは固定寿命のキューを参照してC renderを呼ぶ。処理前にチャンネル数と各バッファ容量を検証する。callbackとワーカーの停止完了を確認するまでキューを解放しない。
- [x] 停止手順を次の順序に統一する。

```text
世代更新 → mo_queue_silence → producerキャンセル → engine停止
→ producer/callbackの終了確認 → queueとconverter/limiterの残音破棄
→ stopped表示
```

- [x] pauseでは操作ticketを更新してrenderを可逆holdし、workerの駐止完了を待つ。同じ音声sessionのqueue、未push PCM＋offset、pipeline（SRC位相・DSP履歴・limiter先読み・開始fade）を保持する。消費framesからのseek/resetで再開位置を作らず、再開時に元PCMの欠落・重複がないことを連続参照とのbit比較で確認する。stop/seek/open/耳・機器変更は旧sessionを破棄し、新音声sessionとして準備する。開始100 ms fadeは新音声sessionに適用し、pause解除では再初期化しない。
- [x] 耳／機器の変更時は停止し、再開操作を待つ。キューunderflowはゼロと通知、デコードエラーや繰り返す供給失敗は停止する。4096 framesを超える音声待ちを作らない。
- [ ] 実機の出力経路確認後、利用者の明示操作で低い初期音量の短い確認音を再生する。確認音も共通ゲイン、レート変換、制限器、キューを通す。
- [ ] `swift test --filter PlaybackControllerTests` とタスク4・5のテストを再実行する。stopから新規供給停止まで100 ms以内を測定する。

**完了条件:** 長いUI操作なしでファイルを再生・停止でき、古い音声が復活しない。

### タスク7: 日常の比較に必要なUIと設定を仕上げる

**対象:** `PlayerView.swift`、`Settings.swift`、`SettingsTests.swift`、`PlayerUITests.swift`、プロジェクトのUIテスト設定。対応: SPEC 4.1、設定とプライバシー。

**インターフェース:** `Settings: Codable`は`version: Int`、`ear: HearingEar`、`deviceUID: String?`、`gainDB: Float?`、`strength: Float`、`cutoffHz: Float`。`gainDB=nil`はミュート。`validated() -> Settings`は欠損・破損値をSPEC初期値に戻す。設定に再生状態、URL、音声内容を含めない。

- [ ] 設定テストで初期−18 dB、a=0.35、fc=1500、範囲外・非有限値・未知versionを確認する。再起動でrunningを復元できない構造にする。
- [ ] ファイルを開く、再生、一時停止、停止、シーク、機器／耳、通常mono／cue／L/R単独、強さ、周波数、音量を小さい画面に配置する。モノラル入力ではL/R単独を無効化する。
- [ ] ボタン・調整値の日本語ラベルを追加し、キーボードとVoiceOverで停止まで到達できるようにする。

```swift
Button("停止") { controller.stop() }
    .accessibilityLabel("再生を停止")
    .keyboardShortcut(".", modifiers: .command)
```

- [ ] 相殺警告、非対応形式、機器未選択、準備中、停止、errorを色以外でも伝える。「効果は検証中」「音量を無理に上げない」を短い案内にする。
- [ ] UIテストはモック入力・無音出力を使用する。起動で音声開始が呼ばれない、耳変更でstopを呼ぶ、停止操作が準備中も有効、比較モード名の入力L/Rと出力耳が混同されないことを検証する。
- [ ] `swift test --filter SettingsTests` と共有schemeのUIテストを実行し、VoiceOverの実操作は手動結果を記録する。

**完了条件:** SPEC 4.1の8項目を利用者が操作できる。

### タスク8: レベルをそろえた比較と評価記録を作る

**対象:** `EvaluationSession.swift`、`EvaluationView.swift`、`EvaluationSessionTests.swift`、`AudioFilePipeline.swift`。対応: SPEC 7.2。

**インターフェース:**

```swift
enum InputSide: String, Codable { case left, right }
struct EvaluationTrial: Codable {
    let id: Int
    let assetID: String
    let mode: ListeningMode
    let inputSide: InputSide
    let levelOffsetDB: Float
}
struct TrialAnswer: Codable { let trialID: Int; let chosenSide: InputSide? }
// makeTrials(assetIDs: [String], seed: UInt64) -> [EvaluationTrial]
// wilsonLower(correct: Int, total: Int) -> Double?
// exportJSON(to: URL) throws：明示操作時のみ。画面は内部mode/正解を表示しない。
```

- [ ] 通常mono／cue各60試行、各L/R30、ラベル独立±3 dB、固定seedの再現性、回答と試行の対応をテストする。欠測を勝手に正解・不正解へ変換せず理由とともに別記する。
- [ ] 事前レンダリングで条件間の非無音RMSを±0.5 dBへ整合し、主観音量の確認後に固定する。試験用の補正ゲインも最終制限器より前に入れる。試験中に制限器が作動した試行は無効理由を残して別の試行として扱う。
- [ ] レンダリング音はメモリ上の短いブロックで扱い、自動でディスクに保存しない。学習・調整・本試験のassetIDを分離し、左右ラベルと音源種類の偏りを確認する。
- [ ] Wilson下限を次の式で実装し、0/60、30/60、45/60、60/60とtotal=0の扱いをテストする。total=0は成績なしとし継続判定しない。

```text
p = correct / total, z = 1.96
lower = (p + z²/(2n) - z×sqrt(p(1-p)/n + z²/(4n²))) / (1 + z²/n)
```

- [ ] 音楽5曲各20〜30秒の比較順を無作為化し、「広がり・音の分離・自然さ・楽しさ・疲れ」を1〜7で記録する。疲れだけ高いほど悪いことを集計にも明示する。
- [ ] JSONは匿名ID、機器・OS、DSP・校正値、seed、試行と回答、無効理由、主観評点、日時を含め、フルパス・音声・診断を含めない。書き出しキャンセル、失敗、既存ファイル置換確認を試す。
- [ ] `swift test --filter EvaluationSessionTests` を実行し、学習用フィードバックが本試験に出ないことと、停止／中止がいつでも可能なことを画面で確認する。

**完了条件:** 正答率と音楽体験を別に報告できる。試行数を人数へ読み替えない。

### タスク9: 段階Aの工学的受け入れを行う

**対象:** テスト群、`docs/verification/stage-a.md`。新機能は追加せず、見つかった不具合の最小修正だけを行う。

- [ ] 全自動テストを新しく実行する。

```sh
swift test
xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -destination 'platform=macOS' test
```

- [ ] T1〜T9に実行結果を対応付ける。OS権限・機器テストをモックだけで合格としない。macOS 14.2は実機がなければ未検証と記載する。
- [ ] 最終PCMの有限値、−3 dBFS上限、片耳ゼロ、確認音と全モードの共通経路を追う。レート変換後の検査が抜けていないことを別の観点で再監査する。
- [ ] 44.1/48 kHz有線出力で60分運転する。callback処理時間p99、underflow回数、最大キュー長、メモリ推移、停止時間を記録する。性能測定にsanitizerを混ぜない。
- [ ] 機器切断、出力選択変更、スリープ、連続start/stop、シーク直後stopを実機で試す。callback内に確保・解放・ログ・待ちがないことをソースとプロファイルで確認する。
- [ ] UI／VoiceOver、ファイル非対応、破損設定、JSON出力、ネットワークや音声自動保存がないことを確認する。
- [ ] 記録にはコマンド、終了コード、機器UIDを匿名化した識別子、OS、設定、観測結果、未検証事項を残す。必要な機器がない試験は未検証のまま扱う。

**完了条件:** T1〜T9と対象機器の出力制御が合格。当事者評価へ移れる状態であり、知覚効果はまだ未検証。

### タスク10: 当事者評価と段階Bへの判断

**対象:** 明示的に書き出した評価結果、同意された範囲の匿名要約を`docs/verification/stage-a.md`へ記録。被験者や機器の存在を仮定して自動完了しない。

- [ ] SPEC 7.2の暫定条件、音楽・有線ヘッドホンという用途、任意参加・中断操作を本人と確認する。音圧をdBFSから推定しない。
- [ ] 短い練習の後、レベルとDSP値を固定して条件別60試行を休憩可能なブロックで実施する。中断は失敗の隠蔽にも継続の強制にも使わない。
- [ ] 学習に使わない5曲で主観評価を行い、別日に未知素材で反復する。正答率、広がり、音質・疲れを個別に報告する。
- [ ] 次の判定を適用する。

| 結果 | 判断 |
| --- | --- |
| 広がりが5曲中3曲以上で1点以上改善し別日も確認。自然さ・楽しさの中央値の悪化は1点以内。疲れは増えない | 音楽体験改善の探索結果として段階Bを検討 |
| 左右正答率だけが15ポイント以上改善、Wilson下限>50%、広がり・楽しさは改善しない | 当初目的は未達。段階Bを始めず用途を相談 |
| 広がりだけ改善し方向弁別は改善しない | 改善した体験だけを説明し、方向が分かると表現しない |
| 差がない、音質劣化や疲労が大きい | 方式を棄却またはSPECを再検討。UIや取得機能を増やさない |

**完了条件:** 結果と継続／棄却の理由を残す。当事者が未参加なら「アプリ実装完了・知覚評価待ち」で止まり、段階Bへ自動進行しない。

## 5. 段階Bの条件付き工程

段階Bは今回の実装可能タスク群に含めない。以下はA4後の計画を作るための具体的な順序と判定点であり、今からクラスや権限設定を追加する指示ではない。

| 順序 | 調べること | 成果と通過条件 |
| --- | --- | --- |
| B1 | 選択アプリ一つのprocess tap、権限、署名／Sandbox、複数音声プロセス | ステレオ取得、拒否・取消、非対応時に原音を変えない実機記録 |
| B2 | private aggregate、自己除外、原音ミュートと復帰 | 二重再生・自己ループ・ミュート残留がない。強制終了・途中失敗でも原音復帰を確認 |
| B3 | 段階AのDSP接続、キュー短縮、クロック補正 | 有線capture-to-output p95≤30 ms、60分で音切れ・ドリフト・メモリ増加なし。T10合格 |
| B4 | 対象OS／機器拡大と配布判断 | 検証した対応表、原音復帰の説明、署名・公証・依存条件。全システム取得は別の範囲として判断 |

段階Aの最大4096 framesキューをそのまま段階Bに流用して遅延目標を満たしたと扱わない。B1〜B2が不成立なら、問題と必要な変更だけを報告し、仮想ドライバ等を無断導入しない。

## 6. 仕様の対応表と自己監査

| SPECの要求 | 実装・検証先 |
| --- | --- |
| 目的、科学的根拠、仮説、非目標 | グローバル制約、タスク8〜10、段階Bの条件 |
| 入力形式・mono展開・非対応拒否 | 3・7 |
| M/S式、平滑化、相殺、単独確認 | 1・3・7 |
| 最終制限、初期音量、NaN/Inf | 2・3・5・9 |
| 出力耳、機器固定、切断・スリープ停止 | 4〜6・9 |
| シーク、EOF、一時停止、旧世代破棄 | 3〜6・9 |
| 有界バッファ、リアルタイム制約 | 5・6・9 |
| UI、設定、VoiceOver | 7・9 |
| プライバシー、匿名評価、書き出し | 7〜9 |
| T1〜T9 | 各タスクと9の一括受け入れ |
| 当事者の左右弁別・音楽評価・継続基準 | 8・10 |
| process tap、原音制御、T10、遅延 | 条件付き段階B。段階Aでは未実装・未検証と明記 |

自己監査では、最初に仕様の要求を漏れなくタスクへ対応付け、次に失敗経路から逆向きに停止・出力・データ保存を確認する。数値テストが通ること、実機で動くこと、当事者の体験が改善することの三つを同じ合格にまとめない。

## 7. 次に着手する範囲

タスク1〜4は現行環境で検証済み。タスク5の独立キューは実装・自動検証済みで、60分合成負荷でC render最大218 µs／p99 3 µs、5.33 ms以内を確認。タスク6の音楽再生統合は実装・自動検証済み。実機の物理出力とcallback全体の確認は未完了。知覚評価・段階Bは未着手。タスク4の完了は全OSや段階AのT8全体の保証ではない。最新の実行条件と未検証事項は[段階A検証記録](../../verification/stage-a.md)を参照する。
