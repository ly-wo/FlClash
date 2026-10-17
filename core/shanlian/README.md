# FlClash Android 闪连核心

这是给 FlClash 固定 Mihomo 分支使用的 Android 认证补丁，不是把闪连客户端换成 Rust 核心。手机上的流量仍由 FlClash 里的 Go Mihomo 直接拨号。`shanlian-rs` 只负责生成带 `direct=1` 的直连订阅；订阅里的入口和出口继续用 `dialer-proxy` 串起来，访问流量不经过 Rust 服务。

桌面版 Mihomo 补丁仍然是 `deploy/mihomo/v1.19.32-shanlian-auth.patch`，构建入口不变。本目录的补丁只对应 FlClash v0.9.1 子模块 `core/Clash.Meta` 的提交 `8380d0e7462f061a964323e9bf3129a236fcc5d5`，不能套到 v1.19.32 上，也不能套回 `7bdcd60`。

## 认证

节点写出 `shanlian-uid` 时，核心把 32 位十六进制 UID 解码成 16 字节，再按闪连规则拼出 32 字节认证：前 16 字节是 UID，后 16 字节是 UID 与两个大端时间字段的异或。时间字段是启动时刻的毫秒乘 10 再加 3，以及当前毫秒。

没有 `shanlian-uid` 时，认证仍是标准 AnyTLS 的 `SHA-256(password)`。UID 不是 32 位十六进制，或者 UID 和 password 都缺失，配置会被拒绝。错误信息不包含 UID 或 password。这个补丁不改节点的证书校验字段。

直连订阅必须带 `direct=1`。没有这个参数时，服务器仍导出原来的 SOCKS5 转接配置。

## 文件

| 文件 | 作用 |
| --- | --- |
| `flclash-anytls-auth.patch` | 认证补丁和固定时间、配置解析测试 |
| `manifest.json` | 锁定 Mihomo 提交、补丁 SHA-256、来源提交 |
| `flclash_android.py` | 校验、同步到 FlClash、调用 FlClash 的 Android 构建 |

`manifest.json` 里的 `shanlian_rs_commit` 和 `flclash_commit` 是编写时的分支基线，用来对照来源。真正决定补丁是否被换掉的是 `patch_sha256`。`mihomo_commit` 必须和 FlClash 子模块 `HEAD` 一致，否则 Android 构建失败，不会退回未打补丁的核心。

## 同步到 FlClash

在本目录执行：

```sh
python flclash_android.py verify
python flclash_android.py sync --flclash-dir D:/Projects/dm/ns/FlClash
```

同步只复制本目录的补丁、清单和这份说明到 `FlClash/core/shanlian/`。它不修改 `core/Clash.Meta`，也不更新子模块提交。

## 构建 Android 库

构建前设置 `ANDROID_NDK`。下面的命令会先同步集成包，再准备补丁副本，然后调用 FlClash Android 工程的 `:core:bindCore`。补丁打在 FlClash 仓库里的 `build/shanlian-core/`。这个目录被 Git 忽略，不会提交，但它就在仓库目录内，不是仓库外的另一条路径。并发编译多个 ABI 之前只准备一次。缓存键包含 Mihomo 提交、补丁 SHA-256，以及实际复制进构建的 FlClash `core` 桥接源码内容指纹。未提交的桥接文件修改也会改变指纹并重新准备副本。

```sh
python flclash_android.py build --flclash-dir D:/Projects/dm/ns/FlClash --arch arm64
```

省略 `--arch` 时 gomobile 绑定 `android/arm`、`android/arm64` 和 `android/amd64`。只在 FlClash 仓库里准备副本时：

```sh
dart run bin/prepare_shanlian.dart --root-dir D:/Projects/dm/ns/FlClash
```

工作目录是 `FlClash/plugins/setup/setup_hooks`。Android 库由 gomobile 生成，文件名是 `libclash.so`，版本字符串带 `shanlian`。准备失败时 Gradle 停止，不会绑定未打补丁的核心。桌面平台的构建命令不读取这个补丁。

这里没有真机和闪连账号，不能把编译成功当成 VPN 或真实节点已经连通。

## Android 标签发布

`v*` 标签由 FlClash 的 `.github/workflows/android-release.yml` 构建，不走原来的 `build.yaml`。旧 workflow 里的桌面任务还留在文件中，但该 fork 不再用标签触发它，因此不会向 Telegram 或 F-Droid 发送，也不会读取签名密钥。

标签构建使用 Flutter 3.47.6、Go 1.27.1 和 NDK r28c。`.gitmodules` 使用公开的 `https://github.com/` 地址，CI 按固定 gitlink 递归检出。产物是三个 ABI 各自可安装的 release APK、从 APK 抽出的 `libclash.so` zip，以及 `SHA256SUMS`。稳定标签会设置 `APP_ENV=stable`。

没有 `android/app/keystore.jks` 以及 `local.properties` 里的 `storePassword`、`keyAlias`、`keyPassword` 时，`android/app/build.gradle.kts` 继续用 Android debug 签名，并把应用 ID 加上 `.dev`，安装包名是 `com.follow.clash.dev`。这不是稳定的发布签名，CI 不会生成或提交密钥。

上游 v0.9.1 已去掉 Firebase。本 fork 不恢复 Crashlytics。
