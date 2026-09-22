> ⚠️ **【强烈不建议使用 · 不含流量修复】**
>
> 本产物属于 `selfbuild` / `continuous` 历史构建，只修复了「自更新死循环」，**不含**流量统计修复补丁（commit `a90e183`）。
> 在 Debian 12 + Podman 4.x 母鸡上会造成 **流量虚高 3~182 倍**，进而触发平台超额策略、把客户实例误判停机。
>
> ✅ **请改用 [`dev-v0.3.3-trafficfix`](https://github.com/flyingiq/runman-agent/releases/tag/dev-v0.3.3-trafficfix)** —— 免更 + 流量修复，一次到位。
>
> 已经装了本版本？一行命令修好：
> ```bash
> curl -fsSL https://raw.githubusercontent.com/flyingiq/runman-agent/main/scripts/fix-traffic.sh -o /tmp/fix-traffic.sh && bash /tmp/fix-traffic.sh --calibrate
> ```
>
> 原理与处置顺序见 [TRAFFIC-FIX.md](https://github.com/flyingiq/runman-agent/blob/main/TRAFFIC-FIX.md)
