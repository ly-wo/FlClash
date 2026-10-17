# FlClash Android 闪连核心

这是给 FlClash 固定 Mihomo 分支使用的 Android 认证补丁，不是把闪连客户端换成 Rust 核心。手机上的流量仍由 FlClash 里的 Go Mihomo 直接拨号。`shanlian-rs` 只负责生成带 `direct=1` 的直连订阅；订阅里的入口和出口继续用 `dialer-proxy` 串起来，访问流量不经过 Rust 服务。

桌面版 Mihomo 补丁仍然是 `deploy/mihomo/v1.19.32-shanlian-auth.patch`，构建入口不变。本目录的补丁只对应 FlClash 子模块 `core/Clash.Meta` 的提交 `7bdcd60da9db10b681d7507af96d4fad797f3774`，不能套到 v1.19.32 上，也不能反过来。

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

构建前设置 `ANDROID_NDK`。下面的命令会先同步集成包，再运行 FlClash 自己的 `build_tool android`。补丁打在 FlClash 仓库里的 `build/shanlian-core/`。这个目录被 Git 忽略，不会提交，但它就在仓库目录内，不是仓库外的另一条路径。并发编译多个 ABI 之前只准备一次。缓存键包含 Mihomo 提交、补丁 SHA-256，以及实际复制进构建的 FlClash `core` 桥接源码内容指纹。未提交的桥接文件修改也会改变指纹并重新准备副本。

```sh
python flclash_android.py build --flclash-dir D:/Projects/dm/ns/FlClash --arch arm64
```

省略 `--arch` 时构建 `armeabi-v7a`、`arm64-v8a` 和 `x86_64`。只在 FlClash 仓库里构建时，不需要本仓库路径：

```sh
dart run bin/build_tool.dart android --root-dir D:/Projects/dm/ns/FlClash --arch arm64
```

工作目录是 `FlClash/plugins/setup/buildkit/build_tool`。Android 库的版本字符串会带 `shanlian`。桌面平台的构建命令不读取这个补丁。

缺少 `libclash.so`、`libclash.h` 或 `bride.h` 时，Android 原生构建会直接失败，不会生成一个没有核心的安装包。

这里没有真机和闪连账号，不能把编译成功当成 VPN 或真实节点已经连通。

## Android 标签发布

`v*` 标签由 FlClash 的 `.github/workflows/android-release.yml` 构建，不走原来的 `build.yaml`。旧 workflow 里的桌面任务还留在文件中，但该 fork 不再用标签触发它，因此不会向 Telegram 或 F-Droid 发送，也不会读取签名密钥。

标签构建使用 Flutter 3.41.9、Go 1.22.10 和 NDK r28c。`.gitmodules` 使用公开的 `https://github.com/` 地址，CI 按固定 gitlink 递归检出。产物是三个 ABI 各自可安装的 release APK、包含 `libclash.so` 和头文件的核心库 zip，以及 `SHA256SUMS`。稳定标签会设置 `APP_ENV=stable`。

没有 `android/app/keystore.jks` 以及 `local.properties` 里的 `storePassword`、`keyAlias`、`keyPassword` 时，`android/app/build.gradle.kts` 继续用 Android debug 签名，并把应用 ID 加上 `.dev`，安装包名是 `com.follow.clash.dev`。这不是稳定的发布签名，CI 不会生成或提交密钥。

Dart 工程没有 `firebase_core`，也没有 `Firebase.initializeApp`。Android 只在 `google-services.json` 存在时应用 Google Services 和 Crashlytics 插件；文件缺失时插件不应用，`GlobalState.setCrashlytics` 发现没有 `google_app_id` 就跳过初始化。Crashlytics 的映射和原生符号开关在每个 `buildType` 上，默认不上传。只有设置 `FIREBASE_CRASHLYTICS_UPLOAD=true` 或 `local.properties` 的 `crashlyticsUpload=true` 时才恢复上传。
