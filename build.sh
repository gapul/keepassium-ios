#!/usr/bin/env bash
# KeePassium Pro を net.gapul 名前空間・Intune 除去・unsigned device .ipa にビルドする。
# upstream の pbxproj オブジェクトIDに依存しないよう、Intune は「パッケージURL」から動的に特定して除去する。
#
# 使い方: ./build.sh [<upstream git ref>]
#   ref 省略時は keepassium/KeePassium の最新リリースタグを使う。
# 出力: dist/KeePassiumPro-net.gapul.ipa, dist/icon.png, dist/meta.env(VERSION/BUILD/MINOS)
set -euo pipefail

UPSTREAM="https://github.com/keepassium/KeePassium.git"
NS_APP="net.gapul.keepassium"
NS_AF="net.gapul.keepassium.autofill"
NS_GROUP="group.net.gapul.keepassium"
NS_KEYCHAIN="net.gapul.keepassium.SharedItems"
WORK="$(pwd)/work"
DIST="$(pwd)/dist"
rm -rf "$WORK" "$DIST"; mkdir -p "$WORK" "$DIST"

# --- 1) 対象バージョン決定 ---
REF="${1:-}"
if [ -z "$REF" ]; then
  REF="$(gh api 'repos/keepassium/KeePassium/tags?per_page=100' -q '.[].name' 2>/dev/null | sort -V | tail -1 || true)"
  [ -z "$REF" ] && REF="$(git ls-remote --tags --refs "$UPSTREAM" | awk -F/ '{print $NF}' | sort -V | tail -1)"
fi
echo "==> building KeePassium ref: $REF"

# --- 2) clone (浅く) ---
git clone --depth 1 --branch "$REF" "$UPSTREAM" "$WORK/KeePassium"
cd "$WORK/KeePassium"

PBX="KeePassium.xcodeproj/project.pbxproj"

# --- 3) Intune を pbxproj から動的除去 (URLで特定→依存IDを辿る→ブレース深度で安全に削除) ---
python3 - "$PBX" <<'PY'
import sys,re
f=sys.argv[1]; s=open(f).read(); lines=s.split("\n")
# 3-1) ms-intune-app-sdk-ios の XCRemoteSwiftPackageReference ID を URL から特定
pkgref=set(re.findall(r'([0-9A-F]{24}) /\* XCRemoteSwiftPackageReference "ms-intune[^"]*" \*/', s))
if not pkgref:
    # URL 直接一致でも探す
    for m in re.finditer(r'([0-9A-F]{24}) /\* XCRemoteSwiftPackageReference[^=]*= \{(.*?)\};', s, re.S):
        if 'ms-intune-app-sdk-ios' in m.group(2): pkgref.add(m.group(1))
# 3-2) その package を参照する XCSwiftPackageProductDependency (=IntuneMAMSwift 等) を特定
prod=set()
for m in re.finditer(r'([0-9A-F]{24}) /\* [^*]* \*/ = \{\s*isa = XCSwiftPackageProductDependency;(.*?)\};', s, re.S):
    if any(p in m.group(2) for p in pkgref): prod.add(m.group(1))
# 3-3) その product を productRef に持つ PBXBuildFile を特定
bf=set()
for m in re.finditer(r'([0-9A-F]{24}) /\* [^*]* in Frameworks \*/ = \{isa = PBXBuildFile;([^}]*)\};', s):
    if any(p in m.group(2) for p in prod): bf.add(m.group(1))
purge=pkgref|prod|bf
block_start=pkgref|prod                  # 複数行ブロック定義
out=[]; skipping=False; depth=0
for ln in lines:
    if skipping:
        depth += ln.count("{")-ln.count("}")
        if depth<=0: skipping=False
        continue
    st=ln.strip()
    if any(st.startswith(b+" ") for b in block_start) and st.endswith("= {"):
        skipping=True; depth=1; continue
    # 一行 PBXBuildFile 定義 or リスト参照(末尾カンマ)を除去
    if any(i in ln for i in purge) and (st.endswith(",") or (any(b in ln for b in bf) and st.endswith("};"))):
        continue
    out.append(ln)
open(f,"w").write("\n".join(out))
print(f"intune purge: pkgref={len(pkgref)} prod={len(prod)} bf={len(bf)}")
PY

# Package.resolved から intune を除去
for pr in $(find . -name Package.resolved); do
  python3 - "$pr" <<'PY'
import sys,json
p=sys.argv[1]; d=json.load(open(p))
def strip(x): return [i for i in x if 'intune' not in json.dumps(i).lower()]
if "pins" in d: d["pins"]=strip(d["pins"])
if "object" in d and "pins" in d["object"]: d["object"]["pins"]=strip(d["object"]["pins"])
json.dump(d,open(p,"w"),indent=2)
PY
done

# --- 4) entitlements を最小化+改名 (iCloud/associated-domains 除去, App Group/Keychain/AutoFill/NFC 維持) ---
cat > KeePassium/KeePassium.entitlements <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.developer.authentication-services.autofill-credential-provider</key><true/>
	<key>com.apple.developer.default-data-protection</key><string>NSFileProtectionComplete</string>
	<key>com.apple.security.application-groups</key><array><string>${NS_GROUP}</string></array>
	<key>keychain-access-groups</key><array><string>\$(AppIdentifierPrefix)${NS_KEYCHAIN}</string></array>
	<key>com.apple.developer.nfc.readersession.formats</key><array><string>TAG</string></array>
</dict></plist>
EOF
cat > "KeePassium AutoFill/KeePassium_AutoFill.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>com.apple.developer.authentication-services.autofill-credential-provider</key><true/>
	<key>com.apple.security.application-groups</key><array><string>${NS_GROUP}</string></array>
	<key>keychain-access-groups</key><array><string>\$(AppIdentifierPrefix)${NS_KEYCHAIN}</string></array>
</dict></plist>
EOF

# --- 5) bundle id 改名 (長い方=AutoFill を先に) ---
python3 - "$PBX" <<PY
f="$PBX"; s=open(f).read()
s=s.replace("com.keepassium.ios.pro.KeePassium-AutoFill","${NS_AF}")
s=s.replace("com.keepassium.ios.pro","${NS_APP}")
open(f,"w").write(s)
PY
plutil -convert xml1 -o /dev/null "$PBX"   # 構文チェック(失敗すれば非0で止まる)

# --- 5.5) コード内ハードコード App Group を entitlement と一致させる ---
# AppGroup.swift が group.com.keepassium をハードコードしており、entitlement(net.gapul)と
# 食い違うと FileKeeper.init() が共有コンテナ取得に失敗して起動時クラッシュする。
grep -rl 'group\.com\.keepassium' KeePassiumLib KeePassium "KeePassium AutoFill" --include='*.swift' 2>/dev/null | while read -r f; do
  sed -i '' 's/group\.com\.keepassium/group.net.gapul.keepassium/g' "$f"
done
echo "==> patched hardcoded App Group in source"

# --- 6) 依存解決 + unsigned device ビルド ---
export GIT_TERMINAL_PROMPT=0
xcodebuild -resolvePackageDependencies -workspace KeePassium.xcworkspace -scheme "KeePassium Pro" \
  -derivedDataPath build -scmProvider system
xcodebuild build -workspace KeePassium.xcworkspace -scheme "KeePassium Pro" \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

APP="$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name '*.app' | head -1)"
[ -z "$APP" ] && { echo "ERROR: .app not produced"; exit 1; }

# --- 7) .ipa 化 + アイコン + メタ ---
rm -rf Payload; mkdir Payload; cp -R "$APP" Payload/
zip -qry "$DIST/KeePassiumPro-net.gapul.ipa" Payload
icon="$(find "$APP" -iname 'AppIcon*.png' | xargs -I{} sh -c 'echo "$(stat -f%z "{}") {}"' | sort -rn | head -1 | cut -d" " -f2-)"
[ -n "$icon" ] && cp "$icon" "$DIST/icon.png"
PL="$APP/Info.plist"
{
  echo "VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PL")"
  echo "BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PL")"
  echo "MINOS=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PL")"
  echo "UPSTREAM_REF=$REF"
} > "$DIST/meta.env"
cat "$DIST/meta.env"
echo "==> done: $DIST/KeePassiumPro-net.gapul.ipa ($(du -h "$DIST/KeePassiumPro-net.gapul.ipa" | cut -f1))"
