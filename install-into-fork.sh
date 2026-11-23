#!/bin/sh
# 把 Android 适配一次性装进你自己的 fork，并提交成一个 commit。
#
# 用法（在 fork 仓库根目录执行，也就是能看到 end/ 和 app/ 的那一层）：
#   sh install-into-fork.sh
#   git push -u origin android-support
#
# 做的事：
#   1. 打 patches/android-server.patch（android_dns.go 新增、main.go、cmd/index.go）
#   2. 把 android/ 整个目录放进仓库（APK 工程：前台服务、Manifest、资源、构建脚本）
#   3. git add + commit（不自动 push，你自己确认后再推）
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

[ -f end/go.mod ] || { echo "这里不是 wpan 仓库根目录（找不到 end/go.mod）" >&2; exit 1; }
[ -f app/pubspec.yaml ] || echo "提醒：没找到 app/pubspec.yaml，确认一下这是完整仓库" >&2

BRANCH=${BRANCH:-android-support}
if git rev-parse --git-dir >/dev/null 2>&1; then
  CUR=$(git rev-parse --abbrev-ref HEAD)
  if [ "$CUR" != "$BRANCH" ]; then
    git checkout -B "$BRANCH"
    echo "== 已切到分支 $BRANCH"
  fi
fi

echo "== 1/3 打服务端补丁"
if git apply patches/android-server.patch 2>/dev/null; then
  echo "   补丁直接应用成功"
elif git apply --3way patches/android-server.patch; then
  echo "   补丁以 3-way 应用成功"
else
  echo "补丁打不上：上游改了 main.go / cmd/index.go 的相关段落，手工合并后再提交" >&2
  exit 1
fi

echo "== 2/3 检查 android/ 工程是否就位"
[ -f android/src/com/wpan/server/ServerService.java ] || {
  echo "缺 android/ 目录：请把本压缩包解压到仓库根目录（和 end/、app/ 同级）后再执行" >&2
  exit 1
}

echo "== 3/3 提交"
git add -A
git -c user.name="${GIT_AUTHOR_NAME:-wpan android}" -c user.email="${GIT_AUTHOR_EMAIL:-android@local}" \
  commit -m "android: 让服务端能在 Android 上跑（DNS/时区/HWCAP/mDNS 适配 + APK 工程）" \
  -m "补丁内容：end/android_dns.go 新增；end/main.go 提前设置 DNS 并内嵌 tzdata；end/cmd/index.go mDNS 失败不再 panic 并加阶段标记；golang.org/x/sys 的 cpu HWCAP 探测在 Android 下跳过（build 时由 android/prepare-xsys.sh 生成）。" \
  -m "APK 工程在 android/，构建见 android/build-from-repo.sh。" || echo "（没有新改动可提交）"

cat <<'EOF'

== 完成。接下来：
  1) 看一眼 diff：git show --stat HEAD
  2) 推上去：     git push -u origin android-support
  3) 构建 APK：   cd android && sh build-from-repo.sh
     （首次会提示生成自签名 keystore；以后每次构建都用同一个，否则无法覆盖安装）
  4) 与上游同步：git fetch upstream && git merge upstream/main
     冲突只会出现在 end/main.go、end/cmd/index.go 这几个文件
EOF
