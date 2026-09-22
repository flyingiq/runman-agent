# Fork 后必做：静默上游 release.yml 的 main 分支触发

> **一句话**：Fork 这类仓库后，上游自带的 `.github/workflows/release.yml` 默认监听 `push: branches: [main]`，你每次往 main 推文档都会触发一次多架构交叉编译并发布 `continuous` 预发布 —— 既产生 CI 噪音，又可能和你的自编译流水线抢跑。处置方式见下（实测验证过）。

## 1. 背景与目标
上游官方 `.github/workflows/release.yml` 默认监听了 `push: branches: [main]`，导致本 fork 仓库每次向 main 分支推送更新或文档时，都会自动触发耗时的多架构交叉编译并发布 `continuous` 预发布，产生不必要的 CI 噪音，并与本 fork 的自编译流水线抢跑。
本次任务对 `.github/workflows/release.yml` 进行最小化修改，彻底移除 `push: branches: [main]` 触发，保留 `push: tags: ['v*']` 与 `workflow_dispatch:`，推送到 main 分支并进行双重验证。

## 2. 修改前 `on:` 配置原文
```yaml
on:
  push:
    branches:
      - main
    tags:
      - 'v*'
  workflow_dispatch:
```

## 3. 变更 Diff 与提交信息
- **提交 SHA**: `cc81f9e3716f972c003b7094eecb3945d8a4e361` (推送前基线: `cb196ac081b8383bbe841d18f99a0b1a8604db35`)
- **提交信息**: `ci: 禁用 release.yml 的 main 推送触发，消除与自编译流水线抢跑噪音`
- **修改文件**: `.github/workflows/release.yml` (独占修改，未碰仓库任何其余文件)

```diff
diff --git a/.github/workflows/release.yml b/.github/workflows/release.yml
index 5ae9e41..ade5574 100644
--- a/.github/workflows/release.yml
+++ b/.github/workflows/release.yml
@@ -2,8 +2,7 @@ name: Release
 
 on:
   push:
-    branches:
-      - main
+    # 本 fork 已禁用 main 推送触发，避免与自编译流水线抢跑
     tags:
       - 'v*'
   workflow_dispatch:
```

## 4. 本地语法与规则校验
- **YAML 校验命令**:
  ```bash
  python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml')); print('YAML OK')"
  ```
  输出：`YAML OK`
- **Grep 规则断言**:
  - `grep "branches"`: 无任何匹配 (Clean)
  - `grep "workflow_dispatch"`: 第 8 行存在 `workflow_dispatch:`
  - `grep "tags"`: 第 6 行保留 `tags: - 'v*'`

## 5. 推送结果
```
To github.com:flyingiq/runman-agent.git
   cb196ac..cc81f9e  main -> main
```

## 6. 验证结论

### 6.1 GitHub API 回读远端文件内容验证
调用 GitHub API (`/repos/flyingiq/runman-agent/contents/.github/workflows/release.yml?ref=main`) 回读：
- **远端 Blob SHA**: `ade5574c2f20838b3f01aceff9a53d69318d2b56` (与本地一致)
- **Base64 解码前 8 行**:
  ```yaml
  name: Release

  on:
    push:
      # 本 fork 已禁用 main 推送触发，避免与自编译流水线抢跑
      tags:
        - 'v*'
    workflow_dispatch:
  ```
- **断言结果**: `Has branches: False`, `Has workflow_dispatch: True`

### 6.2 Actions 运行列表对比 (等待 60 秒后回读)
对比推送前与推送 60 秒后的 `/actions/runs?per_page=5` 列表：
- **推送前最新运行**:
  - `ID: 35685217089 | Name: Release | Event: push | Head SHA: cb196ac | Status: completed | Conclusion: success | Created: 2026-09-22T04:00:21Z`
  - `Total count: 5`
- **推送后最新运行 (等待 60 秒后获取)**:
  - `ID: 35685217089 | Name: Release | Event: push | Head SHA: cb196ac | Status: completed | Conclusion: success | Created: 2026-09-22T04:00:21Z`
  - `Total count: 5`

**结论**：向 main 分支推送 commit `cc81f9e` 后，未触发任何 Release 工作流运行，静默降噪目标完全达成。
