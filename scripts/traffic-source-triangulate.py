#!/usr/bin/env python3
"""三方相关性诊断（只读）：容器 netns 真值 vs 宿主物理 vs 计量库。

在计量母鸡上运行：
    python3 traffic-source-triangulate.py [实例名前缀 ...] [--interval 60]

判读：库月入/月出增量 ≫ 容器 netns 增量（或容器零流量时库仍在涨）
     → 采集链路仍在虚高；库Δ ≈ netnsΔ 才算真正止血。
"""
import sqlite3
import subprocess
import sys
import time

DB = "/opt/narwhal-agent/agent.db"
INTERVAL = 60
prefixes = []
argv = sys.argv[1:]
for i, a in enumerate(argv):
    if a == "--interval" and i + 1 < len(argv):
        INTERVAL = int(argv[i + 1])
    elif not a.startswith("--"):
        prefixes.append(a)


def netdev(path):
    """汇总一个 netns / 宿主里所有非 lo 接口的 RX/TX（字节）。"""
    rx = tx = 0
    for line in open(path):
        if ":" not in line:          # 跳过 /proc/net/dev 的两行表头
            continue
        p = line.split()
        if len(p) >= 10 and p[0].rstrip(":") != "lo":
            rx += int(p[1])
            tx += int(p[9])
    return rx, tx


def containers():
    out = subprocess.run(["podman", "ps", "--format", "{{.Names}} {{.Pid}}"],
                         capture_output=True, text=True).stdout
    res = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            res.append((parts[0], int(parts[1])))
    return res


def dbrow(vm):
    con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True)   # 不加 immutable
    r = list(con.execute(
        "SELECT month_in, month_out, raw_in, raw_out FROM traffics WHERE vm_id=?", (vm,)))
    con.close()
    return r[0] if r else (0, 0, 0, 0)


def snap():
    d = {}
    for name, pid in containers():
        if prefixes and not any(name.startswith(p) for p in prefixes):
            continue
        try:
            d[name] = netdev("/proc/%d/net/dev" % pid)
        except Exception:
            d[name] = (0, 0)
    return d


t0, h0 = snap(), netdev("/proc/net/dev")
d0 = {n: dbrow(n) for n in t0}
print("采样 %d 个容器，等待 %d 秒..." % (len(t0), INTERVAL))
time.sleep(INTERVAL)
t1, h1 = snap(), netdev("/proc/net/dev")

print("%-42s %13s %13s %13s" % ("实例", "netnsRXΔ(MB)", "netnsTXΔ(MB)", "库月入Δ(MB)"))
for n in sorted(t0, key=lambda x: -(t1.get(x, (0, 0))[0] - t0[x][0])):
    a, b = t0[n], t1.get(n, (0, 0))
    d1 = dbrow(n)
    print("%-42s %13.2f %13.2f %13.2f" % (
        n[:42], (b[0] - a[0]) / 1048576, (b[1] - a[1]) / 1048576,
        (d1[0] - d0[n][0]) / 1048576))
print("宿主物理Δ: RX=%.2f MB  TX=%.2f MB" % ((h1[0] - h0[0]) / 1048576, (h1[1] - h0[1]) / 1048576))
print("库里 raw vs 容器 netns 应逐字节相等；库Δ应≈netnsΔ。")
