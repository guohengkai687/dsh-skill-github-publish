# dsh-skill-github-publish

把本地开发的库 / 插件 / skill / 项目上传到 GitHub 的完整流程 skill：**拿凭据 → 建仓库 → 推代码 → 验结果**。

经过真实发布验证（dsh-plugin-memory-3t、dsh-skill-team-omo 均用此流程成功上传），本 skill 把每一步踩过的坑（凭据读取、沙箱网络/TLS、GCM 崩溃、中文编码）固化成可复用指令。

## 核心流程

1. **前置检查** — git 状态 / 现有 remote / 提交身份 / 目标仓库名与可见性
2. **凭据获取** — 从 Windows 凭据管理器读取 GitHub OAuth token（不向用户索要密码；读取失败才询问并 `cmdkey` 落库）
3. **网络适配** — 沙箱内 schannel 后端不可用时改用 `http.sslBackend=openssl` + 本地代理；GitHub API 走 Node fetch + `NODE_USE_ENV_PROXY`
4. **创建远程仓库** — `POST /api.github.com/user/repos`，幂等处理"已存在"
5. **推送** — `http.extraHeader` 携带 Basic Auth，绕开沙箱内无法弹窗的 GCM；token 不写入 `.git/config`
6. **验证** — `ls-remote` + API 核对分支/可见性/最新提交

## 内置避坑

- **中文编码**：PowerShell 5.1 读取无 BOM 的 UTF-8 脚本按 GBK 解码 → 中文 git 参数乱码（如「鏂板」）。规避：UTF-8 with BOM / `-F` 文件传参 / 用 pwsh 7。
- **凭据**：GCM 在受限沙箱内执行失败（信号管道权限），不依赖 credential helper。
- **网络**：直连 GitHub 连接重置，须走本机代理。

## 使用方式

用户说"传到 / 同步 / 发布 / 推到 GitHub"、给本地项目建远程仓库时触发。主流程见 `SKILL.md`；可复用脚本：

- `references/publish-github.ps1.template` — 一键发布（凭据读取 + 建仓 + push + 验证）
- `references/create-repo.mjs` — 仅建仓（幂等）

## 仓库结构

```
dsh-skill-github-publish/
├── SKILL.md                          # 主流程指令
└── references/
    ├── create-repo.mjs               # Node 建仓脚本
    └── publish-github.ps1.template   # 一键发布脚本模板
```

## License

MIT