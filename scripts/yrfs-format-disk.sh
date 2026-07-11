#!/bin/bash

set -euo pipefail

################################ 全局配置 ###############################
CONFIG_FILE="/etc/yrfs/yrfs-deploy.conf"
LOG_FILE="/var/log/yrfs-format-disk.log"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

DEBUG=false

################################ 日志 & Debug & check_fstab ###############################
log() {
    local node="$1"
    local action="$2"
    local stdout="$3"
    local stderr="$4"
    local status="$5"
    local ts
    ts="$(date '+%F %T')"
    {
        echo "[${ts}] [NODE:${node}] ACTION: ${action}"
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

check_fstab_exists() {
    local disk="$1"
    local uuid

    # 获取磁盘 UUID
    uuid=$(blkid -s UUID -o value "${disk}" 2>/dev/null || true)

    # 检查设备名
    if grep -qw "${disk}" /etc/fstab; then
        echo "ERROR: ${disk} already exists in /etc/fstab (device)"
        return 1
    fi

    # 检查 UUID
    if [[ -n "${uuid}" ]] && grep -qw "${uuid}" /etc/fstab; then
        echo "ERROR: ${disk} (UUID=${uuid}) already exists in /etc/fstab"
        return 1
    fi

    return 0
}

################################ 解析命令行参数 ###############################
for arg in "$@"; do
    case "${arg}" in
        --debug)
            DEBUG=true
            ;;
    esac
done

################################ 1. 检查配置文件 ###############################
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: ${CONFIG_FILE} not found"
    exit 1
fi

################################ 2. 解析配置 ###############################
ROOT_PASS=""
MDS_NODES=()
MDS_DISKS=()
OSS_NODES=()
OSS_DISKS=()

while IFS='=' read -r key value; do
    value=$(echo "${value}" | xargs)
    case "${key}" in
        root_password)
            ROOT_PASS="${value}"
            ;;
        mds_ip)
            IFS=':' read -ra MDS_NODES <<< "${value}"
            ;;
        mds_disk)
            IFS=':' read -ra MDS_DISKS <<< "${value}"
            ;;
        oss_ip)
            IFS=':' read -ra OSS_NODES <<< "${value}"
            ;;
        oss_disk)
            IFS=':' read -ra OSS_DISKS <<< "${value}"
            ;;
    esac
done < "${CONFIG_FILE}"

# 校验
[[ ${#MDS_NODES[@]} -eq 0 ]] && { echo "ERROR: mds_ip empty"; exit 1; }
[[ ${#MDS_DISKS[@]} -eq 0 ]] && { echo "ERROR: mds_disk empty"; exit 1; }
[[ ${#OSS_NODES[@]} -eq 0 ]] && { echo "ERROR: oss_ip empty"; exit 1; }
[[ ${#OSS_DISKS[@]} -eq 0 ]] && { echo "ERROR: oss_disk empty"; exit 1; }
[[ -z "${ROOT_PASS}" ]] && { echo "ERROR: root_password empty"; exit 1; }

debug "MDS_NODES: ${MDS_NODES[*]}"
debug "OSS_NODES: ${OSS_NODES[*]}"

################################ 3. SSH 连通性检查 ###############################
ALL_NODES=("${MDS_NODES[@]}" "${OSS_NODES[@]}")
ALL_NODES=($(echo "${ALL_NODES[@]}" | tr ' ' '\n' | sort -u))

for node in "${ALL_NODES[@]}"; do
    primary_ip="${node%%,*}"
    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" "echo OK" 2>&1)
    status=$?
    log "${primary_ip}" "SSH connectivity check" "${out}" "" "${status}"
    [[ "${status}" -ne 0 ]] && { echo "ERROR: SSH failed for ${primary_ip}"; exit 1; }
done

################################ 4. 每个节点执行 ###############################
for idx in "${!MDS_NODES[@]}"; do
    node="${MDS_NODES[$idx]}"
    disks="${MDS_DISKS[$idx]}"
    primary_ip="${node%%,*}"

    debug "Processing MDS node ${idx}: ${node}"
    debug "Disks: ${disks}"

    sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF | tee -a "${LOG_FILE}"
$(declare -f check_fstab_exists)

set -euxo pipefail
echo "====== NODE: ${primary_ip} ======"

# 4.1 检查磁盘是否已挂载
for disk in \$(echo "${disks}" | tr ',' ' '); do
    if mount | grep -q "\${disk}"; then
        echo "ERROR: Disk \${disk} is already mounted"
        exit 1
    fi

    if ! check_fstab_exists "\${disk}"; then
        echo "ABORT: Disk \${disk} found in fstab"
        exit 1
    fi
done

# 4.2 格式化 MDS 盘
i=0
for disk in \$(echo "${disks}" | tr ',' ' '); do
    mkfs.ext4 -i 2048 -I 1024 -J size=4096 -O dir_index,large_dir,filetype \${disk}
    mkdir -p /data/mds\${i}
    UUID=\$(blkid \${disk} | awk '{print \$2}')
    echo "\${UUID} /data/mds\${i} ext4 defaults,noatime,nodiratime,user_xattr,nofail,x-systemd.device-timeout=5 0 0" >> /etc/fstab
    i=\$((i+1))
done
EOF

done

# OSS 节点
for idx in "${!OSS_NODES[@]}"; do
    node="${OSS_NODES[$idx]}"
    disks="${OSS_DISKS[$idx]}"
    primary_ip="${node%%,*}"

    debug "Processing OSS node ${idx}: ${node}"
    debug "Disks: ${disks}"

    sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" bash <<EOF | tee -a "${LOG_FILE}"
$(declare -f check_fstab_exists)

set -euxo pipefail
echo "====== NODE: ${primary_ip} ======"

# 4.1 检查磁盘是否已挂载
for disk in \$(echo "${disks}" | tr ',' ' '); do
    if mount | grep -q "\${disk}"; then
        echo "ERROR: Disk \${disk} is already mounted"
        exit 1
    fi

    if ! check_fstab_exists "\${disk}"; then
        echo "ABORT: Disk \${disk} found in fstab"
        exit 1
    fi
done

# 4.3 格式化 OSS 盘
i=0
for disk in \$(echo "${disks}" | tr ',' ' '); do
    mkfs.xfs -d su=128k,sw=8 -l version=2,su=128k -isize=512 -f \${disk}
    mkdir -p /data/oss\${i}
    UUID=\$(blkid \${disk} | awk '{print \$2}')
    echo "\${UUID} /data/oss\${i} xfs defaults,prjquota,allocsize=8M,noatime,nodiratime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,nofail,x-systemd.device-timeout=5 0 0" >> /etc/fstab
    i=\$((i+1))
done
EOF
done

################################ 4.7 所有节点 mount -a ###############################
for node in "${ALL_NODES[@]}"; do
    primary_ip="${node%%,*}"
    out=$(sshpass -p "${ROOT_PASS}" ssh ${SSH_OPTS} root@"${primary_ip}" "mount -a && lsblk" 2>&1)
    status=$?
    log "${primary_ip}" "Mount and verify" "${out}" "" "${status}"
done

echo "Disk format and mount completed."