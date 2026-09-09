# 段階A 検証記録

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
