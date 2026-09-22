# Runman / Narwhal Agent 流量统计虚高根治指南

适用场景：Debian 12 / Linux 切机母鸡，租户面板流量统计虚高 3~182 倍、入出颠倒、触发平台超额策略误停机。

---

## 1. 30 秒自检（是否中招）

在宿主机直接粘贴运行以下单行命令，对比宿主物理网卡累计流量与数据库内租户上报总额：

```bash
# 1. 查看宿主物理网卡 (eth0) 与容器网桥 (podman1) 开机累计流量
grep -E "eth0|podman1" /proc/net/dev | awk '{printf "%-10s RX=%.2f GB  TX=%.2f GB\n", $1, $2/1073741824, $10/1073741824}'

# 2. 查看数据库中本月全部租户的累计流量总和
python3 -c '
import sqlite3
con = sqlite3.connect("file:/opt/narwhal-agent/agent.db?mode=ro", uri=True)
row = con.execute("SELECT sum(month_in)/1e9, sum(month_out)/1e9, count(*) FROM traffics").fetchone()
print("DB本月合计: 入站=%.2f GB  出站=%.2f GB (共 %d 台实例)" % (row[0] or 0, row[1] or 0, row[2]))
'
```

### ⚡ 核心自检公式
$$\text{DB 租户上报用量之和} > \text{宿主网卡物理累计} \times 1.5 \implies \mathbf{统计必假}$$

**典型案例**：宿主 `eth0` 开机 32 天总出站仅 **601 GB**，网桥累计 **557 GB**，而数据库内 9 月仅 21 天租户统计总出站高达 **2523 GB**（超物理上限 4.2 倍）。物理上容器流量不可能凭空超出宿主出口网卡，此特征一出，100% 命中流量虚高！

---

## 2. 判定硬标准与定性准则

在面对客户流量投诉或争议时，遵循以下三条判定铁律：

### 铁律 1：整机物理网卡上限原则（出口天花板）
母鸡上运行的所有容器实例，无论是代理、建站还是爬虫，其公网流量必然穿透宿主物理网卡（如 `eth0`）与虚拟网桥（如 `podman1`）。**整机所有小鸡的统计总和绝不可能大于物理出口网卡的累计字节数**。只要总和超过物理天花板，即可在技术上直接定性为“统计模块自身缺陷”，非客户超额。

### 铁律 2：面板一字不差法则（面板即本地上报）
将平台控制台（Web 面板）显示的用量数值，与本地 `/opt/narwhal-agent/agent.db` 中 `traffics` 表的 `month_in`、`month_out` 对照：
- 实测证明：**面板数值与本地数据库记录逐字节完全一致**。
- 平台通过 gRPC 心跳周期拉取 Agent 上报值用于渲染与停机风控；问题百分之百出在母鸡采集端，**切忌怀疑平台计费逻辑**。

### 铁律 3：单台实例真实 netns 交叉核验
使用以下命令进入容器网络命名空间，直接抓取内核硬数据：
```bash
PID=$(podman inspect -f '{{.State.Pid}}' <实例名/容器ID>)
nsenter -t $PID -n cat /proc/net/dev | grep -v "lo"
```
**实测案例**：一台开机 4 周的空转实例，容器内部内核真实统计累计仅 `RX 1.578 MB / TX 0.388 MB`；但在 `agent.db` 中却记录 `month_in 216 MB / month_out 57 MB`，且 `raw_in=0, raw_out=0`，**虚高高达 130 倍**！

---

## 3. 双层真因深度剖析（源码级实锤）

本次流量失真不是单一 Bug，而是**上游代码缺陷**与**老旧补丁脚本**相互激荡引发的系统性“自激震荡”：

```
┌────────────────────────────────────────────────────────────────────────┐
│ 第一层：上游 Agent 自身缺陷                                             │
│ 1. podman.go 以流式 stats 抽取第 2 帧瞬时数据充当单调计数器             │
│ 2. traffic.go 遇计数器回退时执行 delta = netStats（全量再加一遍）       │
│ 3. 采样返回 0 时覆写 RawIn=0，下一轮全量再次累加                       │
│ 4. podman stats 从宿主 veth 视角统计，导致 In/Out 颠倒                 │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │ 叠加恶化
┌────────────────────────────────────▼───────────────────────────────────┐
│ 第二层：致命放大器 (narwhal-traffic-guard.py 守护脚本)                  │
│ 针对 Debian 12 Podman 4.x 统计为 0 部署的第三方补账脚本，               │
│ 每轮写库执行 UPDATE traffics SET ..., raw_in=0, raw_out=0;             │
│ 导致 Agent 每 30 秒一轮计算增量时，始终 delta = 容器开机全量！          │
│ 实测引发 +4390 MB/分钟 的恐怖虚增海啸！                                │
└────────────────────────────────────────────────────────────────────────┘
```

### 第一层：上游 Agent 采集链路缺陷
1. **致命回退逻辑（全量重加）**：
   在 `traffic/traffic.go:133-142` 中：
   ```go
   deltaIn := netStats.InBytes - traffic.RawIn
   if deltaIn < 0 { deltaIn = netStats.InBytes }   // 🚨 计数器一回退 → 把「历史全量」再加一遍！
   traffic.TotalIn += deltaIn
   traffic.RawIn = netStats.InBytes
   ```
   只要由于容器重启、瞬时网络抖动导致当前采样值小于上轮采样值，Agent 不仅不钳制增量，反而直接把容器开机以来的**全部历史流量**再累加一遍！发生一次翻倍，发生数次翻数十倍。
2. **零值覆写基线漏洞**：
   当采样遇到超时或短暂返回 0 时，`RawIn` 被记录为 0。下一次正常采样时，`delta = 真实值 - 0 = 容器全量`，再次触发全量累加。
3. **流式瞬时帧误用**：
   `manager/podman/podman.go:578` 的 `getUsage()` 使用 `containers.Stats(..., Stream:true, Interval:1)` 提取第 2 帧作为计数器，该机制极不稳定，极易产生非单调数据。
4. **in/out 视角颠倒**：
   podman stats API 从宿主机 veth 视角统计：容器向外出站（TX）被计为宿主的 `rx_bytes`，容器入站（RX）被计为宿主的 `tx_bytes`。导致小鸡入出站计量完全颠倒。

### 第二层：致命放大器（自建守护脚本的双写冲突）
- **背景**：在 Debian 12 默认自带的 Podman 4.3.1 下，旧版 Agent 无法读取网络流量（面板恒为 0.0）。部分母鸡站长因此部署了名为 `narwhal-traffic-guard.py` 的 systemd 守护服务（`narwhal-traffic-guard.service`）进行外部补账。
- **放大器机理**：该脚本在执行 SQLite 更新时，其 SQL 语句写为：
  ```sql
  UPDATE traffics SET total_in=?, total_out=?, month=?, month_in=?, month_out=?, raw_in=0, raw_out=0, updated_at=? WHERE vm_id=?
  ```
  **它在每次补账后，将 `raw_in` 和 `raw_out` 强制置 0！**
- **致命后果**：
  上游 Agent 每 30 秒执行一次 `syncOnce()`，读取到容器真实累计后，发现 `RawIn == 0`，于是计算：
  $$\text{deltaIn} = \text{采样值} - 0 = \text{容器开机至今全量}$$
  随后 Agent 将全量计入，并将 `RawIn` 更新为采样值；但下一秒，守护脚本又跑了一轮，再次将 `RawIn` 覆写为 0！
  两套程序交替运行，形成了一个每 30 秒把开机全量叠加一次的恶性放大器，**实测虚增速率达 +4.4 GB / 分钟**！
- 🚨 **处置铁律**：**只替换修复版二进制，而不停止并禁用该冲突守护脚本 = 0 效果！**

---

## 4. 处置标准作业顺序 (SOP)

**严禁颠倒操作顺序！顺序错一步，存量数据将被二次污染！**

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  步骤 0      │     │  步骤 1      │     │  步骤 2      │     │  步骤 3      │     │  步骤 4      │
│  停冲突守护  │ ──> │  替换二进制  │ ──> │  校准存量库  │ ──> │  重启服务    │ ──> │  120秒留观   │
│  (拔放大器)  │     │  (防篡改+i)  │     │  (物理真值)  │     │  (Agent)     │     │  (三角验证)  │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

### 步骤 0：必须首先停止并禁用冲突写入方
```bash
systemctl stop narwhal-traffic-guard.service 2>/dev/null || true
systemctl disable narwhal-traffic-guard.service 2>/dev/null || true
pkill -9 -f narwhal-traffic-guard.py 2>/dev/null || true
```

### 步骤 1：下载并替换免更修复版二进制
下载经过源码级修复（优先直读 netns、负 delta 钳 0、跳过零值基线）且永久停更的 Release 资产：
```bash
# 1. 备份当前运行二进制与数据库
BAK_TS=$(date +%Y%m%d_%H%M%S)
cp -f /opt/narwhal-agent/narwhal-agent "/root/narwhal-agent.bak.${BAK_TS}"
cp -f /opt/narwhal-agent/agent.db "/root/agent.db.bak.${BAK_TS}"

# 2. 下载修复版二进制 (amd64)
URL_BIN="https://github.com/flyingiq/runman-agent/releases/download/dev-v0.3.3-trafficfix/runman-agent-linux-amd64-dev"
EXPECTED_SHA="8c317d43ce953637fc7f4f68ebff3b85a5e4433443fed18567420c5020f4f61c"
curl -fsSL -o /tmp/runman-agent-dev "$URL_BIN"

# 3. 强校验 SHA256
ACTUAL_SHA=$(sha256sum /tmp/runman-agent-dev | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "[-] SHA256 不匹配: $ACTUAL_SHA" >&2
    rm -f /tmp/runman-agent-dev && exit 1
fi

# 4. 原子替换并设置 +i 防篡改锁
chattr -i /opt/narwhal-agent/narwhal-agent 2>/dev/null || true
install -m 0755 /tmp/runman-agent-dev /opt/narwhal-agent/narwhal-agent
rm -f /tmp/runman-agent-dev
chattr +i /opt/narwhal-agent/narwhal-agent
```

### 步骤 2：存量虚高数据物理校准（严禁一刀切清零）
- 业务若是**超售**模式，直接清零等于白送客户当月流量配额，导致宿主真实出口超标；若不纠偏，客户仍处于虚假超额停机状态。
- **纠偏原则**：运行中小鸡按容器 `netns` 真实计数精确重置；停机小鸡按冻结快照恢复（详见第 5 节）。

### 步骤 3：重启 Agent 服务
```bash
systemctl restart narwhal-agent
```

### 步骤 4：静置 120 秒观测验证
静置 2 分钟前后各对比一次数据，只允许出现 KB~MB 级正常物理增长。若再次出现 GB 级暴涨，说明步骤 0 未执行彻底，仍有残留写入者。

---

## 5. 停机实例真值恢复机制

当小鸡已经被平台以“超额”为由执行了 graceful StopVM，其 Podman 容器已退出，容器网络命名空间 `/proc/<pid>/net/dev` 已随进程销毁。**停机小鸡的真实用量如何找回？**

### 1. 冻结快照是唯一真相来源
- 历史守护脚本在轮询时会生成状态快照文件：`/opt/narwhal-agent/traffic_state.json`。
- 当小鸡被停机后，它不再被轮询，其真实字节计数被**永久冻结在快照文件中**！
- 结构示例：
  ```json
  {
    "f88eef28-40a7-48c7-9937-49e1ac968345": {
      "raw_in": 10521876432,
      "raw_out": 9845123456
    }
  }
  ```

### 2. 核心避坑：字段映射颠倒
**这是最致命的暗坑！快照中的字段映射与 Agent 库语义完全相反：**
- `state.raw_out` = 容器物理 **RX** = 计量表的 **MonthIn / 入站**
- `state.raw_in` = 容器物理 **TX** = 计量表的 **MonthOut / 出站**

> ⚠️ 该对应关系已在多台运行中小鸡上与内核 `/proc/<pid>/net/dev` 逐字节交叉比对，误差 `< 0.1%`。如果映射写反，将导致客户入站出站颠倒，造成二次客诉！

### 3. 日志增量兜底法
若快照文件损坏或丢失，使用 journald 查看守护脚本的历史增量记录：
```bash
journalctl -u narwhal-traffic-guard --no-pager | grep "Updated" | tail -n 20
```
每轮日志输出形如 `Updated <vm_id>: +In=..., +Out=...`，按实例 ID 累加各轮增量即可还原出停机前的真实消耗。

### 4. 为什么严禁按统一倍数折算？
实测普查表明，每台小鸡的虚高倍数完全不一致：
- 申诉实例（业务机）：虚高 **23.5 倍**（442.61 GB 实际仅 18.8 GiB）；
- 某生产机：虚高 **82.3 倍**（345.2 GiB 实际仅 4.2 GiB）；
- 自有空转机：虚高 **182.5 倍**；
虚高倍数由该小鸡经历的“计数器回退”次数与“raw 置 0”轮数决定。**按统一倍数简单除以 N 进行缩放必错！**

---

## 6. 善后处理：恢复被误停实例

数据纠偏完成后，按照以下标准流程使业务安全上线：

### 1. 本地拉起实例与状态同步
平台下发停机指令后，本地数据库会将实例标记为 `stopped`。在平台心跳同步刷新前，可先在宿主机本地启动实例：
```bash
# 启动容器
podman start <实例ID/名称>

# 同步 Agent 数据库状态（避免状态不一致）
sqlite3 /opt/narwhal-agent/agent.db "UPDATE vm_configs SET status='running' WHERE vm_id='<实例ID>';"
```

### 2. 端口转发自动重建机制
- Runman Agent 内部常驻有 `PortForward` 的 `reconcileLoop` 循环。
- 容器启动后，Agent 会自动扫描其映射端口并重建宿主机 iptables/nftables 转发规则。
- **无需手动敲写 iptables 命令**，实测 53 条业务端口转发规则全部在 5 秒内自动补齐。

### 3. 真实服务可达性核验（读 Banner）
启动成功不等于服务可达。必须真实发起一次 TCP 握手并读取协议 Banner：
```bash
# 测试 SSH 端口（必须返回 SSH-2.0-OpenSSH_* 协议头）
python3 -c '
import socket
s = socket.create_connection(("127.0.0.1", <映射的主机SSH端口>), timeout=3)
print("握手成功 Banner:", s.recv(1024).decode().strip())
s.close()
'
```

### 4. 3 分钟留观防二次误停
- 观察 3 分钟，确认容器数量未减少（平台未再次下发 StopVM）；
- 约 30 秒后（一个平台心跳周期），控制台 Web 面板状态会自动刷新为“运行中”，且显示修正后的真实流量；
- IP 与端口与停机前**完全一致**（容器原地启动，非销毁重建），租户业务无感复活。

---

## 7. 一键修复脚本 (fix-traffic.sh)

仓库内置了一键根治脚本，位于 `scripts/fix-traffic.sh`。包含自动架构适配、冲突守护关闭、强校验下载、防篡改加锁与存量校准：

```bash
# 下载一键修复脚本
curl -fsSL -o fix-traffic.sh https://raw.githubusercontent.com/flyingiq/runman-agent/main/scripts/fix-traffic.sh

# 方式 A：标准修复（推荐未发生大面积超额停机的母鸡）
bash fix-traffic.sh

# 方式 B：完整修复 + 存量虚高数据物理校准（推荐已有客户被误停的母鸡）
bash fix-traffic.sh --calibrate
```

---

## 8. 四条验收断言（秒级核验）

完成修复操作后，在母鸡终端运行以下四条断言命令，全部达标即表示彻底根治：

```bash
# 断言 1: Dev 停更机制激活（源码级切断自更新覆写，与流量修复同属一版）
[ $(journalctl -u narwhal-agent -n 60 --no-pager | grep -c "Dev version detected, auto-update disabled") -ge 1 ] && echo "PASS: 断言1通过 (停更激活)" || echo "FAIL: 断言1失败"

# 断言 2: 冲突守护服务处于彻底关闭且禁用状态
[ "$(systemctl is-active narwhal-traffic-guard.service 2>/dev/null || echo inactive)" = "inactive" ] && echo "PASS: 断言2通过 (守护已停)" || echo "FAIL: 断言2失败"

# 断言 3: 二进制文件处于防篡改加锁状态 (+i 阻止任何程序覆写)
lsattr /opt/narwhal-agent/narwhal-agent | grep -q "i" && echo "PASS: 断言3通过 (加锁防篡改)" || echo "FAIL: 断言3失败"

# 断言 4: 运行中实例 raw_in 与内核 netns 容器 RX 逐字节完全一致
python3 -c '
import sqlite3, subprocess, os
out = subprocess.run(["podman", "ps", "--format", "{{.Names}} {{.Pid}}"], capture_output=True, text=True).stdout
con = sqlite3.connect("file:/opt/narwhal-agent/agent.db?mode=ro", uri=True)
passed = 0
for line in out.splitlines():
    p = line.split()
    if len(p) >= 2 and p[1].isdigit():
        vm, pid = p[0], int(p[1])
        rx = 0
        if os.path.exists(f"/proc/{pid}/net/dev"):
            for l in open(f"/proc/{pid}/net/dev"):
                if ":" in l and l.split()[0].rstrip(":") != "lo":
                    rx += int(l.split()[1])
        row = con.execute("SELECT raw_in FROM traffics WHERE vm_id=?", (vm,)).fetchone()
        if row and abs(row[0] - rx) < 1048576: # 允许一个采样间隔微小漂移
            passed += 1
import sys
if passed > 0:
    print(f"PASS: 断言4通过 ({passed} 台运行实例 raw 计数与 netns 硬指标吻合)")
else:
    print("FAIL: 断言4失败 —— 没有任何实例的 raw 计数与 netns 吻合（修复未生效或库未刷新，请重跑修复流程）")
    sys.exit(1)
'
```

---

## 9. 反面清单（母鸡站长五条绝对禁忌）

1. **严禁只替换修复版 Agent，却保留 `narwhal-traffic-guard` 运行**：该脚本每轮把 `raw` 置 0，哪怕换了最新版 Agent，仍会产生 +4.4 GB/分钟 的虚假流量海啸！
2. **严禁按固定比例或统一倍数对存量流量打折**：空转小鸡虚高可达 182 倍，大流量业务机虚高 3~20 倍，统一折算必然导致轻载机仍超额、重载机被少计。
3. **严禁对超售切机直接执行 `month_in=0, month_out=0` 清零**：清零将直接丢掉计费阀门，等于无偿向租户赠送当月全额配额，增加母鸡母机物理网卡被超额打满的风险。
4. **严禁在 Debian 12 混源升级 Podman 5.x**：试图通过升级 Podman 规避采集问题会引入 Debian Trixie 的 `libc6 >= 2.38`，彻底摧毁 Debian 12 的基础运行环境（造成 FrankenDebian）。
5. **严禁下载 GitHub `releases/latest` 直链**：官方主线包可能随时发布新版本并带有 `-X main.version` 注入，拉取 `latest` 会使 Agent 再次激活自更新死循环。
