#!/bin/sh
# 把 golang.org/x/sys 复制到 end/third_party/xsys 并打上 Android 补丁。
#
# 背景：x/sys/cpu 的 hwcap_linux.go / cpu_linux_arm64.go 靠文件名后缀 _linux_ 被编译，
# 在 Go 的 android 目标下同样生效。它们在启动时会读 /proc/self/auxv，读不到还会走
# MSR 寄存器读取回退 —— 在 Android 上这两条路分别会被 SELinux 拦和触发 SIGILL，
# 表现为进程在 init 阶段直接崩掉。补丁让它们在 Android 用户态下跳过探测。
#
# 用法： sh prepare-xsys.sh <wpan 源码根目录>
set -eu

SRC=${1:-$(cd "$(dirname "$0")" && pwd)}
HERE=$(cd "$(dirname "$0")" && pwd)
END="$SRC/end"
MODVER=$(grep -E 'golang\.org/x/sys v' "$END/go.mod" | awk '{print $2}' | head -1)
[ -n "$MODVER" ] || { echo "go.mod 里找不到 golang.org/x/sys 版本" >&2; exit 1; }

MODCACHE=$(cd "$END" && go env GOMODCACHE)
MODDIR="$MODCACHE/golang.org/x/sys@$MODVER"
if [ ! -d "$MODDIR" ]; then
  ( cd "$END" && go mod download golang.org/x/sys )
fi

echo "== 复制 $MODDIR -> end/third_party/xsys"
rm -rf "$END/third_party/xsys"
mkdir -p "$END/third_party"
cp -r "$MODDIR" "$END/third_party/xsys"
chmod -R u+w "$END/third_party/xsys"

echo "== 应用 cpu Android 补丁"
patch -p1 -d "$END/third_party/xsys" < "$HERE/xsys-cpu-android.patch"

if ! grep -q 'replace golang.org/x/sys => ./third_party/xsys' "$END/go.mod"; then
  printf '\n// Android 适配：third_party/xsys 为 golang.org/x/sys 副本，仅改 cpu 包 HWCAP 探测\nreplace golang.org/x/sys => ./third_party/xsys\n' >> "$END/go.mod"
  echo "== 已写入 go.mod replace"
fi

echo "== 完成"
