# Development History

此文件记录对 server 目录的重要修改，供后续 AI 检阅。

---

## 2026-01-24: 修复 transfer_codebase_by_git_diff.sh

### 问题描述
1. 之前的 AI 修改导致脚本有bug，执行 `just up` 后本地的修改全部丢失（被reset）
2. 原脚本使用 `git diff` 无法识别新增的 untracked 文件和删除的文件
3. 脚本使用服务器别名（如 rec-server），不够直接

### 修复内容
1. **完全重写 `transfer_codebase_by_git_diff.sh`**
   - 不再使用服务器别名，直接使用环境变量 `$SERVER_IP`（默认：14.103.52.172）
   - 远端用户名固定为 `zhw`
   - 支持主仓库和所有子仓库（submodules）的变更检测
   - 使用 `git add -A` + `git diff --cached --binary` 来生成 patch，能正确识别：
     - 新增文件（untracked files）
     - 删除的文件
     - 修改的文件
     - 二进制文件
   - 生成 patch 后会恢复本地暂存区状态，不影响本地工作区
   - 远端应用 patch 前会 reset 远端的未提交更改并清理 untracked 文件

2. **更新 `justfile`**
   - `just up`: 执行 `./transfer_codebase_by_git_diff.sh`（无需参数）
   - `just sync-logs`: 执行 `./sync_server_logs.sh`

### 配置说明
脚本使用以下环境变量（均有默认值）：
- `SERVER_IP`: 远端服务器 IP（默认：14.103.52.172）
- `REMOTE_USER`: 远端用户名（默认：zhw）
- `LOCAL_PROJECT_DIR`: 本地项目路径（默认：$HOME/framework/server/）
- `REMOTE_PROJECT_DIR`: 远端项目路径（默认：/home/zhw/framework/server/）
- `SSH_KEY_PATH`: SSH 密钥路径（默认：$HOME/.ssh/id_rsa.pub）

### 使用方法
```bash
# 同步本地更改到远端服务器
just up

# 从远端服务器同步训练日志
just sync-logs
```

### 2026-01-24 14:57 修复远端路径

**问题**: `REMOTE_PROJECT_DIR` 默认使用了 `$HOME/framework/server/`，但 `$HOME` 会展开为本地用户路径 `/home/arc`，导致远端找不到目录。

**修复**: 将远端路径硬编码为 `/home/zhw/framework/server/`。

### 2026-01-24 15:00 修复 Git LFS 导致新增文件未应用

**问题**: 远端应用 patch 时，Git LFS 文件（如 .usd）触发 LFS smudge filter，因远端未配置 GitHub 凭据导致失败，进而导致整个 patch 应用不完整，新增的文件没有被创建。

**修复**: 在远端应用 patch 时设置 `GIT_LFS_SKIP_SMUDGE=1` 环境变量，跳过 LFS 文件的自动下载。patch 应用完成后重新启用 LFS。

**效果**: 
- 新增文件正常创建 ✅
- 删除文件正常删除 ✅
- 修改文件正常更新 ✅
- LFS 文件以 pointer 形式存在（需要时可手动 `git lfs pull`）

### 2026-01-24 15:09 自动传输 Git LFS 文件真实内容

**问题**: 虽然 patch 能应用成功，但 LFS 文件（如 .usd）在远端只是 pointer 文件，不是真实内容，导致程序运行时找不到文件。

**修复**: 
1. 在创建 patch 时，自动检测哪些文件是 LFS tracked 的
2. 收集所有新增或修改的 LFS 文件列表
3. patch 应用完成后，使用 `scp` 直接传输这些 LFS 文件的真实内容
4. 只传输本地已下载的真实文件（跳过本地也是 pointer 的文件）

**效果**: 
- LFS 文件自动传输为真实内容 ✅
- 无需远端配置 Git 凭据 ✅
- 远端可直接使用 USD 等资源文件 ✅

### 2026-01-24 15:12 添加 Tensorboard 端口映射命令

**新增**: `just tb-local-tunnel` 命令用于创建 SSH 隧道，将远端 Tensorboard 端口映射到本地。

**使用方法**:
```bash
just tb-local-tunnel 8008 7007 $SERVER_IP
# 将远端的 7007 端口映射到本地 8008 端口
# 然后在浏览器访问 http://localhost:8008
```

---
