# wpan 服务端 · APK 版（装完即用，不需要 Termux）

> **v1.0.1 修复了什么**：v1.0.0 装机后点「启动」会立刻失败，日志里是 `golang.org/x/sys/cpu.readHWCAP` 打头的崩溃。
> 原因是 Go 的 `x/sys/cpu` 在 init 阶段读 `/proc/self/auxv`（Android 上常被 SELinux 拦住），失败后走 `MSR` 寄存器回退，在 Android 内核上可能直接 SIGILL，进程连 main 都没进就死了。
> 现在把这段探测在 Android 下整段跳过（`third_party/xsys`，见 `android-server.patch` 与 `prepare-xsys.sh`），换用 ARMv8-A 基线默认值。
> **可以直接覆盖安装 v1.0.0，数据不会丢**（签名一致）。

把 wpan 的 Go 服务端交叉编译成 arm64 静态二进制，作为原生库打进 APK（`lib/arm64-v8a/libwpan-server.so`），由一个前台 Service 拉起子进程常驻运行。装完打开点「启动」就能用，**不需要 Termux、不需要 root、不需要电脑**。

同一份服务端代码只加了 Android 适配补丁（DNS / CA / 时区，见 `android-server.patch`），业务逻辑零改动。

---

## v1.0.5 更新（保活修正：stdout 不再走管道 + 看护线程）

现象：跑起来一分钟后自检变「无响应」，客户端也扫不到地址；把 App 关掉再打开，界面还停在「运行中」（状态骗人）。

根因是**子进程的 stdout 走了 App 进程的管道**：App 一旦被系统冻结/回收（锁屏、切后台很常见），读端没了或不再读，管道 64KB 写满，Go 服务端就永久阻塞在 write 上——进程还活着、端口还开着（所以「运行中」看着正常），但一个请求都不回；若 App 进程直接死掉，读端消失，子进程下一次写 stderr 会吃 SIGPIPE 直接没。

本版改动：

- 子进程 stdout/stderr **直接重定向到 `log/server.out` 文件**，不再经过任何管道，App 死/冻结都不会拖累服务端；
- 新增看护线程：每 5 秒打一次 `/discovery`，进程死了或接口连续 60 秒无响应就**杀掉重启**（最多自愈 3 次），状态实时回写，界面不再停在假的「运行中」；
- 启动前先探端口：若已有进程在监听就按「已在运行」处理，不会因为残留进程报 `bind: address already in use`；
- 崩溃/退出时把 exit code 和日志末尾直接显示在界面上。


## v1.0.4 更新（关键：x86_64 原生版）

真机日志给出了决定性证据：`boot.log` 里 `abi=x86_64 sdk=28`，即**测试机是 x86_64 的 Android（Intel 设备或电脑上的模拟器）**，之前的 arm64 二进制只能靠 ARM 转译跑。转译层下 Go 运行时不稳，这次崩在 `modernc.org/libc.init.3()` 里 mmap 时抛 `fatal error: wirep: invalid p state`（init 阶段，连 main 都没进）。

- APK 现在同时带 `lib/arm64-v8a/` 与 `lib/x86_64/` 两份二进制（27 MB），系统按 ABI 自动选：真机 arm64 用前者，x86_64 设备/模拟器用后者，不再经过转译；
- `build-apk.sh` 支持 `SERVER_BIN_X64`，缺 x86_64 二进制时只打 arm64；
- x86_64 版在本机构建后又用 `env -i` 最小环境 + APK 的 assets 三件套原生跑通：监听 18090、`/discovery` 200、`admin/123` 登录拿到 token、`/douban/health` 返回 `+08:00` 时间戳。


## v1.0.2 更新（诊断加强）

上一版（v1.0.1）装到真机上启动失败，界面只给出「40 秒内没有监听端口」这种笼统结论，看不到原因。本版不猜、只取证：

- 界面失败信息里直接带上**退出码 + 服务端日志末尾 10 行**，不用再点「查看日志」；
- 新增 `log/boot.log`，记录服务层每一步：nativeLibraryDir、ABI、SDK 版本、二进制大小与 `canExecute`、chmod 结果、进程 pid、TZ、解析到的 DNS；
- 新增「复制日志到剪贴板」按钮，一次复制 `boot.log` + `server.out`；
- 区分「进程启动后立即退出（exit code=X，多为加载/指令问题）」与「进程还在但 60 秒不监听（多为卡在某一步初始化）」，两者修法完全不同；
- 等待窗口从 40 秒放宽到 60 秒，并给日志线程 0.8 秒落盘时间再判定。


## 一、安装

1. 把 `wpan-server-arm64.apk` 传到手机（微信/QQ/USB 都行）；
2. 点击安装，允许「安装未知来源应用」；
3. 打开「wpan 服务端」，点 **启动**，等状态变成「● 运行中（pid xxx）」；
4. 首次启动要初始化 SQLite 库，十几秒，别急着退出。

然后打开 wpan 客户端 App，登录页/设置页的服务端地址填：

```
http://127.0.0.1:18090
```

账号 `admin / 123`，进去第一件事是改密码。同一 WiFi 下的其他设备用界面里列出的「局域网」地址。

---

## 二、界面能干什么

- **启动 / 停止**：控制前台服务（带常驻通知，通知里有「停止」按钮）；
- **复制地址**：一键复制 `http://127.0.0.1:18090`；
- **打开检查接口**：跳浏览器打开 `/api/v1/public/discovery`，返回 JSON 就说明服务端真活着；
- **查看日志**：看 `server.out` 最近 80 行，出问题直接截这里；
- **加入电池优化白名单**：减少被系统杀掉；
- 界面上的「自检」会每 1.5 秒真实请求一次 `/discovery`，比只看进程状态可靠。

---

## 三、实现要点（也是排错时的判断依据）

| 环节 | 做法 |
|---|---|
| 二进制 | `GOOS=linux GOARCH=arm64`、`CGO_ENABLED=0`、静态链接，放进 `jniLibs` 位置由系统解压到 `nativeLibraryDir`，在那里才允许被 exec |
| 运行目录 | `OHOME_BASE_DIR=/data/data/com.wpan.server/files/wpan`，首次运行把 assets 里的 `config.yaml` / `init_data.sql` / CA 证书释放出来，之后不覆盖用户改动 |
| DNS | Android 没有 `/etc/resolv.conf`，Service 通过 `ConnectivityManager` 读当前网络的 DNS，用 `WPAN_DNS` 传给服务端 |
| 证书 | 没有系统 CA 目录，包内自带 Mozilla CA，传 `SSL_CERT_FILE` |
| 时区 | 二进制内嵌 `time/tzdata`，并传 `TZ=Asia/Shanghai`（跟随系统时区） |
| 保活 | `PARTIAL_WAKE_LOCK` + WiFi `MulticastLock`（顺带让 mDNS 播发可用）+ 前台服务 + 开机自启 Receiver |
| 端口 | 固定 18090（改端口要改 `files/wpan/conf/config.yaml`，需要 root 或 adb run-as，见下） |

---

## 四、已知限制（请先看这里）

- **只支持 arm64 + Android 8.0+**：包里只有一个 ABI 的二进制，老 32 位设备装不了。
- **验证到哪一步**：二进制部分已用 `qemu-aarch64` 做真实 arm64 指令级运行验证（启动、监听 18090、`admin/123` 登录、外部 HTTPS 拉豆瓣接口、时区 `+08:00` 全部通过），并单独强制走了一遍「Android 分支」的代码路径确认不崩；APK 结构 `zipalign` / `apksigner` 校验通过、dex 类完整。**Java 侧（前台服务、唤醒锁、通知、开机自启）仍未在真机验证**，有问题把「查看日志」截图发我。
- **开机自启可能被拦**：Android 12+ 限制后台拉起前台服务，`BootReceiver` 失败会静默跳过，手动开 App 一样能起。
- **熄屏被杀**：国产 ROM 必须手动允许「自启动 / 后台运行 / 无限制省电」，否则再多的锁也保不住。
- **不能像 Termux 版那样命令行管理**：没有 shell 入口，一切通过界面 + 通知。
- **升级**：必须用同一个 keystore 签名（`keystore/wpan.jks`，密码 `wpan123456`），否则覆盖安装会失败、只能先卸载再装（这会丢掉 `files/wpan` 里的数据）。
- **端口冲突**：如果同一个手机同时装了 Termux 版服务端，两个都抢 18090，二选一。

---

## 五、自己改配置 / 看数据（需要 adb）

```sh
adb shell run-as com.wpan.server ls files/wpan
adb shell run-as com.wpan.server cat files/wpan/conf/config.yaml
# 改端口：把 server.port 改成 18092，然后 adb shell am force-stop com.wpan.server 再开 App
```

APK 是自签名（非 debug 签名也能用 run-as 的前提是 debuggable，这里**没有**开 debuggable，所以 `run-as` 会失败）。
真要改配置，两个办法：把 APK 重新构建一次（改 `build-apk.sh` 里的 assets 或加 `android:debuggable`），或者用具有 root 的文件管理器。

---

## 六、重新构建

需要：JDK 17、Android SDK（`platforms;android-34` + `build-tools;34.0.0`）。不依赖 Gradle。

```sh
# 先把补丁打到上游源码并编出 arm64 二进制（见 Termux 版的 build-android.sh）
export JAVA_HOME=/path/to/jdk17
export ANDROID_SDK_ROOT=/path/to/sdk
SERVER_BIN=/path/to/server sh build-apk.sh
```

产物：`wpan-server-arm64.apk`。改版本号在 `AndroidManifest.xml` 的 `versionCode` / `versionName`。

文件结构：

```
AndroidManifest.xml      清单（前台服务类型 specialUse、开机自启、权限）
src/com/wpan/server/     MainActivity / ServerService / BootReceiver
res/                     图标、应用名
assets/                  首次运行释放的 conf / sql / certs
build-apk.sh             aapt2 → javac → d8 → zip → zipalign → apksigner
keystore/wpan.jks        自签名密钥（升级请沿用）
```

当前签名信息：`CN=wpan server`，证书 SHA-256 `ced5d5d2c2346c075561f930439866fd5b1169c33187e24ddfa428ef3d5fafb8`。

---

## 七、和 Termux 版怎么选

| | APK 版 | Termux 版 |
|---|---|---|
| 安装复杂度 | 装个 APK 就行 | 装 Termux + 拷目录 + 跑 `install.sh` |
| 命令行管理 | 无 | 有（start/stop/status/log/boot） |
| 改配置 | 麻烦 | 直接编辑文件 |
| 开机自启 | 内置（可能被 ROM 拦） | 靠 Termux:Boot |
| 后台稳定性 | 前台服务 + 锁 | 依赖 `termux-wake-lock` |
| 数据位置 | 应用私有目录 | `~/wpan` |

两个版本用的是同一个二进制、同一套补丁，服务端行为完全一致。

---

## 八、合规

上游 wpan 为 AGPL-3.0、声明仅供学习交流。本 APK 只是对上游源码的构建与 Android 适配，请同样遵守其许可；服务端仅封装夸克官方 API，不涉及破解，账号与数据风险自负。

## 九、版本记录

| 版本 | 说明 |
|---|---|
| 1.0.0 | 首版 APK |
| **1.0.1** | 修复启动即崩溃：`x/sys/cpu` 在 Android 上读 `/proc/self/auxv` + `MSR` 回退导致的 SIGILL，改为 Android 下跳过探测；可直接覆盖安装升级，`files/wpan` 里的数据保留 |
