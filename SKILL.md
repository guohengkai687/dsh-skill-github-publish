---
name: dsh-skill-github-publish
description: 把本地开发的库/插件/skill/项目上传到 GitHub 的完整流程：先判断当前是 Linux 还是 Windows 环境，再拿凭据（Linux 读 gh_token.txt，Windows 读凭据管理器）→ 探测网络与代理 → 通过 GitHub API 创建远程仓库 → 配置 origin → push → 验证。当用户说"传到 GitHub 上""同步/发布/推到 github"、把本地项目/仓库/插件/skill 上传、创建 GitHub 仓库并推送代码、发布开源库、或给本地东西建远程仓库时，务必使用本 skill，即使没有明说"skill"或"上传"两个字；本地已有 git 仓库要加远程、或远程仓库要重命名/换可见性也在范围内。简单浏览 GitHub 页面、clone 别人仓库、给现有远程仓库追加提交不属于本 skill 的触发场景。
---

# dsh-skill-github-publish：把本地库发布到 GitHub

一个经过真实验证的完整流程（dsh-plugin-memory-3t、dsh-skill-team-omo、dsh-plugin-scifi-ui、
elastic-desktop-manager-wpf、本 skill 自身），把本地开发目录变成 GitHub 上的公开/私有仓库。
核心是四步：**拿凭据 → 建仓库 → 推代码 → 验结果**。

平台差异集中在头两步：凭据在哪、网络怎么走。所以**先判平台，再走对应分支**，别把 Windows 的
经验（凭据管理器 / schannel / GBK）生搬到 Linux，反之亦然——两边踩的坑几乎不重叠。

## 第 0 步：判断环境（必做，决定后面怎么走）

```bash
uname -s              # Linux / Darwin / MINGW64_NT-* / MSYS_NT-* / CYGWIN_NT-*
echo "$OS"            # Windows_NT（Windows Git Bash 里）
command -v powershell.exe cmdkey      # 存在 => Windows 侧能力可用
```

| 判据 | 平台分支 | 凭据来源 | 一键脚本 |
| --- | --- | --- | --- |
| `Linux`（含 WSL）/ `Darwin` | **Linux 路径**（本文主流程） | `gh_token.txt` 文件 > 环境变量 | `references/publish-github.sh` |
| `MINGW*` / `MSYS*` / `CYGWIN*`，或 `$OS=Windows_NT` | **Windows 路径** | `gh_token.txt` 文件 > 凭据管理器 | `references/publish-github.ps1.template` |

两套脚本的步骤与输出完全对齐（`REPO_CREATED` / `PUSH_OK` / `DONE <url>`），token 解析顺序也一致，
所以"先文件后系统凭据"的行为跨平台统一。WSL 同时具备两边能力：优先用 `.sh`（Linux 路径），
只有需要读 Windows 凭据管理器时才回退到 `powershell.exe`。

## 第 1 步：前置检查

1. **git 仓库**：`git -C <目录> status`；不是仓库则 `git init -b master` + 首次提交。
2. **现有 remote**：`git -C <目录> remote -v`。已有 origin = 之前发过，走「更新模式」，不要重复建仓。
3. **提交身份**：`git -C <目录> config user.name` / `user.email`。身份缺失或明显是占位符
   （如全局的 `Sisyphus <sisyphus@llm-wiki.local>`）时必须按仓库覆盖：
   `git -C <目录> config user.name <GitHub 昵称>` + `config user.email <邮箱>`。
   GitHub 会把提交挂到"能匹配上的"账号，占位身份会让你以为推成功了、但贡献图是别人的。
4. **仓库名与可见性**：仓库名默认 = 目录名；public/private 拿不准就问用户，别臆断。
5. **当前分支**：`git -C <目录> branch --show-current`——push 的目标分支以它为准，不要硬编码 main/master。

## 第 2 步：拿凭据（Linux：gh_token.txt；Windows：文件 > 凭据管理器）

**绝不要一上来就问用户要 token**，先按下面的顺序自己找：

1. 环境变量 `GH_TOKEN` / `GITHUB_TOKEN`（CI 或临时注入，优先级最高）
2. `$GH_TOKEN_FILE` 指定的文件
3. **`<目标仓库>/gh_token.txt`**（最常见的放法：token 文件就放在要发布的仓库根目录）
4. `$PWD/gh_token.txt`
5. `~/.config/gh_token.txt`
6. `~/.dsh/gh_token.txt`、`~/gh_token.txt`
7. Windows：`git:https://<user>@github.com` / `git:https://github.com` 凭据管理器条目
   （见 `references/publish-github.ps1.template` 里的 `CredRead` P/Invoke 代码；只有 Windows 才有这一步）

文件解析要容忍真实世界里的小脏东西（这些都是踩过的）：行尾 CRLF/BOM、值被引号包住、
写成 `GH_TOKEN=ghp_xxx`、文件里有多行或注释。取**第一个形如 token 的值**：

```bash
TOKEN=""
for f in "${GH_TOKEN_FILE:-}" "<目标仓库>/gh_token.txt" "$PWD/gh_token.txt" \
         "$HOME/.config/gh_token.txt" "$HOME/.dsh/gh_token.txt" "$HOME/gh_token.txt"; do
  [ -n "$f" ] && [ -f "$f" ] || continue
  while IFS= read -r line; do
    v="${line%$'\r'}"; v="${v#$'\xef\xbb\xbf'}"
    v="${v##*[=: ]}"; v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    case "$v" in
      gh[pousr]_*|github_pat_*|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        TOKEN="$v"; break 2;;
    esac
  done < "$f"
done
[ -n "$TOKEN" ] && echo "token found: ${TOKEN:0:4}…(${#TOKEN} chars)"
```

**不要打印完整 token**（会话记录、日志、shell history 都会留痕），只报前缀 + 长度。

- 找到后用 API 反查账号，别让用户手填用户名：`GET https://api.github.com/user` → `.login`
  （本 skill 的 `gh-api.mjs whoami` 就是干这个的）。这样"用户名"永远和 token 的真实归属一致。
- 顺手检查文件权限：`ls -l <token文件>`，group/other 可读就 `chmod 600`（同机多用户环境）。
- **找到后必须确认它不会被提交**：`git check-ignore -v gh_token.txt`，没被忽略就把它追加进
  `<目标仓库>/.gitignore`。`gh_token.txt` 一旦进了 git 历史，即使后来删除也能被翻出来，
  只能 revoke 重发。发布前再扫一遍暂存区：
  `git diff --cached | grep -nE 'gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'` —— 命中就停下。
- 全都没有才问用户要 token，并**帮用户落盘**：Linux `install -m 600 /dev/stdin ~/.config/gh_token.txt`；
  Windows `cmdkey /generic:git:https://<user>@github.com /user:<user> /pass:<token>`，下次自动可用。

## 第 3 步：网络（默认直连，按症状降级）

**先直连再谈代理**。两代环境的经验是相反的：Windows 沙箱里往往必须走代理，而 Linux 本机通常直连就通
（`curl https://api.github.com` 返回 200 即 OK）；反过来照搬旧代理设置，会连到一个已经关掉的
`127.0.0.1:34210` 上，表现为卡死几十秒后超时。

```bash
curl -sS -o /dev/null -w 'api=%{http_code} %{time_total}s\n' --max-time 15 https://api.github.com/
git -C <目录> ls-remote https://github.com/<user>/<repo>.git   # 128 + "could not read Username" = 仓库不存在（正常）
env | grep -iE '^(https?|all)_proxy='                          # 有代理变量才考虑用
```

按探测结果选路径：

| 症状 | 处置 |
| --- | --- |
| api 200，`ls-remote` 正常 | 直连，什么都不用加 |
| 环境里就有 `HTTPS_PROXY`/`ALL_PROXY` 且直连失败 | 显式用它：`-c http.proxy=$HTTPS_PROXY`，Node 侧加 `NODE_USE_ENV_PROXY=1` |
| 卡死/超时，但某个 GitHub IP 可达 | DNS 被墙场景：走 **IP + Host 头**（见下） |
| TLS 报错（`SEC_E_NO_CREDENTIALS`、证书校验失败） | 换 TLS 后端：`-c http.sslBackend=openssl`；Linux 的 gnutls-only git 不认 openssl，要用 `gnutls`；Windows 沙箱里 curl/PowerShell 的 schannel 会挂，改用 Node `fetch` |
| 提示连不上代理 | `.git/config` 里多半有**陈旧 `http.proxy` 残留**，用 `-c http.proxy=` 覆盖为空并清掉 `*_proxy` 环境变量 |

IP + Host 头绕行（GitHub 官方北美 IP 实测可达；**不要采信 DoH 返回的第一个 A 记录**，它可能正好是挂掉的那台）：

```bash
IP=140.82.112.3                    # 备选：140.82.113.3 / 140.82.114.3 / 140.82.121.3
git -C <目录> -c http.extraHeader="Host: github.com" \
  -c http.extraHeader="Authorization: Basic $BASIC" \
  push https://$IP/<user>/<repo>.git <branch>:<branch>
```

TLS 仍按域名 `github.com` 做 SNI/证书校验，所以 `ssl_verify_result=0` 是正常的，不算降级。

## 第 4 步：创建远程仓库（幂等）

用 GitHub API，不要手点网页：

```bash
GH_TOKEN="$TOKEN" node references/gh-api.mjs create --name <repo> [--private] --desc "<一行简介>"
# REPO_CREATED <owner>/<repo>   或   REPO_EXISTS <owner>/<repo>
```

- `POST /user/repos`，`422 + name already exists` 视为成功（幂等），脚本已内置。
- 简介从用户意图或项目 README 提炼一行；没有就写通用描述。
- 描述等非 ASCII 内容走 **UTF-8 文件/独立 .mjs**，不要内联进 `powershell -Command`（见踩坑表）。

## 第 5 步：配置 remote 并 push

```bash
git -C <目录> remote remove origin 2>/dev/null
git -C <目录> remote add origin https://github.com/<user>/<repo>.git
```

**remote URL 里绝对不要写 token**（`https://user:token@github.com/...`）：它会落进 `.git/config`，
并在 `git remote -v`、报错信息、`branch.<name>.remote` 里反复出现。认证统一走一次性头：

```bash
BASIC=$(printf '%s:%s' "<user>" "$TOKEN" | base64 | tr -d '\n')
GIT_TERMINAL_PROMPT=0 git -C <目录> \
  -c credential.helper= -c http.extraHeader="Authorization: Basic $BASIC" \
  push -u origin <branch>
```

- `-c credential.helper=` + `GIT_TERMINAL_PROMPT=0`：禁用一切凭据助手与交互提示，
  受限沙箱里（GCM 无法弹窗、没有 tty）不会挂住，失败就直接失败。
- 分支用 `git branch --show-current` 的真实值；`-u` 让后续 `git push` 不必再带参数。
- 中文提交信息：写进 UTF-8 文件后 `git commit -F <file>`，别内联 `-m`。
- 首推后建议顺手补 README / LICENSE（LICENSE 与同账号其他仓库保持一致，如 MIT）。

## 第 6 步：验证（必须做，别信"命令没报错"）

1. `git -C <目录> -c http.extraHeader="Authorization: Basic $BASIC" ls-remote origin` —— 能看到 refs 即通。
2. `node references/gh-api.mjs get --repo <owner>/<repo>` 核对 `private=`、`default_branch=`；
   `node references/gh-api.mjs commits --repo <owner>/<repo> --branch <branch>` 核对最新 commit 与本地一致。
3. 向用户汇报：仓库 URL、可见性、推了哪个分支/标签、怎么验证的。

## 一键脚本

```bash
# Linux / macOS / WSL / Git-Bash
references/publish-github.sh --dir ~/proj [--repo name] [--desc "简介"] [--private] \
                             [--branch master] [--message "提交说明"] [--token-file ~/.config/gh_token.txt]
```

```powershell
# Windows 原生（pwsh 7 优先）
.\publish-github.ps1.template -RepoDir "D:\path\to\repo" -RepoName "my-repo" -Private
```

两个脚本都完成「解析 token → 查账号 → 建仓 → 配 origin → （可选）提交 → push → ls-remote 验证」，
最后打印 `DONE https://github.com/<user>/<repo>`。`--dry-run` 只做平台/凭据/API 体检并打印计划，
不改动远程仓库和本地仓库。

## 踩坑表（跨平台高频事故）

| 事故 | 真实原因 | 规避 |
| --- | --- | --- |
| token 被提交进仓库 | `gh_token.txt` 没进 `.gitignore`，`git add -A` 一把梭 | 发布前 `git check-ignore -v gh_token.txt` + 扫暂存区；已提交则**立即 revoke**再重写历史 |
| 中文提交信息变「鏂板」 | PowerShell 5.1 按 ANSI(GBK) 解码无 BOM 的 UTF-8 `.ps1` | `.ps1` 存 UTF-8 with BOM / 用 pwsh 7 / 中文参数一律 `git commit -F` |
| push 卡死几十秒后超时 | 环境变量或 `.git/config` 里残留已关闭的代理 | 先看 `git config --get http.proxy` 和 `env \| grep -i proxy`，再用 `-c http.proxy=` 覆盖 |
| `error: could not read Username` | 没有可用凭据助手，或 extraHeader 没生效 | 带上 `Authorization: Basic <b64>` 头；仓库不存在时也是这个报错，属正常 |
| TLS/证书类报错 | Windows schannel 在沙箱取不到证书存储；Linux gnutls-only git 不认 openssl 后端 | 按平台换后端；API 调用优先 Node `fetch`（自带 OpenSSL） |
| 提交算不到自己账号 | 全局身份是占位符（如 `Sisyphus <sisyphus@llm-wiki.local>`） | 按仓库 `git config user.name/email` 覆盖成 GitHub 账号 |
| 401/403 认证或权限失败 | token 过期或 scope 不足（发布需要 `repo`，推 workflow 文件还需 `workflow`，删除仓库另需 `delete_repo`） | 先跑 `gh-api.mjs whoami` 验证；scope 不够就换 token，或改用网页 UI |

## 参考脚本

| 文件 | 用途 |
| --- | --- |
| `references/publish-github.sh` | **Linux/macOS/WSL/Git-Bash 一键发布**（本 skill 主路径） |
| `references/publish-github.ps1.template` | Windows 原生一键发布（含凭据管理器 `CredRead` 读取） |
| `references/gh-api.mjs` | GitHub API 小工具：`whoami` / `create` / `get` / `patch` / `commits` / `delete` |
