#!/bin/bash

set -euo pipefail

######################## 全局配置 ########################
CONFIG_FILE="/etc/yrfs/yrfs-deploy.conf"
LOG_FILE="/var/log/yrfs-uninstall.log"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
DEBUG=false
MODE=""
FORCE=false
REMOVE_DEPLOY_CONF=false
REMOVE_SCRIPT_LOGS=false
REMOVE_ETCD_BINARIES=false

usage() {
    cat <<'EOF'
Usage:
  ./yrfs-uninstall.sh --clean [--debug] [--config FILE]
  ./yrfs-uninstall.sh --purge [--debug] [--config FILE] [--remove-deploy-conf] [--remove-script-logs] [--remove-etcd-binaries]
  ./yrfs-uninstall.sh --check [--debug] [--config FILE]
  ./yrfs-uninstall.sh --clean -f [--debug]

Modes:
  --clean   Stop YRFS, etcdctl del /yrcf/ (3x), uninstall etcd (service/conf/data/logs),
            clear mounted /data data, remove all generated configs (public, mgmt, MDS/OSS/Agent).
            Keep packages, mounts/fstab, yrfs-mgr.conf and deploy conf.
  --purge   Do --clean, then umount + clean fstab, remove yrfs-mgr.conf, purge yrfs
            packages (etcd binaries kept by default).
  --check   Check residuals only (non-destructive).

Safety:
  After reading config, printing plan and SSH check, --clean / --purge ask for
  interactive confirmation (type: yes). Use -f / --force to skip confirmation.

Optional:
  -f, --force              Skip interactive confirmation
  --config FILE            Default: /etc/yrfs/yrfs-deploy.conf
  --remove-deploy-conf     With --purge: delete deploy conf on controller
  --remove-script-logs     With --purge: delete deploy/uninstall logs on controller
  --remove-etcd-binaries   With --purge: also remove /usr/bin/etcd{,ctl} and etcd user
  --debug                  Print debug messages
EOF
}

###################### 解析命令行参数 #####################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --clean|--purge|--check)
            if [[ -n "${MODE}" ]]; then
                echo "ERROR: only one mode allowed (--clean / --purge / --check)"
                exit 1
            fi
            MODE="${1#--}"
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        --config)
            CONFIG_FILE="${2:-}"
            shift 2
            ;;
        --config=*)
            CONFIG_FILE="${1#*=}"
            shift
            ;;
        --remove-deploy-conf)
            REMOVE_DEPLOY_CONF=true
            shift
            ;;
        --remove-script-logs)
            REMOVE_SCRIPT_LOGS=true
            shift
            ;;
        --remove-etcd-binaries)
            REMOVE_ETCD_BINARIES=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${MODE}" ]]; then
    echo "ERROR: must specify --clean, --purge, or --check"
    usage
    exit 1
fi

if [[ "${MODE}" != "purge" ]]; then
    if [[ "${REMOVE_DEPLOY_CONF}" == "true" || "${REMOVE_SCRIPT_LOGS}" == "true" || "${REMOVE_ETCD_BINARIES}" == "true" ]]; then
        echo "ERROR: --remove-deploy-conf / --remove-script-logs / --remove-etcd-binaries only valid with --purge"
        exit 1
    fi
fi

######################## 日志与工具函数 ########################
log() {
    local node="$1"
    local action="$2"
    local stdout="$3"
    local stderr="$4"
    local status="$5"
    local time_str
    time_str="$(date '+%F %T')"

    {
        echo "[${time_str}] [NODE:${node}] ACTION: ${action}"
        echo "STDOUT:"
        echo "${stdout:-<empty>}"
        echo "STDERR:"
        echo "${stderr:-<empty>}"
        echo "STATUS: ${status}"
        echo "--------------------------------------------------"
    } >> "${LOG_FILE}"
}

debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        echo "[DEBUG] $*"
    fi
}

is_valid_ipv4() {
    local ip="$1"
    local octets=()
    local octet

    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS='.' read -ra octets <<< "${ip}"
    [[ ${#octets[@]} -eq 4 ]] || return 1

    for octet in "${octets[@]}"; do
        [[ ${#octet} -le 3 ]] || return 1
        ((10#${octet} <= 255)) || return 1
    done
}

check_remote_status() {
    local node="$1"
    local action="$2"
    local stdout="$3"
    local status="$4"

    log "${node}" "${action}" "${stdout}" "" "${status}"
    if [[ "${status}" -ne 0 ]]; then
        echo "ERROR: ${action} failed on ${node} (status: ${status})"
        exit 1
    fi
}

remote_exec() {
    local ip="$1"
    local action="$2"
    local script="$3"
    local out status

    if out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${ip}" bash -s <<< "${script}" 2>&1); then
        status=0
    else
        status=$?
    fi

    check_remote_status "${ip}" "${action}" "${out}" "${status}"
    echo "${out}"
}

ip_in_list() {
    local needle="$1"
    shift
    local item

    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

# 从 "ip1,ip2:ip3,ip4" 提取每组首个 IP 到数组名 $2
parse_primary_ips() {
    local value="$1"
    local -n out_arr="$2"
    local groups=()
    local group

    out_arr=()
    [[ -z "${value}" ]] && return 0
    IFS=':' read -ra groups <<< "${value}"
    for group in "${groups[@]}"; do
        [[ -z "${group}" ]] && { echo "ERROR: empty node group in config"; exit 1; }
        out_arr+=("${group%%,*}")
    done
}

validate_primary_ips() {
    local label="$1"
    shift
    local ip
    for ip in "$@"; do
        [[ -z "${ip}" ]] && { echo "ERROR: empty IP in ${label}"; exit 1; }
        is_valid_ipv4 "${ip}" || { echo "ERROR: invalid IPv4 '${ip}' in ${label}"; exit 1; }
    done
}

######################## 1. 检查配置文件 ########################
debug "检查配置文件开始..."

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: ${CONFIG_FILE} not found"
    exit 1
fi

debug "检查配置文件完成"

######################## 2. 解析配置 ########################
debug "解析配置开始..."

ROOT_PASS=""
OSS_IP_VALUE=""
MDS_IP_VALUE=""
MGR_IP_VALUE=""
ETCD_IP_VALUE=""
AGENT_IP_VALUE=""
ETCD_ROOT_PASS=""

while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
    key="$(echo "${key}" | tr -d '[:space:]')"
    value="$(echo "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${key}" ]] && continue

    case "${key}" in
        root_password) ROOT_PASS="${value}" ;;
        oss_ip) OSS_IP_VALUE="${value}" ;;
        mds_ip) MDS_IP_VALUE="${value}" ;;
        mgr_ip) MGR_IP_VALUE="${value}" ;;
        etcd_ip) ETCD_IP_VALUE="${value}" ;;
        agent_ip) AGENT_IP_VALUE="${value}" ;;
        etcd_root_password) ETCD_ROOT_PASS="${value}" ;;
    esac
done < "${CONFIG_FILE}"

OSS_NODES=()
MDS_NODES=()
MGR_NODES=()
ETCD_NODES=()
AGENT_NODES=()

parse_primary_ips "${OSS_IP_VALUE}" OSS_NODES
parse_primary_ips "${MDS_IP_VALUE}" MDS_NODES
parse_primary_ips "${MGR_IP_VALUE}" MGR_NODES
parse_primary_ips "${ETCD_IP_VALUE}" ETCD_NODES
parse_primary_ips "${AGENT_IP_VALUE}" AGENT_NODES

[[ -z "${ROOT_PASS}" ]] && { echo "ERROR: root_password empty"; exit 1; }
[[ ${#OSS_NODES[@]} -eq 0 ]] && { echo "ERROR: oss_ip empty"; exit 1; }
[[ ${#MDS_NODES[@]} -eq 0 ]] && { echo "ERROR: mds_ip empty"; exit 1; }
[[ ${#MGR_NODES[@]} -eq 0 ]] && { echo "ERROR: mgr_ip empty"; exit 1; }
[[ ${#ETCD_NODES[@]} -eq 0 ]] && { echo "ERROR: etcd_ip empty"; exit 1; }

validate_primary_ips "oss_ip" "${OSS_NODES[@]}"
validate_primary_ips "mds_ip" "${MDS_NODES[@]}"
validate_primary_ips "mgr_ip" "${MGR_NODES[@]}"
validate_primary_ips "etcd_ip" "${ETCD_NODES[@]}"
if [[ ${#AGENT_NODES[@]} -gt 0 ]]; then
    validate_primary_ips "agent_ip" "${AGENT_NODES[@]}"
fi

# Agent 节点：配置了 agent_ip 则用它，否则对所有 OSS 节点尝试停 Agent
if [[ ${#AGENT_NODES[@]} -eq 0 ]]; then
    AGENT_NODES=("${OSS_NODES[@]}")
fi

ALL_NODES=()
for ip in "${OSS_NODES[@]}" "${MDS_NODES[@]}" "${MGR_NODES[@]}" "${ETCD_NODES[@]}" "${AGENT_NODES[@]}"; do
    ip_in_list "${ip}" "${ALL_NODES[@]}" || ALL_NODES+=("${ip}")
done

debug "解析配置完成"

echo "======= YRCF / YRFS uninstall plan ======="
echo "mode:                 ${MODE}"
echo "config:               ${CONFIG_FILE}"
echo "all nodes(ssh):       ${ALL_NODES[*]}"
echo "oss nodes:            ${OSS_NODES[*]}"
echo "mds nodes:            ${MDS_NODES[*]}"
echo "mgr nodes:            ${MGR_NODES[*]}"
echo "etcd nodes:           ${ETCD_NODES[*]}"
echo "agent nodes:          ${AGENT_NODES[*]}"
echo "etcd_root_password:   $([ -n "${ETCD_ROOT_PASS}" ] && echo set || echo unset)"
echo "remove_deploy_conf:   ${REMOVE_DEPLOY_CONF}"
echo "remove_script_logs:   ${REMOVE_SCRIPT_LOGS}"
echo "remove_etcd_binaries: ${REMOVE_ETCD_BINARIES}"
echo "=========================================="

######################## 3. SSH 连通性检查 ########################
debug "SSH 连通性检查开始..."

for ip in "${ALL_NODES[@]}"; do
    remote_exec "${ip}" "SSH connectivity check" "echo OK" >/dev/null
done

debug "SSH 连通性检查完成"

######################## 检查残留 ########################
run_check() {
    local expect_purge="$1"
    local failed=0
    local ip out

    echo "----- residual check begin -----"

    for ip in "${ALL_NODES[@]}"; do
        out=$(remote_exec "${ip}" "Check YRFS residual on ${ip}" "$(cat <<'CMD'
set -euo pipefail
echo "=== node check ==="
active=$(systemctl list-units --type=service --state=active,activating --no-legend 2>/dev/null | awk '$1 ~ /^yrfs/ {print $1}' | tr '\n' ' ')
echo "yrfs_active=${active:-none}"
enabled=$(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^yrfs/ && $2 ~ /enabled/ {print $1}' | tr '\n' ' ')
wants=""
shopt -s nullglob
for _w in /etc/systemd/system/multi-user.target.wants/yrfs*.service; do
  wants+="$(basename "${_w}") "
done
shopt -u nullglob
echo "yrfs_enabled=${enabled:-none}"
echo "yrfs_wants=${wants:-none}"
mounts=$(findmnt -rn 2>/dev/null | awk '/\/data\/(mds|oss)/ {print $1}' | tr '\n' ' ')
echo "yrcf_mounts=${mounts:-none}"
fstab_hits=$(grep -E '(/data/mds|/data/oss)' /etc/fstab 2>/dev/null | wc -l || true)
echo "fstab_hits=${fstab_hits}"
leftover=0
for dir in /data/mds* /data/oss*; do
  [[ -d "$dir" ]] || continue
  if findmnt -rn -M "$dir" >/dev/null 2>&1; then
    c=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
    leftover=$((leftover + c))
  fi
done
echo "mounted_data_leftover=${leftover}"
# clean/purge 均要求已删除：MDS/OSS/Agent 实例配置 + 公共配置 + mgmt 配置
conf_hits=0
ls -d /etc/yrfs/oss*.d /etc/yrfs/mds*.d 2>/dev/null | grep -q . && conf_hits=1 || true
[[ -f /etc/yrfs/yrfs-agent.conf ]] && conf_hits=1 || true
[[ -f /etc/yrfs/net-mds ]] && conf_hits=1 || true
[[ -f /etc/yrfs/net-oss ]] && conf_hits=1 || true
[[ -f /etc/yrfs/net-agent ]] && conf_hits=1 || true
[[ -f /etc/yrfs/net ]] && conf_hits=1 || true
[[ -f /etc/yrfs/net_plane.yaml ]] && conf_hits=1 || true
[[ -f /etc/yrfs/ipwhitelist ]] && conf_hits=1 || true
[[ -f /etc/yrfs/ipwhitelist-mgmt ]] && conf_hits=1 || true
[[ -f /etc/yrfs/net-mgmt ]] && conf_hits=1 || true
echo "yrfs_gen_conf_present=${conf_hits}"
mgr_conf_hits=0
[[ -f /etc/yrfs/yrfs-mgr.conf ]] && mgr_conf_hits=1 || true
echo "yrfs_mgr_conf_present=${mgr_conf_hits}"
pkg=$(dpkg -l 2>/dev/null | awk '$1=="ii" && $2 ~ /^yrfs-(oss|mds|mgr|agent)$/ {print $2}' | tr '\n' ' ')
echo "yrfs_packages=${pkg:-none}"
CMD
)")
        echo "[${ip}]"
        echo "${out}"
        echo "${out}" | grep -q 'yrfs_active=none' || failed=1
        echo "${out}" | grep -q 'yrfs_enabled=none' || failed=1
        echo "${out}" | grep -q 'yrfs_wants=none' || failed=1
        echo "${out}" | grep -q 'mounted_data_leftover=0' || failed=1
        echo "${out}" | grep -q 'yrfs_gen_conf_present=0' || failed=1
        if [[ "${expect_purge}" == "true" ]]; then
            echo "${out}" | grep -q 'yrcf_mounts=none' || failed=1
            echo "${out}" | grep -q 'fstab_hits=0' || failed=1
            echo "${out}" | grep -q 'yrfs_packages=none' || failed=1
            echo "${out}" | grep -q 'yrfs_mgr_conf_present=0' || failed=1
        fi
    done

    for ip in "${ETCD_NODES[@]}"; do
        out=$(remote_exec "${ip}" "Check etcd residual on ${ip}" "$(cat <<'CMD'
set -euo pipefail
echo "=== etcd check ==="
etcd_state=$(systemctl is-active etcd 2>/dev/null || true)
echo "etcd_state=${etcd_state}"
test ! -e /usr/lib/systemd/system/etcd.service && echo "etcd_unit=absent" || echo "etcd_unit=present"
test ! -e /var/lib/etcd && echo "etcd_data=absent" || echo "etcd_data=present"
test ! -e /etc/etcd/etcd.conf && echo "etcd_conf=absent" || echo "etcd_conf=present"
test ! -e /var/log/etcd && echo "etcd_log=absent" || echo "etcd_log=present"
CMD
)")
        echo "[${ip}]"
        echo "${out}"
        # clean/purge 均要求 etcd 已停止且服务/配置/数据/日志已删除
        echo "${out}" | grep -q 'etcd_state=active' && failed=1
        echo "${out}" | grep -q 'etcd_unit=absent' || failed=1
        echo "${out}" | grep -q 'etcd_data=absent' || failed=1
        echo "${out}" | grep -q 'etcd_conf=absent' || failed=1
        echo "${out}" | grep -q 'etcd_log=absent' || failed=1
    done

    echo "----- residual check end -----"
    return "${failed}"
}

if [[ "${MODE}" == "check" ]]; then
    if run_check "false"; then
        echo "Check completed: no obvious clean-mode residuals (packages/mounts may still exist)."
        exit 0
    else
        echo "Check completed: residuals detected. See output above and ${LOG_FILE}"
        exit 1
    fi
fi

######################## 二次确认 ########################
if [[ "${FORCE}" == "true" ]]; then
    echo "Force mode (-f): skip interactive confirmation."
else
    echo
    echo "SSH check passed. About to uninstall YRCF with mode=${MODE}."
    echo "This may stop YRFS services and delete cluster data on the nodes listed above."
    printf "Type yes to continue: "
    read -r answer
    if [[ "${answer}" != "yes" ]]; then
        echo "Aborted by user."
        exit 1
    fi
    echo "Confirmed. Continue uninstall..."
fi

######################## 4. 停止并 disable YRFS 服务 ########################
# 说明：
# - 不只依赖 mgr_ip/mds_ip 等角色列表：包常装在所有节点，可能被误 enable（如 .97 上的 mgr）
# - systemctl disable 在同时存在 /etc/init.d/yrfs-* 且 Default-Start 为空时，
#   会因 update-rc.d 失败而整体失败，wants 软链不删、仍显示 enabled；
#   因此 disable 失败后手动删除 *.wants 下的 enable 软链
debug "停止并 disable YRFS 服务开始（全部节点）..."

for ip in "${ALL_NODES[@]}"; do
    remote_exec "${ip}" "Stop and disable all yrfs services" "$(cat <<'CMD'
set -euo pipefail

force_stop_disable() {
  local u="${1%.service}"
  [[ -z "${u}" ]] && return 0
  systemctl stop "${u}" 2>/dev/null || true
  systemctl disable "${u}" >/dev/null 2>&1 || true
  # SysV 同步失败时 systemctl disable 可能未删软链
  rm -f "/etc/systemd/system/multi-user.target.wants/${u}.service"
  shopt -s nullglob
  local link
  for link in /etc/systemd/system/*.wants/"${u}.service"; do
    rm -f "${link}"
  done
  shopt -u nullglob
}

# 常见实例（节点上可能不存在，忽略错误）
for u in yrfs-agent yrfs-mgr yrfs-oss@oss0 yrfs-oss@oss1 yrfs-mds@mds0; do
  force_stop_disable "${u}"
done

# 仍 active / activating / failed 的 yrfs*
while IFS= read -r u; do
  [[ -n "${u}" ]] && force_stop_disable "${u}"
done < <(systemctl list-units --type=service --state=active,activating,failed --no-legend 2>/dev/null \
  | awk '$1 ~ /^yrfs/ {sub(/\.service$/,"",$1); print $1}')

# 仍 enabled 的 yrfs*（含未在角色列表中的节点）
while IFS= read -r u; do
  [[ -n "${u}" ]] && force_stop_disable "${u}"
done < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null \
  | awk '$1 ~ /^yrfs/ && $2 ~ /enabled/ {sub(/\.service$/,"",$1); print $1}')

# 直接扫 multi-user.target.wants 残留
shopt -s nullglob
for link in /etc/systemd/system/multi-user.target.wants/yrfs*.service; do
  force_stop_disable "$(basename "${link}" .service)"
done
shopt -u nullglob

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true
true
CMD
)" >/dev/null
done

debug "停止并 disable YRFS 服务完成"

######################## 4.5 清理 etcd 中 /yrcf/ 元数据 ########################
debug "清理 etcd /yrcf/ 前缀开始（etcdctl del --prefix=true，执行 3 遍）..."

ETCDCTL_ENDPOINTS=""
for ip in "${ETCD_NODES[@]}"; do
    ETCDCTL_ENDPOINTS+="http://${ip}:2379,"
done
ETCDCTL_ENDPOINTS="${ETCDCTL_ENDPOINTS%,}"

ETCD_DEL_TARGET="${ETCD_NODES[0]}"
ETCD_USER_OPT=""
if [[ -n "${ETCD_ROOT_PASS}" ]]; then
    ETCD_USER_OPT="--user=root:$(printf '%q' "${ETCD_ROOT_PASS}")"
fi

for attempt in 1 2 3; do
    debug "etcdctl del /yrcf/ 第 ${attempt}/3 次（节点 ${ETCD_DEL_TARGET}）..."
    if out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${ETCD_DEL_TARGET}" bash -s <<CMD 2>&1
set -euo pipefail
export ETCDCTL_API=3
command -v etcdctl >/dev/null 2>&1 || { echo "ERROR: etcdctl not found on ${ETCD_DEL_TARGET}"; exit 1; }
etcdctl --endpoints='${ETCDCTL_ENDPOINTS}' ${ETCD_USER_OPT} del --prefix=true /yrcf/
CMD
    ); then
        status=0
    else
        status=$?
    fi
    log "${ETCD_DEL_TARGET}" "etcdctl del --prefix=true /yrcf/ (attempt ${attempt}/3)" "${out}" "" "${status}"
    if [[ "${attempt}" -eq 3 ]]; then
        if [[ "${status}" -ne 0 ]]; then
            echo "ERROR: etcdctl del --prefix=true /yrcf/ 第 3 次失败 (status=${status})"
            echo "${out}"
            exit 1
        fi
        echo "etcdctl del --prefix=true /yrcf/ 第 3 次成功 (status=0)"
    fi
done

debug "清理 etcd /yrcf/ 前缀完成"

######################## 5. 停止并卸载 etcd ########################
debug "卸载 etcd（服务/配置/数据/日志）开始..."

for ip in "${ETCD_NODES[@]}"; do
    remote_exec "${ip}" "Uninstall etcd service, data and logs" "$(cat <<'CMD'
set -euo pipefail
systemctl stop etcd 2>/dev/null || true
systemctl disable --now etcd 2>/dev/null || true
rm -f /etc/etcd/etcd.conf
rm -rf /var/lib/etcd
rm -rf /var/log/etcd
rm -f /usr/lib/systemd/system/etcd.service
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
true
CMD
)" >/dev/null
done

debug "卸载 etcd（服务/配置/数据/日志）完成"

######################## 6. 清理磁盘数据（仅已挂载） ########################
debug "清理挂载点数据开始..."

for ip in "${ALL_NODES[@]}"; do
    remote_exec "${ip}" "Clear mounted YRCF data dirs" "$(cat <<'CMD'
set -euo pipefail
for dir in /data/mds* /data/oss*; do
  [[ -d "$dir" ]] || continue
  if findmnt -rn -M "$dir" >/dev/null 2>&1; then
    find "$dir" -mindepth 1 -delete
  else
    echo "SKIP: $dir is not a mounted filesystem"
  fi
done
true
CMD
)" >/dev/null
done

debug "清理挂载点数据完成"

######################## 7. 清理 YRFS 生成配置 ########################
debug "清理 YRFS 配置开始..."

for ip in "${ALL_NODES[@]}"; do
    remote_exec "${ip}" "Remove YRFS generated configs" "$(cat <<'CMD'
set -euo pipefail
rm -rf /etc/yrfs/oss*.d
rm -rf /etc/yrfs/mds*.d
rm -f /etc/yrfs/yrfs-agent.conf
rm -f /etc/yrfs/net-mds
rm -f /etc/yrfs/net-oss
rm -f /etc/yrfs/net-agent
rm -f /etc/yrfs/ipwhitelist-mds*
rm -f /etc/yrfs/ipwhitelist-oss*
rm -f /etc/yrfs/ipwhitelist-agent
rm -f /etc/yrfs/ipwhitelist-mgmt
rm -f /etc/yrfs/net-mgmt
rm -f /etc/yrfs/net
rm -f /etc/yrfs/net_plane.yaml
rm -f /etc/yrfs/ipwhitelist
# --clean 保留 /etc/yrfs/yrfs-mgr.conf 与 /etc/yrfs/yrfs-deploy.conf，
# 重新执行自动化部署（--mgr）时会按新配置更新 yrfs-mgr.conf
true
CMD
)" >/dev/null
done

debug "清理 YRFS 配置完成"

######################## 8. 彻底卸载（可选） ########################
if [[ "${MODE}" == "purge" ]]; then
    debug "卸载磁盘与 fstab 开始..."

    for ip in "${ALL_NODES[@]}"; do
        remote_exec "${ip}" "Umount and clean fstab" "$(cat <<'CMD'
set -euo pipefail
for dir in /data/mds* /data/oss*; do
  [[ -d "$dir" ]] || continue
  if findmnt -rn -M "$dir" >/dev/null 2>&1; then
    umount "$dir"
  fi
done
cp -a /etc/fstab "/etc/fstab.yrcf-backup.$(date +%Y%m%d%H%M%S)"
sed -i '/\/data\/mds/d;/\/data\/oss/d' /etc/fstab
mount -a
true
CMD
)" >/dev/null
    done

    debug "卸载磁盘与 fstab 完成"

    debug "卸载 YRFS 软件包开始..."

    for ip in "${ALL_NODES[@]}"; do
        remote_exec "${ip}" "Purge yrfs packages and mgr conf" "$(cat <<'CMD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
dpkg -P yrfs-oss yrfs-mds yrfs-mgr yrfs-agent 2>/dev/null || true
rm -f /etc/yrfs/yrfs-mgr.conf
rm -f /etc/yrfs/yrfs-mds.conf
rm -f /etc/yrfs/yrfs-oss.conf
true
CMD
)" >/dev/null
    done

    debug "卸载 YRFS 软件包完成"

    if [[ "${REMOVE_ETCD_BINARIES}" == "true" ]]; then
        debug "删除 etcd 二进制开始..."

        for ip in "${ETCD_NODES[@]}"; do
            remote_exec "${ip}" "Remove etcd binaries and user" "$(cat <<'CMD'
set -euo pipefail
rm -f /usr/bin/etcd /usr/bin/etcdctl
userdel -r etcd 2>/dev/null || true
true
CMD
)" >/dev/null
        done

        debug "删除 etcd 二进制完成"
    fi

    if [[ "${REMOVE_DEPLOY_CONF}" == "true" ]]; then
        rm -f "${CONFIG_FILE}"
        echo "Removed deploy conf: ${CONFIG_FILE}"
    fi

    if [[ "${REMOVE_SCRIPT_LOGS}" == "true" ]]; then
        echo "Will remove script logs after success."
    fi
fi

######################## 9. 验收 ########################
expect_purge="false"
if [[ "${MODE}" == "purge" ]]; then
    expect_purge="true"
fi

if run_check "${expect_purge}"; then
    echo "YRCF uninstall (${MODE}) completed successfully."
    echo "Log file: ${LOG_FILE}"
    if [[ "${MODE}" == "purge" && "${REMOVE_SCRIPT_LOGS}" == "true" ]]; then
        rm -f /var/log/yrfs-etcd-deploy.log
        rm -f /var/log/yrfs-format-disk.log
        rm -f /var/log/yrfs-deploy-mgr.log
        rm -f /var/log/yrfs-deploy-mds.log
        rm -f /var/log/yrfs-deploy-oss.log
        rm -f /var/log/yrfs-deploy-agent.log
        rm -f "${LOG_FILE}"
        echo "Removed script logs on controller."
    fi
    exit 0
else
    echo "ERROR: uninstall finished but residuals remain. See output above and ${LOG_FILE}"
    exit 1
fi
