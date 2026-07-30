#!/bin/bash

set -euo pipefail

######################## 全局配置 ########################
CONFIG_FILE="/etc/redis/redis-sentinel-deploy.conf"
LOG_FILE="/var/log/redis-sentinel-uninstall.log"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
DEBUG=false
MODE=""
FORCE=false
REMOVE_DEPLOY_CONF=false
REMOVE_SCRIPT_LOGS=false

usage() {
    cat <<'EOF'
Usage:
  ./redis-sentinel-uninstall.sh --clean [--debug] [--config FILE]
  ./redis-sentinel-uninstall.sh --purge [--debug] [--config FILE] [--remove-deploy-conf] [--remove-script-logs]
  ./redis-sentinel-uninstall.sh --check [--debug] [--config FILE]
  ./redis-sentinel-uninstall.sh --clean -f [--debug]   # skip confirmation

Modes:
  --clean               Stop services, clear data, remove redis/sentinel conf. Keep packages.
  --purge               Do --clean, then apt purge packages, remove logs and data dirs.
  --check               Check residual services/ports/files (non-destructive).

Safety:
  After reading config, printing plan and SSH check, --clean / --purge ask for
  interactive confirmation (type: yes). Use -f / --force to skip confirmation.

Optional:
  -f, --force           Skip interactive confirmation (for automation)
  --config FILE         Config file (default: /etc/redis/redis-sentinel-deploy.conf)
  --remove-deploy-conf  With --purge: also delete the deploy conf on the controller
  --remove-script-logs  With --purge: also delete deploy/uninstall script logs on the controller
  --debug               Print debug messages
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
    if [[ "${REMOVE_DEPLOY_CONF}" == "true" || "${REMOVE_SCRIPT_LOGS}" == "true" ]]; then
        echo "ERROR: --remove-deploy-conf / --remove-script-logs only valid with --purge"
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
REDIS_IP_VALUE=""
SENTINEL_IP_VALUE=""
REDIS_PORT="6379"
SENTINEL_PORT="26379"
REDIS_DIR_TEMPLATE="/var/lib/redis/node{index}-{port}"
REDIS_LOGFILE="/var/log/redis/redis.log"
SENTINEL_LOGFILE="/var/log/redis/sentinel.log"

while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
    key="$(echo "${key}" | tr -d '[:space:]')"
    value="$(echo "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${key}" ]] && continue

    case "${key}" in
        root_password) ROOT_PASS="${value}" ;;
        redis_ip) REDIS_IP_VALUE="${value}" ;;
        sentinel_ip) SENTINEL_IP_VALUE="${value}" ;;
        redis_port) REDIS_PORT="${value}" ;;
        sentinel_port) SENTINEL_PORT="${value}" ;;
        redis_dir_template) REDIS_DIR_TEMPLATE="${value}" ;;
        redis_logfile) REDIS_LOGFILE="${value}" ;;
        sentinel_logfile) SENTINEL_LOGFILE="${value}" ;;
    esac
done < "${CONFIG_FILE}"

render_path_template() {
    local template="$1"
    local index="$2"
    local port="$3"
    local out="${template}"
    out="${out//\{index\}/${index}}"
    out="${out//\{port\}/${port}}"
    printf '%s' "${out}"
}

REDIS_NODES=()
SENTINEL_NODES=()

if [[ -n "${REDIS_IP_VALUE}" ]]; then
    IFS=':' read -ra REDIS_NODES <<< "${REDIS_IP_VALUE}"
fi

if [[ -n "${SENTINEL_IP_VALUE}" ]]; then
    IFS=':' read -ra SENTINEL_NODES <<< "${SENTINEL_IP_VALUE}"
fi

[[ -z "${ROOT_PASS}" ]] && { echo "ERROR: root_password empty"; exit 1; }
[[ ${#REDIS_NODES[@]} -eq 0 ]] && { echo "ERROR: redis_ip empty"; exit 1; }
[[ ${#SENTINEL_NODES[@]} -eq 0 ]] && { echo "ERROR: sentinel_ip empty"; exit 1; }

for ip in "${REDIS_NODES[@]}" "${SENTINEL_NODES[@]}"; do
    [[ -z "${ip}" ]] && { echo "ERROR: empty IP in config"; exit 1; }
    is_valid_ipv4 "${ip}" || { echo "ERROR: invalid IPv4 address '${ip}'"; exit 1; }
done

for sentinel_ip in "${SENTINEL_NODES[@]}"; do
    ip_in_list "${sentinel_ip}" "${REDIS_NODES[@]}" || {
        echo "ERROR: sentinel_ip '${sentinel_ip}' is not listed in redis_ip"
        exit 1
    }
done

debug "解析配置完成"

UNIQUE_IPS=()
for ip in "${REDIS_NODES[@]}"; do
    ip_in_list "${ip}" "${UNIQUE_IPS[@]}" || UNIQUE_IPS+=("${ip}")
done

echo "======= Redis Sentinel uninstall plan ======="
echo "mode:              ${MODE}"
echo "config:            ${CONFIG_FILE}"
echo "redis nodes:       ${REDIS_IP_VALUE}"
echo "sentinel nodes:    ${SENTINEL_IP_VALUE}"
echo "redis_port:        ${REDIS_PORT}"
echo "sentinel_port:     ${SENTINEL_PORT}"
echo "remove_deploy_conf:${REMOVE_DEPLOY_CONF}"
echo "remove_script_logs:${REMOVE_SCRIPT_LOGS}"
echo "============================================="

######################## 3. SSH 连通性检查 ########################
debug "SSH 连通性检查开始..."

for ip in "${UNIQUE_IPS[@]}"; do
    remote_exec "${ip}" "SSH connectivity check" "echo OK" >/dev/null
done

debug "SSH 连通性检查完成"

######################## 检查残留 ########################
run_check() {
    local expect_packages_removed="$1"
    local failed=0
    local index=1
    local ip out

    echo "----- residual check begin -----"

    for ip in "${SENTINEL_NODES[@]}"; do
        out=$(remote_exec "${ip}" "Check sentinel residual on ${ip}" "$(cat <<CMD
set -euo pipefail
echo "=== node ${ip} (sentinel) ==="
redis_state=\$(systemctl is-active redis-server 2>/dev/null || true)
sentinel_state=\$(systemctl is-active redis-sentinel 2>/dev/null || true)
echo "redis_state=\${redis_state}"
echo "sentinel_state=\${sentinel_state}"
ss -lntp 2>/dev/null | grep -E ':${REDIS_PORT}\\b|:${SENTINEL_PORT}\\b' || true
test ! -f /etc/redis/sentinel.conf && echo "sentinel.conf=absent" || echo "sentinel.conf=present"
test ! -f /etc/redis/redis.conf && echo "redis.conf=absent" || echo "redis.conf=present"
if command -v redis-sentinel >/dev/null 2>&1; then echo "redis-sentinel-bin=present"; else echo "redis-sentinel-bin=absent"; fi
if dpkg -l redis-sentinel 2>/dev/null | awk '/^ii/ {found=1} END {exit found ? 0 : 1}'; then
  echo "redis-sentinel-pkg=installed"
else
  echo "redis-sentinel-pkg=not-installed"
fi
CMD
)")
        echo "${out}"
        echo "${out}" | grep -q 'sentinel_state=active' && failed=1
        echo "${out}" | grep -q 'redis_state=active' && failed=1
        echo "${out}" | grep -q 'sentinel.conf=present' && failed=1
        echo "${out}" | grep -q 'redis.conf=present' && failed=1
        if echo "${out}" | grep -qE 'LISTEN'; then
            failed=1
        fi
        if [[ "${expect_packages_removed}" == "true" ]]; then
            echo "${out}" | grep -q 'redis-sentinel-pkg=installed' && failed=1
            echo "${out}" | grep -q 'redis-sentinel-bin=present' && failed=1
        fi
    done

    index=1
    for ip in "${REDIS_NODES[@]}"; do
        data_dir="$(render_path_template "${REDIS_DIR_TEMPLATE}" "${index}" "${REDIS_PORT}")"
        out=$(remote_exec "${ip}" "Check redis residual on ${ip}" "$(cat <<CMD
set -euo pipefail
echo "=== node ${ip} (redis index ${index}) ==="
redis_state=\$(systemctl is-active redis-server 2>/dev/null || true)
echo "redis_state=\${redis_state}"
ss -lntp 2>/dev/null | grep -E ':${REDIS_PORT}\\b' || true
test ! -f /etc/redis/redis.conf && echo "redis.conf=absent" || echo "redis.conf=present"
data_dir="${data_dir}"
if [[ -d "\${data_dir}" ]]; then
  leftover=\$(find "\${data_dir}" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  echo "data_dir_state=present"
  echo "data_dir_leftover=\${leftover}"
else
  echo "data_dir_state=absent"
  echo "data_dir_leftover=0"
fi
if command -v redis-server >/dev/null 2>&1; then echo "redis-server-bin=present"; else echo "redis-server-bin=absent"; fi
if dpkg -l redis 2>/dev/null | awk '/^ii/ {found=1} END {exit found ? 0 : 1}'; then
  echo "redis-pkg=installed"
else
  echo "redis-pkg=not-installed"
fi
CMD
)")
        echo "${out}"
        echo "${out}" | grep -q 'redis_state=active' && failed=1
        echo "${out}" | grep -q 'redis.conf=present' && failed=1
        if echo "${out}" | grep -qE 'LISTEN'; then
            failed=1
        fi
        leftover_count=$(echo "${out}" | awk -F= '/data_dir_leftover=/ {print $2; exit}')
        leftover_count=${leftover_count:-0}
        if [[ "${leftover_count}" -gt 0 ]]; then
            failed=1
        fi
        if [[ "${expect_packages_removed}" == "true" ]]; then
            echo "${out}" | grep -q 'redis-pkg=installed' && failed=1
            echo "${out}" | grep -q 'redis-server-bin=present' && failed=1
            echo "${out}" | grep -q 'data_dir_state=present' && failed=1
        fi
        index=$((index + 1))
    done

    echo "----- residual check end -----"
    return "${failed}"
}

if [[ "${MODE}" == "check" ]]; then
    if run_check "false"; then
        echo "Check completed: no obvious Redis/Sentinel residuals found (packages may still be installed)."
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
    echo "SSH check passed. About to uninstall with mode=${MODE}."
    echo "This will stop Redis/Sentinel and delete data on the nodes listed above."
    printf "Type yes to continue: "
    read -r answer
    if [[ "${answer}" != "yes" ]]; then
        echo "Aborted by user."
        exit 1
    fi
    echo "Confirmed. Continue uninstall..."
fi

######################## 4. 停止服务 ########################
debug "停止 Sentinel 开始..."

for ip in "${SENTINEL_NODES[@]}"; do
    remote_exec "${ip}" "Stop and disable redis-sentinel" "$(cat <<'CMD'
set -euo pipefail
systemctl stop redis-sentinel 2>/dev/null || true
systemctl disable redis-sentinel 2>/dev/null || true
systemctl is-active redis-sentinel 2>/dev/null || true
CMD
)" >/dev/null
done

debug "停止 Sentinel 完成"

debug "停止 Redis 开始..."

for ip in "${REDIS_NODES[@]}"; do
    remote_exec "${ip}" "Stop and disable redis" "$(cat <<'CMD'
set -euo pipefail
systemctl stop redis-server 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true
systemctl is-active redis-server 2>/dev/null || true
CMD
)" >/dev/null
done

debug "停止 Redis 完成"

######################## 5. 清理数据 ########################
debug "清理 Redis 数据开始..."

index=1
for ip in "${REDIS_NODES[@]}"; do
    data_dir="$(render_path_template "${REDIS_DIR_TEMPLATE}" "${index}" "${REDIS_PORT}")"
    remote_exec "${ip}" "Clear redis data on node${index}" "$(cat <<CMD
set -euo pipefail
data_dir="${data_dir}"
if [[ -d "\${data_dir}" ]]; then
  find "\${data_dir}" -mindepth 1 -delete
fi
# 兼容手工部署可能留下的其他 node*-port 目录
for dir in /var/lib/redis/node*-${REDIS_PORT}; do
  [[ -d "\${dir}" ]] || continue
  find "\${dir}" -mindepth 1 -delete
done
CMD
)" >/dev/null
    index=$((index + 1))
done

debug "清理 Redis 数据完成"

######################## 6. 清理配置 ########################
debug "清理配置文件开始..."

for ip in "${REDIS_NODES[@]}"; do
    remote_exec "${ip}" "Remove redis.conf" "$(cat <<'CMD'
set -euo pipefail
if [[ -f /etc/redis/redis.conf ]]; then
  cp -a /etc/redis/redis.conf "/etc/redis/redis.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
fi
rm -f /etc/redis/redis.conf
CMD
)" >/dev/null
done

for ip in "${SENTINEL_NODES[@]}"; do
    remote_exec "${ip}" "Remove sentinel.conf" "$(cat <<'CMD'
set -euo pipefail
rm -f /etc/redis/sentinel.conf
CMD
)" >/dev/null
done

debug "清理配置文件完成"

######################## 7. 彻底卸载（可选） ########################
if [[ "${MODE}" == "purge" ]]; then
    debug "卸载软件包开始..."

    for ip in "${SENTINEL_NODES[@]}"; do
        remote_exec "${ip}" "Purge redis-sentinel" "$(cat <<'CMD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y redis-sentinel || true
CMD
)" >/dev/null
    done

    for ip in "${REDIS_NODES[@]}"; do
        remote_exec "${ip}" "Purge redis" "$(cat <<'CMD'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get purge -y redis || true
CMD
)" >/dev/null
    done

    debug "卸载软件包完成"

    debug "清理日志和目录开始..."

    index=1
    for ip in "${REDIS_NODES[@]}"; do
        data_dir="$(render_path_template "${REDIS_DIR_TEMPLATE}" "${index}" "${REDIS_PORT}")"
        remote_exec "${ip}" "Remove logs and data dirs on node${index}" "$(cat <<CMD
set -euo pipefail
rm -f ${REDIS_LOGFILE}
rm -f ${SENTINEL_LOGFILE}
rm -rf ${data_dir}
for dir in /var/lib/redis/node*-${REDIS_PORT}; do
  [[ -e "\${dir}" ]] || continue
  rm -rf "\${dir}"
done
rmdir /var/lib/redis 2>/dev/null || true
rmdir /var/log/redis 2>/dev/null || true
CMD
)" >/dev/null
        index=$((index + 1))
    done

    debug "清理日志和目录完成"

    if [[ "${REMOVE_DEPLOY_CONF}" == "true" ]]; then
        rm -f "${CONFIG_FILE}"
        echo "Removed deploy conf: ${CONFIG_FILE}"
    fi

    if [[ "${REMOVE_SCRIPT_LOGS}" == "true" ]]; then
        rm -f /var/log/redis-sentinel-deploy.log
        # keep current uninstall log until end; remove previous copies only if requested after success
        echo "Will remove uninstall log after success: ${LOG_FILE}"
    fi
fi

######################## 8. 验收 ########################
expect_packages_removed="false"
if [[ "${MODE}" == "purge" ]]; then
    expect_packages_removed="true"
fi

if run_check "${expect_packages_removed}"; then
    echo "Redis Sentinel uninstall (${MODE}) completed successfully."
    echo "Log file: ${LOG_FILE}"
    if [[ "${MODE}" == "purge" && "${REMOVE_SCRIPT_LOGS}" == "true" ]]; then
        rm -f /var/log/redis-sentinel-deploy.log
        rm -f "${LOG_FILE}"
        echo "Removed script logs on controller."
    fi
    exit 0
else
    echo "ERROR: uninstall finished but residuals remain. See output above and ${LOG_FILE}"
    exit 1
fi
