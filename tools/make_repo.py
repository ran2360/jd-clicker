#!/usr/bin/env python3
"""
把一个或多个越狱 .deb 生成 Sileo/Cydia 可加的"扁平源" (flat repo)。

扁平源就是一个目录, 里面直接放:
    Release         源元信息 (Origin/Label/Suite/Codename/Architectures/...)
    Packages        包索引 (Debian control 格式, 每个包一个 stanza)
    Packages.gz     Packages 的 gzip 版本 (Sileo 优先读这个)
    *.deb           包本体 (Filename 字段相对仓库根写 ./xxx.deb)

Sileo/Cydia 添加源时只要填这个目录的 URL 即可, 例如:
    https://raw.githubusercontent.com/ran2360/jd-clicker/main/repo/

用法:
    python3 tools/make_repo.py --debs "tweak/packages/*.deb" --out repo

    # 只生成索引、不复制 deb (deb 已经在 out 里)
    python3 tools/make_repo.py --debs "repo/*.deb" --out repo --no-copy
"""
import argparse
import gzip
import hashlib
import io
import os
import shutil
import sys
import tarfile

ORIGIN = "ran2360"
LABEL = "JDClicker"
SUITE = "stable"
VERSION = "1.0"
CODENAME = "ios"
DESCRIPTION = "JDClicker 京东连点器源 —— 悬浮球/准星瞄准/10-30-50 次每秒, 只在京东前台显示"


# ---------------------------------------------------------------------------
# .deb 解析 (和 make_deb.py 里同一套 ar/tar 逻辑, 这里保持自包含, 方便在工作流里单独跑)
# ---------------------------------------------------------------------------
def _parse_ar(blob):
    if not blob.startswith(b"!<arch>\n"):
        raise ValueError("不是 ar 归档 (缺少 !<arch> 魔数)")
    pos = 8
    members = {}
    while pos + 60 <= len(blob):
        hdr = blob[pos:pos + 60]
        if hdr[58:60] != b"\x60\n":
            raise ValueError(f"ar 成员头魔数损坏 @ {pos}")
        name = hdr[0:16].decode("ascii").rstrip()
        size = int(hdr[48:58].decode("ascii").strip())
        pos += 60
        members[name] = blob[pos:pos + size]
        pos += size + (size % 2)
    return members


def _extract_control_and_size(deb_path):
    """返回 (control 字段 dict, 安装大小 KB)。"""
    blob = open(deb_path, "rb").read()
    members = _parse_ar(blob)
    ctrl_name = next((n for n in members if n.startswith("control.tar")), None)
    data_name = next((n for n in members if n.startswith("data.tar")), None)
    if not ctrl_name or not data_name:
        raise ValueError(f"{deb_path}: ar 成员不对 {list(members)}")

    fields = {}
    with tarfile.open(fileobj=io.BytesIO(members[ctrl_name]), mode="r:*") as tf:
        names = tf.getnames()
        ctrl_file = next((n for n in names if n in ("./control", "control")), None)
        if not ctrl_file:
            raise ValueError(f"{deb_path}: control.tar 里没有 control")
        text = tf.extractfile(ctrl_file).read().decode("utf-8", "replace")
        # 支持多行字段 (Description 可能折行, 但我们自己的 control 都是单行)
        for line in text.splitlines():
            if ": " in line:
                k, v = line.split(": ", 1)
                fields[k] = v

    size_kb = 1
    with tarfile.open(fileobj=io.BytesIO(members[data_name]), mode="r:*") as tf:
        total = sum(m.size for m in tf.getmembers() if m.isfile())
        size_kb = max(1, (total + 1023) // 1024)

    return fields, size_kb


def _hashes(deb_path):
    raw = open(deb_path, "rb").read()
    return {
        "Size": len(raw),
        "MD5sum": hashlib.md5(raw).hexdigest(),
        "SHA1": hashlib.sha1(raw).hexdigest(),
        "SHA256": hashlib.sha256(raw).hexdigest(),
    }


# ---------------------------------------------------------------------------
# 索引生成
# ---------------------------------------------------------------------------
def make_packages_text(debs):
    """debs: [(repo 内相对文件名, 绝对路径), ...] -> Packages 文本"""
    stanzas = []
    for rel, abs_path in sorted(debs):
        fields, size_kb = _extract_control_and_size(abs_path)
        h = _hashes(abs_path)
        pkg = fields.get("Package")
        ver = fields.get("Version")
        arch = fields.get("Architecture")
        if not (pkg and ver and arch):
            raise ValueError(f"{abs_path}: control 缺 Package/Version/Architecture: {fields}")

        # 关键字段顺序: Filename 必须是相对仓库根的 ./xxx.deb
        lines = [
            f"Package: {pkg}",
            f"Version: {ver}",
            f"Architecture: {arch}",
            f"Maintainer: {fields.get('Maintainer', 'local build')}",
            f"Installed-Size: {size_kb}",
        ]
        # 我们的 control 明确不写 Depends (避免隐根上 Sileo 拒装), 空就整个省略
        deps = fields.get("Depends")
        if deps and deps.strip():
            lines.append(f"Depends: {deps.strip()}")
        lines += [
            f"Filename: ./{rel}",
            f"Size: {h['Size']}",
            f"MD5sum: {h['MD5sum']}",
            f"SHA1: {h['SHA1']}",
            f"SHA256: {h['SHA256']}",
            f"Section: {fields.get('Section', 'Tweaks')}",
            f"Name: {fields.get('Name', pkg)}",
            f"Author: {fields.get('Author', 'local build')}",
            f"Description: {fields.get('Description', '')}",
        ]
        stanzas.append("\n".join(lines))

    return "\n\n".join(stanzas) + "\n"


def make_release_text(archs):
    """archs: 出现的 Architecture 去重列表"""
    return "\n".join([
        f"Origin: {ORIGIN}",
        f"Label: {LABEL}",
        f"Suite: {SUITE}",
        f"Version: {VERSION}",
        f"Codename: {CODENAME}",
        f"Architectures: {' '.join(sorted(archs))}",
        "Components: main",
        f"Description: {DESCRIPTION}",
    ]) + "\n"


def main():
    ap = argparse.ArgumentParser(description="生成 Sileo/Cydia 扁平源")
    ap.add_argument("--debs", required=True, help="deb 文件 glob 或逗号分隔列表")
    ap.add_argument("--out", required=True, help="源目录 (会创建)")
    ap.add_argument("--no-copy", action="store_true",
                    help="不复制 deb (deb 已经在 out 里), 只生成索引")
    a = ap.parse_args()

    # 展开 glob
    import glob
    patterns = [p for p in a.debs.split(",") if p.strip()]
    deb_paths = []
    for p in patterns:
        deb_paths += glob.glob(p)
    deb_paths = sorted(set(os.path.abspath(p) for p in deb_paths))
    if not deb_paths:
        print("!! --debs 没匹配到任何 .deb")
        return 1

    os.makedirs(a.out, exist_ok=True)
    out_abs = os.path.abspath(a.out)

    # 复制 deb 到源目录, 并记录 (相对文件名, 绝对路径)
    entries = []
    for p in deb_paths:
        base = os.path.basename(p)
        dst = os.path.join(out_abs, base)
        if not a.no_copy and os.path.abspath(p) != os.path.abspath(dst):
            shutil.copy2(p, dst)
        entries.append((base, dst))
        print(f"包: {base}")

    packages = make_packages_text(entries)
    archs = []
    for rel, dst in entries:
        f, _ = _extract_control_and_size(dst)
        if f.get("Architecture"):
            archs.append(f["Architecture"])

    with open(os.path.join(out_abs, "Packages"), "w", encoding="utf-8") as fh:
        fh.write(packages)
    with open(os.path.join(out_abs, "Packages.gz"), "wb") as fh:
        fh.write(gzip.compress(packages.encode("utf-8"), compresslevel=9, mtime=0))
    with open(os.path.join(out_abs, "Release"), "w", encoding="utf-8") as fh:
        fh.write(make_release_text(archs))

    print("-" * 66)
    print("Release:")
    print(make_release_text(archs).rstrip())
    print("-" * 66)
    print("Packages 前几行:")
    print("\n".join(packages.splitlines()[:12]))
    print("-" * 66)
    print(f"✓ 源已生成到 {out_abs}")
    print(f"  Release / Packages / Packages.gz + {len(entries)} 个 deb")
    print("  添加源 URL (仓库提交后):")
    print("  https://raw.githubusercontent.com/ran2360/jd-clicker/main/repo/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
