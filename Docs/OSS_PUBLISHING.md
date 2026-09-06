# 初回OSS公開手順

更新日: 2026-09-06

## 現在の監査結果

公開対象のsource/configから、秘密鍵、API token、`.p12`、`.p8`、provisioning profile、署名identityは
見つかっていません。projectのbuild設定には実Team selectorを置かず、Archive検証helperにだけ期待する
Team IDを固定しています。Team ID、CloudKit container、bundle ID、IAP product IDは署名済みappや
Store listingから確認できる公開識別子で、credentialではありません。

初回公開前のbuild artifact退避とGit初期化の実施履歴は
`Docs/LEGACY_RELEASE_PROVENANCE.md`に保持します。現在の公開対象は既存履歴を保持して
`git@github.com:hinoshiba/PomoGem.git`へ名称変更するrepositoryです。改名のためにGitを再初期化したり、
既存履歴を捨てたりしません。push前に到達可能な全blobとauthor／committer metadataを再監査します。
将来別のhistoryを移植する場合も全blobを別途scanします。

現在のrepositoryはprivateです。ユーザーが最後に改名するため、それまでは既存originと名前を保持して
commit／CI／Pagesを進めます。新しい`hinoshiba/PomoGem` URLを公開Webのsource／issue導線へは載せず、
問い合わせは公式supportメールへ案内します。改名とPublic化を実施し匿名accessを確認した後に、
`AppStore/configuration.yml`の`oss_publication.repository_visibility`とWebのsource linkを更新します。
Pagesの公式repository制限は、改名で変化しないrepository ID `1351233156`で判定し、forkの配信を拒否します。
commit／annotated tagのraw identity emailは、ownerが公開と全履歴への使用を明示指定した
 kai.openclaw01@gmail.com 、従来のGitHub noreply identity、公開済みの`support@hinoshiba.com`を
許可します。今後のcommitは kai.openclaw01@gmail.com を使います。`.mailmap`による表示上の
置換は許可根拠にせず、ほかの個人メールや、このアドレスに似た別アドレスは引き続き拒否します。

2026-09-06にownerの指示で、既存13 commitのraw author／committer emailを指定アドレスへ
統一しました。変更前の全refをrepository外へbundleとして保存し、各commitのtree、親子関係、
名前、日時、messageが保持されることを照合しています。メール変更で無効になる元のGit署名は
書換え後のcommitから取り除き、元の署名付きobjectは非公開のbackupに保存します。
remoteへの反映には、確認済みの旧HEADを指定した`--force-with-lease`を使います。
書換え後の全履歴を含む別cloneで標準OSS検査が成功し、公開メール検査の回帰13件も成功しました。

## 初回公開の参考手順（既存repositoryでは再初期化しない）

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
PomoGem/  PomoGemTests/  PomoGemUITests/  PomoGemWidgets/
http_dists/  project.yml  PomoGem.xcodeproj/
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
- `http_dists/CNAME`の`pomogem.hinoshiba.com`をcustom domainとして設定し、DNS検証後にHTTPSを強制する
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
