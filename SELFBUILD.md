# runman-agent 自编译与发布指南 (NoUpdate Dev Build)

本文档说明 `flyingiq/runman-agent` 的定制自编译工作流、为什么需要自编译、与上游官方工作流的物理隔离策略、如何触发构建出包、显式版本直链下载方式、上游同步方案及上游/分发边界说明。

> 🚑 **只想快速把母鸡修好？** 直接看 [QUICKSTART.md](QUICKSTART.md) —— 5 分钟一键修复（含 30 秒自检、自动备份、SHA256 强校验与三条验收断言）。  
> 📊 **遭遇流量统计虚高或客户被超额误停？** 详见 [TRAFFIC-FIX.md](TRAFFIC-FIX.md) —— 30 秒自检、双层真因剖析、停机小鸡真值恢复与一键脚本。

---

## 0. 先说好处：装自编译版能得到什么（3 条，都带实测数据）

> 一句话：**官方包身上带着两个隐患 —— 会自己"半夜抖"、会把流量算虚高；自编译一次解决两个，代价只是"上游更新后手动同步一次"。**

### 好处 ① 永不自更 —— 服务不再半夜自己抖，版本永远可控

**原来会怎样**：官方二进制内置自更新逻辑，在 Debian 12 + Podman 4.x（或出口受限）的母鸡上会陷入**更新死循环**：反复拉包 → 反复重启 agent 服务 → CPU/IO 飙高、agent 周期性断连，客户端的端口转发时通时不通。

**装上之后**（源码级停更，代码依据见第 1 节）：

- 不会被官方新版本半夜替换掉 —— **你的机器只在你动手时才会变**
- 版本恒定、行为可复现 —— 排障少一个变量，少一半折腾
- 自己合进去的修复**永远不会被覆盖后复发**

### 好处 ② 带上官方还没合的修复 —— 不用等排期，现在就能止血

**原来会怎样**：上游 `main` 至今不含流量统计修复（commit `a90e183`）。在 Debian 12 + Podman 4.x 母鸡上实测：

- 空转实例流量虚高最高 **182 倍**，客户实例最高 **23.5 倍**
- 数据库流量以 **+4390 MB/分钟** 疯涨（而真实带宽只有 24 KB/s）
- 平台按超额策略把客户实例**直接误判停机** → 客户流失、退款、口碑受损

**装上之后**：修复提前合进二进制，实测从 **+4390 MB/分钟 收敛到 +2.9 MB / 2 分钟（约 3000 倍）**，计量回归物理真值，不再误杀。

### 好处 ③ 控制权在自己手里 —— 上游节奏不再绑架你的业务

- **源码在手**：出问题自己改、推个 tag 自己出包（CI 约 2 分钟出产物）
- **commit 可追溯**：永远知道线上跑的是哪个版本（本仓库当前产物对应 `a90e183`）
- **零额外成本**：用 GitHub Actions 免费额度出包，不需要买 CI、不需要本地 Go 环境

### 代价（也讲清楚，不吹）

1. 上游更新后要**手动同步一次**（Sync fork → 重打 tag → 重新出包，见第 5 节）
2. 出包时**必须记得带上修复补丁**，否则等于"切了自更但人还是病的"（第 1 节已给出强制要求）

---

## 1. 为什么自编译（源码级彻底停更机制与核心补丁注入）

- **上游自动更新机制**：上游 `runman-agent` 内置自动更新服务（`updater/updater.go`）。当构建时通过 `-ldflags "-X main.version=...\"` 注入版本号（如 release tag 或 commit SHA）时，Agent 会定期比对并从上游 Releases 强制下载新二进制覆盖本地文件并重启。这会导致定制修复（例如 Podman 4 流量统计补丁）被强行覆写，严重时导致崩溃死循环。
- **源码级停更防御**：根据 `updater/updater.go` 第 94-98 行代码：
  ```go
  // 如果是开发版本，不执行自动更新
  if s.currentVer == "dev" || s.currentVer == "" {
      log.Printf("[Updater] Dev version detected, auto-update disabled")
      return
  }
  ```
  在 `main.go` 中，默认 `var version = "dev"`。
  只要编译参数中**严禁注入 `-X main.version`**，二进制内部版本恒定为 `"dev"`。更新服务在启动时即直接返回退出，从源码逻辑上彻底阻断更新器运行与回滚。
- **自编译关键修复补丁注入**：
  官方主线代码存在流式 stats 误用与计数器回退重加缺陷，导致 Debian 12 节点流量虚高数十倍（触发超额停机）。自编译分支必须包含 commit `a90e183`（流量修复补丁），否则产出的二进制虽然切断了自更，但仍存在严重的计量失真隐患。

---

## 2. 与上游 release.yml 的隔离策略（防撞车与防覆写机制）

Fork 仓库中同时存在上游自带的 `.github/workflows/release.yml` 与定制的 `.github/workflows/build-noupdate.yml`，必须通过双重隔离机制确保构建与分发安全：

### 工作流职责与分工矩阵

| 维度 | 上游官方工作流 (`release.yml`) | 自编译停更工作流 (`build-noupdate.yml`) |
| :--- | :--- | :--- |
| **触发条件** | `push: branches: [main]`, `tags: ['v*']` | `push: tags: ['dev-v*']`, `workflow_dispatch` |
| **构建参数** | 注入 `-X main.version=${build_version}` | **严禁 `-X main.version`**（构建前强制断言） |
| **内置版本** | 注入具体版本号（激活更新器） | 恒定为原生 `"dev"`（更新器自动退出） |
| **发布资产名** | `runman-agent-linux-amd64`<br>`runman-agent-linux-arm64`<br>`SHA256SUMS` | `runman-agent-linux-amd64-dev`<br>`runman-agent-linux-arm64-dev`<br>`SHA256SUMS-dev` |
| **Artifact 命名**| `runman-agent-linux-amd64` 等 | `runman-agent-dev-binaries-dev` |

### 误维护时的“拼车”撞车风险与后果

1. **触发冲突（拼车）**：若自编译工作流同样监听 `'v*'`，推送形如 `v0.3.3` 的标签时，上游 `release.yml` 和定制 `build-noupdate.yml` 会被**同时触发**。
2. **资产覆盖与致命后果**：两个工作流会竞争推送到同一个 Release。若上游官方构建版本覆盖了 dev 版本，下载方拉取到的将是携带 `-X main.version` 的官方自更新二进制。Agent 运行后检测到更新，立即下载官方 release 覆盖本地，重新陷入崩溃/死循环。
3. **双重隔离防御方案**：
   - **第一道防线（Tag 命名空间物理隔离）**：自编译工作流严格限定 `push: tags: ['dev-v*']`。上游配置的 `'v*'` 通配符无法匹配以 `dev-` 开头的字符串，在 Actions 调度层面实现绝对物理隔离。
   - **第二道防线（资产名命名空间隔离）**：自编译产物一律附加 `-dev` 后缀（`runman-agent-linux-{amd64,arm64}-dev` 与 `SHA256SUMS-dev`），杜绝任何资产重名覆盖可能。

---

## 3. 构建与发布流程

工作流配置文件位于 `.github/workflows/build-noupdate.yml`（暂存备份：`build-noupdate.yml`）。

### 方式 A：打 Tag 触发发布（自动创建 GitHub Release）

当需要正式发布新版本供部署脚本拉取时，在本地仓库打 Tag 并推送到 GitHub（**必须使用 `dev-v*` 命名空间**）：

```bash
# 示例：创建并推送 dev-v0.3.3 标签
git tag dev-v0.3.3 && git push origin dev-v0.3.3
```

- **工作流行为**：
  1. 检出代码并配置 Go 环境；
  2. 自检断言验证构建参数未包含 `-X main.version`；
  3. 编译产出 `runman-agent-linux-amd64-dev` 与 `runman-agent-linux-arm64-dev`；
  4. 产出并打印 `SHA256SUMS-dev`；
  5. 上传 Workflow Artifact（命名为 `runman-agent-dev-binaries-dev`，留存 30 天）；
  6. 识别到 `github.ref_type == 'tag'`，自动创建对应的 GitHub Release 并将两个架构二进制与 `SHA256SUMS-dev` 作为 Release Assets 上传发布。

### 方式 B：手动触发测试（workflow_dispatch）

当仅需测试构建、验证代码改动而不需要发布正式 Release 时：

1. 打开 GitHub 仓库页面：`https://github.com/flyingiq/runman-agent`；
2. 点击 **Actions** 标签页；
3. 在左侧选择 **Build NoUpdate dev binary**；
4. 点击右侧 **Run workflow** 下拉按钮，选择分支（如 `main`），点击绿色 **Run workflow**。
- **工作流行为**：只产出 Artifact 供下载测试，因 `github.ref_type == 'branch'`，**绝对不会创建 Release**，防止误发版。

---

## 4. Release 直链下载（显式版本 URL）

编译发布完成后，可通过 GitHub Release 稳定直链直接获取二进制与校验和（适用于部署脚本 `--from-url` 参数拉取）：

### 为什么弃用 latest 直链

GitHub 的 `/releases/latest` 别名会解析为仓库中“最新创建且未标记为 Prerelease”的 Release。在 Fork 仓库场景下：
- 上游同步或后续触发官方工作流时可能生成新的官方 Release；
- `latest` 指针可能被官方发布抢占，导致部署脚本意外下载到包含自更新逻辑的官方包，破坏停更机制；
- `latest` 缺乏版本确定性与可复现性。

因此，**全流程彻底弃用 `releases/latest`，统一改用确定性的显式版本 URL**。

### 显式版本直链格式（以当前最新 `dev-v0.3.3-trafficfix` 为例）

- **linux/amd64 直链**：
  ```
  https://github.com/flyingiq/runman-agent/releases/download/dev-v0.3.3-trafficfix/runman-agent-linux-amd64-dev
  ```
  - **SHA256**: `8c317d43ce953637fc7f4f68ebff3b85a5e4433443fed18567420c5020f4f61c`
- **linux/arm64 直链**：
  ```
  https://github.com/flyingiq/runman-agent/releases/download/dev-v0.3.3-trafficfix/runman-agent-linux-arm64-dev
  ```
  - **SHA256**: `a7c7b34ff4ee6e1946ce0a47ea37cee80650924c5a36d15a9b6e81a5fcb98522`
- **SHA256 校验和直链**：
  ```
  https://github.com/flyingiq/runman-agent/releases/download/dev-v0.3.3-trafficfix/SHA256SUMS-dev
  ```

> ℹ️ **节点网络连通性说明**：
> JP-acck 母鸡历史配置的 `/etc/hosts` 阻断（`127.0.0.1 github.com`）已于 2026-09-22 彻底移除。目前 4 台母鸡节点均可直连 GitHub 访问 Release 资产。
> 作为纵深防御策略，批量部署脚本与分发逻辑仍保留本地文件传输（如 scp/rsync）与本地镜像回退路径，以应对偶发公网抖动。

### 辅助途径：Actions Artifact 下载

在 GitHub Actions 每次运行（含 `workflow_dispatch` 手动测试）的 Summary 页面底部，可直接下载打包好的 `runman-agent-dev-binaries-dev.zip`。

---

## 5. 与上游代码同步方案 (Fork Sync)

当上游仓库（`narwhal-cloud/runman-agent`）有新功能或安全修复时，可按以下步骤同步：

### 方案 1：GitHub Web 界面一键同步（最便捷）

1. 访问 Fork 仓库主页：`https://github.com/flyingiq/runman-agent`；
2. 在分支信息栏下方找到 **Sync fork** 按钮；
3. 点击 **Update branch** 即可自动 Fast-forward 合并上游提交。

### 方案 2：GitHub REST API 调用（支持自动化）

通过 GitHub 的 upstream 合并接口直接触发同步：

```bash
curl -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ***" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/flyingiq/runman-agent/merge-upstream \
  -d '{"branch":"main"}'
```

- **所需 Token 权限**：
  - Classic PAT：需勾选 `repo` 作用域（若仅针对公开仓库可为 `public_repo`）；
  - Fine-grained PAT：需对 `flyingiq/runman-agent` 仓库授予 `Contents` 读写权限（`Contents: Read and write`）。

同步完成后，推送新的 Tag（如 `dev-v0.3.4`）或在 Actions 页面点击手动触发，即可一键获得合并上游最新代码后的 dev 版二进制。

> ⚠️ **出包铁律：务必合入流量修复补丁**  
> 上游官方代码目前尚未合入流量统计修复补丁，若直接基于上游 `main` 出包，产物仍会受到“流式 stats 瞬时帧 + 计数器回退全量重加”影响，导致流量虚高 3~182 倍！  
> 在推送新 Tag 前，务必确认当前构建分支已 cherry-pick 或合并 commit `a90e183`（或应用 `traffic-fix.patch`），并通过 `go test ./traffic/... ./db/...` 验证。详情见 [TRAFFIC-FIX.md](TRAFFIC-FIX.md)。

---

## 6. 关于上游与分发

- 上游项目 `narwhal-cloud/runman-agent` 为**开源项目**；本仓库是它的 **Fork**，并在其源码基础上做了自编译与补丁增强。
- 本仓库发布的二进制均为**自编译产物**（非上游官方发布物），仅供自用及同环境站长参考；部署前请自行评估，并按各自规范做好备份。
- 如需将本仓库产物对外二次分发，请以你与上游作者之间的实际约定为准。

---

## 7. 仓库写入权限说明（实操踩坑）

若通过 GitHub MCP 集成（GitHub App 安装令牌）推送，**修改 `.github/workflows/` 目录下的文件需要额外的 `Workflows` 权限**；权限不足时写入工作流文件会返回：

```
403 Resource not accessible by integration
```

因此本套件提供两处镜像文件：

- **暂存/分发副本（Contents 权限即可写入）**：`build-noupdate.yml`
- **生效工作流路径（需 Workflows 权限）**：`.github/workflows/build-noupdate.yml`

**网页端一分钟落地（推荐）**：

1. 打开 `https://github.com/flyingiq/runman-agent/upload/main`；
2. 将本地 `build-noupdate.yml` 拖入上传区；
3. 在文件名输入框中把路径补全为 `.github/workflows/build-noupdate.yml`；
4. 点 **Commit changes**。此后 Actions 页签即可看到该工作流。

**或**在 GitHub App 安装设置中为该集成勾选 `Workflows: Read and write`，之后即可由 MCP 直接维护。
