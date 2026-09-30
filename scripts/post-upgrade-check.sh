#!/usr/bin/env bash
# runman-agent 升级后体检（只读，不改动任何配置，可反复运行）
# 用法：  bash scripts/post-upgrade-check.sh
# 退出码：0=全部通过  1=有 FAIL（不要回复"可以了"）  2=有 WARN（逐条确认）
set -u
PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [OK]   %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf '  [WARN] %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }
info() { printf '  ----   %s\n' "$*"; }
printf '%s\n' "=============================================="
printf ' runman-agent 升级后体检（只读）\n %s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname 2>/dev/null)"
printf '%s\n' "=============================================="

printf '[1/7] Agent 服务\n'
SVC=""
for s in narwhal-agent runman-agent; do
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^${s}\."; then
    st=$(systemctl is-active "$s" 2>/dev/null); SVC="$s"
  elif [ -x "/etc/init.d/${s}" ]; then
    st=$(rc-service "$s" status 2>&1 | grep -qi started && echo active || echo inactive); SVC="$s"
  else continue; fi
  [ "$st" = active ] && ok "服务 $s = active" || fail "服务 $s = ${st:-unknown}（应为 active）"
  break
done
[ -z "$SVC" ] && warn "未找到 narwhal-agent / runman-agent 服务单元（手工部署或改名？）"

printf '[2/7] Agent 二进制（mtime 应接近本次升级时间；sha256 应与发布物 SHA256SUMS 一致）\n'
FOUND=0
for p in /usr/local/bin/runman-agent /usr/local/bin/narwhal-agent /opt/narwhal-agent/narwhal-agent /opt/runman-agent/runman-agent; do
  [ -x "$p" ] || continue
  FOUND=1
  printf '  ----   %s\n         mtime=%s  size=%s  sha256=%s\n' "$p" \
    "$(stat -c %y "$p" 2>/dev/null | cut -c1-19)" "$(stat -c %s "$p" 2>/dev/null)" "$(sha256sum "$p" 2>/dev/null | cut -c1-16)"
done
[ "$FOUND" -eq 1 ] && ok "找到 agent 二进制" || fail "找不到 agent 二进制"

printf '[3/7] rfw 防火墙（租户端口转发靠它，端口 7734）\n'
if ss -lnt 2>/dev/null | grep -q ':7734'; then ok "rfw 在 127.0.0.1:7734 监听"
elif command -v rfw >/dev/null 2>&1; then warn "有 rfw 可执行文件，但 7734 未监听 → 转发可能已失效"
else fail "没有 rfw 且 7734 未监听 → 租户端口转发可能已坏"; fi

printf '[4/7] 容器（数量应与升级前一致）\n'
for rt in podman docker; do
  command -v "$rt" >/dev/null 2>&1 && printf '  ----   %s: 运行 %s / 共 %s\n' "$rt" "$($rt ps -q 2>/dev/null | wc -l)" "$($rt ps -aq 2>/dev/null | wc -l)"
done
command -v incus >/dev/null 2>&1 && printf '  ----   incus: 共 %s\n' "$(incus list -c n --format csv 2>/dev/null | wc -l)"

printf '[5/7] 端口转发（规则数 + 抽样连通性实测）\n'
if command -v iptables >/dev/null 2>&1; then
  info "DNAT 规则：v4=$(iptables -t nat -S 2>/dev/null | grep -c DNAT)  v6=$(ip6tables -t nat -S 2>/dev/null | grep -c DNAT)"
else
  info "无 iptables 命令（nft 主机？）→ 请用 rfw 自身状态确认转发"
fi
# 取一个真实转发端口：优先 agent DB 的 port_forwards.host_port，其次 iptables 的 dport
PORT=""
ADB=/opt/narwhal-agent/agent.db
if command -v sqlite3 >/dev/null 2>&1 && [ -f "$ADB" ]; then
  PORT=$(sqlite3 "file:$ADB?mode=ro" "select host_port from port_forwards where protocol='tcp' order by host_port limit 1;" 2>/dev/null)
fi
[ -z "${PORT:-}" ] && PORT=$(iptables -t nat -S 2>/dev/null | grep -oE '\-\-dport [0-9]+' | awk '{print $2}' | head -1)
PUBIP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
if [ -n "${PORT:-}" ]; then
  info "抽样转发端口：$PORT（目标顺序：公网 IP $PUBIP → 127.0.0.1）"
  HIT=0
  for tgt in "${PUBIP:-127.0.0.1}" 127.0.0.1; do
    [ -n "$tgt" ] || continue
    if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$tgt/$PORT" 2>/dev/null; then ok "转发端口 $PORT 经 $tgt 可连通"; HIT=1; break; fi
  done
  [ "$HIT" -eq 0 ] && warn "转发端口 $PORT 本机走公网与回环都连不通 → 查 rfw 与 iptables NAT"
else
  warn "没取到任何转发端口（agent.db 无 port_forwards 且 iptables 无 dport）→ 手动确认一个租户端口能否连上"
fi

printf '[6/7] IPv6（NDP 模式升级后最容易被覆盖）\n'
info "公网 IPv6 地址数：$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)"
CFG=/opt/narwhal-agent/config.json
ADDR=""
if [ -f "$CFG" ] && command -v python3 >/dev/null 2>&1; then
  ADDR=$(python3 -c "import json;print(json.load(open('$CFG')).get('ipv6_addr') or '')" 2>/dev/null)
  python3 -c "import json;d=json.load(open('$CFG'));[print('  ----   config.%s = %s'%(k,d.get(k))) for k in ('ipv6_mode','ipv6_subnet','ipv6_addr','ipv6_iface') if d.get(k)]" 2>/dev/null
  if [ -n "$ADDR" ]; then
    if ip -6 addr show 2>/dev/null | grep -q "${ADDR%%/*}"; then ok "配置里的 ipv6_addr（$ADDR）仍在网卡上"
    else fail "配置里的 ipv6_addr（$ADDR）不在网卡上 → NDP/IPv6 配置可能被覆盖"; fi
  fi
fi
[ -z "$ADDR" ] && { [ "$(ip -6 addr show scope global 2>/dev/null | grep -c inet6)" -gt 0 ] && ok "存在公网 IPv6 地址" || warn "未发现公网 IPv6（本机不用 v6 可忽略）"; }

printf '[7/7] Agent API 与近期日志\n'
CODE=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:8792/ 2>/dev/null || echo 000)
case "$CODE" in
  200|401|403) ok "Agent API :8792 有应答（HTTP $CODE）";;
  000)         fail "Agent API :8792 无应答 → 面板下发指令会失败";;
  *)           warn "Agent API :8792 返回 HTTP $CODE";;
esac
if command -v journalctl >/dev/null 2>&1 && [ -n "$SVC" ]; then
  E=$(journalctl -u "$SVC" --since '30 min ago' --no-pager 2>/dev/null | grep -ciE 'error|panic|fail')
  [ "${E:-0}" -eq 0 ] && ok "近 30 分钟 $SVC 日志无 error" || warn "近 30 分钟 $SVC 日志有 ${E} 条 error，建议人工看一眼"
else
  for lg in /opt/narwhal-agent/*.log; do
    [ -f "$lg" ] || continue
    E=$(tail -200 "$lg" 2>/dev/null | grep -ciE 'error|panic|fail')
    [ "${E:-0}" -eq 0 ] && ok "$(basename "$lg") 尾部无 error" || warn "$(basename "$lg") 尾部有 ${E} 条 error"
  done
fi

printf '\n最近一次升级备份（回滚点）：\n'
BK=0; for d in $(ls -dt /var/lib/narwhal-agent/backups/upgrade-* 2>/dev/null | head -3); do BK=1; printf '  ----   %s\n' "$d"; done
[ "$BK" -eq 0 ] && info "未找到 /var/lib/narwhal-agent/backups/upgrade-*"

printf '\n%s\n' "=============================================="
printf ' 结论：通过 %s / 警告 %s / 失败 %s\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf ' 判定：**不通过** —— 有 %s 项失败，先按 UPGRADE-VERIFY.md 排查，不要回复"可以了"\n' "$FAIL"
  printf '%s\n' "=============================================="; exit 1
elif [ "$WARN" -gt 0 ]; then
  printf ' 判定：**基本通过（有警告）** —— 逐条确认警告项后再回复\n'
  printf '%s\n' "=============================================="; exit 2
else
  printf ' 判定：**通过** —— 再去面板确认该机在线且版本已更新即可\n'
  printf '%s\n' "=============================================="; exit 0
fi
