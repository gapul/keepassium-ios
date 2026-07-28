# keepassium-ios

KeePassium Pro を **premium 全解錠・Intune 除去・`net.gapul` 名前空間**でセルフビルドし、
unsigned device `.ipa` を Release として自動配信するリポジトリ。SideStore で再署名して使う。

- `build.sh` — 上流 `keepassium/KeePassium` をビルド(Intune はパッケージURLで動的除去=upstream更新に強い)
- `.github/workflows/build.yml` — 毎日上流をチェックし、新バージョンだけ再ビルドして Release 作成
- 集約ソース: [gapul/altstore-source](https://github.com/gapul/altstore-source)
