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
ROOT_PASS=""

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
    [[ -z "${ROOT_PASS}" ]] && { log_mgr "ERROR: root_password empty"; exit 1; }
    [[ -z "${ipwhitelist}" ]] && { log_mgr "ERROR: ipwhitelist empty"; exit 1; }
    [[ -z "${net}" ]] && { log_mgr "ERROR: net empty"; exit 1; }
    [[ -z "${net_plane}" ]] && { log_mgr "ERROR: net_plane empty"; exit 1; }
    [[ -z "${mgr_ip}" ]] && { log_mgr "ERROR: mgr_ip empty"; exit 1; }
    [[ -z "${mgr_ipwhitelist}" ]] && { log_mgr "ERROR: mgr_ipwhitelist empty"; exit 1; }
    [[ -z "${mgr_net}" ]] && { log_mgr "ERROR: mgr_net empty"; exit 1; }

    ################################ 3. 解析节点 ###############################
    IFS=':' read -ra MGR_NODES <<< "${mgr_ip}"
    IFS=':' read -ra IPWHITELIST_NODES <<< "${ipwhitelist}"
    IFS=':' read -ra MGR_IPWL_NODES <<< "${mgr_ipwhitelist}"

    if [[ "${mgr_ip}" == :* || "${mgr_ip}" == *: || "${mgr_ip}" == *::* ]] ||
       [[ "${mgr_ipwhitelist}" == :* || "${mgr_ipwhitelist}" == *: || "${mgr_ipwhitelist}" == *::* ]] ||
       [[ "${#MGR_NODES[@]}" -ne "${#MGR_IPWL_NODES[@]}" ]]; then
        log_mgr "ERROR: mgr_ip and mgr_ipwhitelist group counts must match and contain no empty groups"
        exit 1
    fi

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
set -euo pipefail

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
        local this_mgr_ipwl="${MGR_IPWL_NODES[$idx]:-}"

        debug "this_mgr_ipwl=$this_mgr_ipwl"

        ################################ 远程执行 ###############################
        sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF | tee -a /var/log/yrfs-deploy-mgr.log
set -euo pipefail

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
    local mgr_ip=""

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | xargs)
        case "${key}" in
            root_password) ROOT_PASS="${value}" ;;
            oss_ip) oss_ip="${value}" ;;
            oss_install) oss_install="${value}" ;;
            oss_ipwhitelist) oss_ipwhitelist="${value}" ;;
            oss_net) oss_net="${value}" ;;
            oss_rdma_ip) oss_rdma_ip="${value}" ;;
            mgr_ip) mgr_ip="${value}" ;;
        esac
    done < "${CONFIG_FILE}"

    ################################ 2. 校验并解析节点 ###############################
    [[ -z "${ROOT_PASS}" ]] && { log_oss "ERROR: root_password empty"; exit 1; }
    [[ -z "${oss_ip}" ]] && { log_oss "ERROR: oss_ip empty"; exit 1; }
    [[ -z "${oss_install}" ]] && { log_oss "ERROR: oss_install empty"; exit 1; }
    [[ -z "${oss_ipwhitelist}" ]] && { log_oss "ERROR: oss_ipwhitelist empty"; exit 1; }
    [[ -z "${oss_net}" ]] && { log_oss "ERROR: oss_net empty"; exit 1; }
    [[ -z "${oss_rdma_ip}" ]] && { log_oss "ERROR: oss_rdma_ip empty"; exit 1; }
    [[ -z "${mgr_ip}" ]] && { log_oss "ERROR: mgr_ip empty"; exit 1; }

    IFS=':' read -ra OSS_NODES <<< "${oss_ip}"
    IFS=':' read -ra OSS_INSTALL_NODES <<< "${oss_install}"
    IFS=':' read -ra OSS_IPWL_NODES <<< "${oss_ipwhitelist}"
    IFS=':' read -ra OSS_RDMA_NODES <<< "${oss_rdma_ip}"

    if [[ "${oss_ip}" == :* || "${oss_ip}" == *: || "${oss_ip}" == *::* ]] ||
       [[ "${oss_install}" == :* || "${oss_install}" == *: || "${oss_install}" == *::* ]] ||
       [[ "${oss_ipwhitelist}" == :* || "${oss_ipwhitelist}" == *: || "${oss_ipwhitelist}" == *::* ]] ||
       [[ "${oss_rdma_ip}" == :* || "${oss_rdma_ip}" == *: || "${oss_rdma_ip}" == *::* ]] ||
       [[ "${mgr_ip}" == :* || "${mgr_ip}" == *: || "${mgr_ip}" == *::* ]] ||
       [[ "${#OSS_NODES[@]}" -ne "${#OSS_INSTALL_NODES[@]}" ]] ||
       [[ "${#OSS_NODES[@]}" -ne "${#OSS_IPWL_NODES[@]}" ]] ||
       [[ "${#OSS_NODES[@]}" -ne "${#OSS_RDMA_NODES[@]}" ]]; then
        log_oss "ERROR: OSS node/install/whitelist/RDMA group counts must match and contain no empty groups"
        exit 1
    fi

    local check_idx
    for ((check_idx = 0; check_idx < ${#OSS_NODES[@]}; check_idx++)); do
        local check_install="${OSS_INSTALL_NODES[$check_idx]}"
        local check_ipwl="${OSS_IPWL_NODES[$check_idx]}"
        IFS='|' read -ra CHECK_PROCS <<< "${check_install}"
        IFS='|' read -ra CHECK_IPWLS <<< "${check_ipwl}"

        if [[ "${check_install}" == \|* || "${check_install}" == *\| || "${check_install}" == *"||"* ]] ||
           [[ "${check_ipwl}" == \|* || "${check_ipwl}" == *\| || "${check_ipwl}" == *"||"* ]] ||
           [[ "${#CHECK_PROCS[@]}" -ne "${#CHECK_IPWLS[@]}" ]]; then
            log_oss "ERROR: OSS node $((check_idx + 1)) instance and instance-whitelist counts must match and contain no empty groups"
            exit 1
        fi

        local check_proc
        for check_proc in "${CHECK_PROCS[@]}"; do
            if [[ -z "${check_proc}" || "${check_proc}" == ,* || "${check_proc}" == *, || "${check_proc}" == *",,"* ]]; then
                log_oss "ERROR: every OSS instance must contain at least one non-empty disk"
                exit 1
            fi
        done
    done

    ################################ 3. 构造 -m ###############################
    local ALL_MGR_IPS=""
    local mgr_node
    for mgr_node in ${mgr_ip//:/ }; do
        [[ -z "${mgr_node}" ]] && { log_oss "ERROR: mgr_ip contains an empty group"; exit 1; }
        for ip in $(echo "${mgr_node}" | tr ',' ' '); do
            ALL_MGR_IPS+="${ip},"
        done
    done
    ALL_MGR_IPS="${ALL_MGR_IPS%,}"

    debug "ALL_MGR_IPS=$ALL_MGR_IPS"

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
set -euo pipefail

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
set -euo pipefail

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

                log_oss "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -i ${i_val} -I ${I_val} -c ${conf_file} -m ${ALL_MGR_IPS})"
                debug   "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -i ${i_val} -I ${I_val} -c ${conf_file} -m ${ALL_MGR_IPS})"

                sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
set -euo pipefail

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
  -m ${ALL_MGR_IPS}

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
    local mgr_ip=""

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | xargs)
        case "${key}" in
            root_password) ROOT_PASS="${value}" ;;
            mds_ip) mds_ip="${value}" ;;
            mds_install) mds_install="${value}" ;;
            mds_ipwhitelist) mds_ipwhitelist="${value}" ;;
            mds_net) mds_net="${value}" ;;
            mds_rdma_ip) mds_rdma_ip="${value}" ;;
            mgr_ip) mgr_ip="${value}" ;;
        esac
    done < "${CONFIG_FILE}"

    ################################ 2. 校验并解析节点 ###############################
    [[ -z "${ROOT_PASS}" ]] && { log_mds "ERROR: root_password empty"; exit 1; }
    [[ -z "${mds_ip}" ]] && { log_mds "ERROR: mds_ip empty"; exit 1; }
    [[ -z "${mds_install}" ]] && { log_mds "ERROR: mds_install empty"; exit 1; }
    [[ -z "${mds_ipwhitelist}" ]] && { log_mds "ERROR: mds_ipwhitelist empty"; exit 1; }
    [[ -z "${mds_net}" ]] && { log_mds "ERROR: mds_net empty"; exit 1; }
    [[ -z "${mds_rdma_ip}" ]] && { log_mds "ERROR: mds_rdma_ip empty"; exit 1; }
    [[ -z "${mgr_ip}" ]] && { log_mds "ERROR: mgr_ip empty"; exit 1; }

    IFS=':' read -ra MDS_NODES <<< "${mds_ip}"
    IFS=':' read -ra MDS_INSTALL_NODES <<< "${mds_install}"
    IFS=':' read -ra MDS_IPWL_NODES <<< "${mds_ipwhitelist}"
    IFS=':' read -ra MDS_RDMA_NODES <<< "${mds_rdma_ip}"

    if [[ "${mds_ip}" == :* || "${mds_ip}" == *: || "${mds_ip}" == *::* ]] ||
       [[ "${mds_install}" == :* || "${mds_install}" == *: || "${mds_install}" == *::* ]] ||
       [[ "${mds_ipwhitelist}" == :* || "${mds_ipwhitelist}" == *: || "${mds_ipwhitelist}" == *::* ]] ||
       [[ "${mds_rdma_ip}" == :* || "${mds_rdma_ip}" == *: || "${mds_rdma_ip}" == *::* ]] ||
       [[ "${mgr_ip}" == :* || "${mgr_ip}" == *: || "${mgr_ip}" == *::* ]] ||
       [[ "${#MDS_NODES[@]}" -ne "${#MDS_INSTALL_NODES[@]}" ]] ||
       [[ "${#MDS_NODES[@]}" -ne "${#MDS_IPWL_NODES[@]}" ]] ||
       [[ "${#MDS_NODES[@]}" -ne "${#MDS_RDMA_NODES[@]}" ]]; then
        log_mds "ERROR: MDS node/install/whitelist/RDMA group counts must match and contain no empty groups"
        exit 1
    fi

    local check_idx
    for ((check_idx = 0; check_idx < ${#MDS_NODES[@]}; check_idx++)); do
        local check_install="${MDS_INSTALL_NODES[$check_idx]}"
        local check_ipwl="${MDS_IPWL_NODES[$check_idx]}"
        IFS='|' read -ra CHECK_PROCS <<< "${check_install}"
        IFS='|' read -ra CHECK_IPWLS <<< "${check_ipwl}"

        if [[ "${check_install}" == \|* || "${check_install}" == *\| || "${check_install}" == *"||"* ]] ||
           [[ "${check_ipwl}" == \|* || "${check_ipwl}" == *\| || "${check_ipwl}" == *"||"* ]] ||
           [[ "${#CHECK_PROCS[@]}" -ne "${#CHECK_IPWLS[@]}" ]]; then
            log_mds "ERROR: MDS node $((check_idx + 1)) instance and instance-whitelist counts must match and contain no empty groups"
            exit 1
        fi

        local check_proc
        for check_proc in "${CHECK_PROCS[@]}"; do
            if [[ -z "${check_proc}" || "${check_proc}" == ,* || "${check_proc}" == *, || "${check_proc}" == *",,"* ]]; then
                log_mds "ERROR: every MDS instance must contain at least one non-empty disk"
                exit 1
            fi
        done
    done

    ################################ 3. 构造 -m ###############################
    local ALL_MGR_IPS=""
    local mgr_node
    for mgr_node in ${mgr_ip//:/ }; do
        [[ -z "${mgr_node}" ]] && { log_mds "ERROR: mgr_ip contains an empty group"; exit 1; }
        for ip in $(echo "${mgr_node}" | tr ',' ' '); do
            ALL_MGR_IPS+="${ip},"
        done
    done
    ALL_MGR_IPS="${ALL_MGR_IPS%,}"

    debug "ALL_MGR_IPS=$ALL_MGR_IPS"

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

set -euo pipefail

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
set -euo pipefail

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
                log_mds "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -c ${conf_file} -m ${ALL_MGR_IPS})"
                debug   "    → Install disk ${disk} (-S ${node_name} -s ${s_val} -c ${conf_file} -m ${ALL_MGR_IPS})"

                sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF
set -euo pipefail

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
  -m ${ALL_MGR_IPS}

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
    local mgr_ip=""

    while IFS='=' read -r key value; do
        value=$(echo "${value}" | xargs)
        case "${key}" in
            root_password) ROOT_PASS="${value}" ;;
            agent_ip) agent_ip="${value}" ;;
            agent_ipwhitelist) agent_ipwhitelist="${value}" ;;
            agent_net) agent_net="${value}" ;;
            mgr_ip) mgr_ip="${value}" ;;
        esac
    done < "${CONFIG_FILE}"

    ################################ 2. 校验并解析节点 ###############################
    [[ -z "${ROOT_PASS}" ]] && { log_agent "ERROR: root_password empty"; exit 1; }
    [[ -z "${agent_ip}" ]] && { log_agent "ERROR: agent_ip empty"; exit 1; }
    [[ -z "${agent_ipwhitelist}" ]] && { log_agent "ERROR: agent_ipwhitelist empty"; exit 1; }
    [[ -z "${agent_net}" ]] && { log_agent "ERROR: agent_net empty"; exit 1; }
    [[ -z "${mgr_ip}" ]] && { log_agent "ERROR: mgr_ip empty"; exit 1; }

    IFS=':' read -ra AGENT_NODES <<< "${agent_ip}"
    IFS=':' read -ra AGENT_IPWL_NODES <<< "${agent_ipwhitelist}"
    IFS=':' read -ra AGENT_NET_NODES <<< "${agent_net}"

    if [[ "${agent_ip}" == :* || "${agent_ip}" == *: || "${agent_ip}" == *::* ]] ||
       [[ "${agent_ipwhitelist}" == :* || "${agent_ipwhitelist}" == *: || "${agent_ipwhitelist}" == *::* ]] ||
       [[ "${agent_net}" == :* || "${agent_net}" == *: || "${agent_net}" == *::* ]] ||
       [[ "${mgr_ip}" == :* || "${mgr_ip}" == *: || "${mgr_ip}" == *::* ]] ||
       [[ "${#AGENT_NODES[@]}" -ne "${#AGENT_IPWL_NODES[@]}" ]] ||
       [[ "${#AGENT_NODES[@]}" -ne "${#AGENT_NET_NODES[@]}" ]]; then
        log_agent "ERROR: agent_ip, agent_ipwhitelist and agent_net group counts must match and contain no empty groups"
        exit 1
    fi

    ################################ 3. 构造 -m（所有 MGR IP）###############################
    local ALL_MGR_IPS=""
    local mgr_node
    for mgr_node in ${mgr_ip//:/ }; do
        [[ -z "${mgr_node}" ]] && { log_agent "ERROR: mgr_ip contains an empty group"; exit 1; }
        for ip in $(echo "${mgr_node}" | tr ',' ' '); do
            ALL_MGR_IPS+="${ip},"
        done
    done
    ALL_MGR_IPS="${ALL_MGR_IPS%,}"

    debug "ALL_MGR_IPS=$ALL_MGR_IPS"

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
set -euo pipefail

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
  -m ${ALL_MGR_IPS} \
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
