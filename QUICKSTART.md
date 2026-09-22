# Runman / Narwhal Agent 5分钟自更死循环根治指南

适用场景：Debian 12 母鸡 Agent 陷入重启风暴、带宽被测速打满、租户断连。

---

## 1. 30 秒自检（是否中招）

在宿主机直接粘贴运行以下自检命令：

```bash
# 查看 Agent 累计重启次数（正常机应为 0 或固定不变；中招机持续递增）
systemctl show narwhal-agent -p NRestarts --value

# 查看最近日志中是否存在退出更新与 92MB 测速循环特征
journalctl -u narwhal-agent -n 50 --no-pager | grep -E "exiting for update|speed.cloudflare.com"
```

**典型症状**：Agent 陷入 6~15 秒一轮重启死循环（实测累计最高 2470 次），小鸡业务端口全断，每次重启硬拉 92MB Cloudflare 测速包打满宿主出口带宽。

---

## 2. 一句话原理与职责边界

- **根本原因**：官方 `install.sh` 硬要求 Podman ≥ 5.4.2，Debian 12 自带 4.3.1 导致脚本 `exit 1` 中断；同时官方二进制注入了 `-X main.version`，运行后强制从 Release 拉取新版覆写自身。
- **根治机理**：自编译 Dev 版构建时**未注入** `-X main.version`，内部版本恒为 `"dev"`。源码 `updater/updater.go` 命中 `currentVer == "dev"` 立即 return，**永久停更**；且已合并上游 commit `0da61a1`，彻底修复 Debian 12 Podman 4.x 租户流量归零问题。
- **职责边界**：平台负责凭证鉴权与容器生命周期调度；Agent 负责本地 Podman 管理与状态上报。Dev 版仅切断本地 updater 覆写，平台 gRPC 调度 100% 兼容。官方基建（XFS pquota、udev direct_io、BBR、token 注册）仍需基建脚本打底。

---

## 3. 一键修复命令块（直接复制执行）

整段复制到母鸡终端执行。命令包含自动备份、SHA256 强校验与只读防篡改加锁：

```bash
# 1. 备份当前运行二进制与容器状态
BAK_TS=$(date +%Y%m%d_%H%M%S)
cp -f /opt/narwhal-agent/narwhal-agent "/root/narwhal-agent.bak.${BAK_TS}"

# 2. 停用并拔除冲突的第三方补账脚本（若存在，避免 raw 归零导致全量重加）
systemctl stop narwhal-traffic-guard.service 2>/dev/null || true
systemctl disable narwhal-traffic-guard.service 2>/dev/null || true

# 3. 下载免更 Dev 修复版二进制（含自更死循环根治 + 流量统计防虚高补丁）
URL_BIN="https://github.com/flyingiq/runman-agent/releases/download/dev-v0.3.3-trafficfix/runman-agent-linux-amd64-dev"
EXPECTED_SHA="8c317d43ce953637fc7f4f68ebff3b85a5e4433443fed18567420c5020f4f61c"
curl -fsSL -o /tmp/runman-agent-dev "$URL_BIN"

# 4. 强校验 SHA256 哈希，若不符立即中断退出
ACTUAL_SHA=$(sha256sum /tmp/runman-agent-dev | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "[-] SHA256 校验失败: $ACTUAL_SHA 不符预期" >&2
    rm -f /tmp/runman-agent-dev
    exit 1
fi
echo "[+] SHA256 校验通过: $ACTUAL_SHA"

# 5. 解锁、原子安装并加锁防篡改 (+i 阻止任何进程覆写)
chattr -i /opt/narwhal-agent/narwhal-agent 2>/dev/null || true
install -m 0755 /tmp/runman-agent-dev /opt/narwhal-agent/narwhal-agent
rm -f /tmp/runman-agent-dev
chattr +i /opt/narwhal-agent/narwhal-agent

# 6. 重启服务
systemctl restart narwhal-agent
```

---

## 4. 验收三条断言（秒级核验）

替换完成后运行以下三行命令，全部达标即表示彻底根治：

```bash
# 断言 1: Dev 停更日志命中 >= 1（源码级退出更新器的铁证）
[ $(journalctl -u narwhal-agent -n 50 --no-pager | grep -c "Dev version detected, auto-update disabled") -ge 1 ] && echo "PASS: 断言1通过" || echo "FAIL: 断言1失败"

# 断言 2: exiting for update 退出次数严格为 0
[ $(journalctl -u narwhal-agent -n 50 --no-pager | grep -c "exiting for update") -eq 0 ] && echo "PASS: 断言2通过" || echo "FAIL: 断言2失败"

# 断言 3: 业务管理端口 8792 处于正常监听状态
ss -tulpn | grep -q ":8792" && echo "PASS: 断言3通过" || echo "FAIL: 断言3失败"
```

---

## 5. 反面清单（母鸡站长五条绝对禁忌）

1. **严禁在 Debian 12 强行混源升级 Podman 5.4.2**：Trixie 的 Podman 依赖 `libc6 >= 2.38`，强行引入混合源会毁坏 Debian 12 的 `libc6 2.36` 底座（构成 FrankenDebian），导致母鸡崩盘。
2. **严禁下载 releases/latest 直链**：GitHub `latest` 会被官方发布抢占，拉下来的包带 `-X main.version`，启动后立刻再次自毁。
3. **严禁打 `v*` 开头的 Tag 出包**：会意外触发上游官方 `release.yml` 撞车覆盖；必须使用 `dev-v*` 命名空间。
4. **严禁在 Debian 12 直接跑上游最新 install.sh**：其 `check_podman_version()` 会在检测到 4.3.1 时直接 `exit 1`，中断全部初始化。
5. **严禁保留或部署把 raw 置 0 的第三方流量补账脚本（如 narwhal-traffic-guard.py）**：该脚本每次写库把 `raw_in=0, raw_out=0`，直接诱发 Agent 遇 0 触发全量重复累加，造成 +4.4 GB/分钟 的虚假流量海啸！详见 [TRAFFIC-FIX.md](TRAFFIC-FIX.md)。

---

## 6. 想自己出包（三步法）

若希望自己掌控编译分发，只需三步（**直接 Fork 本仓库即可，流水线文件已内置**）：

1. **Fork 仓库**：Fork `flyingiq/runman-agent`（若坚持 Fork 上游 `narwhal-cloud/runman-agent`，需自行把 `.github/workflows/build-noupdate.yml` 复制过去）；
2. **同步上游并打 Tag 触发**（Actions 仅对 `dev-v*` 标签构建免更版）：
   ```bash
   git clone https://github.com/你的用户名/runman-agent && cd runman-agent
   git remote add upstream https://github.com/narwhal-cloud/runman-agent.git
   git fetch upstream && git merge upstream/main      # 务必先同步上游，否则产物会缺最新修复
   git tag dev-v0.3.3 && git push origin dev-v0.3.3   # 只推 tag，不要推 main
   ```
3. **获取产物**：构建约 2 分钟后，在 GitHub Releases 下载 `-dev` 结尾的产物。完整流程与隔离细节见 [SELFBUILD.md](SELFBUILD.md)。

---

## 7. 产物档案与指纹

- **发行标签**: `dev-v0.3.3-trafficfix`
- **下载直链**: `https://github.com/flyingiq/runman-agent/releases/download/dev-v0.3.3-trafficfix/runman-agent-linux-amd64-dev`
- **文件 SHA256**: `8c317d43ce953637fc7f4f68ebff3b85a5e4433443fed18567420c5020f4f61c`
- **校验和直链**: `https://github.com/flyingiq/runman-agent/releases/download/dev-v0.3.3-trafficfix/SHA256SUMS-dev`
- **包含上游与自编译修复**:
  1. commit `0da61a14e2`（修复 Podman 4.x 租户流量显示 0.0）
  2. commit `a90e183`（流量修复：消除非单调回退导致的全量重复累加 + 修正 in/out 颠倒）
- **停更自证方法**: `go version -m runman-agent-linux-amd64-dev | grep ldflags` 输出仅包含 `-s -w`，无 `-X main.version`。
- **流量专项排障**: 详见 [TRAFFIC-FIX.md](TRAFFIC-FIX.md)（含 30 秒自检、停机小鸡真值恢复与一键脚本 `scripts/fix-traffic.sh`）。

---

## 8. 免责与授权说明

上游源码完全开源，本自编译修复版本**已获原作者授权公开分发**。替换操作直接作用于宿主核心服务，执行前请务必使用第 3 节自带的备份机制保存当前副本。
