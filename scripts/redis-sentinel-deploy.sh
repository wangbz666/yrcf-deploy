#!/bin/bash

set -euo pipefail

######################## 全局配置 ########################
CONFIG_FILE="/etc/redis/redis-sentinel-deploy.conf"
LOG_FILE="/var/log/redis-sentinel-deploy.log"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
DEBUG=false

###################### 解析命令行参数 #####################
while [[ $# -gt 0 ]]; do
    case "$1" in
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
        *)
            echo "ERROR: unknown argument: $1"
            exit 1
            ;;
    esac
done

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
REDIS_PASS=""
REDIS_IP_VALUE=""
SENTINEL_IP_VALUE=""
MASTER_NAME="mymaster"
MASTER_IP=""
MASTER_PORT="6379"
SENTINEL_QUORUM="2"
REDIS_PORT="6379"
SENTINEL_PORT="26379"
MAXMEMORY="4gb"
DOWN_AFTER_MS="30000"
FAILOVER_TIMEOUT="180000"
PARALLEL_SYNCS="1"

# Redis 参数默认值（配置文件未给出时生效；与当前生成模板一致）
REDIS_BIND="0.0.0.0"
DAEMONIZE="yes"
PROTECTED_MODE="no"
REDIS_LOGFILE="/var/log/redis/redis.log"
# {index} / {port} 会在下发时替换为节点序号与 redis_port
REDIS_DIR_TEMPLATE="/var/lib/redis/node{index}-{port}"
MAXMEMORY_POLICY="allkeys-lru"
APPENDONLY="yes"
APPENDFILENAME_TEMPLATE="node{index}-{port}-appendonly.aof"
AUTO_AOF_REWRITE_PERCENTAGE="100"
AUTO_AOF_REWRITE_MIN_SIZE="64mb"
SAVE="900 1"
REPLICA_READ_ONLY="yes"
MIN_REPLICAS_TO_WRITE="1"
MIN_REPLICAS_MAX_LAG="10"

# Sentinel 参数默认值
SENTINEL_BIND="0.0.0.0"
SENTINEL_PROTECTED_MODE="no"
SENTINEL_PIDFILE="/var/run/redis-sentinel.pid"
SENTINEL_LOGFILE="/var/log/redis/sentinel.log"
SENTINEL_DIR="/tmp"
DENY_SCRIPTS_RECONFIG="yes"

while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" =~ ^[[:space:]]*# ]] && continue
    key="$(echo "${key}" | tr -d '[:space:]')"
    value="$(echo "${value}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "${key}" ]] && continue

    case "${key}" in
        root_password) ROOT_PASS="${value}" ;;
        redis_password) REDIS_PASS="${value}" ;;
        redis_ip) REDIS_IP_VALUE="${value}" ;;
        sentinel_ip) SENTINEL_IP_VALUE="${value}" ;;
        master_name) MASTER_NAME="${value}" ;;
        master_ip) MASTER_IP="${value}" ;;
        master_port) MASTER_PORT="${value}" ;;
        sentinel_quorum) SENTINEL_QUORUM="${value}" ;;
        redis_port) REDIS_PORT="${value}" ;;
        sentinel_port) SENTINEL_PORT="${value}" ;;
        maxmemory) MAXMEMORY="${value}" ;;
        down_after_milliseconds) DOWN_AFTER_MS="${value}" ;;
        failover_timeout) FAILOVER_TIMEOUT="${value}" ;;
        parallel_syncs) PARALLEL_SYNCS="${value}" ;;
        redis_bind) REDIS_BIND="${value}" ;;
        daemonize) DAEMONIZE="${value}" ;;
        protected_mode) PROTECTED_MODE="${value}" ;;
        redis_logfile) REDIS_LOGFILE="${value}" ;;
        redis_dir_template) REDIS_DIR_TEMPLATE="${value}" ;;
        maxmemory_policy) MAXMEMORY_POLICY="${value}" ;;
        appendonly) APPENDONLY="${value}" ;;
        appendfilename_template) APPENDFILENAME_TEMPLATE="${value}" ;;
        auto_aof_rewrite_percentage) AUTO_AOF_REWRITE_PERCENTAGE="${value}" ;;
        auto_aof_rewrite_min_size) AUTO_AOF_REWRITE_MIN_SIZE="${value}" ;;
        save) SAVE="${value}" ;;
        replica_read_only) REPLICA_READ_ONLY="${value}" ;;
        min_replicas_to_write) MIN_REPLICAS_TO_WRITE="${value}" ;;
        min_replicas_max_lag) MIN_REPLICAS_MAX_LAG="${value}" ;;
        sentinel_bind) SENTINEL_BIND="${value}" ;;
        sentinel_protected_mode) SENTINEL_PROTECTED_MODE="${value}" ;;
        sentinel_pidfile) SENTINEL_PIDFILE="${value}" ;;
        sentinel_logfile) SENTINEL_LOGFILE="${value}" ;;
        sentinel_dir) SENTINEL_DIR="${value}" ;;
        deny_scripts_reconfig) DENY_SCRIPTS_RECONFIG="${value}" ;;
    esac
done < "${CONFIG_FILE}"

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

# redis_password 为空：无密码模式（不写 requirepass / masterauth / sentinel auth-pass）
AUTH_REDIS_LINES=""
AUTH_SENTINEL_LINE=""
if [[ -n "${REDIS_PASS}" ]]; then
    AUTH_REDIS_LINES="requirepass ${REDIS_PASS}
masterauth ${REDIS_PASS}"
    AUTH_SENTINEL_LINE="sentinel auth-pass ${MASTER_NAME} ${REDIS_PASS}"
    debug "Redis auth: enabled"
else
    debug "Redis auth: disabled (redis_password empty)"
fi

if [[ -z "${MASTER_IP}" ]]; then
    MASTER_IP="${REDIS_NODES[0]}"
fi

for ip in "${REDIS_NODES[@]}" "${SENTINEL_NODES[@]}" "${MASTER_IP}"; do
    [[ -z "${ip}" ]] && { echo "ERROR: empty IP in config"; exit 1; }
    is_valid_ipv4 "${ip}" || { echo "ERROR: invalid IPv4 address '${ip}'"; exit 1; }
done

for sentinel_ip in "${SENTINEL_NODES[@]}"; do
    ip_in_list "${sentinel_ip}" "${REDIS_NODES[@]}" || {
        echo "ERROR: sentinel_ip '${sentinel_ip}' is not listed in redis_ip"
        exit 1
    }
done

ip_in_list "${MASTER_IP}" "${REDIS_NODES[@]}" || {
    echo "ERROR: master_ip '${MASTER_IP}' is not listed in redis_ip"
    exit 1
}

render_path_template() {
    local template="$1"
    local index="$2"
    local port="$3"
    local out="${template}"
    out="${out//\{index\}/${index}}"
    out="${out//\{port\}/${port}}"
    printf '%s' "${out}"
}

debug "解析配置完成"
debug "redis: bind=${REDIS_BIND} port=${REDIS_PORT} maxmemory=${MAXMEMORY} policy=${MAXMEMORY_POLICY} appendonly=${APPENDONLY} save=${SAVE}"
debug "sentinel: bind=${SENTINEL_BIND} port=${SENTINEL_PORT} quorum=${SENTINEL_QUORUM} down_after=${DOWN_AFTER_MS} failover=${FAILOVER_TIMEOUT}"

######################## 3. SSH 连通性检查 ########################
debug "SSH 连通性检查开始..."

UNIQUE_IPS=()
for ip in "${REDIS_NODES[@]}"; do
    ip_in_list "${ip}" "${UNIQUE_IPS[@]}" || UNIQUE_IPS+=("${ip}")
done

for ip in "${UNIQUE_IPS[@]}"; do
    remote_exec "${ip}" "SSH connectivity check" "echo OK"
done

debug "SSH 连通性检查完成"

######################## 4. 检查软件包 ########################
debug "检查 Redis 软件包开始..."

for ip in "${REDIS_NODES[@]}"; do
    remote_exec "${ip}" "Check redis package installed" "$(cat <<'CMD'
set -euo pipefail
command -v redis-server >/dev/null
command -v redis-cli >/dev/null
dpkg -l redis 2>/dev/null | awk '/^ii/ {found=1} END {exit found ? 0 : 1}'
CMD
)"
done

debug "检查 Redis 软件包完成"

debug "检查 Sentinel 软件包开始..."

for ip in "${SENTINEL_NODES[@]}"; do
    remote_exec "${ip}" "Check redis-sentinel package installed" "$(cat <<'CMD'
set -euo pipefail
command -v redis-sentinel >/dev/null
dpkg -l redis-sentinel 2>/dev/null | awk '/^ii/ {found=1} END {exit found ? 0 : 1}'
CMD
)"
done

debug "检查 Sentinel 软件包完成"

######################## 5. 创建目录 ########################
debug "创建目录开始..."

index=1
for ip in "${REDIS_NODES[@]}"; do
    redis_dir="$(render_path_template "${REDIS_DIR_TEMPLATE}" "${index}" "${REDIS_PORT}")"
    remote_exec "${ip}" "Create redis directories for node${index}" "$(cat <<CMD
set -euo pipefail
mkdir -p /var/log/redis
mkdir -p ${redis_dir}
chown redis:redis /var/log/redis
chown redis:redis ${redis_dir}
CMD
)"
    index=$((index + 1))
done

debug "创建目录完成"

######################## 6. 写入 Redis 配置 ########################
debug "写入 Redis 配置开始..."

index=1
for ip in "${REDIS_NODES[@]}"; do
    redis_dir="$(render_path_template "${REDIS_DIR_TEMPLATE}" "${index}" "${REDIS_PORT}")"
    appendfilename="$(render_path_template "${APPENDFILENAME_TEMPLATE}" "${index}" "${REDIS_PORT}")"

    if [[ "${ip}" == "${MASTER_IP}" ]]; then
        remote_exec "${ip}" "Write redis.conf (master) on node${index}" "$(cat <<CMD
set -euo pipefail
cat > /etc/redis/redis.conf <<'REDIS_EOF'
bind ${REDIS_BIND}
port ${REDIS_PORT}
daemonize ${DAEMONIZE}
protected-mode ${PROTECTED_MODE}

dir ${redis_dir}
logfile ${REDIS_LOGFILE}

maxmemory ${MAXMEMORY}
maxmemory-policy ${MAXMEMORY_POLICY}

appendonly ${APPENDONLY}
appendfilename "${appendfilename}"
auto-aof-rewrite-percentage ${AUTO_AOF_REWRITE_PERCENTAGE}
auto-aof-rewrite-min-size ${AUTO_AOF_REWRITE_MIN_SIZE}
save ${SAVE}

replica-read-only ${REPLICA_READ_ONLY}
min-replicas-to-write ${MIN_REPLICAS_TO_WRITE}
min-replicas-max-lag ${MIN_REPLICAS_MAX_LAG}
${AUTH_REDIS_LINES}
REDIS_EOF
CMD
)"
    else
        remote_exec "${ip}" "Write redis.conf (slave) on node${index}" "$(cat <<CMD
set -euo pipefail
cat > /etc/redis/redis.conf <<'REDIS_EOF'
bind ${REDIS_BIND}
port ${REDIS_PORT}
daemonize ${DAEMONIZE}
protected-mode ${PROTECTED_MODE}

dir ${redis_dir}
logfile ${REDIS_LOGFILE}

maxmemory ${MAXMEMORY}
maxmemory-policy ${MAXMEMORY_POLICY}

replicaof ${MASTER_IP} ${MASTER_PORT}
replica-read-only ${REPLICA_READ_ONLY}

appendonly ${APPENDONLY}
appendfilename "${appendfilename}"
auto-aof-rewrite-percentage ${AUTO_AOF_REWRITE_PERCENTAGE}
auto-aof-rewrite-min-size ${AUTO_AOF_REWRITE_MIN_SIZE}
save ${SAVE}

min-replicas-to-write ${MIN_REPLICAS_TO_WRITE}
min-replicas-max-lag ${MIN_REPLICAS_MAX_LAG}
${AUTH_REDIS_LINES}
REDIS_EOF
CMD
)"
    fi

    index=$((index + 1))
done

debug "写入 Redis 配置完成"

######################## 7. 写入 Sentinel 配置 ########################
debug "写入 Sentinel 配置开始..."

for ip in "${SENTINEL_NODES[@]}"; do
    remote_exec "${ip}" "Write sentinel.conf" "$(cat <<CMD
set -euo pipefail
cat > /etc/redis/sentinel.conf <<'SENTINEL_EOF'
bind ${SENTINEL_BIND}
port ${SENTINEL_PORT}
protected-mode ${SENTINEL_PROTECTED_MODE}

pidfile ${SENTINEL_PIDFILE}
logfile ${SENTINEL_LOGFILE}
dir ${SENTINEL_DIR}

sentinel monitor ${MASTER_NAME} ${MASTER_IP} ${MASTER_PORT} ${SENTINEL_QUORUM}
${AUTH_SENTINEL_LINE}
sentinel down-after-milliseconds ${MASTER_NAME} ${DOWN_AFTER_MS}
sentinel failover-timeout ${MASTER_NAME} ${FAILOVER_TIMEOUT}
sentinel parallel-syncs ${MASTER_NAME} ${PARALLEL_SYNCS}

sentinel deny-scripts-reconfig ${DENY_SCRIPTS_RECONFIG}
SENTINEL_EOF
CMD
)"
done

debug "写入 Sentinel 配置完成"

######################## 8. 启动服务 ########################
debug "启动 Redis 开始..."

index=1
for ip in "${REDIS_NODES[@]}"; do
    if [[ "${ip}" == "${MASTER_IP}" ]]; then
        MASTER_NODE_INDEX="${index}"
    fi
    index=$((index + 1))
done

index=1
for ip in "${REDIS_NODES[@]}"; do
    if [[ "${index}" -eq "${MASTER_NODE_INDEX}" ]]; then
        index=$((index + 1))
        continue
    fi

    remote_exec "${ip}" "Start redis (slave first) on node${index}" "$(cat <<CMD
set -euo pipefail
systemctl restart redis-server
systemctl enable redis-server
systemctl is-active redis-server
CMD
)"
    index=$((index + 1))
done

remote_exec "${MASTER_IP}" "Start redis (master)" "$(cat <<CMD
set -euo pipefail
systemctl restart redis-server
systemctl enable redis-server
systemctl is-active redis-server
CMD
)"

debug "启动 Redis 完成"

debug "启动 Sentinel 开始..."

for ip in "${SENTINEL_NODES[@]}"; do
    remote_exec "${ip}" "Start redis-sentinel" "$(cat <<CMD
set -euo pipefail
systemctl restart redis-sentinel
systemctl enable redis-sentinel
systemctl is-active redis-sentinel
CMD
)"
done

debug "启动 Sentinel 完成"

######################## 9. 部署验收 ########################
debug "部署验收开始..."

slave_count=$(( ${#REDIS_NODES[@]} - 1 ))

remote_exec "${MASTER_IP}" "Verify redis replication on master" "$(cat <<CMD
set -euo pipefail
if [[ -n '${REDIS_PASS}' ]]; then
  out=\$(redis-cli -a '${REDIS_PASS}' INFO replication)
else
  out=\$(redis-cli INFO replication)
fi
echo "\${out}"
echo "\${out}" | grep -q 'role:master'
echo "\${out}" | grep -q "connected_slaves:${slave_count}"
CMD
)"

remote_exec "${SENTINEL_NODES[0]}" "Verify sentinel cluster" "$(cat <<CMD
set -euo pipefail
out=\$(redis-cli -p ${SENTINEL_PORT} INFO sentinel)
echo "\${out}"
echo "\${out}" | grep -q 'sentinel_masters:1'
echo "\${out}" | grep -q 'name=${MASTER_NAME}'
echo "\${out}" | grep -q 'slaves=${slave_count}'
echo "\${out}" | grep -q 'sentinels=${#SENTINEL_NODES[@]}'
master_addr=\$(redis-cli -p ${SENTINEL_PORT} SENTINEL get-master-addr-by-name ${MASTER_NAME})
echo "MASTER_ADDR=\${master_addr}"
echo "\${master_addr}" | grep -q '${MASTER_IP}'
CMD
)"

echo "Redis Sentinel deployment completed successfully."
echo "Log file: ${LOG_FILE}"
