#!/usr/bin/env bash
set -Eeuo pipefail

readonly TOOL_VERSION="0.1.0"
readonly BEGIN_HOSTS="# BEGIN YRCF MANAGED HOSTS"
readonly END_HOSTS="# END YRCF MANAGED HOSTS"

declare -A CFG=()
declare -a NODES=()
CONFIG_FILE=""
MODE=""
CURRENT_NODE=""
LOG_FILE=""
ERRORS=0
WARNINGS=0

usage() {
    cat <<'EOF'
YRCF 节点环境准备工具

用法：
  yrcf-node-prepare.sh [--config <配置文件>] --dry-run
  yrcf-node-prepare.sh [--config <配置文件>] --apply
  yrcf-node-prepare.sh [--config <配置文件>] --check

内部参数（请勿手工使用）：
  --local-apply --node <节点名>
  --local-check --node <节点名>

选项：
  --config FILE    指定 INI 配置文件；默认 /etc/yrfs/node-prepare.conf
  --apply          从控制节点集中配置所有节点
  --check          从控制节点集中检查所有节点
  --dry-run        校验配置并显示执行计划，不修改节点
  --version        显示版本
  -h, --help       显示帮助
EOF
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local level="$1"
    shift
    printf '[%s] [%-5s] %s\n' "$(timestamp)" "$level" "$*"
}

info() { log INFO "$@"; }
warn() {
    WARNINGS=$((WARNINGS + 1))
    log WARN "$@"
}
fail() {
    ERRORS=$((ERRORS + 1))
    log ERROR "$@"
}
die() {
    log ERROR "$*"
    exit 1
}

trim() {
    local value="$*"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

parse_args() {
    while (($#)); do
        case "$1" in
            --config)
                (($# >= 2)) || die "--config 缺少参数"
                CONFIG_FILE="$2"
                shift 2
                ;;
            --apply|--check|--dry-run|--local-apply|--local-check)
                [[ -z "$MODE" ]] || die "只能指定一种执行模式"
                MODE="${1#--}"
                shift
                ;;
            --node)
                (($# >= 2)) || die "--node 缺少参数"
                CURRENT_NODE="$2"
                shift 2
                ;;
            --version)
                printf '%s\n' "$TOOL_VERSION"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        CONFIG_FILE="/etc/yrfs/node-prepare.conf"
    fi
    [[ -f "$CONFIG_FILE" ]] || die "配置文件不存在：$CONFIG_FILE"
    [[ -n "$MODE" ]] || die "必须指定 --apply、--check 或 --dry-run"

    if [[ "$MODE" == local-* ]]; then
        [[ -n "$CURRENT_NODE" ]] || die "内部执行模式必须指定 --node"
    fi
}

parse_config() {
    local section=""
    local raw line key value

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        raw="${raw%$'\r'}"
        line="$(trim "$raw")"
        [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && continue

        if [[ "$line" =~ ^\[([A-Za-z0-9._-]+)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            if [[ "$section" != "global" ]]; then
                NODES+=("$section")
            fi
            continue
        fi

        [[ -n "$section" ]] || die "配置项必须位于节中：$line"
        [[ "$line" == *=* ]] || die "无效配置行：$line"
        key="$(trim "${line%%=*}")"
        value="$(trim "${line#*=}")"
        [[ "$key" =~ ^[A-Za-z][A-Za-z0-9_]*$ ]] || die "无效配置键：$key"
        CFG["$section.$key"]="$value"
    done < "$CONFIG_FILE"

    ((${#NODES[@]} > 0)) || die "配置文件中没有节点"
}

cfg() {
    local section="$1"
    local key="$2"
    local default="${3-}"
    printf '%s' "${CFG["$section.$key"]-$default}"
}

require_cfg() {
    local section="$1"
    local key="$2"
    local value
    value="$(cfg "$section" "$key")"
    [[ -n "$value" ]] || die "缺少配置项 [$section] $key"
    printf '%s' "$value"
}

is_true() {
    case "${1,,}" in
        true|yes|1|on) return 0 ;;
        *) return 1 ;;
    esac
}

valid_ipv4_cidr() {
    local value="$1"
    local ip prefix octet
    local -a octets=()
    [[ "$value" == */* ]] || return 1
    ip="${value%/*}"
    prefix="${value##*/}"
    [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 32)) || return 1
    IFS='.' read -ra octets <<< "$ip"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

validate_config() {
    local node connect_ip hosts_ip interfaces iface address table network
    local sync_time timezone ntp_servers ntp_master max_skew
    local -A seen_hosts=()
    local -A seen_connect_ips=()
    local -A node_set=()

    for node in "${NODES[@]}"; do
        node_set["$node"]=1
        connect_ip="$(require_cfg "$node" connect_ip)"
        hosts_ip="$(cfg "$node" hosts_ip "$connect_ip")"
        interfaces="$(require_cfg "$node" interfaces)"

        [[ "$node" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
            die "无效节点名：$node"
        [[ -z "${seen_hosts[$node]-}" ]] || die "节点名重复：$node"
        [[ -z "${seen_connect_ips[$connect_ip]-}" ]] ||
            die "connect_ip 重复：$connect_ip"
        seen_hosts["$node"]=1
        seen_connect_ips["$connect_ip"]=1

        valid_ipv4_cidr "$connect_ip/32" ||
            die "[$node] connect_ip 不是有效 IPv4 地址：$connect_ip"
        valid_ipv4_cidr "$hosts_ip/32" ||
            die "[$node] hosts_ip 不是有效 IPv4 地址：$hosts_ip"

        IFS=',' read -ra iface_list <<< "$interfaces"
        ((${#iface_list[@]} > 0)) || die "[$node] interfaces 不能为空"
        for iface in "${iface_list[@]}"; do
            iface="$(trim "$iface")"
            [[ "$iface" =~ ^[A-Za-z0-9_.:-]+$ ]] ||
                die "[$node] 无效网卡名称：$iface"
            address="$(require_cfg "$node" "${iface}_address")"
            table="$(require_cfg "$node" "${iface}_table")"
            network="$(require_cfg "$node" "${iface}_network")"
            valid_ipv4_cidr "$address" ||
                die "[$node] ${iface}_address 不是有效 CIDR：$address"
            valid_ipv4_cidr "$network" ||
                die "[$node] ${iface}_network 不是有效 CIDR：$network"
            [[ "$table" =~ ^[0-9]+$ ]] && ((table >= 1 && table <= 4294967295)) ||
                die "[$node] ${iface}_table 不是有效路由表号：$table"
        done
    done

    sync_time="$(cfg global sync_time true)"
    case "${sync_time,,}" in
        true|yes|1|on|false|no|0|off) ;;
        *) die "[global] sync_time 必须是 true/false：$sync_time" ;;
    esac

    timezone="$(cfg global timezone Asia/Shanghai)"
    [[ -n "$timezone" ]] || die "[global] timezone 不能为空"

    max_skew="$(cfg global max_time_skew_sec 1)"
    [[ "$max_skew" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
        die "[global] max_time_skew_sec 必须是非负数字：$max_skew"

    ntp_servers="$(cfg global ntp_servers)"
    ntp_master="$(cfg global ntp_master)"
    if [[ -n "$ntp_master" && -z "${node_set[$ntp_master]-}" ]]; then
        die "[global] ntp_master 不是已配置的节点名：$ntp_master"
    fi
    if [[ -z "$ntp_servers" && -z "$ntp_master" ]]; then
        ntp_master="${NODES[0]}"
        CFG["global.ntp_master"]="$ntp_master"
    fi
}

require_commands() {
    local cmd
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少命令：$cmd"
    done
}

setup_logging() {
    LOG_FILE="$(cfg global log_file /var/log/yrcf-node-prepare.log)"
    if [[ "$MODE" == local-* ]]; then
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE"
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi
}

print_plan() {
    local node interfaces iface
    local sync_time timezone ntp_servers ntp_master max_skew
    info "配置文件校验通过，共 ${#NODES[@]} 个节点"
    info "以下操作仅为预览，不会修改系统"

    sync_time="$(cfg global sync_time true)"
    timezone="$(cfg global timezone Asia/Shanghai)"
    ntp_servers="$(cfg global ntp_servers)"
    ntp_master="$(cfg global ntp_master "${NODES[0]}")"
    max_skew="$(cfg global max_time_skew_sec 1)"
    printf '\n[时钟同步]\n'
    printf '  sync_time：%s\n' "$sync_time"
    printf '  timezone：%s\n' "$timezone"
    printf '  max_time_skew_sec：%s\n' "$max_skew"
    if is_true "$sync_time"; then
        if [[ -n "$ntp_servers" ]]; then
            printf '  模式：NTP客户端（ntp_servers=%s）\n' "$ntp_servers"
        else
            printf '  模式：集群内时间源（ntp_master=%s）\n' "$ntp_master"
        fi
        printf '  要求：各节点事先安装 chrony（脚本不负责安装）\n'
    else
        printf '  模式：跳过\n'
    fi

    for node in "${NODES[@]}"; do
        printf '\n[%s]\n' "$node"
        printf '  连接地址：%s\n' "$(cfg "$node" connect_ip)"
        printf '  hosts地址：%s\n' "$(cfg "$node" hosts_ip "$(cfg "$node" connect_ip)")"
        printf '  网卡配置：\n'
        interfaces="$(cfg "$node" interfaces)"
        IFS=',' read -ra iface_list <<< "$interfaces"
        for iface in "${iface_list[@]}"; do
            iface="$(trim "$iface")"
            printf '    %s: %s，网段 %s，路由表 %s\n' \
                "$iface" \
                "$(cfg "$node" "${iface}_address")" \
                "$(cfg "$node" "${iface}_network")" \
                "$(cfg "$node" "${iface}_table")"
        done
        printf '  预期磁盘：%s\n' "$(cfg "$node" expected_disks 未指定)"
        printf '  Netplan文件：%s\n' "$(resolve_netplan_file "$node")"
    done
}

ssh_options() {
    printf '%s\n' \
        "-i" "$(cfg global controller_key /root/.ssh/id_rsa)" \
        "-o" "ConnectTimeout=$(cfg global ssh_connect_timeout 10)" \
        "-o" "ServerAliveInterval=15" \
        "-o" "ServerAliveCountMax=2" \
        "-o" "StrictHostKeyChecking=accept-new"
}

run_ssh() {
    local ip="$1"
    shift
    local -a opts=()
    mapfile -t opts < <(ssh_options)
    ssh "${opts[@]}" "root@$ip" "$@"
}

copy_to_node() {
    local source="$1"
    local ip="$2"
    local target="$3"
    local -a opts=()
    mapfile -t opts < <(ssh_options)
    scp "${opts[@]}" "$source" "root@$ip:$target"
}

ensure_controller_access() {
    local key_file node ip
    key_file="$(cfg global controller_key /root/.ssh/id_rsa)"
    mkdir -p "$(dirname "$key_file")"

    if [[ ! -f "$key_file" ]]; then
        info "生成控制节点 SSH 密钥：$key_file"
        ssh-keygen -q -t rsa -b 3072 -N '' -f "$key_file"
    fi

    for node in "${NODES[@]}"; do
        ip="$(cfg "$node" connect_ip)"
        if ssh -i "$key_file" -o BatchMode=yes -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=accept-new "root@$ip" true >/dev/null 2>&1; then
            info "[$node] 控制节点SSH访问正常"
        else
            info "[$node] 首次建立SSH访问，请按提示输入 root 密码"
            ssh-copy-id -i "${key_file}.pub" -o StrictHostKeyChecking=accept-new \
                "root@$ip"
        fi
    done
}

remote_execute() {
    local action="$1"
    local script_path config_path node ip remote_base
    script_path="$(readlink -f "$0")"
    config_path="$(readlink -f "$CONFIG_FILE")"
    remote_base="/tmp/yrcf-node-prepare.$$"

    for node in "${NODES[@]}"; do
        ip="$(cfg "$node" connect_ip)"
        info "[$node] 开始执行 $action"
        copy_to_node "$script_path" "$ip" "${remote_base}.sh"
        copy_to_node "$config_path" "$ip" "${remote_base}.conf"
        if run_ssh "$ip" \
            "chmod 700 '${remote_base}.sh' && bash '${remote_base}.sh' --config '${remote_base}.conf' --local-${action} --node '$node'; rc=\$?; rm -f '${remote_base}.sh' '${remote_base}.conf'; exit \$rc"; then
            info "[$node] $action 完成"
        else
            fail "[$node] $action 失败"
        fi
    done
}

configure_all_to_all_ssh() {
    local node ip pubkey peer peer_ip attempt ok
    local -a public_keys=()
    local max_attempts=5
    local retry_delay=3

    info "收集各节点SSH公钥"
    for node in "${NODES[@]}"; do
        ip="$(cfg "$node" connect_ip)"
        pubkey="$(run_ssh "$ip" "cat /root/.ssh/id_rsa.pub")" ||
            die "无法读取 $node 的SSH公钥"
        public_keys+=("$pubkey")
    done

    info "向各节点分发SSH公钥"
    for node in "${NODES[@]}"; do
        ip="$(cfg "$node" connect_ip)"
        for pubkey in "${public_keys[@]}"; do
            printf '%s\n' "$pubkey" | run_ssh "$ip" \
                "umask 077; mkdir -p /root/.ssh; touch /root/.ssh/authorized_keys; key=\$(cat); grep -qxF \"\$key\" /root/.ssh/authorized_keys || printf '%s\n' \"\$key\" >> /root/.ssh/authorized_keys" ||
                die "[$node] 写入SSH公钥失败"
        done
    done

    info "检查节点间SSH互信"
    for node in "${NODES[@]}"; do
        ip="$(cfg "$node" connect_ip)"
        for peer in "${NODES[@]}"; do
            [[ "$node" == "$peer" ]] && continue
            peer_ip="$(cfg "$peer" hosts_ip "$(cfg "$peer" connect_ip)")"
            ok=0
            for ((attempt = 1; attempt <= max_attempts; attempt++)); do
                if run_ssh "$ip" \
                    "ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new root@'$peer_ip' hostname >/dev/null"; then
                    ok=1
                    break
                fi
                if ((attempt < max_attempts)); then
                    warn "[$node] 访问 $peer($peer_ip) 失败，${retry_delay}s 后重试 ($attempt/$max_attempts)"
                    sleep "$retry_delay"
                fi
            done
            if ((ok == 0)); then
                fail "[$node] 无法免密访问 $peer($peer_ip)"
            else
                info "[$node] 免密访问 $peer($peer_ip) 正常"
            fi
        done
    done
}

# 生成写入 chrony conf.d 的内容：mode=servers|master|client
build_chrony_managed_conf() {
    local mode="$1"
    local ntp_servers="$2"
    local master_ip="$3"
    local server item peer peer_ip

    printf '%s\n' '# Managed by yrcf-node-prepare. Do not edit.'
    case "$mode" in
        servers)
            IFS=',' read -ra server_list <<< "$ntp_servers"
            for item in "${server_list[@]}"; do
                item="$(trim "$item")"
                [[ -n "$item" ]] || continue
                printf 'server %s iburst\n' "$item"
            done
            ;;
        master)
            printf 'local stratum 10\n'
            for peer in "${NODES[@]}"; do
                peer_ip="$(cfg "$peer" hosts_ip "$(cfg "$peer" connect_ip)")"
                printf 'allow %s\n' "$peer_ip"
            done
            ;;
        client)
            printf 'server %s iburst\n' "$master_ip"
            ;;
        *)
            die "未知时钟同步模式：$mode"
            ;;
    esac
}

configure_node_time() {
    local node="$1"
    local mode="$2"
    local timezone="$3"
    local ntp_servers="$4"
    local master_ip="$5"
    local ip managed_conf
    local -a opts=()

    ip="$(cfg "$node" connect_ip)"
    managed_conf="$(build_chrony_managed_conf "$mode" "$ntp_servers" "$master_ip")"
    mapfile -t opts < <(ssh_options)

    info "[$node] 配置时钟同步（mode=$mode, timezone=$timezone）"
    ssh "${opts[@]}" "root@$ip" "bash -s" <<REMOTE
set -euo pipefail
timezone='$timezone'

command -v chronyd >/dev/null 2>&1 || {
    echo "ERROR: chrony 未安装，请先手工执行: apt install -y chrony" >&2
    exit 1
}
command -v chronyc >/dev/null 2>&1 || {
    echo "ERROR: chronyc 不可用，请确认已安装 chrony" >&2
    exit 1
}

timedatectl set-timezone "\$timezone"
systemctl disable --now systemd-timesyncd 2>/dev/null || true

if [[ -f /etc/chrony/chrony.conf ]]; then
    if [[ ! -f /etc/chrony/chrony.conf.yrcf-orig ]]; then
        cp -a /etc/chrony/chrony.conf /etc/chrony/chrony.conf.yrcf-orig
    fi
    # 注释主配置中的 stock pool/server，避免与托管源冲突
    sed -E -i 's/^(pool|server)([[:space:]])/# \1\2/' /etc/chrony/chrony.conf
    if ! grep -qE '^[[:space:]]*confdir[[:space:]]+/etc/chrony/conf\.d' /etc/chrony/chrony.conf; then
        printf '\nconfdir /etc/chrony/conf.d\n' >> /etc/chrony/chrony.conf
    fi
fi

mkdir -p /etc/chrony/conf.d
cat > /etc/chrony/conf.d/yrcf-time.conf <<'CONF'
${managed_conf}
CONF

systemctl enable chrony >/dev/null
systemctl restart chrony
sleep 2
chronyc -a makestep >/dev/null 2>&1 || chronyc makestep >/dev/null 2>&1 || true
systemctl is-active --quiet chrony
REMOTE
}

configure_cluster_time() {
    local timezone ntp_servers ntp_master master_ip node mode

    if ! is_true "$(cfg global sync_time true)"; then
        info "跳过时钟同步（sync_time=false）"
        return 0
    fi

    timezone="$(cfg global timezone Asia/Shanghai)"
    ntp_servers="$(cfg global ntp_servers)"
    ntp_master="$(cfg global ntp_master "${NODES[0]}")"
    master_ip="$(cfg "$ntp_master" hosts_ip "$(cfg "$ntp_master" connect_ip)")"

    info "开始配置集群时钟同步"
    if [[ -n "$ntp_servers" ]]; then
        info "使用 NTP 服务器：$ntp_servers"
        for node in "${NODES[@]}"; do
            configure_node_time "$node" servers "$timezone" "$ntp_servers" "" ||
                fail "[$node] 时钟同步配置失败"
        done
    else
        info "使用集群时间源：$ntp_master ($master_ip)"
        for node in "${NODES[@]}"; do
            if [[ "$node" == "$ntp_master" ]]; then
                mode=master
            else
                mode=client
            fi
            configure_node_time "$node" "$mode" "$timezone" "" "$master_ip" ||
                fail "[$node] 时钟同步配置失败"
        done
    fi

    sleep 3
    check_cluster_time_skew
}

check_node_time() {
    local timezone expected
    if ! is_true "$(cfg global sync_time true)"; then
        return 0
    fi

    timezone="$(cfg global timezone Asia/Shanghai)"
    if ! command -v chronyd >/dev/null 2>&1; then
        fail "未安装 chrony，请先手工执行: apt install -y chrony"
        return 0
    fi
    if ! systemctl is-active --quiet chrony; then
        fail "chrony 服务未运行"
    else
        info "chrony 服务运行中"
    fi

    expected="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    if [[ -n "$expected" && "$expected" != "$timezone" ]]; then
        fail "时区不符合预期：实际 $expected，预期 $timezone"
    else
        info "时区：$timezone"
    fi
}

check_cluster_time_skew() {
    local node ip epoch max_skew ref_node ref_epoch skew
    local -A epochs=()

    if ! is_true "$(cfg global sync_time true)"; then
        return 0
    fi

    max_skew="$(cfg global max_time_skew_sec 1)"
    info "检查节点间时间偏差（阈值 ${max_skew}s）"

    for node in "${NODES[@]}"; do
        ip="$(cfg "$node" connect_ip)"
        epoch="$(run_ssh "$ip" "date -u +%s" 2>/dev/null || true)"
        if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
            fail "[$node] 无法读取系统时间"
            continue
        fi
        epochs["$node"]="$epoch"
        info "[$node] unix时间=$epoch"
    done

    ref_node="${NODES[0]}"
    ref_epoch="${epochs[$ref_node]-}"
    [[ -n "$ref_epoch" ]] || return 1

    for node in "${NODES[@]}"; do
        [[ -n "${epochs[$node]-}" ]] || continue
        skew=$(( epochs[$node] - ref_epoch ))
        ((skew < 0)) && skew=$((-skew))
        # bash 整数比较；支持小数阈值时向下取整到秒，至少按 1 秒比较若阈值为小数
        if awk -v s="$skew" -v m="$max_skew" 'BEGIN { exit !(s > m) }'; then
            fail "[$node] 相对 $ref_node 时间偏差 ${skew}s，超过阈值 ${max_skew}s"
        else
            info "[$node] 相对 $ref_node 时间偏差 ${skew}s，正常"
        fi
    done

    ((ERRORS == 0))
}

backup_file() {
    local path="$1"
    if [[ -e "$path" ]]; then
        cp -a "$path" "${path}.yrcf-backup.$(date +%Y%m%d%H%M%S)"
    fi
}

check_os_hardware() {
    local expected_arch expected_os actual_arch actual_os pretty_os
    local min_memory_gb memory_gb
    expected_arch="$(cfg global expected_arch)"
    expected_os="$(cfg global expected_os_id)"
    actual_arch="$(uname -m)"
    actual_os="$(awk -F= '$1 == "ID" {
        value=substr($0, index($0, "=") + 1)
        gsub(/^"|"$/, "", value)
        print value
    }' /etc/os-release)"
    pretty_os="$(awk -F= '$1 == "PRETTY_NAME" {
        value=substr($0, index($0, "=") + 1)
        gsub(/^"|"$/, "", value)
        print value
    }' /etc/os-release)"
    actual_os="${actual_os:-unknown}"
    pretty_os="${pretty_os:-$actual_os}"

    if [[ -n "$expected_arch" && "$actual_arch" != "$expected_arch" ]]; then
        fail "CPU架构不符合预期：实际 $actual_arch，预期 $expected_arch"
    else
        info "CPU架构：$actual_arch"
    fi

    if [[ -n "$expected_os" && "$actual_os" != "$expected_os" ]]; then
        fail "操作系统不符合预期：实际 $actual_os，预期 $expected_os"
    else
        info "操作系统：$pretty_os"
    fi

    min_memory_gb="$(cfg global min_memory_gb 0)"
    if [[ "$min_memory_gb" =~ ^[0-9]+$ ]] && ((min_memory_gb > 0)); then
        memory_gb="$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))"
        if ((memory_gb < min_memory_gb)); then
            fail "内存不足：实际约 ${memory_gb}GiB，最低 ${min_memory_gb}GiB"
        else
            info "内存检查通过：约 ${memory_gb}GiB"
        fi
    fi
}

check_required_interfaces() {
    local interfaces iface
    interfaces="$(cfg "$CURRENT_NODE" interfaces)"
    IFS=',' read -ra iface_list <<< "$interfaces"
    for iface in "${iface_list[@]}"; do
        iface="$(trim "$iface")"
        if [[ ! -d "/sys/class/net/$iface" ]]; then
            fail "预期网卡不存在：$iface"
        fi
    done
}

configure_security() {
    if is_true "$(cfg global disable_ufw true)"; then
        if command -v ufw >/dev/null 2>&1; then
            ufw --force disable
        fi
        systemctl disable --now ufw 2>/dev/null || true
    fi

    if is_true "$(cfg global disable_apparmor true)"; then
        systemctl disable --now apparmor 2>/dev/null || true
    fi
}

configure_logrotate() {
    if ! is_true "$(cfg global configure_logrotate true)"; then
        info "跳过日志轮询配置（configure_logrotate=false）"
        return 0
    fi

    command -v logrotate >/dev/null 2>&1 ||
        die "未安装 logrotate，请先手工安装后再执行"

    mkdir -p /etc/logrotate.d

    # 与现网参考机（如 192.168.21.10）保持一致：copytruncate + maxsize + compress
    cat > /etc/logrotate.d/yrfs <<'EOF'
compress
/var/log/yrfs*.log {
    rotate 10
    missingok
    compress
    maxsize 1G
    copytruncate
}
EOF

    # 覆盖 /var/log/etcd.log 与 /var/log/etcd/*.log（本仓库 etcd 部署路径）
    cat > /etc/logrotate.d/etcd <<'EOF'
compress
/var/log/etcd*.log
/var/log/etcd/*.log {
    rotate 10
    missingok
    compress
    maxsize 100M
    copytruncate
}
EOF

    chmod 644 /etc/logrotate.d/yrfs /etc/logrotate.d/etcd
    if ! logrotate -d /etc/logrotate.d/yrfs >/dev/null 2>&1; then
        die "logrotate 配置语法检查失败：/etc/logrotate.d/yrfs"
    fi
    if ! logrotate -d /etc/logrotate.d/etcd >/dev/null 2>&1; then
        die "logrotate 配置语法检查失败：/etc/logrotate.d/etcd"
    fi

    # 每 15 分钟检查 yrfs/etcd 日志（使 maxsize 及时生效；Ubuntu/CentOS 通用）
    command -v crontab >/dev/null 2>&1 ||
        die "未安装 cron，请先手工执行: apt install -y cron"

    cat > /etc/cron.d/yrcf-logrotate <<'EOF'
# Managed by yrcf-node-prepare. Do not edit.
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/15 * * * * root /usr/sbin/logrotate /etc/logrotate.d/yrfs /etc/logrotate.d/etcd >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/yrcf-logrotate

    if systemctl list-unit-files cron.service >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 || true
    elif systemctl list-unit-files crond.service >/dev/null 2>&1; then
        systemctl enable --now crond >/dev/null 2>&1 || true
    fi

    info "已部署日志轮询：/etc/logrotate.d/yrfs、/etc/logrotate.d/etcd、/etc/cron.d/yrcf-logrotate（每15分钟）"
}

check_security() {
    if is_true "$(cfg global disable_ufw true)" &&
        systemctl is-active --quiet ufw 2>/dev/null; then
        fail "ufw仍处于运行状态"
    else
        info "ufw状态符合预期"
    fi

    if is_true "$(cfg global disable_apparmor true)" &&
        systemctl is-active --quiet apparmor 2>/dev/null; then
        fail "AppArmor仍处于运行状态"
    else
        info "AppArmor状态符合预期"
    fi
}

check_logrotate() {
    if ! is_true "$(cfg global configure_logrotate true)"; then
        return 0
    fi

    if ! command -v logrotate >/dev/null 2>&1; then
        fail "未安装 logrotate"
        return 0
    fi

    if [[ ! -f /etc/logrotate.d/yrfs ]]; then
        fail "缺少 /etc/logrotate.d/yrfs"
    else
        info "已存在 /etc/logrotate.d/yrfs"
    fi

    if [[ ! -f /etc/logrotate.d/etcd ]]; then
        fail "缺少 /etc/logrotate.d/etcd"
    else
        info "已存在 /etc/logrotate.d/etcd"
    fi

    if [[ ! -f /etc/cron.d/yrcf-logrotate ]]; then
        fail "缺少 /etc/cron.d/yrcf-logrotate"
    else
        info "已存在 /etc/cron.d/yrcf-logrotate"
    fi

    if systemctl is-active --quiet cron 2>/dev/null ||
        systemctl is-active --quiet crond 2>/dev/null; then
        info "cron 服务运行中"
    else
        fail "cron 服务未运行（日志轮询定时任务不会执行）"
    fi
}

configure_hostname_hosts() {
    local node hosts_ip temp_file
    hostnamectl set-hostname "$CURRENT_NODE"
    backup_file /etc/hosts
    temp_file="$(mktemp)"

    awk -v begin="$BEGIN_HOSTS" -v end="$END_HOSTS" '
        $0 == begin {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' /etc/hosts > "$temp_file"

    {
        printf '\n%s\n' "$BEGIN_HOSTS"
        for node in "${NODES[@]}"; do
            hosts_ip="$(cfg "$node" hosts_ip "$(cfg "$node" connect_ip)")"
            printf '%s %s\n' "$hosts_ip" "$node"
        done
        printf '%s\n' "$END_HOSTS"
    } >> "$temp_file"

    install -m 0644 "$temp_file" /etc/hosts
    rm -f "$temp_file"
}

check_hostname_hosts() {
    local node expected_ip actual_ip errors_before
    errors_before="$ERRORS"
    if [[ "$(hostname)" != "$CURRENT_NODE" ]]; then
        fail "主机名不正确：实际 $(hostname)，预期 $CURRENT_NODE"
    else
        info "主机名检查通过：$CURRENT_NODE"
    fi

    for node in "${NODES[@]}"; do
        expected_ip="$(cfg "$node" hosts_ip "$(cfg "$node" connect_ip)")"
        actual_ip="$(getent ahostsv4 "$node" | awk 'NR==1 {print $1}')"
        if [[ "$actual_ip" != "$expected_ip" ]]; then
            fail "$node 解析错误：实际 ${actual_ip:-无结果}，预期 $expected_ip"
        fi
    done
    if ((ERRORS == errors_before)); then
        info "主机解析检查通过"
    fi
    return 0
}

ensure_node_key() {
    install -d -m 0700 /root/.ssh
    if [[ ! -f /root/.ssh/id_rsa ]]; then
        ssh-keygen -q -t rsa -b 3072 -N '' -f /root/.ssh/id_rsa
    fi
}

resolve_netplan_file() {
    local node="$1"
    local explicit template connect_ip id out

    explicit="$(cfg global netplan_file)"
    if [[ -n "$explicit" ]]; then
        printf '%s' "$explicit"
        return
    fi

    template="$(cfg global netplan_file_template /etc/netplan/{id}-ib-net.yaml)"
    connect_ip="$(cfg "$node" connect_ip)"
    id="${connect_ip##*.}"
    out="${template//\{id\}/$id}"
    printf '%s' "$out"
}

generate_netplan() {
    local output="$1"
    local interfaces iface address table network source_ip renderer
    renderer="$(cfg global netplan_renderer networkd)"
    interfaces="$(cfg "$CURRENT_NODE" interfaces)"

    {
        printf 'network:\n'
        printf '  version: 2\n'
        printf '  ethernets:\n'
        IFS=',' read -ra iface_list <<< "$interfaces"
        for iface in "${iface_list[@]}"; do
            iface="$(trim "$iface")"
            address="$(cfg "$CURRENT_NODE" "${iface}_address")"
            table="$(cfg "$CURRENT_NODE" "${iface}_table")"
            network="$(cfg "$CURRENT_NODE" "${iface}_network")"
            source_ip="${address%%/*}"
            printf '    %s:\n' "$iface"
            printf '      renderer: %s\n' "$renderer"
            printf '      match:\n'
            printf '        name: %s\n' "$iface"
            printf '      dhcp4: false\n'
            printf '      optional: true\n'
            printf '      addresses:\n'
            printf '        - %s\n' "$address"
            printf '      routes:\n'
            printf '        - to: %s\n' "$network"
            printf '          scope: link\n'
            printf '          table: %s\n' "$table"
            printf '      routing-policy:\n'
            printf '        - from: %s/32\n' "$source_ip"
            printf '          table: %s\n' "$table"
            printf '        - to: %s/32\n' "$source_ip"
            printf '          table: %s\n' "$table"
        done
    } > "$output"
}

restore_netplan() {
    local target="$1"
    local backup="$2"
    if [[ -n "$backup" && -f "$backup" ]]; then
        cp -a "$backup" "$target"
    else
        rm -f "$target"
    fi
    netplan generate >/dev/null 2>&1 || true
    netplan apply >/dev/null 2>&1 || true
}

configure_network() {
    local target temp_file backup="" errors_before
    target="$(resolve_netplan_file "$CURRENT_NODE")"
    temp_file="$(mktemp)"
    generate_netplan "$temp_file"

    if [[ -e "$target" ]]; then
        backup="${target}.yrcf-backup.$(date +%Y%m%d%H%M%S)"
        cp -a "$target" "$backup"
    fi
    install -m 0600 "$temp_file" "$target"
    rm -f "$temp_file"

    if ! netplan generate; then
        restore_netplan "$target" "$backup"
        die "Netplan语法检查失败，已恢复原配置"
    fi

    if ! netplan apply; then
        restore_netplan "$target" "$backup"
        die "Netplan应用失败，已恢复原配置"
    fi

    errors_before="$ERRORS"
    check_network false
    if ((ERRORS > errors_before)); then
        restore_netplan "$target" "$backup"
        die "Netplan应用后的本地检查失败，已恢复原配置"
    fi
}

check_network() {
    local check_peers="${1:-true}"
    local interfaces iface address source_ip table network peer peer_address peer_ip
    interfaces="$(cfg "$CURRENT_NODE" interfaces)"
    IFS=',' read -ra iface_list <<< "$interfaces"

    for iface in "${iface_list[@]}"; do
        iface="$(trim "$iface")"
        address="$(cfg "$CURRENT_NODE" "${iface}_address")"
        source_ip="${address%%/*}"
        table="$(cfg "$CURRENT_NODE" "${iface}_table")"
        network="$(cfg "$CURRENT_NODE" "${iface}_network")"

        if [[ ! -d "/sys/class/net/$iface" ]]; then
            fail "网卡不存在：$iface"
            continue
        fi
        ip -o -4 addr show dev "$iface" | grep -Fqw "$address" ||
            fail "$iface 未配置地址 $address"
        ip rule show | grep -Eq "from ${source_ip//./\\.}(/32)? .*lookup ${table}([[:space:]]|$)" ||
            fail "$iface 缺少源地址策略路由"
        ip rule show | grep -Eq "to ${source_ip//./\\.}(/32)? .*lookup ${table}([[:space:]]|$)" ||
            fail "$iface 缺少目的地址策略路由"
        ip route show table "$table" | grep -Eq "^${network//./\\.} .*dev ${iface}([[:space:]]|$)" ||
            fail "路由表 $table 缺少 $network dev $iface"

        if is_true "$check_peers"; then
            for peer in "${NODES[@]}"; do
                [[ "$peer" == "$CURRENT_NODE" ]] && continue
                if [[ ",$(cfg "$peer" interfaces)," == *",$iface,"* ]]; then
                    peer_address="$(cfg "$peer" "${iface}_address")"
                    peer_ip="${peer_address%%/*}"
                    ping -I "$iface" -c 2 -W 2 "$peer_ip" >/dev/null 2>&1 ||
                        fail "$iface 无法访问 $peer($peer_ip)"
                fi
            done
        fi
    done
}

check_disks() {
    local expected_disks disk missing=0
    expected_disks="$(cfg "$CURRENT_NODE" expected_disks)"
    if [[ -z "$expected_disks" ]]; then
        warn "未配置 expected_disks，仅输出当前磁盘信息"
        lsblk -d -o NAME,SIZE,TYPE,MODEL
        return
    fi

    IFS=',' read -ra disk_list <<< "$expected_disks"
    for disk in "${disk_list[@]}"; do
        disk="$(trim "$disk")"
        if [[ ! -b "$disk" ]]; then
            fail "预期磁盘不存在：$disk"
            missing=1
        elif findmnt -rn -S "$disk" >/dev/null 2>&1; then
            fail "预期磁盘已被挂载：$disk"
        fi
    done
    if ((missing == 0)); then
        info "预期磁盘均已识别"
    fi
    return 0
}

local_apply() {
    [[ "$EUID" -eq 0 ]] || die "节点配置必须以root执行"
    require_commands hostnamectl systemctl ip awk install getent ssh-keygen \
        netplan ping lsblk findmnt
    info "[$CURRENT_NODE] 开始节点环境配置"
    check_os_hardware
    check_required_interfaces
    check_disks
    ((ERRORS == 0)) || die "系统或硬件预检查失败"
    configure_security
    configure_logrotate
    configure_hostname_hosts
    ensure_node_key
    configure_network
    local_check false
}

local_check() {
    local check_peers="${1:-true}"
    [[ "$EUID" -eq 0 ]] || die "节点检查必须以root执行"
    require_commands systemctl ip awk getent ping lsblk findmnt
    ERRORS=0
    WARNINGS=0
    info "[$CURRENT_NODE] 开始节点环境检查"
    check_os_hardware
    check_required_interfaces
    check_security
    check_logrotate
    check_hostname_hosts
    check_network "$check_peers"
    check_disks
    check_node_time

    if ((ERRORS > 0)); then
        log ERROR "[$CURRENT_NODE] 检查失败：${ERRORS}项错误，${WARNINGS}项警告"
        return 1
    fi
    info "[$CURRENT_NODE] 检查通过，${WARNINGS}项警告"
}

controller_apply() {
    [[ "$EUID" -eq 0 ]] || die "请在控制节点上以root执行"
    require_commands ssh scp ssh-keygen ssh-copy-id readlink
    ensure_controller_access
    remote_execute apply
    ((ERRORS == 0)) || die "存在节点配置失败，停止建立节点间互信"
    configure_all_to_all_ssh
    ((ERRORS == 0)) || die "节点间SSH互信检查失败"
    configure_cluster_time
    ((ERRORS == 0)) || die "节点时钟同步失败"
    remote_execute check
    ((ERRORS == 0)) || die "节点配置后检查失败"
    check_cluster_time_skew
    ((ERRORS == 0)) || die "节点间时间偏差检查失败"
}

controller_check() {
    [[ "$EUID" -eq 0 ]] || die "请在控制节点上以root执行"
    require_commands ssh scp readlink
    remote_execute check
    if ((ERRORS > 0)); then
        die "节点环境检查失败，共 ${ERRORS} 个节点执行失败"
    fi
    check_cluster_time_skew
    ((ERRORS == 0)) || die "节点间时间偏差检查失败"
    info "所有节点环境检查通过"
}

main() {
    parse_args "$@"
    parse_config
    validate_config
    setup_logging

    case "$MODE" in
        dry-run) print_plan ;;
        apply) controller_apply ;;
        check) controller_check ;;
        local-apply) local_apply ;;
        local-check) local_check ;;
        *) die "不支持的模式：$MODE" ;;
    esac
}

main "$@"
