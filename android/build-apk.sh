#!/bin/sh
# 手动构建 wpan 服务端 APK（不依赖 Gradle / AGP，只要 JDK17 + Android SDK build-tools）
# 用法： sh build-apk.sh
set -eu

SDK=${ANDROID_SDK_ROOT:-$HOME/sdk}
BT="$SDK/build-tools/34.0.0"
AJ="$SDK/platforms/android-34/android.jar"
JAVA_HOME=${JAVA_HOME:-$HOME/jdk}
export JAVA_HOME
PATH="$JAVA_HOME/bin:$PATH"

AAPT2="$BT/aapt2"
D8="$BT/d8"
ZIPALIGN="$BT/zipalign"
APKSIGNER="$BT/apksigner"

PROJ=$(cd "$(dirname "$0")" && pwd)
SERVER_BIN=${SERVER_BIN:-$PROJ/build-out/server-arm64}   # arm64-v8a
SERVER_BIN_X64=${SERVER_BIN_X64:-$PROJ/build-out/server-amd64}
BUILD="$PROJ/build"
KS="$PROJ/keystore/wpan.jks"
KS_PASS=wpan123456
KS_ALIAS=wpan

[ -f "$AJ" ] || { echo "缺少 android.jar：$AJ" >&2; exit 1; }
[ -f "$SERVER_BIN" ] || { echo "缺少 arm64 服务端二进制：$SERVER_BIN（用 SERVER_BIN=... 指定）" >&2; exit 1; }
[ -f "$SERVER_BIN_X64" ] || echo "提示：没有 x86_64 二进制（$SERVER_BIN_X64），本次只打 arm64" >&2

rm -rf "$BUILD"
mkdir -p "$BUILD/classes" "$BUILD/dex" "$BUILD/gen" "$BUILD/stage/lib/arm64-v8a"

echo "== 1/7 编译资源"
"$AAPT2" compile --dir "$PROJ/res" -o "$BUILD/res.zip"

echo "== 2/7 链接资源与清单（含 assets）"
"$AAPT2" link -o "$BUILD/base.apk" \
  -I "$AJ" \
  --manifest "$PROJ/AndroidManifest.xml" \
  --java "$BUILD/gen" \
  --min-sdk-version 26 --target-sdk-version 34 \
  -A "$PROJ/assets" \
  "$BUILD/res.zip"

echo "== 3/7 javac"
"$JAVA_HOME/bin/javac" -source 8 -target 8 -bootclasspath "$AJ" -Xlint:-options \
  -d "$BUILD/classes" \
  "$BUILD"/gen/com/wpan/server/R.java \
  "$PROJ"/src/com/wpan/server/*.java

echo "== 4/7 d8 -> dex"
"$D8" --lib "$AJ" --min-api 26 --release \
  --output "$BUILD/dex" \
  "$BUILD"/classes/com/wpan/server/*.class

echo "== 5/7 组装 APK"
cp "$BUILD/base.apk" "$BUILD/unsigned.apk"
cp "$BUILD"/dex/classes.dex "$BUILD/stage/classes.dex"
cp "$SERVER_BIN" "$BUILD/stage/lib/arm64-v8a/libwpan-server.so"
chmod 755 "$BUILD/stage/lib/arm64-v8a/libwpan-server.so"
# x86_64 是给 Intel 设备 / 电脑上的 Android 模拟器用的：这类机器上跑 arm64 只能靠转译，
# Go 运行时会 fatal error（invalid p state / invalid p state wirep），必须原生 x86_64
if [ -f "$SERVER_BIN_X64" ]; then
  mkdir -p "$BUILD/stage/lib/x86_64"
  cp "$SERVER_BIN_X64" "$BUILD/stage/lib/x86_64/libwpan-server.so"
  chmod 755 "$BUILD/stage/lib/x86_64/libwpan-server.so"
fi
# extractNativeLibs=true 时会由系统解压提取，压缩存放可把 APK 从 37MB 降到 13MB
( cd "$BUILD/stage" && zip -q -r -X "$BUILD/unsigned.apk" classes.dex lib )

"$ZIPALIGN" -f -p 4 "$BUILD/unsigned.apk" "$BUILD/aligned.apk"

echo "== 6/7 签名"
if [ ! -f "$KS" ]; then
  mkdir -p "$(dirname "$KS")"
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$KS" -storetype PKCS12 \
    -alias "$KS_ALIAS" -keyalg RSA -keysize 2048 -validity 10950 \
    -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=wpan server, OU=local build, O=wpan, C=CN" >/dev/null 2>&1
  echo "   已生成自签名密钥 $KS（今后升级请用同一个 keystore，否则无法覆盖安装）"
fi
"$APKSIGNER" sign --ks "$KS" --ks-pass "pass:$KS_PASS" --ks-key-alias "$KS_ALIAS" \
  --key-pass "pass:$KS_PASS" --v1-signing-enabled true --v2-signing-enabled true \
  --out "$PROJ/wpan-server-arm64.apk" "$BUILD/aligned.apk"

echo "== 7/7 校验"
"$APKSIGNER" verify --print-certs "$PROJ/wpan-server-arm64.apk" | head -6
"$AAPT2" dump badging "$PROJ/wpan-server-arm64.apk" | grep -E "package|application-label|sdkVersion|targetSdk|native-code" || true
ls -lh "$PROJ/wpan-server-arm64.apk"
