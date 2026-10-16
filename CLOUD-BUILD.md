# 用 GitHub Actions 构建（不需要 Mac）

## 为什么不能直接用 Windows 上编好的

SpringBoard 是 **arm64e** 进程，插件必须包含 arm64e 切片才加载得进去；
而 Windows 侧的工具链（Zig、LLVM 的 ld64.lld）都产不出合法的 arm64e。
详见 README §1.3 和 `theos/README.md`。

GitHub 提供**免费的 macOS runner**，上面有真正的 clang + ld64，能编出正确的
fat（arm64 + arm64e）dylib。全程不需要 Mac、不需要 Apple 开发者账号。

---

## 这个压缩包里有什么

正好是云端构建需要的文件，**目录结构已经排好**：

```
.github/workflows/build-tweak.yml    GitHub Actions 工作流
src/JDClickerSB.m                    插件源码（全部逻辑已写完）
src/JDClickerSB.plist                加载过滤器 (com.apple.springboard)
theos/Makefile                       theos 工程（ARCHS = arm64 arm64e）
theos/control                        包描述
theos/README.md                      构建说明与架构原因
```

> Windows 上的 `toolchain/` 有 ~500MB（Zig 编译器 + iPhoneOS SDK），
> **不需要、也不应该上传** —— 云端会自己装 theos。

---

## 步骤

### 1. 建一个仓库

打开 <https://github.com/new>

- **Repository name**：随便，比如 `jd-clicker`
- 选 **Public**（公开仓库的 Actions 额度免费且不限量）
- **不要**勾 Add a README / .gitignore
- 点 **Create repository**

### 2. 上传文件

在新建的仓库页面点 **Add file → Upload files**，
把解压出来的 **`.github`、`src`、`theos` 三个文件夹一起拖进去**，
等它把所有文件列出来之后点 **Commit changes**。

> GitHub 网页是支持拖整个文件夹的，会保留目录结构。
> 如果拖拽不成功，也可以点 **Add file → Create new file**，
> 在文件名里直接写 `src/JDClickerSB.m` 这样的完整路径，GitHub 会自动建目录。
> 一共只要建 5 个文件。

### 3. 等 Actions 跑完

点仓库顶部的 **Actions** 标签页，能看到 `build-tweak` 正在跑。
第一次大约 3～6 分钟（需要克隆 theos）。

### 4. 下载产物

跑完后点进那次运行，页面底部 **Artifacts** → 下载 `jdclickersb-debs`，里面是两个 deb：

| 文件 | 用途 |
|---|---|
| `..._iphoneos-arm64e.deb` | **隐根用这个** |
| `..._iphoneos-arm64.deb` | 无根 Dopamine 用 |

### 5. 确认切片对不对（重要）

同一次运行的日志里有一段 `lipo -detailed_info`，应该能看到：

```
architecture arm64
architecture arm64e        ← 必须有这一行
```

**看到 arm64e 就说明这次构建成功了。** 如果没有这一行，把那段日志发我。

---

## 装到手机

回到主 README §1.3，简单说：

1. **先卸载之前所有测试包**（NoOp / NoOpNotes / NoOpHide / Beacon / Canary / AutoClicker / JDClickerSB 全卸掉）；
2. 装新的 `JDClickerSB_..._iphoneos-arm64e.deb`；
3. ⚠️ **注销一次 / 重启用户空间** —— SpringBoard 本来就在跑，插件不会自己进去；
4. 打开京东，屏幕右侧约 1/3 高度处应该出现深灰「连点」悬浮球。

菜单第三行是显示模式，首次默认「总是显示」（防止前台检测不灵时球藏起来、你又点不到它）。
确认状态栏里「京东: 前台」能正常切换之后，再切成「仅京东显示」。

---

## 如果 Sileo 报错（两种常见情况）

### A. `Depends mobilesubstrate:none` / `Depends firmware:none(>= 15.0)`

这是**依赖查不到**被拦下 —— 你的 APT 索引里没有这两个虚拟包。

**1.0.9 起已经把 `Depends` 整个去掉了**，不会再有这个问题。
（本插件不做任何 hook，只要 ElleKit 在就行，而那是越狱自带的，本来也不需要声明依赖。）

如果你手里还是旧版 deb，重新跑一次 Actions 拿新版，或者自己删掉 control 里的 `Depends` 那一行。

### B. `Install Identifier Mismatch for Identifiers` / `APT was unable to find this package`

这通常是**手工改 deb 之后结构坏了**（`.deb` 是个 `ar` 归档，里面成员的 header 和大小必须自洽，
用文本编辑器改 control 会让它不一致）。**不要手工改 deb** —— 改源文件重新构建。

另外也可能是 Sileo 的安装队列里留着上一次失败的条目：

1. 打开 Sileo → **安装** 标签页；
2. 找到 `JDClickerSB`，点左边那个**红色 ⊖** 把它从队列里移除；
3. 回 **软件包 / 软件源** 页面下拉**刷新一次**；
4. 再重新点开新的 deb 安装。

---

## 出问题看哪里

日志写在（SpringBoard 是 root 进程，写哪都行）：

```
/tmp/JDClicker.log
/var/mobile/Library/Caches/JDClicker.log
```

用 **Filza** 直接打开。

- **装上之后没有这个文件** → 插件还是没进 SpringBoard。先确认 Actions 日志里的
  `lipo -detailed_info` 有 arm64e，再把手机上的 `/tmp` 和
  `/Library/MobileSubstrate/DynamicLibraries/` 截图给我。
- **有日志但球不显示** → 把日志发我（里面有前台检测和窗口安装的详细信息）。
- **球在、能点开始、京东没反应** → 说明 HID 派发被系统拒了，也把日志发我。
