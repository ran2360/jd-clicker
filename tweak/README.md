# 在 macOS / GitHub Actions 上构建（产出真正的 arm64e）

## 为什么需要这一步

Windows 侧的工具链**产不出 arm64e 切片**，而 SpringBoard 恰恰需要它：

- **SpringBoard 是 arm64e 进程。** dyld 从主可执行文件推导进程的「分级架构列表」，
  再按 cputype/cpusubtype **精确相等**匹配 fat 切片：
  ```c
  static const Architecture* const archs_arm64[]  = { arm64, arm64_alt };
  static const Architecture* const archs_arm64e[] = { arm64e };
  ```
  纯 arm64 的 dylib **加载不进 arm64e 进程** —— 表现就是"插件装了但毫无反应，
  连日志文件都没有"（代码从未被执行）。

- Windows 上两条路都试过，都不行：
  | 工具链 | 结果 |
  |---|---|
  | **Zig 0.13** | 架构表里没有 `arm64e`；`-mcpu=apple_a16+pauth`、`-Xclang -triple arm64e-apple-ios` 都试过，`cpusubtype` 恒为 0；后者还会破坏头文件搜索 |
  | **LLVM 18.1.8（含 `ld64.lld`）** | `clang -target arm64e-apple-ios16.0` **确实**产出 arm64e 目标文件（`.o` 的 `cpusubtype=2`、`__arm64e__`、`__ARM_FEATURE_PAUTH` 都有），但 **`ld64.lld` 链接出来的 dylib `cpusubtype` 恒为 0，而且不生成任何 arm64e 认证节（`__auth_got` / 认证 stub）** —— 没有认证节的"arm64e"在真正的 arm64e 进程里，第一次 block 调用就会崩 |

- **不能靠手改头部 cpusubtype 蒙混。** 把 arm64 代码标成 arm64e 之后，
  arm64e 的 libdispatch 会用 `blraaz`（带认证的调用）去调我们的 block invoke 指针，
  而那个指针没被签名 → 崩。这正是"贴假标签比不贴更糟"的典型。

## 怎么build

### 方式 A：GitHub Actions（免费，不需要 Mac）

1. 把整个 `ios-autoclicker` 目录推到一个 GitHub 仓库（公开仓库免费额度完全够）；
2. `.github/workflows/build-tweak.yml` 会自动运行（也可以在 Actions 页面手动触发）；
3. 跑完在页面底部 **Artifacts** 里下载 `.deb`。

工作流会：
- 在 `macos-14` runner 上克隆 **roothide/theos**（上游 theos 只有 `rootless`，没有 `roothide`）；
- 用 `ARCHS = arm64 arm64e` 分别构建 **隐根** 和 **无根** 两个 deb；
- 用 `lipo -detailed_info` 打印产物切片，**确认 arm64 和 arm64e 都在**。

### 方式 B：找一台 Mac

```bash
export THEOS=~/theos
# 一次性: 装 theos (roothide 分支)
git clone --recursive https://github.com/roothide/theos.git "$THEOS"
"$THEOS/bin/install-theos"

# 把源文件放进工程目录
cp ../src/JDClickerSB.m     .
cp ../src/JDClickerSB.plist .

make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide   # 隐根
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # 无根
ls packages/
```

### 方式 C：Linux + theos

theos 官方支持 Linux。但需要下载 iOS SDK 和 Linux 版工具链，
且 `ld64` 用的是 theos 自带的那份（不是 LLD），通常能正确产出 arm64e。

## 产物应该长什么样

```
$ lipo -detailed_info packages/…/JDClickerSB.dylib
…
architecture arm64
architecture arm64e        ← 必须有这一行
```

拿到正确的 deb 之后，回到主 README §1.3 的安装步骤即可。
