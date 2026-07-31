# YRCF集群手工部署

## 1. 部署说明

本章基于以下4节点规划进行手工部署：

| 配置项 | node1 | node2 | node3 | node4 |
|---|---|---|---|---|
| TCP IP | 192.168.255.95 | 192.168.255.96 | 192.168.255.97 | 192.168.255.98 |
| ib0 IP | 100.18.60.95 | 100.18.60.96 | 100.18.60.97 | 100.18.60.98 |
| ib1 IP | 100.18.60.195 | 100.18.60.196 | 100.18.60.197 | 100.18.60.198 |
| 磁盘数量 | 7块 | 7块 | 6块 | 6块 |
| etcd | 部署 | 部署 | 不部署 | 不部署 |
| MGR实例 | 1 | 1 | 0 | 0 |
| MDS实例 | 1 | 1 | 0 | 0 |
| MDS磁盘 | 1块 | 1块 | 0块 | 0块 |
| OSS实例 | 2 | 2 | 2 | 2 |
| 每个OSS管理磁盘 | 3块 | 3块 | 3块 | 3块 |
| OSS磁盘 | 6块 | 6块 | 6块 | 6块 |
| Agent实例 | 1 | 1 | 1 | 1 |

部署前应已完成节点环境准备，包括主机名、主机解析、SSH互信和网络路由配置。

> 文档中的`REPLACE_*`均为必须根据现场环境替换的占位符，不能直接执行。

## 2. 安装YRFS软件包

在所有节点上传YRFS软件包，并进入软件包所在目录执行：

```bash
apt install ./yrfs-*deb
```

检查软件包：

```bash
dpkg -l | grep yrfs
```

## 3. 部署etcd集群

etcd部署在node1和node2，版本为`3.4.18 arm64`：

- Client端口：`2379`
- Peer端口：`2380`
- node1成员名称：`etcd0`
- node2成员名称：`etcd1`

> 当前为2成员etcd集群。任意一个成员不可用时，集群将失去多数派并停止写入。

### 3.1 安装etcd

在node1、node2上传`etcd-v3.4.18-linux-arm64.tar.gz`并执行：

```bash
tar xvf etcd-v3.4.18-linux-arm64.tar.gz
cp etcd-v3.4.18-linux-arm64/etcd /usr/bin/
cp etcd-v3.4.18-linux-arm64/etcdctl /usr/bin/
chmod 755 /usr/bin/etcd /usr/bin/etcdctl
```

检查版本：

```bash
ETCD_UNSUPPORTED_ARCH=arm64 /usr/bin/etcd --version
/usr/bin/etcdctl version
```

### 3.2 创建etcd用户和目录

在node1、node2执行：

```bash
id etcd >/dev/null 2>&1 || useradd -m etcd
mkdir -p /etc/etcd
```

node1执行：

```bash
mkdir -p /var/lib/etcd/etcd0
chown -R etcd:etcd /var/lib/etcd
```

node2执行：

```bash
mkdir -p /var/lib/etcd/etcd1
chown -R etcd:etcd /var/lib/etcd
```

### 3.3 配置node1

在node1创建`/etc/etcd/etcd.conf`：

```bash
cat > /etc/etcd/etcd.conf <<'EOF'
ETCD_NAME="etcd0"
ETCD_DATA_DIR="/var/lib/etcd/etcd0"
ETCD_LISTEN_PEER_URLS="http://100.18.60.95:2380,http://100.18.60.195:2380,http://192.168.255.95:2380"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://100.18.60.95:2380,http://100.18.60.195:2380,http://192.168.255.95:2380"
ETCD_INITIAL_CLUSTER="etcd0=http://100.18.60.95:2380,etcd0=http://100.18.60.195:2380,etcd0=http://192.168.255.95:2380,etcd1=http://100.18.60.96:2380,etcd1=http://100.18.60.196:2380,etcd1=http://192.168.255.96:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="mritd-etcd-cluster"
ETCD_ADVERTISE_CLIENT_URLS="http://100.18.60.95:2379,http://100.18.60.195:2379,http://192.168.255.95:2379"
ETCD_MAX_REQUEST_BYTES=15728640
ETCD_QUOTA_BACKEND_BYTES=8589934592
ETCD_AUTO_COMPACTION_RETENTION=10
ETCD_AUTO_COMPACTION_MODE=revision
ETCD_SNAPSHOT_COUNT=5000
ETCD_MAX_WALS=10
ETCD_UNSUPPORTED_ARCH=arm64
EOF
```

### 3.4 配置node2

在node2创建`/etc/etcd/etcd.conf`：

```bash
cat > /etc/etcd/etcd.conf <<'EOF'
ETCD_NAME="etcd1"
ETCD_DATA_DIR="/var/lib/etcd/etcd1"
ETCD_LISTEN_PEER_URLS="http://100.18.60.96:2380,http://100.18.60.196:2380,http://192.168.255.96:2380"
ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://100.18.60.96:2380,http://100.18.60.196:2380,http://192.168.255.96:2380"
ETCD_INITIAL_CLUSTER="etcd0=http://100.18.60.95:2380,etcd0=http://100.18.60.195:2380,etcd0=http://192.168.255.95:2380,etcd1=http://100.18.60.96:2380,etcd1=http://100.18.60.196:2380,etcd1=http://192.168.255.96:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="mritd-etcd-cluster"
ETCD_ADVERTISE_CLIENT_URLS="http://100.18.60.96:2379,http://100.18.60.196:2379,http://192.168.255.96:2379"
ETCD_MAX_REQUEST_BYTES=15728640
ETCD_QUOTA_BACKEND_BYTES=8589934592
ETCD_AUTO_COMPACTION_RETENTION=10
ETCD_AUTO_COMPACTION_MODE=revision
ETCD_SNAPSHOT_COUNT=5000
ETCD_MAX_WALS=10
ETCD_UNSUPPORTED_ARCH=arm64
EOF
```

### 3.5 配置etcd服务

在node1、node2创建`/usr/lib/systemd/system/etcd.service`：

```bash
cat > /usr/lib/systemd/system/etcd.service <<'EOF'
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
EOF

systemctl daemon-reload
systemctl enable etcd
```

### 3.6 启动并检查etcd

确认两个节点均完成配置后，在node1、node2启动：

```bash
systemctl start etcd
systemctl status etcd
```

在任意etcd节点执行：

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS="http://192.168.255.95:2379,http://192.168.255.96:2379"

etcdctl member list
etcdctl endpoint health --cluster
```

应查询到`etcd0`和`etcd1`两个成员，且两个端点健康。

## 4. 格式化并挂载磁盘

> 以下操作会清除目标磁盘上的数据。执行前必须核对设备名，确认磁盘未被系统或其他业务使用。

### 4.1 配置磁盘变量

node1、node2分别根据实际设备名设置：

```bash
MDS_DISK="/dev/REPLACE_MDS_DISK"
OSS_DISKS=(
  "/dev/REPLACE_OSS_DISK_1"
  "/dev/REPLACE_OSS_DISK_2"
  "/dev/REPLACE_OSS_DISK_3"
  "/dev/REPLACE_OSS_DISK_4"
  "/dev/REPLACE_OSS_DISK_5"
  "/dev/REPLACE_OSS_DISK_6"
)
```

node3、node4分别根据实际设备名设置：

```bash
OSS_DISKS=(
  "/dev/REPLACE_OSS_DISK_1"
  "/dev/REPLACE_OSS_DISK_2"
  "/dev/REPLACE_OSS_DISK_3"
  "/dev/REPLACE_OSS_DISK_4"
  "/dev/REPLACE_OSS_DISK_5"
  "/dev/REPLACE_OSS_DISK_6"
)
```

检查设备：

```bash
lsblk -f
```

### 4.2 格式化MDS磁盘

仅在node1、node2执行：

```bash
mkfs.ext4 -i 2048 -I 1024 -J size=4096 \
  -O dir_index,large_dir,filetype "$MDS_DISK"
```

### 4.3 格式化OSS磁盘

在所有节点执行：

```bash
for disk in "${OSS_DISKS[@]}"; do
  mkfs.xfs -d su=128k,sw=8 -l version=2,su=128k \
    -i size=512 -f "$disk"
done
```

### 4.4 配置MDS挂载

仅在node1、node2执行：

```bash
mkdir -p /data/mds0
MDS_UUID="$(blkid -s UUID -o value "$MDS_DISK")"

grep -q "UUID=$MDS_UUID " /etc/fstab || \
  echo "UUID=$MDS_UUID /data/mds0 ext4 defaults,noatime,nodiratime,user_xattr,nofail,x-systemd.device-timeout=5 0 0" \
  >> /etc/fstab
```

### 4.5 配置OSS挂载

在所有节点执行：

```bash
for i in "${!OSS_DISKS[@]}"; do
  mkdir -p "/data/oss$i"
  OSS_UUID="$(blkid -s UUID -o value "${OSS_DISKS[$i]}")"

  grep -q "UUID=$OSS_UUID " /etc/fstab || \
    echo "UUID=$OSS_UUID /data/oss$i xfs defaults,prjquota,allocsize=8M,noatime,nodiratime,logbufs=8,logbsize=256k,largeio,inode64,swalloc,nofail,x-systemd.device-timeout=5 0 0" \
    >> /etc/fstab
done
```

### 4.6 挂载并检查

在所有节点执行：

```bash
mount -a
lsblk -f
findmnt | grep -E '/data/(mds|oss)'
```

确认node1、node2存在`/data/mds0`和`/data/oss0～5`，node3、node4存在`/data/oss0～5`。

## 5. 配置节点部署参数

所有节点均使用以下MGR地址：

```bash
MGR_ENDPOINTS="100.18.60.95,100.18.60.96,100.18.60.195,100.18.60.196,192.168.255.95,192.168.255.96"
ETCD_URIS="http://100.18.60.95:2379,http://100.18.60.96:2379,http://100.18.60.195:2379,http://100.18.60.196:2379,http://192.168.255.95:2379,http://192.168.255.96:2379"
```

在对应节点设置本地变量。

node1：

```bash
NODE_NAME="node1"
TCP_IP="192.168.255.95"
IB0_IP="100.18.60.95"
IB1_IP="100.18.60.195"
MDS_ID="101"
OSS0_ID="101"
OSS1_ID="102"
OSS0_TARGET_IDS=(101 102 103)
OSS1_TARGET_IDS=(104 105 106)
```

node2：

```bash
NODE_NAME="node2"
TCP_IP="192.168.255.96"
IB0_IP="100.18.60.96"
IB1_IP="100.18.60.196"
MDS_ID="201"
OSS0_ID="201"
OSS1_ID="202"
OSS0_TARGET_IDS=(201 202 203)
OSS1_TARGET_IDS=(204 205 206)
```

node3：

```bash
NODE_NAME="node3"
TCP_IP="192.168.255.97"
IB0_IP="100.18.60.97"
IB1_IP="100.18.60.197"
OSS0_ID="301"
OSS1_ID="302"
OSS0_TARGET_IDS=(301 302 303)
OSS1_TARGET_IDS=(304 305 306)
```

node4：

```bash
NODE_NAME="node4"
TCP_IP="192.168.255.98"
IB0_IP="100.18.60.98"
IB1_IP="100.18.60.198"
OSS0_ID="401"
OSS1_ID="402"
OSS0_TARGET_IDS=(401 402 403)
OSS1_TARGET_IDS=(404 405 406)
```

> 后续命令依赖本节变量。如果重新打开终端，需要重新设置当前节点对应的变量及`MGR_ENDPOINTS`、`ETCD_URIS`。

## 6. 配置YRFS公共网络文件

在所有节点执行：

```bash
cat > /etc/yrfs/ipwhitelist <<EOF
$IB0_IP
$IB1_IP
$TCP_IP
EOF

cat > /etc/yrfs/net <<'EOF'
100.18.60.0/24
192.168.0.0/16
EOF

cat > /etc/yrfs/net_plane.yaml <<'EOF'
net_configs:
  - cidr:
      ipv4: 100.18.60.0/24
      ipv6: ''
    net_name: net1
  - cidr:
      ipv4: 192.168.0.0/16
      ipv6: ''
    net_name: net2
EOF
```

## 7. 配置MGR

仅在node1、node2执行：

```bash
/usr/local/sbin/install-yrfs-mgr \
  -E "$MGR_ENDPOINTS" \
  -S "$IB0_IP"

cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-mgmt
cp /etc/yrfs/net /etc/yrfs/net-mgmt

cat >> /etc/yrfs/yrfs-mgr.conf <<'EOF'
conn_ip_whitelist_file = /etc/yrfs/ipwhitelist-mgmt
conn_subnet_filter_file = /etc/yrfs/net-mgmt
etcd_user_name = yrcf
etcd_user_password = REPLACE_ETCD_YRCF_PASSWORD
EOF
```

将`/etc/yrfs/yrfs-mgr.conf`中的`etcd_uris`修改为：

```text
etcd_uris = http://100.18.60.95:2379,http://100.18.60.96:2379,http://100.18.60.195:2379,http://100.18.60.196:2379,http://192.168.255.95:2379,http://192.168.255.96:2379
```

检查：

```bash
grep -E '^(etcd_uris|etcd_user_name|etcd_user_password|conn_ip_whitelist_file|conn_subnet_filter_file)' \
  /etc/yrfs/yrfs-mgr.conf
```

## 8. 配置MDS

仅在node1、node2执行。

### 8.1 创建MDS配置

```bash
mkdir -p /etc/yrfs/mds0.d
cp /etc/yrfs/yrfs-mds.conf /etc/yrfs/mds0.d/yrfs-mds.conf

cat > /etc/yrfs/mds0.d/yrfs-mds.yaml <<EOF
network:
  enable_rdma_ips:
    - $IB0_IP
    - $IB1_IP
EOF

cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-mds0
cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-mds0-sync
cp /etc/yrfs/net /etc/yrfs/net-mds
```

### 8.2 安装MDS实例

```bash
/usr/local/sbin/install-yrfs-mds \
  -p /data/mds0/ \
  -S "$NODE_NAME" \
  -s "$MDS_ID" \
  -c /etc/yrfs/mds0.d/yrfs-mds.conf \
  -m "$MGR_ENDPOINTS"
```

### 8.3 更新MDS配置

```bash
cat >> /etc/yrfs/mds0.d/yrfs-mds.conf <<'EOF'
log_file = /var/log/yrfs-mds@mds0.log
conn_mds_port = 7111
conn_mds_port_udp = 7111
conn_ip_whitelist_file = /etc/yrfs/ipwhitelist-mds0
sync_ip_whitelist_file = /etc/yrfs/ipwhitelist-mds0-sync
yaml_cfg_file = /etc/yrfs/mds0.d/yrfs-mds.yaml
conn_subnet_filter_file = /etc/yrfs/net-mds
EOF
```

## 9. 配置OSS

在所有节点执行。每个节点部署`oss0`和`oss1`两个实例：

- `oss0`管理`/data/oss0～2`
- `oss1`管理`/data/oss3～5`

### 9.1 创建OSS配置

```bash
mkdir -p /etc/yrfs/oss0.d /etc/yrfs/oss1.d
cp /etc/yrfs/yrfs-oss.conf /etc/yrfs/oss0.d/yrfs-oss.conf
cp /etc/yrfs/yrfs-oss.conf /etc/yrfs/oss1.d/yrfs-oss.conf

cat > /etc/yrfs/oss0.d/yrfs-oss.yaml <<EOF
network:
  enable_rdma_ips:
    - $IB0_IP
    - $IB1_IP
EOF

cp /etc/yrfs/oss0.d/yrfs-oss.yaml /etc/yrfs/oss1.d/yrfs-oss.yaml
cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-oss0
cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-oss0-sync
cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-oss1
cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-oss1-sync
cp /etc/yrfs/net /etc/yrfs/net-oss
```

### 9.2 安装oss0管理的Target

```bash
for offset in 0 1 2; do
  target_id="${OSS0_TARGET_IDS[$offset]}"

  /usr/local/sbin/install-yrfs-oss \
    -p "/data/oss$offset" \
    -S "$NODE_NAME" \
    -s "$OSS0_ID" \
    -i "$target_id" \
    -I "tg$target_id" \
    -c /etc/yrfs/oss0.d/yrfs-oss.conf \
    -m "$MGR_ENDPOINTS"
done
```

### 9.3 安装oss1管理的Target

```bash
for offset in 0 1 2; do
  disk_index=$((offset + 3))
  target_id="${OSS1_TARGET_IDS[$offset]}"

  /usr/local/sbin/install-yrfs-oss \
    -p "/data/oss$disk_index" \
    -S "$NODE_NAME" \
    -s "$OSS1_ID" \
    -i "$target_id" \
    -I "tg$target_id" \
    -c /etc/yrfs/oss1.d/yrfs-oss.conf \
    -m "$MGR_ENDPOINTS"
done
```

### 9.4 更新OSS配置

配置oss0：

```bash
cat >> /etc/yrfs/oss0.d/yrfs-oss.conf <<'EOF'
log_file = /var/log/yrfs-oss@oss0.log
conn_oss_port = 7211
conn_oss_port_udp = 7211
conn_ip_whitelist_file = /etc/yrfs/ipwhitelist-oss0
sync_ip_whitelist_file = /etc/yrfs/ipwhitelist-oss0-sync
conn_subnet_filter_file = /etc/yrfs/net-oss
yaml_cfg_file = /etc/yrfs/oss0.d/yrfs-oss.yaml
EOF
```

配置oss1：

```bash
cat >> /etc/yrfs/oss1.d/yrfs-oss.conf <<'EOF'
log_file = /var/log/yrfs-oss@oss1.log
conn_oss_port = 7212
conn_oss_port_udp = 7212
conn_ip_whitelist_file = /etc/yrfs/ipwhitelist-oss1
sync_ip_whitelist_file = /etc/yrfs/ipwhitelist-oss1-sync
conn_subnet_filter_file = /etc/yrfs/net-oss
yaml_cfg_file = /etc/yrfs/oss1.d/yrfs-oss.yaml
EOF
```

## 10. 配置Agent

在所有节点执行：

```bash
/usr/local/sbin/install-yrfs-agent \
  -m "$MGR_ENDPOINTS" \
  -S "$IB0_IP"

cat >> /etc/yrfs/yrfs-agent.conf <<'EOF'
conn_ip_whitelist_file = /etc/yrfs/ipwhitelist
conn_subnet_filter_file = /etc/yrfs/net
EOF

cp /etc/yrfs/ipwhitelist /etc/yrfs/ipwhitelist-agent
cp /etc/yrfs/net /etc/yrfs/net-agent
```

本次集群内部不部署Client，因此不执行`install-yrfs-client`。

## 11. 配置etcd认证

在任意一个etcd节点执行：

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS="http://192.168.255.95:2379,http://192.168.255.96:2379"
```

创建root角色和用户：

```bash
etcdctl role add root
etcdctl user add root
etcdctl user grant-role root root
```

创建YRFS使用的`yrcf`用户：

```bash
etcdctl user add yrcf
etcdctl user grant-role yrcf root
```

启用认证：

```bash
etcdctl auth enable
```

注意：

- 创建用户时会交互式要求输入密码。
- `yrcf`用户密码必须与`yrfs-mgr.conf`中的`etcd_user_password`一致。
- 启用认证后，执行etcdctl命令需要提供用户信息。

验证：

```bash
etcdctl \
  --user=root:REPLACE_ETCD_ROOT_PASSWORD \
  get / --prefix --keys-only

etcdctl \
  --user=yrcf:REPLACE_ETCD_YRCF_PASSWORD \
  get / --prefix --keys-only
```

## 12. 启动YRFS服务

### 12.1 启动MGR

在node1、node2执行：

```bash
systemctl start yrfs-mgr
systemctl enable yrfs-mgr
systemctl status yrfs-mgr
```

确认两个MGR均正常后再启动MDS。

### 12.2 启动MDS

在node1、node2执行：

```bash
systemctl start yrfs-mds@mds0
systemctl enable yrfs-mds@mds0
systemctl status yrfs-mds@mds0
```

检查MDS注册情况：

```bash
yrcli --osd --type=mds
```

预期查询到2个MDS实例。

### 12.3 启动OSS

在所有节点执行：

```bash
systemctl start yrfs-oss@oss0
systemctl start yrfs-oss@oss1
systemctl enable yrfs-oss@oss0
systemctl enable yrfs-oss@oss1
systemctl status yrfs-oss@oss0
systemctl status yrfs-oss@oss1
```

检查OSS注册情况：

```bash
yrcli --osd --type=oss
```

预期查询到8个OSS实例，共管理24个Target。

### 12.4 启动Agent

在所有节点执行：

```bash
systemctl start yrfs-agent
systemctl enable yrfs-agent
systemctl status yrfs-agent
```

### 12.5 检查全部YRFS服务

在各节点执行：

```bash
systemctl list-units --type=service --state=active --no-legend |
  awk '$1 ~ /^yrfs/ {print $1}'
```

## 13. 配置集群

以下命令只在一个能够正常执行`yrcli`的节点运行一次。

> 集群格式化会初始化集群。执行前必须确认MDS、OSS数量及状态符合规划。

### 13.1 创建MDS和OSS分组

```bash
yrcli --addgroup --type=mds --auto
yrcli --addgroup --type=oss --auto
```

`--auto`按照两个实例一组自动建立分组。

### 13.2 格式化集群

```bash
yrcli --mkfs --type=mirror
```

预期输出：

```text
Operation succeeded.
```

### 13.3 配置RAID0 Layout

本集群共有8个OSS实例，按照两个实例一组形成4个OSS分组，因此`stripecount`设置为4：

```bash
yrcli \
  --setentry \
  --stripesize=1m \
  --stripecount=4 \
  --schema=raid0 \
  -u /
```

预期输出：

```text
Operation succeeded.
```

其中：

- `stripesize=1m`：条带大小为1 MiB。
- `stripecount=4`：数据分布到4个OSS分组。
- `schema=raid0`：目录使用RAID0 Layout。
- `-u /`：配置对集群根目录生效。

## 14. 部署验收

### 14.1 etcd检查

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS="http://192.168.255.95:2379,http://192.168.255.96:2379"

etcdctl \
  --user=root:REPLACE_ETCD_ROOT_PASSWORD \
  member list

etcdctl \
  --user=root:REPLACE_ETCD_ROOT_PASSWORD \
  endpoint health --cluster
```

### 14.2 服务实例检查

```bash
yrcli --osd
yrcli --osd --type=mds
yrcli --osd --type=oss
```

确认：

- MDS实例数量为2。
- OSS实例数量为8。
- OSS共管理24个Target。

### 14.3 磁盘挂载检查

在所有节点执行：

```bash
lsblk -f
findmnt | grep -E '/data/(mds|oss)'
```

### 14.4 RDMA流量检查

集群运行并产生业务流量后，在各节点执行：

```bash
mlnx_perf -i ib0 | grep rx_vport_rdma_unicast_packets -A 4
mlnx_perf -i ib1 | grep rx_vport_rdma_unicast_packets -A 4
```

确认两张IB网卡均产生RDMA流量。
