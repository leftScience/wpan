#!/bin/sh
# 在 fork 仓库里直接构建 Android 服务端 APK（arm64 + x86_64 双 ABI）。
#
# 用法（在 android/ 目录下）：
#   sh build-from-repo.sh                 # 编二进制 + 出 APK，versionCode 自增
#   SKIP_APK=1 sh build-from-repo.sh      # 只编二进制（想先放到 Termux 里试）
#   APK_VERSION_NAME=1.3.0 sh build-from-repo.sh
#
# 依赖：go 1.25+、JDK17、Android SDK（build-tools;34.0.0 + platforms;android-34）
# 首次构建会在 android/keystore/wpan.jks 生成自签名密钥；这个文件必须保留，
# 换了签名就只能卸载重装（本地数据库和网盘配置都会丢）。
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
END="$REPO/end"
APK_VERSION_NAME=${APK_VERSION_NAME:-}

[ -f "$END/go.mod" ] || { echo "找不到 $END/go.mod，android/ 要放在仓库根目录下" >&2; exit 1; }
command -v go >/dev/null || { echo "缺 go（需要 1.25+）" >&2; exit 1; }

echo "== 1/5 vendored golang.org/x/sys + HWCAP 补丁"
sh "$HERE/prepare-xsys.sh" "$REPO"

echo "== 2/5 用仓库里的配置刷新 assets"
CONF_SRC="$END/conf/config.release.yaml"
[ -f "$CONF_SRC" ] || CONF_SRC="$END/conf/config.yaml"
cp "$CONF_SRC" "$HERE/assets/conf/config.yaml"
sed -i.bak 's/^  MaxSize: .*/  MaxSize: 2/' "$HERE/assets/conf/config.yaml" 2>/dev/null || \
  sed -i '' 's/^  MaxSize: .*/  MaxSize: 2/' "$HERE/assets/conf/config.yaml"
sed -i.bak 's|^  manifestUrl: .*|  manifestUrl: "" # 手机上关闭服务端自更新|' "$HERE/assets/conf/config.yaml" 2>/dev/null || \
  sed -i '' 's|^  manifestUrl: .*|  manifestUrl: "" # 手机上关闭服务端自更新|' "$HERE/assets/conf/config.yaml"
rm -f "$HERE/assets/conf/config.yaml.bak"
[ -f "$END/sql/init_data.sql" ] && cp "$END/sql/init_data.sql" "$HERE/assets/sql/init_data.sql"
[ -f "$HERE/assets/certs/cacert.pem" ] || echo "   注意：assets/certs/cacert.pem 缺失，HTTPS 会报证书错误" >&2

echo "== 3/5 交叉编译"
COMMIT=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
RV=$(cat "$END/runtime-version.txt" 2>/dev/null || echo "")
LDF="-s -w -X ohome/buildinfo.Commit=$COMMIT -X ohome/buildinfo.Channel=stable"
[ -n "$RV" ] && LDF="$LDF -X ohome/buildinfo.RuntimeVersion=$RV"
mkdir -p "$HERE/build-out"
( cd "$END" && GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -trimpath -ldflags "$LDF -X ohome/buildinfo.Version=android-arm64" -o "$HERE/build-out/server-arm64" . )
( cd "$END" && GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags "$LDF -X ohome/buildinfo.Version=android-amd64" -o "$HERE/build-out/server-amd64" . )
ls -lh "$HERE/build-out/server-arm64" "$HERE/build-out/server-amd64"

if [ "${SKIP_APK:-0}" = "1" ]; then
  echo "== 按 SKIP_APK=1 跳过打包"
  exit 0
fi

echo "== 4/5 打包 APK（versionCode 自增）"
MAN="$HERE/AndroidManifest.xml"
if [ -n "$APK_VERSION_NAME" ]; then
  sed -i.bak "s|android:versionName=\"[^\"]*\"|android:versionName=\"$APK_VERSION_NAME\"|" "$MAN" 2>/dev/null || \
    sed -i '' "s|android:versionName=\"[^\"]*\"|android:versionName=\"$APK_VERSION_NAME\"|" "$MAN"
  rm -f "$MAN.bak"
fi
OLD_CODE=$(sed -n 's/.*android:versionCode="\([0-9]\+\)".*/\1/p' "$MAN")
NEW_CODE=$((OLD_CODE + 1))
sed -i.bak "s|android:versionCode=\"$OLD_CODE\"|android:versionCode=\"$NEW_CODE\"|" "$MAN" 2>/dev/null || \
  sed -i '' "s|android:versionCode=\"$OLD_CODE\"|android:versionCode=\"$NEW_CODE\"|" "$MAN"
rm -f "$MAN.bak"
echo "   versionCode $OLD_CODE -> $NEW_CODE"

SERVER_BIN="$HERE/build-out/server-arm64" SERVER_BIN_X64="$HERE/build-out/server-amd64" sh "$HERE/build-apk.sh"

echo "== 5/5 完成"
APK="$HERE/wpan-server-arm64.apk"
[ -f "$APK" ] || APK="$HERE/wpan-server.apk"
[ -f "$APK" ] && { sha256sum "$APK" 2>/dev/null || shasum -a 256 "$APK"; }
echo "产物在 $HERE，覆盖安装即可（签名不变、数据不丢）"
