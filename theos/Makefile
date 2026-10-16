# theos 工程 —— 在 macOS 上构建真正的 arm64e 切片
#
# 为什么需要这个:
#   我们的 SpringBoard 插件必须包含 **arm64e** 切片 —— SpringBoard 是 arm64e 进程,
#   而 dyld 按主可执行文件推导出的分级架构表精确匹配切片
#   (archs_arm64e = { arm64e }), 纯 arm64 的 dylib 根本加载不进去。
#
#   Windows 侧工具链产不出真正的 arm64e:
#     * Zig 的架构表里没有 arm64e;
#     * LLVM 的 ld64.lld 即使收到 -arch arm64e, 链接出来的 cpusubtype 也是 0,
#       且不生成 arm64e 专有的认证节。
#   所以这一份 Makefile 是给 macOS / GitHub Actions 用的 (见 .github/workflows/)。
#
# 用法 (在 macOS 上, 已装好 theos):
#   make clean
#   make package THEOS_PACKAGE_SCHEME=roothide     # 隐根
#   make package THEOS_PACKAGE_SCHEME=rootless     # 无根
#   产物在 packages/

TARGET := iphone:clang:latest:15.0

# ★ 关键: 必须同时出 arm64 和 arm64e。SpringBoard 是 arm64e, 只出 arm64 加载不了。
ARCHS = arm64 arm64e

# 装完让 SpringBoard 重新加载插件
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = JDClickerSB
JDClickerSB_FILES = JDClickerSB.m
JDClickerSB_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-parameter
JDClickerSB_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
