#!/usr/bin/env python3
"""
把本地文件直接提交到 GitHub 仓库 (走 REST API, 不需要 git)。

为什么写这个:
    用户没有 git, 每轮更新都要在网页上手动拖文件, 很容易传错/漏传。
    有了这个脚本, 拿到一个仓库级的 token 之后就能一步提交。

用法:
    # token 放在环境变量里
    set GITHUB_TOKEN=github_pat_xxx
    python tools/gh_push.py --repo ran2360/jd-clicker

    # 或者从文件读 (推荐: token 不进聊天记录)
    python tools/gh_push.py --repo ran2360/jd-clicker --token-file D:\\gh_token.txt

    # 只检查 token 和将要提交什么, 不真的提交
    python tools/gh_push.py --repo ran2360/jd-clicker --dry-run

需要的 token 权限 (Fine-grained, 只选这一个仓库):
    Contents   : Read and write      <- 提交文件
    Workflows  : Read and write      <- 必须! 否则改不了 .github/workflows/ 下的文件
    Actions    : Read                <- 可选, 用来查构建有没有跑成功
"""

import argparse
import base64
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://api.github.com"

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 默认要提交哪些文件: 本地路径 -> 仓库内路径
DEFAULT_FILES = [
    ("src/JDClickerSB.m", "src/JDClickerSB.m"),
    ("tweak/Makefile", "tweak/Makefile"),
    (".github/workflows/build-tweak.yml", ".github/workflows/build-tweak.yml"),
]


def api(method, url, token, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", "Bearer " + token)
    r.add_header("Accept", "application/vnd.github+json")
    r.add_header("X-GitHub-Api-Version", "2022-11-28")
    r.add_header("User-Agent", "jdclicker-push")
    if data is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=90) as resp:
            body = resp.read().decode("utf-8")
            return resp.status, (json.loads(body) if body.strip() else {})
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        return e.code, body
    except Exception as e:
        return 0, str(e)


def find_token(a):
    if a.token:
        return a.token.strip()
    if a.token_file:
        return open(a.token_file, encoding="utf-8").read().strip()
    for k in ("GITHUB_TOKEN", "GH_TOKEN"):
        v = os.environ.get(k)
        if v:
            return v.strip()
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/name, 例如 ran2360/jd-clicker")
    ap.add_argument("--token")
    ap.add_argument("--token-file")
    ap.add_argument("--message", default=None)
    ap.add_argument("--branch", default=None, help="默认用仓库的 default_branch")
    ap.add_argument("--files", default=None,
                    help="逗号分隔的额外文件列表, 覆盖/追加默认列表; 每项 '本地:远程' 或 '同路径'")
    ap.add_argument("--add", action="store_true",
                    help="--files 是追加到默认列表, 而不是覆盖")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    token = find_token(a)
    if not token:
        print("!! 没有 token。用 --token-file / --token / 环境变量 GITHUB_TOKEN 提供。")
        return 2

    # --- 验证 token ---
    st, user = api("GET", API + "/user", token)
    if st != 200:
        print(f"!! token 验证失败 (HTTP {st}):\n{user}")
        return 3
    print(f"token 属于: {user.get('login')}")

    # --- 仓库信息 ---
    st, repo = api("GET", f"{API}/repos/{a.repo}", token)
    if st != 200:
        print(f"!! 读不到仓库 {a.repo} (HTTP {st}):\n{repo}")
        return 4
    branch = a.branch or repo.get("default_branch") or "main"
    print(f"仓库: {repo.get('full_name')}  默认分支: {branch}  "
          f"({'私有' if repo.get('private') else '公开'})")

    # --- 组装最终要提交的文件列表 ---
    files = list(DEFAULT_FILES)
    if a.files:
        extra = []
        for item in a.files.split(","):
            item = item.strip()
            if not item:
                continue
            if ":" in item:
                local_rel, remote = item.split(":", 1)
            else:
                local_rel = remote = item
            extra.append((local_rel, remote))
        if a.add:
            files += extra
        else:
            files = extra

    # --- 先拿到每个文件的"是否变化" ---
    import hashlib
    updates = []          # [(remote_path, raw_bytes)]
    for local_rel, remote in files:
        local = os.path.join(ROOT, local_rel.replace("/", os.sep))
        if not os.path.exists(local):
            print(f"!! 本地缺少 {local_rel}, 跳过")
            continue
        raw = open(local, "rb").read()

        st, cur = api("GET", f"{API}/repos/{a.repo}/contents/{remote}?ref={branch}", token)
        if st == 404:
            print(f"-> {remote}  新建  {len(raw)} 字节")
            updates.append((remote, raw))
            continue
        if st != 200:
            print(f"!! 读 {remote} 失败 (HTTP {st})")
            continue

        old = None
        if isinstance(cur, dict) and cur.get("encoding") == "base64":
            try:
                old = base64.b64decode(cur.get("content", ""))
            except Exception:
                old = None
        if old == raw:
            print(f"=  {remote}  内容与仓库一致, 跳过 (sha256 {hashlib.sha256(raw).hexdigest()[:12]})")
            continue
        print(f"-> {remote}  更新  {len(raw)} 字节")
        updates.append((remote, raw))

    print("-" * 66)
    if not updates:
        print("没有需要提交的文件。")
        return 0
    if a.dry_run:
        print("dry-run, 没有真的提交。")
        return 0

    # --- 用 Git Data API 做**一次** commit 提交所有文件 (避免一个文件触发一次构建) ---
    st, ref = api("GET", f"{API}/repos/{a.repo}/git/ref/heads/{branch}", token)
    if st != 200 or not isinstance(ref, dict):
        print(f"!! 拿不到分支 ref (HTTP {st}): {ref}")
        return 5
    head_sha = ref.get("object", {}).get("sha")
    st, commit = api("GET", f"{API}/repos/{a.repo}/git/commits/{head_sha}", token)
    if st != 200 or not isinstance(commit, dict):
        print(f"!! 拿不到 head commit (HTTP {st})")
        return 6
    base_tree = commit.get("tree", {}).get("sha")

    # 为每个文件建 blob
    tree_items = []
    for remote, raw in updates:
        st, blob = api("POST", f"{API}/repos/{a.repo}/git/blobs", token,
                       {"content": base64.b64encode(raw).decode("ascii"),
                        "encoding": "base64"})
        if st not in (200, 201):
            print(f"!! 建 blob 失败 {remote} (HTTP {st}): {blob}")
            return 7
        tree_items.append({"path": remote, "mode": "100644", "type": "blob",
                           "sha": blob["sha"]})

    st, tree = api("POST", f"{API}/repos/{a.repo}/git/trees", token,
                   {"base_tree": base_tree, "tree": tree_items})
    if st not in (200, 201):
        print(f"!! 建 tree 失败 (HTTP {st}): {tree}")
        return 8

    names = ", ".join(r for r, _ in updates)
    msg = a.message or f"更新 {names}"
    st, newcommit = api("POST", f"{API}/repos/{a.repo}/git/commits", token,
                        {"message": msg, "tree": tree["sha"], "parents": [head_sha]})
    if st not in (200, 201):
        print(f"!! 建 commit 失败 (HTTP {st}): {newcommit}")
        return 9

    st, res = api("PATCH", f"{API}/repos/{a.repo}/git/refs/heads/{branch}", token,
                  {"sha": newcommit["sha"], "force": False})
    if st not in (200, 201):
        print(f"!! 更新分支失败 (HTTP {st}): {res}")
        return 10

    print(f"✓ 一次提交了 {len(updates)} 个文件: {names}")
    print(f"  commit = {newcommit['sha'][:10]}")
    print(f"  https://github.com/{a.repo}/commit/{newcommit['sha']}")
    print("push 到 src/** 会自动触发 build-tweak 工作流。")
    print(f"看构建: https://github.com/{a.repo}/actions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
