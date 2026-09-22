#!/usr/bin/env python3
"""用采集守护的冻结快照恢复停机实例真值（默认 dry-run，--apply 才写库）。

在计量母鸡上运行：
    python3 recover-traffic-from-state.py            # 先看计划
    python3 recover-traffic-from-state.py --apply     # 写库（自动备份 + sha256）

映射（已在运行中实例上与内核 netns 对照验证，漂移 <0.1%）：
    快照 raw_out = 容器 RX = 计量表的月入/总入
    快照 raw_in  = 容器 TX = 计量表的月出/总出
写回时同时把 raw_in/raw_out 写成真值，避免下一轮再出现「全量重加」。
"""
import hashlib
import json
import shutil
import sqlite3
import sys
import time

DB = "/opt/narwhal-agent/agent.db"
STATE = "/opt/narwhal-agent/traffic_state.json"
APPLY = "--apply" in sys.argv

st = json.load(open(STATE))
con = sqlite3.connect(DB, timeout=30)
cur = con.cursor()
known = {r[0] for r in cur.execute("SELECT vm_id FROM traffics")}

plan = []
for vm, s in st.items():
    if vm not in known:
        continue
    ri, ro = int(s.get("raw_in", 0)), int(s.get("raw_out", 0))
    if ri == 0 and ro == 0:
        continue
    plan.append((vm, ro, ri))     # (vm, 入站, 出站)

print("可恢复 %d 行（入站 ← state.raw_out，出站 ← state.raw_in）" % len(plan))
for vm, i, o in sorted(plan, key=lambda x: -(x[1] + x[2]))[:12]:
    print("  %-42s 入=%9.3f GiB 出=%9.3f GiB" % (vm[:42], i / 2 ** 30, o / 2 ** 30))

if not APPLY:
    print("dry-run：确认无误后加 --apply 写库（会先自动备份）")
    sys.exit(0)

bak = DB + ".recover-bak-" + time.strftime("%Y%m%d_%H%M%S")
shutil.copy2(DB, bak)
print("备份: %s\nsha256: %s" % (bak, hashlib.sha256(open(bak, "rb").read()).hexdigest()))

for vm, i, o in plan:
    cur.execute("UPDATE traffics SET month_in=?, month_out=?, total_in=?, total_out=?, "
                "raw_in=?, raw_out=?, updated_at=? WHERE vm_id=?",
                (i, o, i, o, i, o, time.strftime("%Y-%m-%dT%H:%M:%S"), vm))
con.commit()
con.close()
print("已写回 %d 行；收尾：静置 60~120 秒后复读合计，确认未被覆盖且无 GB 级增长。" % len(plan))
