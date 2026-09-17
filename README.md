# dsh-skill-github-publish

把本地开发的库 / 插件 / skill / 项目上传到 GitHub 的完整流程 skill：**判平台 → 拿凭据 → 建仓库 → 推代码 → 验结果**。

经过真实发布验证（dsh-plugin-memory-3t、dsh-skill-team-omo、dsh-plugin-scifi-ui、elastic-desktop-manager-wpf 均用此流程成功上传），本 skill 把每一步踩过的坑（两代环境的凭据来源、沙箱网络/TLS、GCM 崩溃、中文编码、token 误提交）固化成可复用指令。

## 核心流程

1. **判断环境** — `uname -s` / `$OS` 决定走 Linux 还是 Windows 分支（凭据与网络坑完全不同）
2. **前置检查** — git 状态 / 现有 remote / 提交身份 / 目标仓库名与可见性 / 当前分支
3. **凭据获取** — 环境变量 → `gh_token.txt`（仓库目录、`~/.config` 等）→ Windows 凭据管理器；找到后用 API 反查账号，不向用户索要用户名
4. **网络适配** — 默认直连；失败按症状降级：代理 / TLS 后端（openssl↔gnutls）/ IP+Host 头绕 DNS
5. **创建远程仓库** — `POST /api.github.com/user/repos`，幂等处理"已存在"
6. **推送** — `http.extraHeader` 携带一次性 Basic Auth，绕开无法弹窗的凭据助手；token 不写入 `.git/config`
7. **验证** — `ls-remote` + API 核对分支 / 可见性 / 最新提交

## 内置避坑

- **token 泄漏**：发布前检查 `gh_token.txt` 是否被跟踪、是否进 `.gitignore`，并扫描暂存区里的 token 字面量。
- **中文编码**：PowerShell 5.1 读取无 BOM 的 UTF-8 `.ps1` 按 GBK 解码 → 中文参数乱码（如「鏂板」）。规避：UTF-8 with BOM / `-F` 文件传参 / 用 pwsh 7。脚本自身输出保持 ASCII，避免控制台代码页问题。
- **凭据助手**：受限环境里 GCM 执行失败或无法弹窗，统一 `-c credential.helper=` + `GIT_TERMINAL_PROMPT=0`。
- **陈旧代理**：老环境留下的 `http.proxy=127.0.0.1:34210` 会让 push 卡死几十秒，用 `-c http.proxy=` 覆盖。
- **提交身份**：全局身份是占位符时提交不会算到你的 GitHub 账号上，需按仓库覆盖。

## 使用方式

用户说"传到 / 同步 / 发布 / 推到 GitHub"、给本地项目建远程仓库时触发。主流程见 `SKILL.md`；可复用脚本：

- `references/publish-github.sh` — **Linux / macOS / WSL / Git-Bash** 一键发布（解析 token → 查账号 → 建仓 → 配 origin → 提交 → push → 验证）
- `references/publish-github.ps1.template` — **Windows 原生**一键发布（凭据管理器 `CredRead` 读取）
- `references/gh-api.mjs` — GitHub API 小工具：`whoami` / `create` / `get` / `patch` / `commits` / `delete`

```bash
# Linux/macOS/WSL/Git-Bash
references/publish-github.sh --dir ~/proj --private --desc "一句话简介" --message "feat: init"
references/publish-github.sh --dir ~/proj --dry-run          # 只做环境/凭据/网络体检
```

```powershell
# Windows
.\references\publish-github.ps1.template -RepoDir "D:\path\to\repo" -Private
```

## 凭据文件（`gh_token.txt`）

按顺序查找，命中即用：`$GH_TOKEN` / `$GITHUB_TOKEN` 环境变量 → `--token-file` → `<仓库>/gh_token.txt` → `$PWD/gh_token.txt` → `~/.config/gh_token.txt` → `~/.dsh/gh_token.txt` → `~/gh_token.txt` → Windows 凭据管理器。

```bash
printf '%s\n' 'ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' > ~/.config/gh_token.txt
chmod 600 ~/.config/gh_token.txt
```

token 需要 `repo` scope（要改 workflow 文件再加 `workflow`）。**这个文件永远不要提交**。

## 仓库结构

```
dsh-skill-github-publish/
├── SKILL.md                              # 主流程指令
├── README.md
└── references/
    ├── publish-github.sh                 # Linux/macOS/WSL/Git-Bash 一键发布
    ├── publish-github.ps1.template       # Windows 一键发布模板
    └── gh-api.mjs                        # GitHub API 小工具（whoami/create/get/patch/commits/delete）
```

## License

MIT
