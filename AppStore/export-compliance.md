# Export compliance draft

つみべんは独自の暗号algorithm、VPN、messaging encryption、credential storage、暗号libraryを
実装・同梱していません。CloudKit、StoreKit、App Store通信など、Apple OSが提供する標準機能を
利用します。この実装監査に基づき、`ITSAppUsesNonExemptEncryption = NO`を設定します。

これは法的助言ではありません。提出時のApp Store Connect質問と配布国、追加dependency、
network機能を再確認し、必要ならAppleの案内に従ってdocumentationを提出します。

参照: [Determine and upload app encryption documentation](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation)
