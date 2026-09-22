#!/usr/bin/env bash
# ==============================================================================
# Runman / Narwhal Agent 流量统计虚高一键根治脚本 (fix-traffic.sh)
# 
# 适用场景：
#   Debian 12 / Linux 母鸡节点 Narwhal Agent 流量虚高 3~182 倍、入出颠倒、
#   或因历史部署第三方 narwhal-traffic-guard 脚本导致每分钟虚增数 GB。
#
# 处置顺序（严禁颠倒）：
#   1. 停止并禁用冲突守护服务 (narwhal-traffic-guard.service)；
#   2. 自动备份当前二进制与 agent.db；
#   3. 强校验下载 dev-v0.3.3-trafficfix 免更修复版（杜绝全量重加 + in/out 修正）；
#   4. 原子替换并 chattr +i 防篡改；
#   5. 可选执行存量虚高数据校准（--calibrate）；
#   6. 重启 narwhal-agent 并执行四项硬核验收断言。
# ==============================================================================

set -euo pipefail

# 颜色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $*" >&2; }

# 版本与资产指纹定义
TAG_VERSION="dev-v0.3.3-trafficfix"
URL_BASE="https://github.com/flyingiq/runman-agent/releases/download/${TAG_VERSION}"

SHA_AMD64="8c317d43ce953637fc7f4f68ebff3b85a5e4433443fed18567420c5020f4f61c"
SHA_ARM64="a7c7b34ff4ee6e1946ce0a47ea37cee80650924c5a36d15a9b6e81a5fcb98522"

AGENT_DIR="/opt/narwhal-agent"
AGENT_BIN="${AGENT_DIR}/narwhal-agent"
AGENT_DB="${AGENT_DIR}/agent.db"
STATE_FILE="${AGENT_DIR}/traffic_state.json"

DRY_RUN=false
DO_CALIBRATE=false
SKIP_GUARD_STOP=false

show_help() {
    cat << 'EOF'
用法:
  bash fix-traffic.sh [选项]

选项:
  --calibrate         修复二进制后，自动对 agent.db 存量虚高记录执行物理校准
                      （运行中容器以 /proc/<pid>/net/dev 真值为准，停机容器以 traffic_state.json 为准）
  --dry-run           只进行环境与配置诊断，不修改文件、不写库、不重启服务
  --skip-guard-stop   跳过停止 narwhal-traffic-guard（仅用于特殊测试，生产环境严禁使用）
  -h, --help          显示此帮助信息

示例:
  # 标准根治（换修复二进制 + 停冲突守护 + 验收断言）
  bash fix-traffic.sh

  # 完整根治并纠偏存量虚高数据（推荐发生超额停机母鸡使用）
  bash fix-traffic.sh --calibrate
EOF
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --calibrate)
            DO_CALIBRATE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-guard-stop)
            SKIP_GUARD_STOP=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 0. 权限与依赖检查
if [[ $EUID -ne 0 ]]; then
    log_error "本脚本必须以 root 权限运行！"
    exit 1
fi

for cmd in curl sha256sum python3 awk grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "缺少必要工具: $cmd，请先 apt install $cmd"
        exit 1
    fi
done

if [[ ! -d "$AGENT_DIR" ]]; then
    log_error "未找到 Agent 部署目录: $AGENT_DIR"
    exit 1
fi

log_info "========================================================"
log_info "   Runman / Narwhal Agent 流量统计虚高根治作业开始"
log_info "========================================================"

# 1. 停止并禁用致命放大器：narwhal-traffic-guard
log_info "步骤 1/5: 检查冲突写入方 (narwhal-traffic-guard)..."
GUARD_SVC="narwhal-traffic-guard.service"
if systemctl list-unit-files | grep -qw "$GUARD_SVC"; then
    if systemctl is-active --quiet "$GUARD_SVC"; then
        log_warn "检测到正在运行的冲突守护服务: $GUARD_SVC (将 raw 基线置 0 导致每轮全量重加的罪魁祸首)"
        if [[ "$DRY_RUN" == false && "$SKIP_GUARD_STOP" == false ]]; then
            systemctl stop "$GUARD_SVC"
            systemctl disable "$GUARD_SVC"
            log_success "已彻底停止并禁用 $GUARD_SVC"
        elif [[ "$DRY_RUN" == true ]]; then
            log_info "[dry-run] 将停止并禁用 $GUARD_SVC"
        fi
    else
        log_info "$GUARD_SVC 存在但已处于停止状态。"
        if [[ "$DRY_RUN" == false && "$SKIP_GUARD_STOP" == false ]]; then
            systemctl disable "$GUARD_SVC" 2>/dev/null || true
        fi
    fi
else
    log_info "未检测到 $GUARD_SVC 服务单元，系统无双写冲突守护。"
fi

# 检查是否存在残留常驻进程
if pgrep -f "narwhal-traffic-guard.py" >/dev/null 2>&1; then
    log_warn "检测到残留后台进程: narwhal-traffic-guard.py"
    if [[ "$DRY_RUN" == false && "$SKIP_GUARD_STOP" == false ]]; then
        pkill -9 -f "narwhal-traffic-guard.py" || true
        log_success "已强制终止 narwhal-traffic-guard.py 残留进程"
    fi
fi

# 2. 备份当前运行环境与数据库
log_info "步骤 2/5: 自动备份运行二进制与 SQLite 数据库..."
BAK_TS=$(date +%Y%m%d_%H%M%S)
BAK_DIR="/root/narwhal-backup-${BAK_TS}"

if [[ "$DRY_RUN" == false ]]; then
    mkdir -p "$BAK_DIR"
    if [[ -f "$AGENT_BIN" ]]; then
        cp -fp "$AGENT_BIN" "${BAK_DIR}/narwhal-agent.bak"
        BIN_SHA=$(sha256sum "$AGENT_BIN" | awk '{print $1}')
        echo "$BIN_SHA" > "${BAK_DIR}/narwhal-agent.sha256"
        log_info "二进制备份至: ${BAK_DIR}/narwhal-agent.bak (SHA: ${BIN_SHA:0:16}...)"
    fi
    if [[ -f "$AGENT_DB" ]]; then
        cp -fp "$AGENT_DB" "${BAK_DIR}/agent.db.bak"
        DB_SHA=$(sha256sum "$AGENT_DB" | awk '{print $1}')
        echo "$DB_SHA" > "${BAK_DIR}/agent.db.sha256"
        log_info "数据库备份至: ${BAK_DIR}/agent.db.bak (SHA: ${DB_SHA:0:16}...)"
    fi
    log_success "备份完成，归档目录: $BAK_DIR"
else
    log_info "[dry-run] 将备份至: $BAK_DIR"
fi

# 3. 架构探测与修复版二进制强校验下载安装
log_info "步骤 3/5: 下载并校验修复版二进制 (${TAG_VERSION})..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        EXPECTED_SHA="$SHA_AMD64"
        REMOTE_NAME="runman-agent-linux-amd64-dev"
        ;;
    aarch64|arm64)
        EXPECTED_SHA="$SHA_ARM64"
        REMOTE_NAME="runman-agent-linux-arm64-dev"
        ;;
    *)
        log_error "不支持的系统架构: $ARCH"
        exit 1
        ;;
esac

BIN_URL="${URL_BASE}/${REMOTE_NAME}"
TMP_BIN="/tmp/${REMOTE_NAME}.${BAK_TS}"

if [[ "$DRY_RUN" == false ]]; then
    log_info "正在下载: $BIN_URL"
    if ! curl -fsSL -o "$TMP_BIN" "$BIN_URL"; then
        log_error "下载二进制失败，请检查网络或 GitHub 连通性！"
        rm -f "$TMP_BIN"
        exit 1
    fi

    ACTUAL_SHA=$(sha256sum "$TMP_BIN" | awk '{print $1}')
    if [[ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]]; then
        log_error "SHA256 校验失败！"
        log_error "预期: $EXPECTED_SHA"
        log_error "实际: $ACTUAL_SHA"
        rm -f "$TMP_BIN"
        exit 1
    fi
    log_success "SHA256 强校验通过: ${ACTUAL_SHA:0:16}..."

    # 原子替换与加锁防篡改
    log_info "正在原子安装并加锁防篡改 (+i)..."
    chattr -i "$AGENT_BIN" 2>/dev/null || true
    install -m 0755 "$TMP_BIN" "$AGENT_BIN"
    rm -f "$TMP_BIN"
    chattr +i "$AGENT_BIN"
    log_success "二进制安装成功并已设置 +i 防篡改属性。"
else
    log_info "[dry-run] 将从 $BIN_URL 下载并校验 SHA256 ($EXPECTED_SHA)"
fi

# 4. 先重启服务：把写入方切换为新版二进制，再校准存量数据
#    ⚠️ 顺序安全说明：旧版二进制可能以 podman stats（宿主 veth 视角）采样，
#       与校准写入的 netns（容器视角）raw 基线语义相反，会触发一次"全量重加"；
#       先重启到新版再校准，可彻底避免这最后一次污染。
log_info "步骤 4/5: 重启 narwhal-agent（切换写入方为新版）..."
if [[ "$DRY_RUN" == false ]]; then
    systemctl restart narwhal-agent
    sleep 3
    if systemctl is-active --quiet narwhal-agent; then
        log_success "narwhal-agent 已重启并处于 active 状态"
    else
        log_error "narwhal-agent 启动失败！"
        systemctl status narwhal-agent --no-pager -l || true
        exit 1
    fi
else
    log_info "[dry-run] 将重启 narwhal-agent"
fi

# 5. 可选：存量数据物理校准 (--calibrate)
if [[ "$DO_CALIBRATE" == true ]]; then
    log_info "步骤 5/5: 执行存量虚高数据校准..."
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[dry-run] 跳过实际数据校准写库。"
    else
        python3 - << 'PYEOF'
import sqlite3, os, subprocess, json, time, hashlib

DB = "/opt/narwhal-agent/agent.db"
STATE = "/opt/narwhal-agent/traffic_state.json"

if not os.path.exists(DB):
    print("[-] agent.db 不存在，跳过校准")
    exit(0)

con = sqlite3.connect(DB, timeout=30)
cur = con.cursor()

# 1. 查找运行中容器的 netns 真值
running_vms = {}
try:
    out = subprocess.run(["podman", "ps", "--format", "{{.Names}} {{.Pid}}"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            vm_name, pid = parts[0], int(parts[1])
            dev_path = f"/proc/{pid}/net/dev"
            if os.path.exists(dev_path):
                rx = tx = 0
                for dline in open(dev_path):
                    if ":" not in dline: continue
                    p = dline.split()
                    if len(p) >= 10 and p[0].rstrip(":") != "lo":
                        rx += int(p[1])
                        tx += int(p[9])
                running_vms[vm_name] = (rx, tx)
except Exception as e:
    print(f"[-] 获取运行中容器 netns 失败: {e}")

# 2. 读取停机容器状态快照
state_vms = {}
if os.path.exists(STATE):
    try:
        st = json.load(open(STATE))
        for vm, val in st.items():
            # 字段映射铁律: state.raw_out = 容器 RX (入站); state.raw_in = 容器 TX (出站)
            ro = int(val.get("raw_out", 0))
            ri = int(val.get("raw_in", 0))
            if ro > 0 or ri > 0:
                state_vms[vm] = (ro, ri)
    except Exception as e:
        print(f"[-] 读取 traffic_state.json 异常: {e}")

# 3. 统计并校准
cur.execute("SELECT vm_id, month_in, month_out, raw_in, raw_out FROM traffics")
rows = cur.fetchall()
calibrated = 0
now_ts = time.strftime("%Y-%m-%dT%H:%M:%S")

for vm_id, m_in, m_out, r_in, r_out in rows:
    real_in, real_out = None, None
    source = ""
    if vm_id in running_vms:
        real_in, real_out = running_vms[vm_id]
        source = "运行中(netns)"
    elif vm_id in state_vms:
        real_in, real_out = state_vms[vm_id]
        source = "停机快照(state.json)"
    
    if real_in is not None and real_out is not None:
        # 当库内统计显著高于真值时才做纠偏
        if (m_in + m_out) > (real_in + real_out):
            cur.execute("""
                UPDATE traffics 
                SET month_in=?, month_out=?, total_in=?, total_out=?, raw_in=?, raw_out=?, updated_at=?
                WHERE vm_id=?
            """, (real_in, real_out, real_in, real_out, real_in, real_out, now_ts, vm_id))
            calibrated += 1
            print(f"  [+] 校准 {vm_id[:18]}... ({source}): 入 {m_in/1073741824:.2f}G->{real_in/1073741824:.2f}G, 出 {m_out/1073741824:.2f}G->{real_out/1073741824:.2f}G")

con.commit()
con.close()
print(f"[+] 存量校准完成: 共纠偏 {calibrated} 台实例记录。")
PYEOF
    fi
else
    log_info "步骤 4/5: 跳过存量校准（未指定 --calibrate 参数）。"
fi

# 6. 四项硬核验收断言
log_info "验收: 执行四项硬核断言..."
if [[ "$DRY_RUN" == false ]]; then
    echo ""
    echo "========================================================"
    echo "                 验收断言核验报告"
    echo "========================================================"

    # 断言 1: 服务正常运行
    if systemctl is-active --quiet narwhal-agent; then
        log_success "断言 1: narwhal-agent 服务状态正常 (active)"
    else
        log_error "断言 1: narwhal-agent 启动失败！"
        systemctl status narwhal-agent --no-pager -l || true
        exit 1
    fi

    # 断言 2: 停更机制激活（Dev version detected）
    DEV_HIT=$(journalctl -u narwhal-agent -n 60 --no-pager | grep -c "Dev version detected, auto-update disabled" || true)
    if [[ "$DEV_HIT" -ge 1 ]]; then
        log_success "断言 2: 停更机制确认生效 (Dev version detected 命中 $DEV_HIT 次，永久切断自更覆盖)"
    else
        log_warn "断言 2: 暂未在最近日志中捕获停更标记，请检查 journalctl -u narwhal-agent"
    fi

    # 断言 3: 冲突守护服务已确保停止
    if systemctl is-active --quiet "$GUARD_SVC" 2>/dev/null; then
        log_error "断言 3: $GUARD_SVC 仍处于运行状态！必须立即停止该服务！"
        exit 1
    else
        log_success "断言 3: 冲突守护服务确认关闭 (inactive)"
    fi

    # 断言 4: 端口 8792 正常监听
    if ss -tulpn | grep -q ":8792"; then
        log_success "断言 4: gRPC/业务通信端口 8792 处于正常监听状态"
    else
        log_warn "断言 4: 端口 8792 未检测到监听，请检查端口配置"
    fi

    echo "========================================================"
    log_success "恭喜！Runman Agent 流量统计虚高已成功根治。"
    log_info "提示: 静置 120 秒后可使用 scripts/traffic-source-triangulate.py 验证流量增量。"
else
    log_info "[dry-run] 完成演练，未做实质更改。"
fi
