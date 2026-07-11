#!/bin/bash

set -euo pipefail

######################## 全局配置 ########################
CONFIG_FILE="/etc/yrfs/yrfs-deploy.conf"
LOG_FILE="/var/log/yrfs-etcd-deploy.log"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
DEBUG=false

###################### 解析命令行参数 #####################
for arg in "$@"; do
    case "${arg}" in
        --debug)
            DEBUG=true
            ;;
    esac
done


######################## 日志,debug函数 ########################
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

######################## 1. 检查配置文件 ########################
debug "检查配置文件开始..."

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: ${CONFIG_FILE} not found"
    exit 1
fi

debug "检查配置文件完成"

######################## 2. 解析配置 ########################
debug "解析配置开始..."

ETCD_NODES=()
ROOT_PASS=""

while IFS='=' read -r key value; do
    case "${key}" in
        etcd_ip)
            IFS=':' read -ra ETCD_NODES <<< "${value}"
            ;;
        root_password)
            ROOT_PASS="${value}"
            ;;
    esac
done < "${CONFIG_FILE}"

[[ ${#ETCD_NODES[@]} -eq 0 ]] && { echo "ERROR: etcd_ip empty"; exit 1; }
[[ -z "${ROOT_PASS}" ]] && { echo "ERROR: root_password empty"; exit 1; }

debug "解析配置完成"

######################## 3. SSH 连通性检查 ########################
debug "SSH 连通性检查..."

for node in "${ETCD_NODES[@]}"; do
    primary_ip="${node%%,*}" #取配置文件中每个节点第一个ip

    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" \
        "echo OK" 2>&1 || true)
    status=$?

    log "${primary_ip}" "SSH connectivity check" "${out}" "" "${status}"

    [[ "${status}" -ne 0 ]] && {
        echo "ERROR: SSH to ${primary_ip} failed"
        exit 1
    }
done

debug "SSH 连通性检查完成"

######################## 4. 构造 ETCD_INITIAL_CLUSTER,ETCDCTL_ENDPOINTS ########################
debug "构造 ETCD_INITIAL_CLUSTER..."

INITIAL_CLUSTER=""
ETCDCTL_ENDPOINTS=""
index=0
for node in "${ETCD_NODES[@]}"; do
    # INITIAL_CLUSTER
    name="etcd${index}"
    # 把 node 里的 : 换成空格，逐个 IP 处理
    for ip in $(echo "${node}" | tr ',' ' '); do
        # ✅ 每个 IP 一个 etcdX= 条目
        INITIAL_CLUSTER+="${name}=http://${ip}:22380,"
        debug "INITIAL_CLUSTER=$INITIAL_CLUSTER"
    done

    # ETCDCTL_ENDPOINTS
    primary_ip="${node%%,*}" #取配置文件中每个节点第一个ip
    ETCDCTL_ENDPOINTS+="http://${primary_ip}:22379,"
    debug "ETCDCTL_ENDPOINTS=$ETCDCTL_ENDPOINTS"

    index=$((index + 1))
done

# 去掉最后一个逗号
INITIAL_CLUSTER="${INITIAL_CLUSTER%,}"
ETCDCTL_ENDPOINTS="${ETCDCTL_ENDPOINTS%,}"

debug "INITIAL_CLUSTER=$INITIAL_CLUSTER"
debug "ETCDCTL_ENDPOINTS=$ETCDCTL_ENDPOINTS"

debug "构造 ETCD_INITIAL_CLUSTER完成"

######################## 5. 逐节点部署 ########################
debug "逐节点部署开始.."
index=0
for node in "${ETCD_NODES[@]}"; do
    primary_ip="${node%%,*}"
    debug "primary_ip=$primary_ip"
    all_ips="${node}"
    debug "all_ips=$all_ips"
    name="etcd${index}"
    debug "name=$name"
    data_dir="/var/lib/etcd/${name}"
    debug "data_dir=$data_dir"

    #################### 4.1 ETCDCTL_API ####################
    debug "node:$node ETCDCTL_API"
    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<'CMD' 2>&1
set -e
echo "export ETCDCTL_API=3" >> /root/.bash_profile
CMD
)
    status=$?
    log "${primary_ip}" "Set ETCDCTL_API=3" "${out}" "" "${status}"

    #################### 4.2 systemd service ####################
    debug "node:$node systemd service"
    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<'CMD' 2>&1
set -e
cat > /usr/lib/systemd/system/etcd.service << 'SERVICE'
[Unit]
Description=Etcd Server
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
WorkingDirectory=/var/lib/etcd/
EnvironmentFile=-/etc/etcd/etcd.conf
User=etcd
LimitNOFILE=65536
ExecStart=/bin/bash -c "GOMAXPROCS=$(nproc) /usr/bin/etcd"
Restart=always
RestartSec=5s
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
SERVICE
CMD
)
    status=$?
    log "${primary_ip}" "Write etcd systemd unit" "${out}" "" "${status}"

    #################### 4.3 目录 & 用户 ####################
    debug "node:$node 目录 & 用户"
    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<CMD 2>&1
set -e
useradd -m etcd || true
mkdir -p /etc/etcd/
mkdir -p /var/lib/etcd
mkdir -p ${data_dir}
chown -R etcd:etcd /var/lib/etcd
CMD
)
    status=$?
    log "${primary_ip}" "Create etcd user and data dir" "${out}" "" "${status}"

    #################### 4.4 etcd.conf ####################
    debug "node:$node etcd.conf"
    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<CMD 2>&1
set -e
peer_urls=""
adv_urls=""
for ip in ${all_ips//,/ }; do
    peer_urls+="http://\${ip}:22380,"
    adv_urls+="http://\${ip}:22379,"
done

cat > /etc/etcd/etcd.conf << CONF
ETCD_NAME="${name}"
ETCD_DATA_DIR="${data_dir}"
ETCD_LISTEN_PEER_URLS="\${peer_urls%,}"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:22379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="\${peer_urls%,}"
ETCD_INITIAL_CLUSTER="${INITIAL_CLUSTER}"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="mritd-etcd-cluster"
ETCD_ADVERTISE_CLIENT_URLS="\${adv_urls%,}"

ETCD_MAX_REQUEST_BYTES=15728640
ETCD_QUOTA_BACKEND_BYTES=8589934592
ETCD_AUTO_COMPACTION_RETENTION=10
ETCD_AUTO_COMPACTION_MODE=revision
ETCD_SNAPSHOT_COUNT=5000
ETCD_MAX_WALS=10

ETCD_UNSUPPORTED_ARCH=arm64
CONF
CMD
)
    status=$?
    log "${primary_ip}" "Write etcd.conf" "${out}" "" "${status}"

#     #################### 4.5 启动 etcd ####################
#     out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<'CMD' 2>&1
# set -e
# systemctl daemon-reload
# systemctl enable etcd
# systemctl restart etcd
# CMD
# )
#     status=$?
#     log "${primary_ip}" "Enable and start etcd" "${out}" "" "${status}"

    #################### 4.5 持久化etcdctl参数 ####################
    debug "node:$node Persist etcdctl alias"
    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<CMD 2>&1
set -e
cat >> ~/.bashrc << ALIAS
alias etcdctl='etcdctl --endpoints=${ETCDCTL_ENDPOINTS}'
ALIAS
CMD
)
    status=$?
    log "${primary_ip}" "Persist etcdctl alias" "${out}" "" "${status}"

    ######################## end #####################################
    index=$((index + 1))
    debug "node:$node 部署完成"
done

log "ALL" "Etcd cluster deployment finished" "All nodes completed" "" "0"
echo "deploy etcd finished"
