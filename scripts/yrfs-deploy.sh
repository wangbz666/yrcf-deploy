#!/bin/bash

set -euo pipefail

################################ 全局配置 ###############################
CONFIG_FILE="/etc/yrfs/yrfs-deploy.conf"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
DEBUG=false

DEPLOY_MGR=false
DEPLOY_OSS=false
DEPLOY_MDS=false
DEPLOY_AGENT=false

################################ 日志函数（按模块） ###############################
log_mgr()   { _log "/var/log/yrfs-deploy-mgr.log"   "$*"; }
log_oss()   { _log "/var/log/yrfs-deploy-oss.log"   "$*"; }
log_mds()   { _log "/var/log/yrfs-deploy-mds.log"   "$*"; }
log_agent() { _log "/var/log/yrfs-deploy-agent.log" "$*"; }

_log() {
    local file="$1"
    shift
    echo "[$(date '+%F %T')] $*" | tee -a "${file}"
}

################################ Debug 函数 ###############################
debug() {
    if [[ "${DEBUG}" == "true" ]]; then
        echo "[DEBUG] $*"
    fi
}

################################ 参数解析 ###############################
parse_args() {
    for arg in "$@"; do
        case "${arg}" in
            --mgr)
                DEPLOY_MGR=true
                ;;
            --oss)
                DEPLOY_OSS=true
                ;;
            --mds)
                DEPLOY_MDS=true
                ;;
            --agent)
                DEPLOY_AGENT=true
                ;;
            --debug)
                DEBUG=true
                ;;
            *)
                echo "ERROR: unknown argument: ${arg}"
                usage
                exit 1
                ;;
        esac
    done

    # 至少选一个模块
    if ! ${DEPLOY_MGR} && ! ${DEPLOY_OSS} && ! ${DEPLOY_MDS} && ! ${DEPLOY_AGENT}; then
        echo "ERROR: no deploy target specified"
        usage
        exit 1
    fi
}

usage() {
    cat <<EOF
Usage:
  $0 [--mgr] [--oss] [--mds] [--agent] [--debug]

Options:
  --mgr      Deploy Manager
  --oss      Deploy OSS
  --mds      Deploy MDS
  --agent    Deploy Agent
  --debug    Enable debug output
EOF
}

################################ 安全追加配置函数 ##########################
safe_append_conf() {
    local key="$1"
    local value="$2"
    local file="$3"

    # 如果 key=value 已存在，跳过
    if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"; then
        echo "Skip existing: ${key}"
        # log_mds "Skip existing: ${key}"
        return
    fi

    echo "${key} = ${value}" >> "$file"
    # log_mds "Append: ${key} = ${value}"
}


################################ 配置文件检查 ###############################
check_config() {
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        echo "ERROR: config file not found: ${CONFIG_FILE}"
        exit 1
    fi
    debug "Config file exists: ${CONFIG_FILE}"
}

deploy_mgr() {
    log_mgr "====== Start deploy MGR ======"

    ################################ 1. 读取配置 ###############################
    local ipwhitelist=""
    local net=""
    local net_plane=""
    local mgr_ip=""
    local mgr_ipwhitelist=""
    local mgr_net=""

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | xargs)
        case "${key}" in
            root_password)
                ROOT_PASS="${value}"
                ;;
            ipwhitelist)
                ipwhitelist="${value}"
                ;;
            net)
                net="${value}"
                ;;
            net_plane)
                net_plane="${value}"
                ;;
            mgr_ip)
                mgr_ip="${value}"
                ;;
            mgr_ipwhitelist)
                mgr_ipwhitelist="${value}"
                ;;
            mgr_net)
                mgr_net="${value}"
                ;;
        esac
    done < "${CONFIG_FILE}"

    debug "ipwhitelist=${ipwhitelist}"
    debug "net=${net}"
    debug "net_plane=${net_plane}"
    debug "mgr_ip=${mgr_ip}"
    debug "mgr_ipwhitelist=${mgr_ipwhitelist}"
    debug "mgr_net=${mgr_net}"

    ################################ 2. 校验 ###############################
    [[ -z "${ipwhitelist}" ]] && { log_mgr "ERROR: ipwhitelist empty"; exit 1; }
    [[ -z "${net}" ]] && { log_mgr "ERROR: net empty"; exit 1; }
    [[ -z "${net_plane}" ]] && { log_mgr "ERROR: net_plane empty"; exit 1; }
    [[ -z "${mgr_ip}" ]] && { log_mgr "ERROR: mgr_ip empty"; exit 1; }
    [[ -z "${mgr_ipwhitelist}" ]] && { log_mgr "ERROR: mgr_ipwhitelist empty"; exit 1; }
    [[ -z "${mgr_net}" ]] && { log_mgr "ERROR: mgr_net empty"; exit 1; }

    ################################ 3. 解析节点 ###############################
    IFS=':' read -ra MGR_NODES <<< "${mgr_ip}"
    IFS=':' read -ra IPWHITELIST_NODES <<< "${ipwhitelist}"

    # 构造 -E 参数（所有 IP 逗号拼接）
    local E_IPS=""
    for node in "${MGR_NODES[@]}"; do
        for ip in $(echo "${node}" | tr ',' ' '); do
            E_IPS+="${ip},"
        done
    done
    E_IPS="${E_IPS%,}"
    debug "E_IPS=$E_IPS"

    ################################## 4. 配置ipwhitelist，net ##########################
    local ipwhitelist_idx=0
    for node in "${IPWHITELIST_NODES[@]}"; do
        local ipwhitelist_ip="${node%%,*}"

        log_mgr "Deploy common on ${ipwhitelist_ip} (node index ${ipwhitelist_idx})"
        debug "Deploy common on ${ipwhitelist_ip} (node index ${ipwhitelist_idx})"

        ################################ SSH 连通性 ###############################
        if ! sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${ipwhitelist_ip}" "echo OK" >/dev/null 2>&1; then
            log_mgr "ERROR: SSH failed for ${ipwhitelist_ip}"
            exit 1
        fi

        ################################ 取当前节点的配置 ###############################
        local this_ipwl="${IPWHITELIST_NODES[$ipwhitelist_idx]:-}"

        debug "this_ipwl=$this_ipwl"

        ################################ 远程执行 ###############################
        sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${ipwhitelist_ip}" bash <<EOF | tee -a /var/log/yrfs-deploy-mgr.log
# set -euxo pipefail

mkdir -p /etc/yrfs

###################################### ipwhitelist（当前节点）#####################################
echo "${this_ipwl}" | tr ',' '\n' > /etc/yrfs/ipwhitelist

###################################### net（所有节点一致）#####################################
echo "${net}" | tr ',' '\n' > /etc/yrfs/net

###################################### net_plane.yaml（动态生成）#####################################
cat > /etc/yrfs/net_plane.yaml <<YAML
net_configs:
$(echo "${net_plane}" | tr ',' '\n' | awk '{print "- cidr:\n    ipv4: " $0 "\n    ipv6: ''''\n  net_name: net" NR}')
YAML
EOF
        log_mgr "common deploy finished on ${ipwhitelist_ip}"
        debug "common deploy finished on ${ipwhitelist_ip}"
        ipwhitelist_idx=$((ipwhitelist_idx+1))
    done


    ################################ 5. 按节点执行配置mgr ###############################
    local idx=0
    for node in "${MGR_NODES[@]}"; do
        local primary_ip="${node%%,*}"
        local S_IP="${node%%,*}"

        log_mgr "Deploy MGR on ${primary_ip} (node index ${idx})"
        debug "Deploy MGR on ${primary_ip} (node index ${idx})"

        ################################ SSH 连通性 ###############################
        if ! sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" "echo OK" >/dev/null 2>&1; then
            log_mgr "ERROR: SSH failed for ${primary_ip}"
            exit 1
        fi

        ################################ 取当前节点的配置 ###############################
        IFS=':' read -ra MGR_IPWL_NODES <<< "${mgr_ipwhitelist}"

        local this_mgr_ipwl="${MGR_IPWL_NODES[$idx]:-}"

        debug "this_mgr_ipwl=$this_mgr_ipwl"

        ################################ 远程执行 ###############################
        sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF | tee -a /var/log/yrfs-deploy-mgr.log
# set -euxo pipefail

mkdir -p /etc/yrfs

###################################### install-yrfs-mgr #####################################
/usr/local/sbin/install-yrfs-mgr -E ${E_IPS} -S ${S_IP}

###################################### yrfs-mgr.conf #####################################
echo "" >> /etc/yrfs/yrfs-mgr.conf
# conn_ip_whitelist_file
grep -q "^conn_ip_whitelist_file\s*=" /etc/yrfs/yrfs-mgr.conf || \
    echo "conn_ip_whitelist_file = /etc/yrfs/ipwhitelist-mgmt" >> /etc/yrfs/yrfs-mgr.conf

# conn_subnet_filter_file
grep -q "^conn_subnet_filter_file\s*=" /etc/yrfs/yrfs-mgr.conf || \
    echo "conn_subnet_filter_file = /etc/yrfs/net-mgmt" >> /etc/yrfs/yrfs-mgr.conf

# etcd_user_name
grep -q "^etcd_user_name\s*=" /etc/yrfs/yrfs-mgr.conf || \
    sed -i '$ a etcd_user_name = yrcf' /etc/yrfs/yrfs-mgr.conf

# etcd_user_password
grep -q "^etcd_user_password\s*=" /etc/yrfs/yrfs-mgr.conf || \
    sed -i '$ a etcd_user_password = Passw0rd@ETCD' /etc/yrfs/yrfs-mgr.conf

###################################### ipwhitelist-mgmt（当前节点）#####################################
echo "${this_mgr_ipwl}" | tr ',' '\n' > /etc/yrfs/ipwhitelist-mgmt

###################################### net-mgmt（所有节点一致）#####################################
echo "${mgr_net}" | tr ',' '\n' > /etc/yrfs/net-mgmt

EOF

        log_mgr "MGR deploy finished on ${primary_ip}"
        debug "MGR deploy finished on ${primary_ip}"
        idx=$((idx+1))
    done

    log_mgr "====== All MGR nodes deployed ======"
}

deploy_oss() {
    log_oss "====== Start deploy OSS ======"

    ################################ 1. 读取配置 ###############################
    local oss_ip=""
    local oss_install=""
    local oss_ipwhitelist=""
    local oss_net=""
    local oss_rdma_ip=""

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | xargs)
        case "${key}" in
            root_password) ROOT_PASS="${value}" ;;
            oss_ip) oss_ip="${value}" ;;
            oss_install) oss_install="${value}" ;;
            oss_ipwhitelist) oss_ipwhitelist="${value}" ;;
            oss_net) oss_net="${value}" ;;
            oss_rdma_ip) oss_rdma_ip="${value}" ;;
        esac
    done < "${CONFIG_FILE}"

    ################################ 2. 解析节点 ###############################
    IFS=':' read -ra OSS_NODES <<< "${oss_ip}"
    IFS=':' read -ra OSS_INSTALL_NODES <<< "${oss_install}"
    IFS=':' read -ra OSS_IPWL_NODES <<< "${oss_ipwhitelist}"

    if [[ -n "${oss_rdma_ip}" ]]; then
        IFS=':' read -ra OSS_RDMA_NODES <<< "${oss_rdma_ip}"
    else
        OSS_RDMA_NODES=()
    fi

    ################################ 3. 构造 -m ###############################
    local ALL_OSS_IPS=""
    for node in "${OSS_NODES[@]}"; do
        for ip in $(echo "${node}" | tr ',' ' '); do
            ALL_OSS_IPS+="${ip},"
        done
    done
    ALL_OSS_IPS="${ALL_OSS_IPS%,}"

    debug "ALL_OSS_IPS=$ALL_OSS_IPS"

    ################################ 4. 遍历节点 ###############################
    local node_idx=1
    for node in "${OSS_NODES[@]}"; do
        local primary_ip="${node%%,*}"
        local node_name="node${node_idx}"

        log_oss "Deploy OSS on ${primary_ip} (${node_name})"

        debug "Deploy OSS on ${primary_ip} (${node_name})"

        if ! sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" "echo OK" >/dev/null 2>&1; then
            log_oss "ERROR: SSH failed for ${primary_ip}"
            exit 1
        fi

        local this_install="${OSS_INSTALL_NODES[$((node_idx - 1))]}"
        local this_ipwl="${OSS_IPWL_NODES[$((node_idx - 1))]:-}"
        local this_rdma="${OSS_RDMA_NODES[$((node_idx - 1))]:-}"

        IFS='|' read -ra PROCS <<< "${this_install}"
        IFS='|' read -ra IPWLS <<< "${this_ipwl}"

        ################################ 节点级磁盘序号（关键） ###############################
        local disk_seq=1

        ################################ 5. 每个进程 ###############################
        local proc_idx=1
        for proc in "${PROCS[@]}"; do
            local proc_name="oss$((proc_idx - 1))"
            local conf_dir="/etc/yrfs/${proc_name}.d"
            local conf_file="${conf_dir}/yrfs-oss.conf"
            local port=$((7210 + proc_idx))
            local s_val="${node_idx}0${proc_idx}"
            local this_proc_ipwl="${IPWLS[$((proc_idx - 1))]:-}"

            log_oss "  → Configure process ${proc_name}"

            debug "  → Configure process ${proc_name}"
            debug "conf_dir=$conf_dir"
            debug "conf_file=$conf_file"
            debug "port=$port"
            debug "node_name=$node_name"

            sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
$(declare -f safe_append_conf)
# set -euxo pipefail

mkdir -p ${conf_dir}

if [[ ! -f "${conf_file}" ]]; then
    cp /etc/yrfs/yrfs-oss.conf "${conf_file}"
fi

###################################### 安全追加配置 #####################################
safe_append_conf "conn_ip_whitelist_file" "/etc/yrfs/ipwhitelist-${proc_name}" "${conf_file}"
safe_append_conf "sync_ip_whitelist_file" "/etc/yrfs/ipwhitelist-${proc_name}-sync" "${conf_file}"
safe_append_conf "yaml_cfg_file" "${conf_dir}/yrfs-oss.yaml" "${conf_file}"
safe_append_conf "conn_subnet_filter_file" "/etc/yrfs/net-oss" "${conf_file}"
safe_append_conf "log_file" "/var/log/yrfs-oss@${proc_name}.log" "${conf_file}"
safe_append_conf "conn_oss_port" "${port}" "${conf_file}"
safe_append_conf "conn_oss_port_udp" "${port}" "${conf_file}"

EOF

            ###################################### net / ipwhitelist / yaml #####################################
            sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
# set -euxo pipefail

echo "${this_proc_ipwl}" | tr ',' '\n' > /etc/yrfs/ipwhitelist-${proc_name}
cp /etc/yrfs/ipwhitelist-${proc_name} /etc/yrfs/ipwhitelist-${proc_name}-sync

echo "${oss_net}" | tr ',' '\n' > /etc/yrfs/net-oss

cat > ${conf_dir}/yrfs-oss.yaml <<YAML
network:
$(if [[ -n "${this_rdma}" ]]; then
    echo "  enable_rdma_ips:"
    echo "${this_rdma}" | tr ',' '\n' | sed 's/^/  - /'
else
    echo "  enable_rdma_ips: []"
fi)
YAML
EOF

            ################################ 6. 每个磁盘 install ###############################
            IFS=',' read -ra DISKS <<< "${proc}"
            for disk in "${DISKS[@]}"; do
                local i_val=$(( node_idx * 100 + disk_seq ))
                local I_val="tg${i_val}"

                log_oss "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -i ${i_val} -I ${I_val} -c ${conf_file} -m ${ALL_OSS_IPS})"
                debug   "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -i ${i_val} -I ${I_val} -c ${conf_file} -m ${ALL_OSS_IPS})"

                sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
# set -euxo pipefail

MOUNT_POINT=\$(df -h "${disk}" | awk 'NR==2{print \$6}')
if [[ -z "\${MOUNT_POINT}" ]]; then
    echo "ERROR: ${disk} not mounted"
    exit 1
fi

/usr/local/sbin/install-yrfs-oss \
  -p "\${MOUNT_POINT}/" \
  -S ${node_name} \
  -s ${s_val} \
  -i ${i_val} \
  -I ${I_val} \
  -c ${conf_file} \
  -m ${ALL_OSS_IPS}

EOF
                disk_seq=$((disk_seq + 1))
            done

            proc_idx=$((proc_idx + 1))
        done

        node_idx=$((node_idx + 1))
    done

    log_oss "====== All OSS nodes deployed ======"
}


deploy_mds() {
    log_mds "====== Start deploy MDS ======"

    ################################ 1. 读取配置 ###############################
    local mds_ip=""
    local mds_install=""
    local mds_ipwhitelist=""
    local mds_net=""
    local mds_rdma_ip=""

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | xargs)
        case "${key}" in
            root_password) ROOT_PASS="${value}" ;;
            mds_ip) mds_ip="${value}" ;;
            mds_install) mds_install="${value}" ;;
            mds_ipwhitelist) mds_ipwhitelist="${value}" ;;
            mds_net) mds_net="${value}" ;;
            mds_rdma_ip) mds_rdma_ip="${value}" ;;
        esac
    done < "${CONFIG_FILE}"

    ################################ 2. 解析节点 ###############################
    IFS=':' read -ra MDS_NODES <<< "${mds_ip}"
    IFS=':' read -ra MDS_INSTALL_NODES <<< "${mds_install}"
    IFS=':' read -ra MDS_IPWL_NODES <<< "${mds_ipwhitelist}"
    if [[ -n "${mds_rdma_ip}" ]]; then
        IFS=':' read -ra MDS_RDMA_NODES <<< "${mds_rdma_ip}"
    else
        MDS_RDMA_NODES=()  # 设为空数组，避免后续取索引时报错
    fi

    ################################ 3. 构造 -m ###############################
    local ALL_MDS_IPS=""
    for node in "${MDS_NODES[@]}"; do
        for ip in $(echo "${node}" | tr ',' ' '); do
            ALL_MDS_IPS+="${ip},"
        done
    done
    ALL_MDS_IPS="${ALL_MDS_IPS%,}"

    debug "ALL_MDS_IPS=$ALL_MDS_IPS"

    ################################ 4. 遍历节点 ###############################
    local node_idx=1
    for node in "${MDS_NODES[@]}"; do
        local primary_ip="${node%%,*}"
        local node_name="node${node_idx}"

        log_mds "Deploy MDS on ${primary_ip} (${node_name})"

        debug "Deploy MDS on ${primary_ip} (${node_name})"

        if ! sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" "echo OK" >/dev/null 2>&1; then
            log_mds "ERROR: SSH failed for ${primary_ip}"
            exit 1
        fi

        local this_install="${MDS_INSTALL_NODES[$((node_idx - 1))]}"
        local this_ipwl="${MDS_IPWL_NODES[$((node_idx - 1))]}"
        # 如果数组越界或者为空，默认给空字符串
        local this_rdma="${MDS_RDMA_NODES[$((node_idx - 1))]:-}"

        IFS='|' read -ra PROCS <<< "${this_install}"
        IFS='|' read -ra IPWLS <<< "${this_ipwl}"
        IFS=',' read -ra RDMA_IPS <<< "${this_rdma}" # wbz: 这一步看起来没有用

        ################################ 5. 每个进程：模板复制 + 增量配置 ###############################
        local proc_idx=1
        for proc in "${PROCS[@]}"; do
            local proc_name="mds$((proc_idx - 1))"
            local conf_dir="/etc/yrfs/${proc_name}.d"
            local conf_file="${conf_dir}/yrfs-mds.conf"
            local port=$((7110 + proc_idx))
            local s_val="${node_idx}0${proc_idx}"
            local this_proc_ipwl="${IPWLS[$((proc_idx - 1))]:-}"

            log_mds "  → Configure process ${proc_name}"

            debug "  → Configure process ${proc_name}"
            debug "conf_dir=$conf_dir"
            debug "conf_file=$conf_file"
            debug "port=$port"
            debug "node_name=$node_name"

            sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
$(declare -f safe_append_conf)

# set -euxo pipefail

mkdir -p ${conf_dir}

###################################### 从模板复制（只复制一次）#####################################
if [[ ! -f "${conf_file}" ]]; then
    cp /etc/yrfs/yrfs-mds.conf "${conf_file}"
fi

###################################### 安全追加配置（幂等）#####################################
safe_append_conf "conn_ip_whitelist_file" "/etc/yrfs/ipwhitelist-${proc_name}" "${conf_file}"
safe_append_conf "sync_ip_whitelist_file" "/etc/yrfs/ipwhitelist-${proc_name}-sync" "${conf_file}"
safe_append_conf "yaml_cfg_file" "${conf_dir}/yrfs-mds.yaml" "${conf_file}"
safe_append_conf "conn_subnet_filter_file" "/etc/yrfs/net-mds" "${conf_file}"
safe_append_conf "log_file" "/var/log/yrfs-mds@${proc_name}.log" "${conf_file}"
safe_append_conf "conn_mds_port" "${port}" "${conf_file}"
safe_append_conf "conn_mds_port_udp" "${port}" "${conf_file}"

EOF

            ###################################### net / ipwhitelist / yaml（进程级）#####################################
            sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
# set -euxo pipefail

echo "${this_proc_ipwl}" | tr ',' '\n' > /etc/yrfs/ipwhitelist-${proc_name}
cp /etc/yrfs/ipwhitelist-${proc_name} /etc/yrfs/ipwhitelist-${proc_name}-sync

echo "${mds_net}" | tr ',' '\n' > /etc/yrfs/net-mds

cat > ${conf_dir}/yrfs-mds.yaml <<YAML
network:
$(if [[ -n "${this_rdma}" ]]; then
    echo "  enable_rdma_ips:"
    echo "${this_rdma}" | tr ',' '\n' | sed 's/^/  - /'
else
    echo "  enable_rdma_ips: []"
fi)

YAML
EOF

            ################################ 6. 每个磁盘执行 install ###############################
            IFS=',' read -ra DISKS <<< "${proc}"
            for disk in "${DISKS[@]}"; do
                log_mds "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -c ${conf_file} -m ${ALL_MDS_IPS})"
                debug   "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -c ${conf_file} -m ${ALL_MDS_IPS})"

                sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
# set -euxo pipefail

MOUNT_POINT=\$(df -h "${disk}" | awk 'NR==2{print \$6}')
if [[ -z "\${MOUNT_POINT}" ]]; then
    echo "ERROR: ${disk} not mounted"
    exit 1
fi

/usr/local/sbin/install-yrfs-mds \
  -p "\${MOUNT_POINT}/" \
  -S ${node_name} \
  -s ${s_val} \
  -c ${conf_file} \
  -m ${ALL_MDS_IPS}

EOF
            done

            proc_idx=$((proc_idx + 1))
        done

        node_idx=$((node_idx + 1))
    done

    log_mds "====== All MDS nodes deployed ======"
}


deploy_agent() {
    log_agent "====== Start deploy AGENT ======"

    ################################ 1. 读取配置 ###############################
    local agent_ip=""
    local agent_ipwhitelist=""
    local agent_net=""

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | xargs)
        case "${key}" in
            root_password) ROOT_PASS="${value}" ;;
            agent_ip) agent_ip="${value}" ;;
            agent_ipwhitelist) agent_ipwhitelist="${value}" ;;
            agent_net) agent_net="${value}" ;;
        esac
    done < "${CONFIG_FILE}"

    ################################ 2. 解析节点 ###############################
    IFS=':' read -ra AGENT_NODES <<< "${agent_ip}"
    IFS=':' read -ra AGENT_IPWL_NODES <<< "${agent_ipwhitelist}"
    IFS=':' read -ra AGENT_NET_NODES <<< "${agent_net}"

    ################################ 3. 构造 -m（所有 agent IP）###############################
    local ALL_AGENT_IPS=""
    for node in "${AGENT_NODES[@]}"; do
        for ip in $(echo "${node}" | tr ',' ' '); do
            ALL_AGENT_IPS+="${ip},"
        done
    done
    ALL_AGENT_IPS="${ALL_AGENT_IPS%,}"

    debug "ALL_AGENT_IPS=$ALL_AGENT_IPS"

    ################################ 4. 遍历节点 ###############################
    local node_idx=1
    for node in "${AGENT_NODES[@]}"; do
        local primary_ip="${node%%,*}"
        local node_name="node${node_idx}"

        log_agent "Deploy AGENT on ${primary_ip} (${node_name})"

        if ! sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" "echo OK" >/dev/null 2>&1; then
            log_agent "ERROR: SSH failed for ${primary_ip}"
            exit 1
        fi

        local this_ipwl="${AGENT_IPWL_NODES[$((node_idx - 1))]:-}"
        local this_net="${AGENT_NET_NODES[$((node_idx - 1))]:-}"

        debug "this_ipwl=$this_ipwl"
        debug "this_net=$this_net"

        ################################ 5. 远程执行 ###############################
        sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF | tee -a /var/log/yrfs-deploy-agent.log
# set -euxo pipefail

mkdir -p /etc/yrfs

###################################### ipwhitelist-agent #####################################
echo "${this_ipwl}" | tr ',' '\n' > /etc/yrfs/ipwhitelist-agent

###################################### net-agent #####################################
echo "${this_net}" | tr ',' '\n' > /etc/yrfs/net-agent

###################################### yrfs-agent.conf（追加 + 去重）#####################################
touch /etc/yrfs/yrfs-agent.conf

grep -q "conn_ip_whitelist_file" /etc/yrfs/yrfs-agent.conf || \
    echo "conn_ip_whitelist_file = /etc/yrfs/ipwhitelist-agent" >> /etc/yrfs/yrfs-agent.conf

grep -q "conn_subnet_filter_file" /etc/yrfs/yrfs-agent.conf || \
    echo "conn_subnet_filter_file = /etc/yrfs/net-agent" >> /etc/yrfs/yrfs-agent.conf

###################################### 安装 agent #####################################
/usr/local/sbin/install-yrfs-agent \
  -m ${ALL_AGENT_IPS} \
  -S ${primary_ip}

EOF

        node_idx=$((node_idx + 1))
    done

    log_agent "====== All AGENT nodes deployed ======"
}

################################ 主流程 ###############################
main() {
    parse_args "$@"
    check_config

    debug "DEPLOY_MGR=${DEPLOY_MGR}"
    debug "DEPLOY_OSS=${DEPLOY_OSS}"
    debug "DEPLOY_MDS=${DEPLOY_MDS}"
    debug "DEPLOY_AGENT=${DEPLOY_AGENT}"

    if ${DEPLOY_MGR}; then
        deploy_mgr
    fi

    if ${DEPLOY_OSS}; then
        deploy_oss
    fi

    if ${DEPLOY_MDS}; then
        deploy_mds
    fi

    if ${DEPLOY_AGENT}; then
        deploy_agent
    fi

    echo "All selected modules deployed."
}

main "$@"
