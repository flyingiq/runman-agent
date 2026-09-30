# 变更记录（CHANGELOG）

> 只记录**会影响部署与排查**的变更和注意要点，方便部署方对照。
> 体检命令：`bash scripts/post-upgrade-check.sh`（只读）｜判定标准：`UPGRADE-VERIFY.md`

---

## 2026-09-30

### 新增

- **`scripts/post-upgrade-check.sh`** —— 升级后**只读**体检：服务 / 二进制 / rfw(7734) / 容器数 / 端口转发(规则+实测) / IPv6(含与 config.json 的 `ipv6_addr` 比对) / API(`:8792`) 与近期日志 + 列出回滚点。
  退出码：`0` 通过 ｜ `2` 有警告 ｜ `1` 有失败（**不要回复"可以了"**）
- **`UPGRADE-VERIFY.md`** —— 「可以了」的三条硬判定标准、回滚路径、部署方安全提示。

### 修复

- **`manager/incus/incus.go`：builder 创建失败时如实上抛真实原因**（commit `022f38ca7c`）
  - 旧版：`_ = op.Wait()` 把创建操作的错误丢弃，于是"镜像拉取/解包/存储不足"这类异步失败，会在随后启动 builder 时被伪装成
    `Failed to fetch instance 'builder-<ts>' in project 'default': Instance not found` —— **报错误导，根因被藏起来**。
  - 新版：先注册清理（失败不留半成品），再校验创建结果，报错形如
    `builder create failed (base=<别名>, builder=<名>): <真实原因>`。
  - **注意**：如果你在**旧版本**的失败现场看到残留的 `builder-<时间戳>` 容器，可安全删除：
    `incus delete -f builder-<时间戳>`

### 注意要点（部署前必读）

1. **升级 ≠ 完成**：安装脚本打印的「更新完成」只代表流程跑完。必须跑 `bash scripts/post-upgrade-check.sh`，并到面板确认该机**在线且版本已更新**，才算真的好了。
2. **升级会动这几样**：内核参数（BBR/转发）、systemd-journald、**rfw 防火墙（127.0.0.1:7734，租户端口转发的执行者）**、容器镜像指纹、**IPv6 / NDP 配置**。
   → 最容易坏的就是「**租户端口转发**」和「**IPv6 被覆盖**」，这两项在面板上通常看不出来。
3. **升级前先备份 IPv6 配置**（维护菜单里的「备份 / 回滚 IPv6 配置」），出事才有退路。
4. **失败先看两个日志**：
   - agent 侧：`/opt/narwhal-agent/*.log` 或 `journalctl -u narwhal-agent`
   - Incus 侧：`journalctl -u incus` ← **自动构建镜像的真实错误在这里**
5. **对接 Token 不要共用**：每个部署方 / 每台母鸡单独签发，出事只废一个；装完确认 agent 的 `:8792` **不要在公网裸奔**（只让面板可达）。
6. **本仓库是公开仓库**：任何真实面板地址、对接 Token、证书私钥都不要提交上来。

### 速查：Alpine 装不上 / 实例"一直在重装"

Alpine 与 Debian 走的**基础镜像来源不同**：Alpine 优先用**本地定制基础镜像**，Debian 走私有镜像站 → 失败再回退上游。
所以「**Debian 能装、Alpine 装不上**」的第一嫌疑是**别名没命中**（见下节"定案"），其次才是基础镜像缺失或类型不对。

```bash
incus image alias list | grep -iE "alpine|ready"          # 本地定制基础镜像别名是否存在
incus image info <上面的别名>                              # 类型必须是 container（不能是 virtual-machine）
curl -sI https://alpine-incus-base.428048.xyz/streams/v1/images.json | head -1
df -h / /var/lib/incus 2>/dev/null                        # 存储余量（盘满同样会构建失败）
journalctl -u incus --since '30 min ago' | tail -40       # 真实失败原因
```

修复：跑维护菜单的「**配置 / 刷新容器镜像**」重新导入，或手动 `incus image import` 对应的基础镜像 fingerprint。

### 追加（同日实测补充）：`auto-build image failed` 的完整症状链

**症状**：面板创建实例时报

```
auto-build image failed: Failed to fetch instance 'builder-<时间戳>' in project 'default': Instance not found
```

且上方日志里有 `curl: (23) Failure writing output to destination, passed <大数> returned <小数>`。

**三层解读（别被最后一层骗了）**

1. `Instance not found` 是**表象** —— builder 是异步创建的，创建真的失败了却被旧代码吞掉（本日已修 `022f38ca7c`）。
2. `curl: (23)` 才是**直接原因**：下载镜像时**写入端提前死亡**（实际写出的字节数远小于已投递的）。
3. 写入端为什么死，按可能性排序：
   - **解包/导入进程报错退出** —— 镜像格式与流程预期不符，管道对端一退，curl 立刻写不进去。**这是"Debian 能装、Alpine 装不上"最典型的原因**（两者镜像来源/格式不同）。
   - **内存不足被 OOM 杀** —— 小内存母鸡解大镜像。
   - 盘满也会，但**先排除**：`df -h / /var/lib/incus` 有余量（如 5G+）即可排除。

**排查顺序（照抄即可）**

```bash
df -h / /var/lib/incus /tmp                                  # 先排除盘满
journalctl -u incus --since '2 hours ago' | tail -40          # incusd 侧真实错误（优先看这个）
journalctl -u narwhal-agent --since '2 hours ago' | grep -iE "curl|image|builder" | tail -30
dmesg -T | grep -iE "oom|killed process|read-only|remount" | tail -10
systemctl cat narwhal-agent | grep -E "ExecStart|Standard"    # 日志落点（不一定在 /opt/narwhal-agent/*.log）
```

**抓现场（最保准）**：窗口 A `journalctl -u narwhal-agent -f`，窗口 B 在面板点一次创建，把 curl 那行**完整命令行**抄下来 ——
带 `|` 即"管道对端死"（按镜像格式处理）；带 `-o <文件>` 即"文件写不了"（查只读重挂载 / 配额）。

> 另注：维护菜单/升级脚本的输出只打在终端，跑完即失。下次跑之前加留档：
> `bash install.sh 2>&1 | tee /root/run-$(date +%F-%H%M).log`

### 定案（同日实测）：自定义基础镜像别名必须带 `/amd64`，否则 Alpine 永远走"现场构建"

**代码规则**（`manager/incus/incus.go` L174–215）：ready 别名是<b>拼</b>出来的，不是查出来的 ——

```
alias = "alpine"  且 incus_alpine_base 非空  →  alias = <incus_alpine_base>
否则 alpine  →  "alpine/3.24/cloud"     ｜  debian → "debian/13/cloud"
if !strings.Contains(alias, "amd64") { alias += "/amd64" }
readyAlias := alias + "/ready"
GetImageAlias(readyAlias)  → 不存在则 ensureReadyImage 现场构建；构建失败即 "auto-build image failed"
```

**一台上真实踩到的例子**（本机已有 `alpine/3.24/cloud/amd64/ready`、`debian/13/cloud/amd64/ready`、以及裸别名 `my-cloud-alpine`，全部 CONTAINER 类型）：

| 系统 | 算出的 ready 别名 | 本机是否存在 | 结果 |
|---|---|---|---|
| Debian | `debian/13/cloud/amd64/ready` | ✅ 在 | 直接用 → 成功 |
| Alpine | `my-cloud-alpine/amd64/ready`（因 `incus_alpine_base=my-cloud-alpine`）| ❌ 不在 | 触发构建 → 用 `my-cloud-alpine/amd64` 建 builder → 别名也不存在 → 异步失败 → 表象为 `Instance not found` |

**结论**：定制基础镜像的别名必须遵循 `<名字>/<架构>`（如 `podcctv/alpine-base/amd64`），裸别名（`my-cloud-alpine`）**永远不会被命中**，Alpine 会稳定走构建路径并失败。

**两条修法（任选）**

```bash
# 先确认配置值
python3 -c "import json;c=json.load(open('/opt/narwhal-agent/config.json'));print(repr(c.get('incus_alpine_base')))"

# 方案 A（最快）：不使用定制基础镜像，直接吃本机已就绪的 ready 镜像
python3 - <<'PY'
import json; p='/opt/narwhal-agent/config.json'
c=json.load(open(p)); c['incus_alpine_base']=''
json.dump(c, open(p,'w'), indent=2)
PY
systemctl restart narwhal-agent

# 方案 B（保留定制镜像）：补一个带架构后缀的别名，之后首次创建会自动构建出 .../amd64/ready
incus image alias create my-cloud-alpine/amd64 <fingerprint>
```

**一条命令判断"是别名没命中还是镜像真缺"**：

```bash
python3 -c "import json;print(repr(json.load(open('/opt/narwhal-agent/config.json')).get('incus_alpine_base')))"
incus image alias list | grep -iE "alpine|debian|ready"   # 对比算出来的 <别名>/amd64/ready 是否在列
```

> 配套提醒：若同时看到 `curl: (23) Failure writing output to destination`，那是**镜像导入/刷新**环节的下载写入失败（另一层，见上一节）；**判定 Alpine 能不能建，以别名是否命中为准**。
