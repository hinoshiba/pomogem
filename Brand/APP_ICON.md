# つみべん App Icon — Focus Vessel v4

## Brand idea

「集中時間を質量に変える」という体験を、落下中の通常粒と、底で育つまとまり粒の二つだけで表現する。

- 深いネイビーのオーロラは、アプリのホーム／シェア画面と共通。
- コーラルの一粒は、毎日の標準的な集中。レア報酬を主役にしない。
- 多色のまとまり粒は、小さな努力を失わず長期に集約する仕組み。
- 縦長で開いた瓶は、積み続けられる余白と物理的な落下を示す。
- 文字、数字、粒子状の装飾、床反射、画像内の角丸は使わない。

## Production files

- Source render: `AppIcon-FocusVessel-v4-source.png`
- Shipping iOS asset: `../Tsumiben/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-FocusVessel-v4.png`
- Website icon: `../http_dists/public/app-icon-focus-v4.png`
- Website touch icon: `../http_dists/public/apple-touch-icon.png`

The shipping icon is a flattened 1024×1024 sRGB image for compatibility with the app's iOS 17 minimum deployment target. The composition is intentionally separable into background, vessel, falling pebble, and cluster layers for a future Icon Composer source.

## Small-size acceptance

- At 64 px: the open vessel, falling coral pebble, and fused cluster must all remain distinct.
- At 29 px: the icon must still read as “one drop entering a vessel,” not as a collection of unrelated jewels.
- The system supplies the rounded mask; never bake rounded corners into the source.
