# YRCF集群自动化部署

## 1. 部署说明

自动化部署使用以下三个脚本：

- `yrfs-etcd-deploy.sh`：配置etcd集群。
- `yrfs-format-disk.sh`：格式化并挂载MDS、OSS磁盘。
- `yrfs-deploy.sh`：部署MGR、MDS、OSS等YRFS组件。

三个脚本统一读取：

```text
/etc/yrfs/yrfs-deploy.conf
```

## 2. 部署配置文件

在控制节点创建配置文件：

```bash
vim /etc/yrfs/yrfs-deploy.conf
```

写入以下内容：

```ini
# 分隔规则：
# : 分隔节点，, 分隔同一节点的 IP、磁盘或挂载点，| 分隔同一节点的服务实例。
# mds_disk / oss_disk 填 /dev/nvme* 盘符（给格式化脚本）；
# mds_install / oss_install 填 /data/mds*、/data/oss* 挂载点（给部署脚本）。
# 注释必须单独占一行，不要追加在配置值末尾。

# etcd部署在node1、node2；每组依次为TCP、ib0、ib1，首个IP用于SSH。
etcd_ip=192.168.255.95,100.18.60.95,100.18.60.195:192.168.255.96,100.18.60.96,100.18.60.196

# 所有节点的root用户SSH密码。
root_password=Passw0rd

# MDS部署在node1、node2，每个节点一个实例、使用一块磁盘。
mds_ip=192.168.255.95,100.18.60.95,100.18.60.195:192.168.255.96,100.18.60.96,100.18.60.196
# 格式化脚本使用的MDS磁盘。
mds_disk=/dev/nvme0n1:/dev/nvme0n1
# MDS实例与挂载点对应关系（格式化后一般为 /data/mds0）。
mds_install=/data/mds0:/data/mds0
# node1优先ib0，node2优先ib1。
mds_ipwhitelist=100.18.60.95,100.18.60.195,192.168.255.95:100.18.60.196,100.18.60.96,192.168.255.96
mds_net=100.18.60.0/24,192.168.0.0/16
# 每个MDS启用本节点的两张IB网卡。
mds_rdma_ip=100.18.60.95,100.18.60.195:100.18.60.96,100.18.60.196

# OSS部署在4个节点；每组依次为TCP、ib0、ib1，首个IP用于SSH。
oss_ip=192.168.255.95,100.18.60.95,100.18.60.195:192.168.255.96,100.18.60.96,100.18.60.196:192.168.255.97,100.18.60.97,100.18.60.197:192.168.255.98,100.18.60.98,100.18.60.198
# 格式化脚本使用的全部OSS磁盘；每个节点6块（按顺序挂到 /data/oss0~/data/oss5）。
oss_disk=/dev/nvme9n1,/dev/nvme2n1,/dev/nvme3n1,/dev/nvme4n1,/dev/nvme5n1,/dev/nvme6n1:/dev/nvme1n1,/dev/nvme2n1,/dev/nvme3n1,/dev/nvme4n1,/dev/nvme5n1,/dev/nvme6n1:/dev/nvme0n1,/dev/nvme2n1,/dev/nvme4n1,/dev/nvme5n1,/dev/nvme10n1,/dev/nvme11n1:/dev/nvme0n1,/dev/nvme2n1,/dev/nvme3n1,/dev/nvme1n1,/dev/nvme4n1,/dev/nvme9n1
# 每个节点以|分成oss0和oss1；写挂载点，避免 reboot 后 /dev/nvme* 盘符变化。
oss_install=/data/oss0,/data/oss1,/data/oss2|/data/oss3,/data/oss4,/data/oss5:/data/oss0,/data/oss1,/data/oss2|/data/oss3,/data/oss4,/data/oss5:/data/oss0,/data/oss1,/data/oss2|/data/oss3,/data/oss4,/data/oss5:/data/oss0,/data/oss1,/data/oss2|/data/oss3,/data/oss4,/data/oss5
# oss0优先ib0，oss1优先ib1；两者均允许使用ib0、ib1和TCP。
oss_ipwhitelist=100.18.60.95,100.18.60.195,192.168.255.95|100.18.60.195,100.18.60.95,192.168.255.95:100.18.60.96,100.18.60.196,192.168.255.96|100.18.60.196,100.18.60.96,192.168.255.96:100.18.60.97,100.18.60.197,192.168.255.97|100.18.60.197,100.18.60.97,192.168.255.97:100.18.60.98,100.18.60.198,192.168.255.98|100.18.60.198,100.18.60.98,192.168.255.98
oss_net=100.18.60.0/24,192.168.0.0/16
# 每个节点的两个OSS实例均启用两张IB网卡。
oss_rdma_ip=100.18.60.95,100.18.60.195:100.18.60.96,100.18.60.196:100.18.60.97,100.18.60.197:100.18.60.98,100.18.60.198

# 所有节点的公共白名单和网络平面配置。
ipwhitelist=100.18.60.95,100.18.60.195,192.168.255.95:100.18.60.96,100.18.60.196,192.168.255.96:100.18.60.97,100.18.60.197,192.168.255.97:100.18.60.98,100.18.60.198,192.168.255.98
net=100.18.60.0/24,192.168.0.0/16
net_plane=100.18.60.0/24,192.168.0.0/16

# MGR部署在node1、node2；MDS、OSS和Agent的-m参数均使用mgr_ip。
mgr_ip=100.18.60.95,100.18.60.195,192.168.255.95:100.18.60.96,100.18.60.196,192.168.255.96
mgr_ipwhitelist=100.18.60.95,100.18.60.195,192.168.255.95:100.18.60.96,100.18.60.196,192.168.255.96
mgr_net=100.18.60.0/24,192.168.0.0/16

# 当前示例未配置agent_ip、agent_ipwhitelist和agent_net，不执行Agent自动部署。
```

> 配置文件包含明文root密码，应设置访问权限。

```bash
chmod 600 /etc/yrfs/yrfs-deploy.conf
```

## 3. 部署前准备

选择一台能够通过TCP网和IB网访问所有节点的服务器作为控制节点。

### 3.1 安装YRFS软件包

在所有节点上传YRFS软件包并执行：

```bash
apt install ./yrfs-*deb
```

### 3.2 安装etcd

在node1、node2上传`etcd-v3.4.18-linux-arm64.tar.gz`并执行：

```bash
tar xvf etcd-v3.4.18-linux-arm64.tar.gz
cp etcd-v3.4.18-linux-arm64/etcd /usr/bin/
cp etcd-v3.4.18-linux-arm64/etcdctl /usr/bin/
chmod 755 /usr/bin/etcd /usr/bin/etcdctl
```

### 3.3 安装sshpass

在控制节点执行：

```bash
apt install -y sshpass
```

### 3.4 准备部署脚本

将三个部署脚本放到控制节点同一目录并添加执行权限：

```bash
chmod +x yrfs-etcd-deploy.sh yrfs-format-disk.sh yrfs-deploy.sh
```

确认：

- 配置文件中的root密码能够登录所有节点。
- 配置文件中的磁盘设备名与实际节点一致。
- 所有待格式化磁盘均未挂载且未写入`/etc/fstab`。

`--debug`为可选参数，用于输出详细执行信息。

## 4. 配置etcd

在控制节点执行：

```bash
./yrfs-etcd-deploy.sh --debug
```

脚本完成：

- 创建etcd用户、数据目录和日志目录（`/var/log/etcd`）。
- 生成etcd配置（含 `ETCD_LOG_OUTPUTS=/var/log/etcd/etcd.log,stderr`）。
- 生成systemd服务。
- 配置etcdctl环境。

脚本不会自动启动etcd。启动后运行日志写入 `/var/log/etcd/etcd.log`，同时仍可通过 `journalctl -u etcd` 查看。

在node1、node2执行：

```bash
systemctl enable etcd
systemctl start etcd
systemctl status etcd
```

检查集群：

```bash
source ~/.bashrc
etcdctl member list
etcdctl endpoint health --cluster
```

应查询到`etcd0`和`etcd1`两个成员。

## 5. 格式化并挂载磁盘

> 本操作会清除配置文件中指定磁盘的全部数据，执行前必须核对磁盘设备名。

在控制节点执行：

```bash
./yrfs-format-disk.sh --debug
```

脚本完成：

- 格式化MDS磁盘。
- 格式化OSS磁盘。
- 创建挂载目录。
- 写入`/etc/fstab`。
- 执行挂载。
- 检查所有预期挂载点。

执行完成后检查各节点：

```bash
lsblk -f
findmnt | grep -E '/data/(mds|oss)'
```

如果脚本执行失败，不可直接重复执行，应先确认磁盘、挂载目录及`/etc/fstab`状态。

## 6. 部署MGR

在控制节点执行：

```bash
./yrfs-deploy.sh --mgr --debug
```

在node1、node2启动MGR：

```bash
systemctl enable yrfs-mgr
systemctl start yrfs-mgr
systemctl status yrfs-mgr
```

确认两个MGR均正常后再部署MDS。

## 7. 部署MDS

在控制节点执行：

```bash
./yrfs-deploy.sh --mds --debug
```

在node1、node2启动MDS：

```bash
systemctl enable yrfs-mds@mds0
systemctl start yrfs-mds@mds0
systemctl status yrfs-mds@mds0
```

检查：

```bash
yrcli --osd --type=mds
```

预期查询到2个MDS实例。

## 8. 部署OSS

在控制节点执行：

```bash
./yrfs-deploy.sh --oss --debug
```

在所有节点启动OSS：

```bash
systemctl enable yrfs-oss@oss0 yrfs-oss@oss1
systemctl start yrfs-oss@oss0 yrfs-oss@oss1
systemctl status yrfs-oss@oss0 yrfs-oss@oss1
```

检查：

```bash
yrcli --osd --type=oss
```

预期查询到8个OSS实例，共管理24块磁盘。

## 9. 配置集群

确认MDS和OSS状态正常后，在一个能够正常执行`yrcli`的节点运行：

```bash
yrcli --addgroup --type=mds --auto
yrcli --addgroup --type=oss --auto
yrcli --mkfs --type=mirror
```

配置RAID0 Layout：

```bash
yrcli \
  --setentry \
  --stripesize=1m \
  --stripecount=4 \
  --schema=raid0 \
  -u /
```

## 10. 查看日志

部署脚本日志：

```text
/var/log/yrfs-etcd-deploy.log
/var/log/yrfs-format-disk.log
/var/log/yrfs-deploy-mgr.log
/var/log/yrfs-deploy-mds.log
/var/log/yrfs-deploy-oss.log
/var/log/yrfs-deploy-agent.log
```

etcd 运行日志（各 etcd 节点）：

```text
/var/log/etcd/etcd.log
```

也可使用：

```bash
journalctl -u etcd -f
```

## 11. 卸载与重新部署

自动化卸载见：[yrcf-automated-uninstall.md](yrcf-automated-uninstall.md)

```bash
# 仅清理（保留软件包、挂载/fstab、yrfs-mgr.conf、部署配置）
./yrfs-uninstall.sh --clean --debug

# 彻底卸载
./yrfs-uninstall.sh --purge --debug
```
