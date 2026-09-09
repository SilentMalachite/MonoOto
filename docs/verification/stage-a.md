# 段階A 検証記録

## 最新状況（2026-09-10、実装コミット`645ac38`）

タスク1〜4の実装と、記録したmacOS／arm64／USB機器の範囲での検証を完了。無音ホストのみで、タスク5・6、音楽再生の統合、知覚評価は未着手。

| 範囲 | 最新の確認と限界 |
| --- | --- |
| 自動テスト・ビルド | キャンセル・所有者解放の修正後にSwiftPM／Xcode各75テスト成功、Releaseビルド成功 |
| 最新版の実機寿命 | USB 48 kHz・4周期、4状態のmain thread最終解放、render入口／出口計377回一致。所有者解放の処理が戻る前に停止・切り離し・状態解放を確認 |
| 過去の実機・プロファイル | 機器固定、切断／再接続、既定出力変更、レート変更、スリープ、44.1／48 kHzプロファイルを確認済み。ただし最新のキャンセル・破棄修正より前の結果 |
| 継続する制約 | 別スレッドでの所有者解放はMainActor実行待ちが残る。通常は明示stop／disposeを行う。最新修正後の44.1 kHz再プロファイル・物理的な切断／スリープ、macOS 14.2実機、60分負荷、音楽経路・知覚評価は未検証 |

以下は時系列の履歴であり、古い節の「未完了」「機器0件」「Git未管理」「非同期破棄」等は当時の実装・環境を示す。新しい結果で過去の測定を書き換えない。末尾の2026-09-10「Grok指摘2」が最新の修正・実行証拠で、本サマリーのためにテストを再実行したものではない。


## 2026-09-09 — タスク4：無音の機器固定ホスト

タスク4のコードと無音ホストを実装した。**実機の機器固定・切断時停止は未検証であり、タスク4は未完了。計画の判定条件に従いタスク5・6は未着手。**

環境: macOS 26.6.2 (25G83)、Apple Silicon、Xcode 26.6、Swift 6.3.3。初期対象のarm64でビルドした。macOS 14.2での実行は未検証。この作業ディレクトリにはGit管理情報がなく、コミットは行っていない。

### 実装と確認範囲

- `PlaybackState` はMainActorで世代と準備完了を管理し、古い準備完了・開始・失敗を拒否する。準備だけではrunningにならない。
- `DeviceOutput` は明示されたUIDをIDに解決し、出力AudioUnitのCurrentDeviceを設定する。準備後および開始前後にID・レート・2ch左右配置を読み戻す。起動時・機器列挙時にはグラフを生成しない。
- 機器・既定出力・構成・スリープ通知で停止する。機器が公開している場合はdata source・jack接続の変更も監視する。旧世代の通知は新しい準備に作用しない。通知処理は制御側へ渡し、render内にはTask生成・ログ・ファイルI/Oを置かない。
- renderは対応形式の有効なバッファだけをゼロ化する。不整合はエラーとatomic faultへ記録し、制御側の単一20 msタイマーから停止する。不正なポインタや長さのメモリ全体をゼロ化できるとは主張しない。20 msは監視間隔であり、停止時間の実測値ではない。
- 無音ホストは明示的な機器選択・開始・停止と、確認済み機器ID・コールバック計数を表示する。停止済みの計数状態も次の準備まで保持するため、停止後の変化を観察できる。音源再生機能はまだない。
- Swift 6のactor推論によりrender closureへMainActor実行時チェックが入る問題を、明示的な`@Sendable`で修正した。最適化後SILでnonisolatedかつexecutor check・retain/release・heap allocation命令なしを静的に確認した。これは実機プロファイルの代替ではない。
- OSAtomicによる固定サイズの診断状態を使用する。APIは非推奨だが対象SDKでコンパイル可能。リアルタイム性・callback終了と解放順序の実機プロファイルは未検証。後続C境界への移行判断はタスク4の実機結果後に行う。

### 実行結果

| 検証 | 結果 |
| --- | --- |
| 状態テストのRED確認 | 同じ7テストを一時領域の意図的に壊した状態実装へ適用し、15 assertion failures、終了1。初回のビルド不成立はRED証拠に含めない |
| 機器制御テストのRED確認 | モック境界の未実装状態で7テスト、39 assertion failures、終了1 |
| Xcode共有scheme build | 成功、終了0 |
| Xcode共有scheme test | 実行不能、終了65。`com.apple.testmanagerd.control`への接続がsandbox restriction (159)で拒否された |
| 生成済みMonoOtoHostTests.xctestの直接実行 | 16テスト（状態7・機器/バッファ9）、0 failures、終了0。scheme経由の実行成功とは区別する |
| CoreAudioを直接呼ぶ機器列挙probe | 出力機器0件。グラフ開始なし。物理機器の不存在ではなく、この実行環境から列挙できなかった結果 |

最終ソースで`swift test --disable-sandbox --scratch-path /private/tmp/monooto-task456/swift-final`を再実行し、55テスト（既存39・状態7・機器/バッファ9）、0 failures、終了0を確認した。`build-for-testing`も終了0。ビルド中のソース更新による途中の失敗は完了判定から除いた。

自動テストは不明UID、準備と開始の分離、形式/ID読み戻し不一致、開始前後の機器消失、変更/スリープ通知、古い通知、無音バッファ・境界保護・fault latchを確認する。これらはモックとメモリ上の検証であり、OS通知の実配送や実際の出力先を証明しない。

### 再実行コマンド

通常環境:

```sh
swift test
xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -destination 'platform=macOS,arch=arm64' build
xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -destination 'platform=macOS,arch=arm64' test
```

今回の制限環境では、一時領域をキャッシュ先に指定した。ユーザー設定の変更は行っていない。

```sh
swift test --disable-sandbox --scratch-path /private/tmp/monooto-task456/swift-final
CFFIXED_USER_HOME=/private/tmp/monooto-task456/xcode-user \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/monooto-task456/module-cache \
CLANG_MODULE_CACHE_PATH=/private/tmp/monooto-task456/clang-cache \
xcodebuild -project MonoOto.xcodeproj -scheme MonoOto \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/monooto-task456/DerivedData \
  -clonedSourcePackagesDirPath /private/tmp/monooto-task456/SourcePackages \
  -packageCachePath /private/tmp/monooto-task456/package-cache \
  -IDEPackageSupportDisableManifestSandbox=YES CODE_SIGNING_ALLOWED=NO build-for-testing
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  /private/tmp/monooto-task456/DerivedData/Build/Products/Debug/MonoOtoHostTests.xctest
```

Xcodeの`test`も同じ引数で試した。最初の試行ではユーザーキャッシュ書込みと入れ子のmanifest sandboxが拒否されたため上記のプロセス限定設定に変更した。外側のsandboxは有効のまま。ログは一時領域に保存し、音声・音源パス・機器UIDは記録していない。

### 次に必要な実機確認（T6/T9、未実施）

1. 有線の2ch出力を接続し、44.1 kHzまたは48 kHzに設定する。通常のXcode環境で共有schemeを起動する。アプリ起動だけでは計数0・停止中であることを確認する。
2. 機器を選択し「選択機器で無音テストを開始」を押す。確認済みIDが選択機器と一致し、計数が増加することを確認する。UIDを記録に残す場合は匿名化する。
3. OSの既定出力変更、選択機器の切断、スリープを個別に試す。停止表示、ID解除、計数の停止、他機器への自動再開始がないことを確認する。再接続だけでは開始しないことも確認する。
4. 停止と再準備を繰り返し、旧通知で新世代が再開しないこと、停止後の計数が増えないことを確認する。44.1/48 kHzそれぞれでOS・匿名機器識別子・観測時間・結果を追記する。

この確認を通過するまでタスク5・6を開始しない。AVAudioEngineで固定・停止を満たせないことが判明した場合は、出力境界の見直しが必要。現状は機器へアクセスできないため、別のAPIへ変更すべきという証拠もない。試聴・安全音圧・知覚効果・停止100 ms・60分負荷試験は未検証。

## 2026-09-09 — 通知後のバックエンド停止の回帰テスト

`testNotificationsStopAndDisposeBackendWhilePreparedOrRunning`を追加した。機器変更・既定出力変更・構成変更・スリープ・render faultの5通知を、準備中／実行中の計10条件で検証する。通知直前からの`stop`・`dispose`呼び出し回数の増加を、後片付けや再開始の試行より前に確認する。準備時の停止やテスト終了時の破棄で誤って合格しないようにした。本番コードの変更はない。

- **RED:** 一時コピーで通知ハンドラーの`self.stop()`だけを世代・公開状態の更新に置き換え、バックエンドの停止・破棄を省略した。以前は既存9テストが成功した変更だが、追加テストでは全10条件の停止・破棄のassertionが失敗した（1テスト、20 failures、終了1）。コンパイルエラーによる失敗ではない。
- **GREEN:** 現行実装で全56テスト、0 failures、終了0。
- 検証は通知を受けた`DeviceOutput`からバックエンドへの呼び出しを対象とする。OS通知の実配送・実機の停止完了を証明するものではなく、タスク4の実機ゲートは引き続き未検証。

```sh
swift test --package-path /private/tmp/monooto-review-task4-mutant --disable-sandbox \
  --filter DeviceOutputTests.testNotificationsStopAndDisposeBackendWhilePreparedOrRunning
swift test --disable-sandbox --scratch-path /private/tmp/monooto-task456/swift-final
```

実行ログ: `/private/tmp/monooto-task456/notification-red.log`、`notification-green.log`。壊した実装は一時領域にのみ存在する。

## 2026-09-09 — 音声出力機器の選択UI

既存のCoreAudio列挙処理を使い、プルダウンを機器名順のスクロール一覧に変更した。機器名・チャンネル数・サンプルレート・選択マーク・選択した出力先を表示する。「一覧を更新」と機器0件時の接続案内を追加し、ウィンドウの初期サイズを620×580へ変更した。機器選択は明示的に停止処理を通り、無音テスト開始は別のボタン操作を必要とする。状態表示を一本化し、一覧更新後に以前の出力エラーが新しい案内を隠さないようにした。

- Xcode `build-for-testing`: 成功、終了0（前節と同じ一時キャッシュ・arm64設定）。
- Computer Useでの画面実操作: 未実施。ツールがMonoOtoへのアクセスを未承認として拒否した。別経路での操作は行っていない。
- 実機の一覧・選択・切断の確認は未検証。機器0件という以前の実行環境の制約を、UI変更で解消したとは扱わない。

手動確認では、起動時未選択、一覧更新、機器選択と選択マーク、別機器選択時の停止、0件時の案内、VoiceOverの機器名・選択状態を確認する。

生成済み`MonoOtoHostTests.xctest`の直接実行は17テスト・0 failures・終了0。これは状態・機器制御の回帰確認であり、画面操作のテストではない。ログは`/private/tmp/monooto-task456/device-ui-build.log`と`device-ui-tests.log`に保存した。

## 2026-09-09 — Claude Codeレビュー指摘の修正

Claude Codeのレビュー結果をコードと対象環境に照合し、次を修正した。

- CoreAudioの機器一覧自体を取得できた後は、個別機器のプロパティ取得失敗をその機器だけに隔離する。aliveを先に読み、切断途中・出力情報なし・不正な仮想機器が混ざっても、正常に読めた機器を一覧へ残す。最上位の機器一覧取得失敗は引き続きthrowする。
- 一覧には段階Aで非対応の機器も理由付きで表示するが、2chかつ44.1/48 kHzでない機器の選択と開始を無効にする。
- 新しいprepare開始時に、UID検証より前にbackendの診断状態をクリアする。停止直後の遅延callback確認用には次のprepareまで保持し、UID不在などで準備に失敗しても旧計数を表示しない。
- 到達不能と想定している世代不一致guardでも、明示的に出力・状態を停止して理由を表示する。
- `isolated deinit`はSwift 6.2で追加されたランタイム処理への依存を避けるため削除した。通常の`stop`/`dispose`は同期のMainActor処理を維持し、明示破棄が漏れた場合だけMainActor Taskでbackendを破棄する。フォールバックが呼ばれる回帰テストを追加した。
- Xcodeの`MonoOtoHostTests`へDSP・ファイル処理の3テストファイルも加え、SwiftPMと同じ59テストを含めた。

テスト先行の確認:

- 機器単位の失敗: 旧ループと同じ全か無かの処理を一時領域で実行し、先頭機器の読出し失敗によって後続の正常機器が失われることを確認（終了1）。本番テスト`testDeviceDiscoverySkipsUnreadableDeviceAndKeepsValidDevice`で隔離後の結果を固定した。
- deinit fallback: 明示破棄をしない場合にbackendの`disposeCount`が0のままであることをREDとして確認（1 failure、終了1）。非同期MainActorフォールバック後はfocused testが成功した。
- 準備失敗時の診断初期化: callback計数12を持つbackendで存在しないUIDをprepareし、旧計数12が残ることをREDとして確認（1 failure、終了1）。`resetDiagnostics`境界の追加後は0を確認した。
- 段階A対応判定は2ch・44.1/48 kHz・finiteを直接テストした。

最終検証:

| 検証 | 結果 |
| --- | --- |
| `swift test --disable-sandbox --scratch-path /private/tmp/monooto-claude-fixes-final` | 60 tests、0 failures、終了0 |
| 標準の`swift test` | 60 tests、0 failures、終了0 |
| Xcode Debug `xcodebuild test` | 60 tests、0 failures、`TEST SUCCEEDED`、終了0 |
| Xcode Release build | 成功、終了0 |
| `plutil -lint` | project.pbxproj・Info.plistともにOK |

Releaseでのビルド成功はrender callbackのリアルタイム性能を証明しない。Debugの観測値も性能判定に使用しない。機器固定・切断時停止・callback停止完了・macOS 14.2での実行・Release実機プロファイルは引き続き未検証であり、タスク4の実機ゲートは未完了。

`@State private var playback = PlaybackState()`はSwiftUIの状態保存として動作しており、参照生成の軽微な効率指摘に対して型と公開状態を拡張する利点がないため変更しなかった。

## 2026-09-09 — タスク4の実機追試（21:56以降）

**タスク4は一部進展したが未完了。タスク5・6は未着手。** HEAD `1cacd28`の本番コードに対して追試した。開始時の作業ツリーはクリーン。今回、製品コード・テストコードの変更を必要とする不具合は再現していない。文書の進捗記述だけを更新した。

環境: macOS 26.6.2 (25G83)、Apple Silicon、Xcode 26.6 (17F113)、Swift 6.3.3。OSからUSB-A（既定出力）、HDMI-A、内蔵出力の3台を列挙できた。すべて2ch・48 kHz。過去の「機器0件」は今回には当てはまらない。音源ファイル・機器UIDは記録せず、OS音量・既定出力・レートは変更していない。

### 自動検証

| コマンド | 今回の結果 |
| --- | --- |
| `swift test` | 60 tests、0 failures、終了0 |
| `xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -destination 'platform=macOS,arch=arm64' test` | 60 tests、0 failures、TEST SUCCEEDED、終了0 |
| `xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -configuration Release -destination 'platform=macOS,arch=arm64' build` | BUILD SUCCEEDED、終了0 |

ログ: `/private/tmp/monooto-task4-current-test.log`、`/private/tmp/monooto-task4-current-release.log`。標準SwiftPMテストはツールの実行結果で確認した。

### 実画面・実機の確認（Debugホスト）

- 起動とUSB-A選択だけではコールバック0、確認済みIDは未接続。明示開始後はUSB-AのIDで計数が増加した。
- 明示停止後はID解除・停止表示となり、計数1620が次の観察でも変わらなかった。別の開始停止でも停止状態へ戻った。
- OSの既定出力がUSB-AのままHDMI-Aを選択して開始し、USB-Aとは異なるIDと計数増加（1829）を確認した。前後のOS機器情報でも既定出力はUSB-Aだった。
- HDMI-A動作中にUSB-Aを選択すると停止・ID解除となり、計数2182を保持した。機器選択だけでUSB-Aへ開始しなかった。
- これらは無音経路のID読み戻しとコールバックの確認であり、物理端子からの信号測定や音楽再生の検証ではない。

Releaseアプリはビルド・起動できたが、画面操作の対象取得が同じ識別子のDebugアプリを起動することをプロセスの実行パスで確認した。このため上のUI結果をReleaseの測定として扱わない。

### 最適化した本番音声境界の実機反復

`Sources/MonoOtoAudio/DeviceOutput.swift`を変更せず、一時領域のMainActor検証プログラムと`swiftc -O -swift-version 6 -parse-as-library`でコンパイルした。USB-Aを一意に指定し、各回でprepare後250 msは計数0、開始後2秒でrunning・選択ID一致・計数増加、stop直後のID解除、さらに1秒後の計数不変をassertした。5回すべて成功、終了0。

| 反復 | 停止後の計数 | stop呼び出し時間 | 1秒後の計数 |
| --- | --- | --- | --- |
| 1 | 189 | 20.848 ms | 不変 |
| 2 | 188 | 19.272 ms | 不変 |
| 3 | 188 | 20.244 ms | 不変 |
| 4 | 189 | 23.021 ms | 不変 |
| 5 | 189 | 25.539 ms | 不変 |

計測対象は制御側の同期`stop()`呼び出し時間であり、新規音声供給停止時間、OS・DACの出力遅延、p95/p99の性能保証ではない。記録は`/private/tmp/monooto-task4-probe.MOT2hq/run.log`、一時検証ソースは同ディレクトリの`Probe.swift`。一時ファイルは永続的なテスト資産ではない。

### リアルタイム経路の監査と計測制約

- 現行ソースから最適化SILを生成し、SourceNode closureがnonisolatedで、closure本体にTask生成・executor check・明示的なheap allocation・retain/release命令がないことを確認した。
- `renderDeviceSilence`には標準ライブラリのCollection witness呼び出しが残る。closureの検査だけで外部実装まで確保・解放がないとは断定しない。状態の確保は制御側、closureによる所有はグラフ寿命にまたがるが、切断時の最終解放スレッドと実行中callbackとの競合は未検証。
- 最適化した検証プログラムへのAllocations attach、およびAllocationsからのlaunchはともに`Failed to attach to target process`、終了2。計測失敗であり、確保なし・ロック待ちなし・期限超過なしの証拠にはしない。DebugホストのTime Profiler記録も性能判定には使わない。

### 残る完了条件

利用者による機器の抜き差しとスリープ・復帰の協力、OS設定変更の実施タイミングの調整が必要。以下を未検証のまま残す。

1. USB-A動作中の切断・再接続と、切断を伴わないOS既定出力変更による停止は下記追試で確認済み。未検証のレート変更とRelease条件は以下に残す。
2. 44.1 kHzでの同じ開始停止確認と、動作中のレート変更での停止。
3. 通知後の再開始に旧通知が干渉しないことの追加実機確認。実スリープ・復帰後の停止維持は下記追試で確認済み。
4. Release実機プロファイルによる確保・解放・ロック待ち・callback終了と資源破棄順序の確認。

macOS 14.2での実行、停止100 msの供給境界計測、60分負荷試験、知覚評価も未検証。自動テスト・無音の通常開始停止・通知モックを、未実施の機器切断試験の代替にしない。SPECと既存計画の進捗を再照合し、上の残条件を完了扱いにしないことを再監査した。

### 利用者によるUSB切断後の確認

利用者からUSBを抜いたとの連絡を受け、OSの一覧からUSB-Aが消え、既定出力が内蔵へ変わっていることを確認した。Debugホストは開始待ち・計数0・ID未接続だった。古い一覧に残っていたUSB-Aに対して明示開始を試すと「選択した出力機器を利用できません。」となり、計数0・ID未接続を維持した。内蔵への代替開始はなかった。一覧更新でUSB-Aと選択状態が消え、開始ボタンが無効になった。

切断直前のrunningと計数増加を確認していないため、この結果は「切断済み機器の開始拒否」の実機証拠であり、「動作中の切断で停止」の合格証拠にはしない。後者はUSB再接続後、明示開始と計数増加を確認してから再度抜く手順で実施する。

### 動作中のUSB切断による自動停止（追試）

利用者の再接続後、Debugホストは停止・計数0のままだった。一覧更新でUSB-A（2ch・48 kHz）を確認し、明示選択・開始した。確認済み機器IDが再接続後のIDとなり、無音テスト中の計数が1から376へ増加することを確認してから、利用者に抜去を依頼した。

抜去後、停止ボタンや一覧更新を操作する前に「機器・音声構成の変更またはスリープにより停止しました。」、ID未接続、計数1945を確認した。OSの機器一覧からUSB-Aが消え、既定出力は内蔵になっていた。OSの確認を挟んだ2回目の画面観察でも計数1945と停止状態を維持し、別機器への自動再開は観察されなかった。

この条件（macOS 26.6.2・Debug・USB-A・48 kHz・1回）で動作中の切断による自動停止を確認した。複数の変更通知が同時に発生し得るため、個別の通知種別の実配送を切り分けた試験とはしない。停止時間、物理端子の無音、44.1 kHz、Release性能をこの観察から推定しない。次はこの停止状態のまま再接続し、明示開始せず停止が維持されることを確認する。

### 動作中切断試験後の再接続

利用者がUSB-Aを再接続した後、開始・停止・一覧更新の操作をせずにDebugホストを観察した。停止メッセージ、計数1945、確認済みID未接続を維持していた。OSではUSB-A（2ch・48 kHz）が再び列挙され、既定出力にも戻っていた。OSの確認を挟んだ2回目の画面観察でも変化がなく、再接続だけで自動再開しないことを確認した。この1回のUSB・48 kHzの切断／再接続試験は合格。タスク4全体の完了とはしない。

### 動作中のスリープ・復帰

USB-A再接続後の停止維持を確認してから、明示開始で新しい機器IDと計数1→329の増加を確認し、利用者にUSBを接続したままスリープ・復帰を依頼した。復帰の連絡後、開始・停止・一覧更新を操作する前に「機器・音声構成の変更またはスリープにより停止しました。」、計数2309、確認済みID未接続を確認した。OSにはUSB-A（2ch・48 kHz）が存在し、既定出力もUSB-Aだった。OS確認を挟む2回の画面観察で計数2309と停止状態は不変だった。

この条件（macOS 26.6.2・Debug・USB-A・48 kHz・1回）で、利用者が実施したスリープ・復帰後に停止を維持し、自動再開しないことを確認した。個別の通知種別、スリープ開始から停止までの時間、Release性能は未測定。既定出力変更・レート変更・Releaseプロファイル等が残るため、タスク4全体は引き続き未完了。

### 切断を伴わないOS既定出力変更

USB-Aで明示開始し、計数1→423の増加を確認してからOSの出力をHDMI-Aへ変更するよう依頼した。最初はサウンドエフェクトの再生装置だけがHDMI-Aとなっており、通常の既定出力はUSB-Aのままだった。実画面とOS情報の両方で区別し、この時点のrunning継続を通常出力変更の停止不具合とは扱わなかった。

利用者が「出力と入力」の通常出力をHDMI-Aへ変更した後、OS情報でHDMI-Aの`Default Output Device: Yes`とUSB-Aの接続維持を確認した。MonoOtoは操作を加える前から停止通知を表示し、確認済みID未接続、計数12884だった。OS情報の確認を挟む2回目の画面観察でも不変で、HDMI-Aへの自動追従・再開は観察されなかった。この条件（macOS 26.6.2・Debug・USB-A・48 kHz・1回）で通常の既定出力変更による停止を確認した。試験後のOS通常出力と効果音出力はHDMI-Aであり、元のUSB-Aにはまだ戻していない。

### 48→44.1 kHz変更による停止と、再開時の不成立

USB-A・48 kHzで計数1→376を確認してから、利用者がAudio MIDI設定でUSB-Aを44.1 kHzへ変更した。操作を加える前のDebugホストは変更による停止通知、計数15234、ID未接続だった。OS情報でUSB-Aは44.1 kHz、既定出力のHDMI-Aは48 kHzであることを確認し、2回目の画面観察でも停止状態と計数は不変だった。レート変更による停止はこの条件で確認済み。

一覧更新でUSB-Aの44.1 kHzを反映して明示開始すると、計数4で変更通知による停止へ戻った。再度開始しても同様に停止し、44.1 kHzでの継続動作は未合格。

一時コピー`/private/tmp/monooto-task4-probe.MOT2hq/DiagnosticOutput.swift`の制御側だけに通知種別とCoreAudioプロパティ通知の出力を追加した。本番ファイルは変更していない。既存の検証プログラムを最適化コンパイルして実行すると、USB-A・44.1 kHzの準備後に`CONTROL event=configurationChanged`が発生し、開始時に`DeviceOutputError.stale`で終了した。プロパティ通知の診断出力はなく、AVAudioEngineの構成変更通知経由と切り分けた。

Appleの[構成変更通知の説明](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/avaudioengineconfigurationchange)と対象SDKのAVAudioEngine.hを確認した。この通知はI/O形式変更に伴うエンジン停止・未初期化を示すため、単純に無視する修正は行わない。既定機器48 kHzと選択機器44.1 kHzの差によるグラフ準備時の通知という仮説を検証中で、原因確定とはしない。次にOSの通常出力だけをUSB-Aへ戻し、USB-Aの44.1 kHzは維持して同じ開始手順を比較する。タスク4は未完了。

### 異レート機器への初期切替の修正

OSの通常出力をUSB-A・44.1 kHzへ戻すと、旧実装でもUIの計数0→303が増加し、停止後は2578になった。最適化した旧実装のUSB-A・44.1 kHzの5反復も成功した。一方、同じOS条件でHDMI-A・48 kHzを選ぶと旧UIは7コールバックで構成変更停止となった。既定と選択機器のレート差を伴う初期設定で、AVAudioEngineの遅延した構成変更処理が準備・開始と競合していた。

変更した製品ファイルは`DeviceOutput.swift`と`PlayerView.swift`、回帰は`DeviceOutputTests.swift`。

- `prepare`／backend `configure`をasync化した。初期出力形式が対象と異なる場合、ハードウェア監視と構成通知監視を先に登録し、CurrentDevice設定に伴う最初の構成通知を、ソース未接続・engine未開始のまま待つ。通知後に機器・形式を再検証してから接続・prepareへ進む。
- 待機は2秒で打ち切り、停止・dispose・Taskキャンセルでも解除する。期待する最初の通知だけを消費し、追加通知・実機変更・動作中の構成通知は停止させる。OSの既定出力や機器レートをアプリから変更しない。
- await後の成功・失敗双方に世代確認を加え、旧準備が新しい世代を停止・復活させないようにした。UIは準備中の重複開始を抑止し、停止で準備Taskを取り消す。旧Taskの成功・失敗・後片付けも現在のUI世代と照合する。
- 通知が必ず来るという全環境の保証は置かない。通知が来なければタイムアウトとして停止する。

回帰テストは修正前に旧prepareの完了が新世代を壊す6箇所のassert失敗を確認してから修正した。通知待機・期限切れ・キャンセル・重複通知・準備中のハードウェアイベント・待機後の形式不一致・旧成功／失敗を追加した。主担当は実装の待機寿命・世代の確認とUIのキャンセル経路を再監査した。

| 今回の検証 | 結果 |
| --- | --- |
| SwiftPM（担当エージェント実行） | 70 tests、0 failures |
| Xcode共有scheme test（主担当実行） | 70 tests、0 failures、終了0 |
| Xcode Release build（主担当実行） | BUILD SUCCEEDED、終了0 |
| 最適化した修正版、既定USB44.1→選択HDMI48 | 5回とも開始・停止・停止後1秒の計数不変を確認、終了0 |
| 最適化した修正版、既定USB44.1→選択USB44.1 | 同じ5反復成功、終了0 |
| 修正版Releaseの実画面、既定USB44.1→選択HDMI48 | 開始後の計数1→330を確認。旧実装で再現した直後停止は起きなかった |

実行ログは`/private/tmp/monooto-task4-async-xcode.log`、`/private/tmp/monooto-task4-async-release.log`、`/private/tmp/monooto-task4-probe.MOT2hq/async-hdmi.log`、`async-usb.log`。一時プログラム`AsyncProbe.swift`を本番`DeviceOutput.swift`と最適化コンパイルして使用した。HDMIログの先頭`USB-A`は一時プログラムの固定表示ラベルであり、実行引数`LCD-GC221HX`で選択した対象はHDMI-A・48 kHzである。

署名済みの旧ReleaseアプリをPIDで明示すると、Allocations／Time Profiler各10秒の記録取得に成功した（`/private/tmp/monooto-task4-release-signed-allocations.trace`、`/private/tmp/monooto-task4-release-signed-time.trace`）。Allocationsの全割り当てを表示できたが、renderのスタック・解放スレッドまでの分析は未完了。これは修正前の記録であり、新しい準備・破棄境界の合格証拠にしない。

**残作業:** 修正版Releaseでの切断・復帰・レート変更・スリープ等の再確認、異レート切替の逆方向（既定HDMI48→選択USB44.1）の修正後確認、リアルタイムのスタック・破棄順序の検証。前節までの実機停止試験は旧実装の結果であり、今回移動した監視登録と非同期準備の検証を代替しない。タスク4は引き続き未完了、タスク5・6は未着手。

### 修正版Release・USB44.1 kHzの動作中切断

修正版Releaseを明示的に起動し、USB-A・44.1 kHzで確認済み機器IDと計数0→474の増加を確認してから、利用者に抜去を依頼した。抜去の連絡後、停止・開始・一覧更新の操作を加える前から変更による停止メッセージ、計数6842、確認済みID未接続だった。OSの一覧からUSB-Aが消え、通常・システム既定出力はHDMI-A・48 kHzとなっていた。OS情報の確認を挟む2回の画面観察で計数6842と停止状態は不変で、HDMI-Aへの自動再開は観察されなかった。

修正版のこの条件・1回で動作中切断による自動停止を確認した。停止時間と物理端子の無音は未測定。次は開始せず再接続し、停止維持を確認する。タスク4全体は未完了。

### 修正版Release・USB44.1 kHz再接続後の停止維持

利用者の再接続後、開始・停止・一覧更新を操作する前に、変更による停止メッセージ、計数6842、ID未接続を確認した。OSではUSB-A・44.1 kHzが再び列挙され、通常・システム既定出力もUSB-Aに戻っていた。OS確認を挟む2回の画面観察で計数と停止状態は不変だった。修正版Releaseでも、この再接続だけでは自動再開しないことを確認した。

その後、次の通常出力変更試験に向け一覧を更新してUSB-Aを明示開始し、新しい確認済み機器IDと計数0→604の増加を確認した。USBのレートは44.1 kHzを維持し、利用者に通常出力だけをHDMI-Aへ変更するよう依頼する。タスク4全体は未完了。

### 修正版Release・通常出力変更と異レート切替の逆方向

利用者が通常出力をHDMI-Aへ変更した後、アプリを操作する前に変更による停止メッセージ、計数5226、ID未接続を確認した。OSでは通常出力がHDMI-A・48 kHz、効果音用のシステム出力はUSB-A・44.1 kHzだった。USB-Aは接続されたままで、OS確認を挟む2回の画面観察でも停止と計数は不変だった。この条件で修正版Releaseの通常出力変更による停止を確認した。

同じOS条件で、修正版の最適化済み一時プログラム`/private/tmp/monooto-task4-probe.MOT2hq/async-probe`を引数なし（USB-A選択）で実行した。5回とも準備中の計数0、開始後2秒のrunning・対象ID・計数増加、停止後1秒の計数不変とID解除を確認し、終了0だった。各回の計数は174／173／173／172／174、stop呼出し時間は約19.1／23.9／87.6／19.8／23.7 ms。これは停止要求から物理出力までの遅延測定ではない。

続いて修正版ReleaseのUIでもUSB-Aを明示開始し、対象IDと計数1→804の増加を確認した。OSの通常出力はHDMI-A・48 kHzのままで、旧実装で失敗した「既定HDMI48→選択USB44.1」の開始直後停止は今回再現しなかった。次のレート変更試験に向けUSB-A・44.1 kHzで動作を維持している。修正版でのレート変更・スリープ、およびリアルタイムのスタック・破棄順序の検証が残り、タスク4全体は未完了。

### 修正版Release・44.1→48 kHz変更による停止

利用者がAudio MIDI設定でUSB-Aを48 kHzへ変更した後、アプリを操作する前から変更による停止メッセージ、計数6256、ID未接続だった。OSではUSB-Aの48 kHzと、通常出力がHDMI-A・48 kHzのままであることを確認した。OS確認を挟む2回の画面観察で停止と計数は不変で、自動再開は観察されなかった。この条件・1回で修正版Releaseのレート変更による停止を確認した。停止遅延と物理端子の無音は未測定。

停止確認後に一覧を更新し、USB-A・48 kHzを明示開始した。確認済み機器IDと計数0→704の増加を確認し、次のスリープ・復帰試験に向け動作を維持している。タスク4全体は未完了。

### 修正版Release・スリープ復帰後の停止維持

利用者がUSBを接続したままスリープ・復帰を実施した後、開始・停止・一覧更新を操作する前に、変更またはスリープによる停止メッセージ、計数4083、確認済みID未接続を確認した。OSではUSB-A・48 kHzが接続され、通常出力はHDMI-A・48 kHz、システム出力はUSB-Aのままだった。OS確認を挟む2回の画面観察で計数4083と停止状態は不変で、自動再開は観察されなかった。修正版Releaseのこの条件・1回でスリープ復帰後の停止維持を確認した。個別通知の配送と停止遅延は切り分けていない。

これで修正版のUSB切断、再接続、通常出力変更、レート変更、スリープ復帰の各停止試験と、異レート初期切替の両方向を確認した。アプリは停止状態を維持している。リアルタイムのスタック・破棄順序の検証は未完了であり、これら実機操作の成功だけではタスク4全体を完了としない。

## 2026-09-09 — タスク4：48 kHzのリアルタイム処理と破棄順序

既存実装計画へ追補手順を記載してから実行した。**USB-A・48 kHzの無音経路について、実renderスタック、確保経路、停止末尾の待機、状態の解放スレッドを確認した。製品コードの追加修正は行っていない。44.1 kHzでの同じプロファイルは未実施であり、タスク4全体は未完了、タスク5・6は未着手。**

環境はmacOS 26.6.2 (25G83)、Apple Silicon、Swift 6.3.3、Instruments 16.0 (17F113)。Git HEADは`1cacd28`、branchは`task4-verification`。開始時から存在した7ファイルの変更を維持した。実行対象`DeviceOutput.swift`のSHA256は`4481ac7a7100844ed13fd496b69c203ab107a621591041623c79d3d6c619b716`で、終了時も同一。最適化条件は`-swift-version 6 -target arm64-apple-macosx14.2 -O -whole-module-optimization -g`。14.2はdeployment targetであり、14.2での実機実行を意味しない。

### 実装した検証手段

- `Task4RealtimeProbe.swift`は本番`DeviceOutput.swift`と一緒にコンパイルする独立した無音プローブ。完全一致する機器名を明示指定し、8反復でprepare中の計数0、開始後の機器IDと計数、stop／dispose後1秒の計数不変、次のprepareでの診断初期化を確認する。2反復ではrunning中に所有者を解放する。OSの既定出力・レート・音量は変更しない。
- `instrument-task4.py`は本番ファイルを一時領域へ複製し、render入口／出口の固定サイズatomic計数と制御側の寿命マーカーだけを挿入する。repo外の新規ディレクトリと排他的ファイル作成を要求し、既存symlink経由でも製品を上書きしない。既存出力を拒否する確認と製品ハッシュ不変を実行した。
- 診断ログはrender内で出さず、stop復帰、detach後、engine参照解放後、state deinitで出す。すべて`main=true`、`active=0`、`entered=exited`をassertする。deinitではdetach後であることもassertし、解放スタックを記録する。診断コードは製品ターゲットに追加していない。

### 静的監査の訂正と実機スタック

以前の「最適化SILでretain/releaseなし」という結果はclosure本体に限定される。今回ObjC→SwiftのrenderBlock thunkまで追跡すると、毎回`swift_retain → closure → swift_release`がある。**呼び出し境界全体にARCがないとは言えない。** backendとSourceNodeの保持により通常callback末尾のreleaseを最後の参照にしない構造を確認し、最終解放は下記の実測で別に確認した。

`renderDeviceSilence`のCollection反復にはiterator metadata・witness・copy/destroy呼び出しが残る。当初cold metadataの確保を疑ったが、prepareと開始前validateの`channelCount`が同じmetadata/conformance cacheを制御側で先に使用する。ローカル実OSのCoreAudio overlayを逆アセンブルすると、pointer wrapperのinit、metadata accessor、Collectionの正常範囲の読出し・インデックス更新はload/store・算術・比較であり、読出しcoroutineのresumeは`ret`だった。今回のOSAtomic実装も`ldaddal`／`ldsetal`等で、外部確保・待機関数呼び出しはなかった。別OSへの一般化はしない。

Time Profilerでは`com.apple.audio.IOThread.client`上の`SilenceRenderState.render → thunk → AVAudioSourceNode pullInputBlockFromRenderBlock → … → HALC_ProxyIOContext::IOWorkLoop`を9サンプル取得した。leafには`memset`、Collection witness、stack probe等があり、この9サンプル内に確保・解放・ログ・待機のleafはなかった。サンプリングの不在だけで全callbackの無待機を保証しない。SourceNode destructorも通常disposeとdeinit fallbackの2サンプルでmain threadに観測された。

### 確保・時間・停止末尾の観測

| 検証 | 今回の結果 |
| --- | --- |
| 本番ソースのAllocations、初回準備前から8反復 | 終了0、PROBE PASS。Instrumentsで解放済みも含む`All Allocations`を指定して解析 |
| `renderDeviceSilence`／`SilenceRenderState.render`を含む確保コールツリー | 一致なし。SourceNodeの`pullInputBlockFromRenderBlock`を含む8件・384 bytesはmainのconfigure内`_Block_copy`で、callback内の確保ではなかった |
| CoreAudioのI/Oループ配下 | 554件の確保を観測。主な枝はSmart Routingのplay state送信・OSログ・workgroup等。アプリのrenderと区別し、音声スレッド全体の確保ゼロとは扱わない |
| 本番ソースのTime Profiler、8反復 | 終了0、PROBE PASS。renderスタックとmainのSourceNode破棄を取得 |
| Audio System Trace、保持窓60秒・実記録約32.297秒 | 8スレッドの開始／停止16イベント、IOProc 1,520区間、client cycle 1,528区間はすべて`Normal`。異常・期限超過分類は観測なし |
| 最後の停止区間を除くIOProc 1,512区間 | 最大115.500 µs、99 percentile 62.583 µs。同一スレッドの開始間隔は約10.5495〜10.7749 ms。区間と重なるBlocked状態はなし（割込み／Runnableは別に観測） |
| 停止末尾8区間 | 最大1.910042 ms。すべてでBlockedを観測し、合計約5.702 ms。待機スタックはCoreAudio Smart Routingの同期XPC返信待ち。初回停止にはObjC lookupの`_os_unfair_lock_lock_slow → __ulock_wait2`約6 µsも観測 |

停止末尾のsyscallスタックは`IOWorkLoop → _SetPlayStateForSmartRouting → setPlayState → sendPlayStateToServer → 同期XPC`で、アプリのSourceNode renderを含まない。停止遷移のOS処理に待機があるという実測を残す。IOProcというトレース上の区間名だけで、それをアプリrender本体の実行時間と解釈しない。今回の数値は無音ホストの短時間観測であり、ハードリアルタイム保証、物理出力停止時間、音楽DSPの性能、60分負荷試験を代替しない。

### 破棄順序の観測

診断用最適化ビルドは8反復、8状態生成／8状態deinit、計1,507回のrender本体入口／出口一致、終了0だった。全stop復帰・detach後・engine参照解放後・state deinitでmain thread、active 0を確認した。明示停止ではstateを保持したまま次prepareの診断初期化で解放し、running中の所有者解放2回では非同期MainActor fallbackがdisposeした後、backendの解放からstate deinitへ進んだ。停止後に旧計数が増えた例、stateの音声スレッド上の解放、stateの生成数と解放数の不一致はなかった。

**計測の限界:** active減算はSwift `render`のdefer内であり、メソッドepilogueとthunkのARC releaseより前。active 0はrender本体退出の観測であり、thunkの最後の命令の終了時刻を直接測ったものではない。一方、stateの最終deinitがmainで起きたことは別の直接観測である。診断追加はスケジューリングを変え得るため、そのビルドの時間は上の性能値に含めていない。製品プローブの`ownerReleased`だけではbackend破棄の合格判定をせず、この8生成／8解放のログと照合した。

### 再実行と証拠

新しい一時ディレクトリを使う。以下の機器名は接続中の対象を明示指定する（ログでは匿名のUSB-Aとする）。プローブは無音だが、既存アプリの試験と同時に実行しない。

```sh
TASK4_OUT=$(mktemp -d /private/tmp/monooto-task4-rt.XXXXXX)
xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.2 \
  -O -whole-module-optimization -g \
  Sources/MonoOtoAudio/DeviceOutput.swift docs/verification/Task4RealtimeProbe.swift \
  -o "$TASK4_OUT/task4-probe"
# ローカル計測専用の署名。アプリの署名設定や権限は変更しない。
cat > "$TASK4_OUT/entitlements.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
codesign --force --sign - --entitlements "$TASK4_OUT/entitlements.plist" "$TASK4_OUT/task4-probe"
xcrun xctrace record --template Allocations --time-limit 35s \
  --output "$TASK4_OUT/allocations.trace" --target-stdout "$TASK4_OUT/allocations.log" \
  --launch -- "$TASK4_OUT/task4-probe" 'Hi-Res Audio' 8 2
xcrun xctrace record --template 'Time Profiler' --time-limit 35s \
  --output "$TASK4_OUT/time.trace" --target-stdout "$TASK4_OUT/time.log" \
  --launch -- "$TASK4_OUT/task4-probe" 'Hi-Res Audio' 8 2
xcrun xctrace record --template 'Audio System Trace' --window 60s --time-limit 35s \
  --output "$TASK4_OUT/audio.trace" --target-stdout "$TASK4_OUT/audio.log" \
  --launch -- "$TASK4_OUT/task4-probe" 'Hi-Res Audio' 8 2
python3 docs/verification/instrument-task4.py "$TASK4_OUT/lifetime"
xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.2 \
  -O -whole-module-optimization -g \
  "$TASK4_OUT/lifetime/DeviceOutput.swift" docs/verification/Task4RealtimeProbe.swift \
  -o "$TASK4_OUT/lifetime-probe"
"$TASK4_OUT/lifetime-probe" 'Hi-Res Audio' 8 2 > "$TASK4_OUT/lifetime.log" 2>&1
```

InstrumentsのAllocationsで`All Allocations`、`Call Trees`を選び、`Involves Symbol`でrender本体とSourceNode callbackの両方を確認する。既定の`Created & Persistent`は解放済みの確保を除外するため、この判定には使わない。`xctrace export --toc`で実際のschemaを確認し、`audio-hal-client-io-cycle-ioproc`、`audio-hal-client-io-cycle`、`audio-hal-client-poi`、`thread-state`、`syscall`をexportして同一thread・重なる時刻で照合する。XMLの`ref`は同じXML内の`id`へ解決する。Allocationsのthread-idとkernel tidは形式が異なるため、その数値を直接joinしない。

今回のログ／traceは`/private/tmp/monooto-task4-rt/`内の`signed-allocations.trace`、`time.trace`、`audio-full.trace`、対応する`*-probe.log`、`lifetime.log`、`full-*.xml`、`render-stacks.txt`、`syscall-overlap.txt`。SIL/IRは`/private/tmp/monooto-render-audit.sil`／`.ll`、外部実装は`/private/tmp/monooto-overlay-audit.log`の名前解決した部分と`monooto-overlay-symbols.log`。前者の固定アドレス指定部分はASLR不一致であり根拠に使っていない。一時領域の証拠は将来削除され得る。

失敗・再試行も区別する。初回の署名前プローブはxctrace attach失敗・終了2で無効。ローカル計測用署名後は記録できた。最初のAudio System Traceは既定の末尾10秒だけだったため全体の証拠に使わず、60秒窓で取り直した。trace保存完了前のexportは一度`Document Missing Template Error`で失敗し、保存完了後のexportを解析した。

最終ソースで`swift test`は70 tests／0 failures、Xcode共有scheme `test`も70 tests／0 failures／終了0、Release `build`は終了0。ログは同ディレクトリの`swift-test.log`、`xcode-test.log`、`release-build.log`。左右交換・逆相・過大入力・NaN/Inf等は既存DSP／出力ガードの自動回帰であり、今回の無音実機プローブで音楽の有効性を評価したものではない。

次の一手はUSB-Aを44.1 kHzにした同じ計測。今回終了時の通常既定出力はHDMI-A・48 kHz、USB-Aも48 kHzであり、OS設定は変更していない。

### 44.1 kHz追試とタスク4の完了判定

続いて利用者がAudio MIDI設定でUSB-Aを44.1 kHzへ変更した。同じハッシュの本番ソース・同じ最適化済みプローブを使用し、各記録の先頭に`rate=44100.0`を確認してから解析した。通常既定出力はHDMI-A・48 kHzのままで、異レートの初期構成変更待機も通る条件である。

| 検証 | 44.1 kHzの結果 |
| --- | --- |
| 初回準備前からのAllocations、8反復 | 終了0、PROBE PASS。`All Allocations`でrender本体の確保は一致なし。SourceNode blockを含む8件・384 bytesは48 kHzと同じmainのprepare中の`_Block_copy` |
| Time Profiler、8反復 | 終了0、PROBE PASS。実render 6サンプルはすべてaudio IOThread。別にSourceNode callback内`swift_retain`を1サンプル観測し、ARCの存在を実測でも確認 |
| 制御側破棄のTime Profiler | backend dispose 8サンプルすべてmain、そのうちengine dealloc／IOUnit destructor 6サンプル。SourceNode destructorそのものは未捕捉。状態の最終解放は次行の直接診断で判定 |
| 寿命診断、8反復 | 終了0、8状態生成／8状態deinit、render本体計1,379回の入口／出口一致。全stop復帰・detach後・engine参照解放後・state deinitでmain、active 0。running中の所有者解放2回も含む |
| Audio System Trace（60秒保持窓）、8反復 | IOProc 1,389区間、client cycle 1,397区間はすべて`Normal`、開始／停止16イベントも`Normal`。異常・期限超過分類は観測なし |
| 停止末尾を除くIOProc 1,381区間 | 最大143.625 µs、99 percentile 68.750 µs。同一スレッドの開始間隔約11.518875〜11.723542 ms。重なるBlocked状態はなし |
| 停止末尾8区間 | 最大2.072542 ms。Blocked合計約5.383 ms。同期XPC・ObjC lookup等の待機はSmart Routingの停止処理で、重なるsyscallのstackにアプリのrenderはなかった |

44.1 kHzのtraceとログは同じ`/private/tmp/monooto-task4-rt/`の`441-allocations.trace`、`441-time.trace`、`441-audio.trace`、`441-*-probe.log`、`441-lifetime.log`、`441-*.xml`、`441-syscall-overlap.txt`。Time Profilerの全ref解決集計は`/private/tmp/monooto-441-time-audit.log`。主担当がログ、XMLの区間・スレッド・待機スタック、製品ハッシュを確認し、独立担当がrender／ARCと検証コードの限界を再監査した。

**判定:** 修正版で既に記録した機器固定、切断／再接続、通常出力変更、レート変更、スリープ復帰、異レート切替両方向と、今回の44.1／48 kHzのrender・寿命検証を合わせ、**現行macOS／arm64／USB-Aでのタスク4の無音ホスト検証を完了**とする。製品コードの追加修正は不要だった。16状態の制御側最終解放と計2,886回のrender本体入口／出口一致を確認したが、thunkの全命令の終了時刻を直接測ったとはしない。OSの停止処理には確保・ログ・同期待ちがあるため、音声スレッド全体の無待機保証へ拡張しない。

macOS 14.2実行、別機器・別OS、60分負荷、音楽DSP／有界キューの枯渇・上限、物理出力の停止遅延と知覚評価は未検証。これら後続範囲を含む段階AのT8全体の完了ではない。次の一手はタスク5の有界キュー実装であり、今回タスク5・6は開始していない。全プローブは終了済み。終了時はUSB-A・44.1 kHz、通常既定出力HDMI-A・48 kHzを維持し、こちらからOS設定を戻していない。

## 2026-09-09 — Claude指摘の検証とキャンセル修正

今回変更したのは`DeviceOutput.swift`、`PlayerView.swift`、`DeviceOutputTests.swift`と本記録。既存の作業ツリー変更を保持した。タスク5・6には進んでいない。

### 修正と回帰テスト

- `prepare`はキャンセル確認より先に旧出力を停止・破棄する。既にキャンセル済みのTaskで準備済み／動作中の出力に再準備を要求する`testAlreadyCancelledPreparationStopsPreviousOutput`は、修正前に7 assertionsで失敗し、修正後に成功した。キャンセル時に新しいbackend configureを呼ばないことも確認した。
- UIはTask開始前にもticketを照合する。古いキュー済みTaskは新世代へ触れず、現在のticketのキャンセルはcatchから`abortStart`へ進む。await後・catch・deferの各ticket照合も保持した。このUI分岐は静的監査とホストのコンパイル確認であり、直接のUI操作テストではない。
- 通知待機は、タイムアウトでcontinuationが再開されてからTaskがキャンセルされた場合にも`CancellationError`を優先する。`testConfigurationWaitCancellationWinsQueuedTimeout`は同じMainActor区間で`timeOut()`→`task.cancel()`を行い、修正前は`configurationTimeout`で失敗、修正後は成功した。時間経過に依存する競合テストではない。キャンセル通知のMainActorへの引き渡し自体は維持している。
- `testConfigurationWaitSuspendsUntilNotification`は`isWaiting`でcontinuationの保留を直接確認する。実行時間0.000秒だけでは旧テストの空振りを証明できないが、検証条件を明確にした。
- `expectPreparationFailure`と非同期失敗テストはエラー型・caseを照合する。`.unavailable`を期待する箇所で`CancellationError`を合格にしない。

### 変更しなかった指摘と根拠

- 初期構成通知は1件のみ消費し、追加通知とタイムアウトは引き続き停止する。本記録の「複数の変更通知」はUSB抜去時の複数種別通知を指し、初期CurrentDevice切替で複数のAVAudioEngine通知が必要だった記録ではない。snapshot一致は遅延したengine停止・未初期化処理の完了証拠にならないため、無条件のタイムアウト後続行は採用しない。多通知を必要とする未検証ドライバの互換性は未解決の仮説として残る。
- 機器ID差だけで待機を有効化しない。形式変更通知が来ない同形式切替を逆にタイムアウトさせ得る。今回、通常既定HDMI-A 48 kHz→明示USB-A 48 kHzの開始・停止を再確認した。
- Core Audioプロパティ監視の事前登録を維持する。CurrentDevice設定はOS既定出力・機器レートを書き換えない。登録を遅らせて実変更を取り逃す窓を作る修正は行わない。自己通知で停止した実機再現はない。
- throw時は`prepare.catch → fail → stop → dispose`で待機・observerを除去する。成功時のobserverによる使用済みゲートの保持は追加通知判定のためで、disposeで解除される。単純なdeferへの移動は旧configureが新世代の状態を消す危険があり、リーク修正として採用しない。
- レートの厳密比較はゲートだけでなく対応判定・prepare・validateに共通する。ゲートだけを許容差化しても近傍レート対応にはならない。集約／仮想機器の近傍レートは今回の対応範囲へ追加しない。
- 重複disposeと世代管理の統合は任意の設計変更として見送った。backendの部分構築後の破棄と、UI／出力／再生状態それぞれの旧処理排除を保持する。

### 今回の実行結果と制約

- `swift test`: 72 tests、0 failures。
- `xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -destination 'platform=macOS,arch=arm64' test`: 72 tests、0 failures、TEST SUCCEEDED。
- 同条件の`-configuration Release build`: BUILD SUCCEEDED。
- 現行ソースを最適化コンパイルした`Task4RealtimeProbe.swift`をUSB-Aで4周期・各1秒動作。機器ID一致、準備中callback 0、動作中callback増加、明示stop/dispose後1秒の計数不変、所有者解放を確認してPROBE PASS。callback数94/95/94、停止呼出し12.4/21.7/17.5 ms。今回の実レートは48 kHzで、通常既定出力HDMI-Aも48 kHzだった。OS設定は変更していない。所有者解放時のbackend最終解放スレッドはこの非計装プローブ単独では判定しない。
- ログ: `/private/tmp/monooto-review-swift-test.log`、`monooto-review-xcode-test.log`、`monooto-review-release.log`、`monooto-review-probe.log`（後3件も同ディレクトリ）。
- render本体・通知登録順・初期通知の消費方針は今回変更していない。44.1 kHz、切断・スリープ等の物理操作、Allocations／Time Profilerの再計測は今回は未実施。前節の実績は以前の実装時の記録として保持し、今回の実行結果と混同しない。

## 2026-09-10 — Grok指摘2：所有者解放後の停止漏れ

**メインスレッド上の所有者解放時に破棄を別Taskへ先送りする空白と、別スレッド解放後の機器イベントをweak owner不在で捨てる経路を再現し、修正した。** 他のGrok改善提案は今回の対象外。変更は`DeviceOutput.swift`、`DeviceOutputTests.swift`、`Task4RealtimeProbe.swift`と本記録のみ。

### 再現と修正

- 事実：旧`deinit`は必ず`Task { @MainActor in backend.dispose() }`へ破棄を送る。イベントclosureは`weak self == nil`で何もせず戻る。仮説：所有者解放後・破棄Task実行前の機器イベントではbackendが停止しない。再現しなければ修正方針を再検討する条件で検証した。
- **RED:** `testOwnerReleaseStopsBeforeReturningToMainActor`は、準備・開始後にMainActorをyieldせず最後の参照を解放し、保持していた機器／既定出力／構成変更の3イベントを配送した。旧コードで12 assertions失敗。fakeの動作状態がtrue、dispose未実行、handler残存を確認した。
- **RED:** `testOffActorOwnerReleaseStillHandlesFaultBeforeDeferredDisposal`は、MainActorをテスト内で保持したまま独立workerに最後の参照を解放させる。最大2秒の同期ハンドオフで解放完了を確認し、破棄Taskより先に5イベント（上記3種、sleep、renderFault）を配送した。旧コードで15 assertions失敗。sleepによる確率的な競合再現ではない。
- `deinit`はmacOSのメインスレッドであれば`MainActor.assumeIsolated`内で同期`dispose()`し、それ以外では従来のMainActor Taskへ送る。現在のSDKのMainActor deinit back-deployment処理も旧OSで`pthread_main_np()`を用いて同様に分岐することを確認した。Swiftの新しい`isolated deinit`構文を必須にせず、既存のSwift tools 6.0宣言とmacOS 14.2ターゲットを維持する。旧Swiftコンパイラ／macOS 14.2実機での実行検証はしていない。
- イベントclosureはbackendも弱参照し、owner消滅後は専有backendの`dispose()`を呼ぶ。所有者が存命の場合は既存のgeneration照合を維持する。弱参照なのでbackend→handler→backendの循環を作らない。テスト注入backendもowner間で共有しない契約をprotocolに明記した。
- 既存deinitテストをyield不要の同期破棄確認へ変更し、別スレッド解放後にイベントがなくても破棄Taskが完了するテストを追加した。遅延通知・古い準備完了が新世代を停止しない既存回帰も成功した。

### 今回の実行結果

- `swift test`: **75 tests、0 failures**。
- `xcodebuild -project MonoOto.xcodeproj -scheme MonoOto -destination 'platform=macOS,arch=arm64' test`: **75 tests、0 failures、TEST SUCCEEDED**。
- 同条件の`-configuration Release build`: **BUILD SUCCEEDED**。
- 現ソースから既存計装スクリプトで一時コピーを作成し、`-O -whole-module-optimization`、arm64／macOS 14.2 deployment targetでコンパイル。USB-Aの実レート48 kHz、4周期・各1秒で`PROBE PASS`。
- 所有者解放周期では、`dispose-stop-returned → detach-returned → engine-released → state-deinit → owner-release-returned`の順を確認した。`state-deinit`のスタックに`DeviceOutput`のdeinitがあり、別Taskの実行を待たずに完了した。4状態すべての最終解放は`main=true active=0`、render入口／出口は計377回一致。通常stop/dispose後は1秒間callback不増加。計装は寿命検証用であり性能の合格値にはしない。
- 製品ソースSHA256：`ab0735cbc027c07a1c17d4e8a6689d1f88fc33f8b09a1726600dfb6257c5de24`。
- 証拠：`/private/tmp/monooto-deinit-red.log`、`monooto-offactor-red.log`、`monooto-deinit-swift-test.log`、`monooto-deinit-xcode-test.log`、`monooto-deinit-release.log`、`monooto-deinit-lifetime/run.log`（すべて`/private/tmp/`配下）。

### 再監査と制約

graphifyの既存グラフで`DeviceOutput`とbackend・テストの関係を参照し、現コードで再照合した。グラフはこの修正前のスナップショットであり、行番号や呼出し先の完全性を今回の証拠にしない。独立した静的監査でも、同期破棄の実行場所、循環参照、旧世代への影響を再確認した。

**別スレッドからの最後の解放では、通知処理または破棄TaskがMainActorで実行されるまで遅延が残る。** MainActorが実行不能な間の即時停止・物理経路固定まで保証する修正ではない。明示`stop`／`dispose`を通常の所有者の終了処理とし、Viewの`onDisappear`の明示停止も保持する。今回の実機確認は無音・48 kHzの所有者解放であり、44.1 kHz再追試、同時USB抜去・スリープ、音楽の物理端子出力やAllocations／Time Profilerの再計測は実施していない。
