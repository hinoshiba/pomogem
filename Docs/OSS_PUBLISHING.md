# 初回OSS公開手順

更新日: 2026-09-02

## 現在の監査結果

公開対象のsource/configから、秘密鍵、API token、`.p12`、`.p8`、provisioning profile、実Team
selectorは見つかっていません。CloudKit、App Group、bundle ID、IAP product IDは公開識別子で、
credentialではありません。

一方、監査時点の作業folderには約4.1GBの`DerivedData*`と`Artifacts/`があり、build logの
absolute path、username、simulator diagnostic、build済み`.app`などを含んでいました。これらは
sourceではないため、repository外の`Tsumiben-local-artifacts-20260902`へ退避し、
`.gitignore`でも除外します。退避folderや親folder全体をzip公開してはいけません。

このfolderは、監査済みの現在treeから`git@github.com:hinoshiba/Tumiben.git`へ公開するために
新規初期化し、既存historyは移植していません。最初のcommit後かつpush前に、到達可能な全blobと
author／committer metadataを再監査します。将来別のhistoryを移植する場合も全blobを別途scanします。

## 初回commit

1. Xcodeでこのprojectを閉じ、`DerivedData*`、`Artifacts/`、すべての`xcuserdata`をrepository外へ
   退避する。`.gitignore`は第二防線であり、公開候補folderへ個人用状態を残さない
2. `./Scripts/check-oss-readiness.sh`を通す
3. `python3 Scripts/validate-site.py`を通す
4. `xcodegen generate`後にprojectが再生成できることを確認し、再作成された`xcuserdata`があれば
   repository外へ退避してreadiness checkを再実行する
5. `git init -b main`を実行
6. `git add .`ではなく、公開対象をallowlistでstageする

公開対象は次のrootに限定します。

```text
.github/  AppStore/  Brand/  Docs/  Scripts/  Shared/
Tsumiben/  TsumibenTests/  TsumibenUITests/  TsumibenWidgets/
http_dists/  project.yml  Tsumiben.xcodeproj/
README.md  LICENSE  LICENSE-fonts.txt  PRIVACY.md
SECURITY.md  CONTRIBUTING.md  CODE_OF_CONDUCT.md
TRADEMARKS.md  ASSET_LICENSES.md  THIRD_PARTY_NOTICES.md  .gitignore
```

7. `git status --short --ignored`で、将来生成された`DerivedData*`、`Artifacts/`、xcuserdataが
   ignoredになることを確認する。現時点の公開候補folderには実体を残さない
8. `git diff --cached --stat`と`git ls-files`を人が全件確認
9. staged contentへsecret scannerを実行
10. 最初のcommit後、remoteへpushする前に`./Scripts/check-oss-readiness.sh`をもう一度実行し、
   tracked fileとfull blob historyのscanを通す

`--release`はApp Store提出用の追加gateです。App Store ID、screenshot、公開済みURL、解消済みの
release blockerまで要求するため、初回OSS公開だけを目的にした未初期化folderでは使いません。

本物のcredentialが一度でもcommitされた場合、単に次commitで消しても無効です。公開前にhistory
から除去し、そのcredentialを失効・rotationします。

## GitHub repository設定

- Private Vulnerability Reportingを有効化
- `main`のforce pushとdeleteを禁止
- PR、iOS CI、OSS readinessをrequired checkにする
- Pages sourceをGitHub Actionsにする
- `main`へのサイト関連ファイルのpushでPages workflowを自動実行し、手動実行も許可する
- `http_dists/CNAME`の`tumiben.hinoshiba.com`をcustom domainとして設定し、DNS検証後にHTTPSを強制する
- `github-pages` environmentを使い、deploy jobだけに`pages:write`と`id-token:write`を許可
- CodeQLのSwift default setupが利用できる場合は有効化
- DependabotのGitHub Actions updateを有効化
- branch protectionをmaintainerにも適用するか明示的に決める

## 公開直前の人手確認

- Support emailとGitHub profileをWebへ公開してよい
- MIT Licenseの権利者表記が正しい
- brand assetをMIT対象外にする方針が意図どおり
- AI支援生成assetのorigin、hash、配布条件が`ASSET_LICENSES.md`にある
- screenshotやissue templateに実際の学習theme、顧客名、案件名がない
- App Store candidateとpublic sourceが同じversion/commit
- Pagesの全URLがHTTPS 200で、redirect・placeholder・Mac対応表記がない
