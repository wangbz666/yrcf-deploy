# YRCF集群卸载

## 1. 操作说明

本操作将停止YRCF服务并删除集群数据、etcd元数据及YRFS配置，执行后无法恢复。

执行前必须确认：

- 已备份需要保留的数据。
- 当前操作节点属于待卸载集群。
- `/data/mds*`和`/data/oss*`对应正确的YRCF磁盘。
- 已停止集群业务访问。

也可使用自动化卸载脚本（推荐批量操作）：

- 使用说明：[yrcf-automated-uninstall.md](yrcf-automated-uninstall.md)
- 脚本：`scripts/yrfs-uninstall.sh`

```bash
# 仅清理后重部署（默认二次确认，输入 yes）
./yrfs-uninstall.sh --clean --debug

# 彻底卸载
./yrfs-uninstall.sh --purge --debug

# 跳过二次确认
./yrfs-uninstall.sh --clean -f --debug
```

## 2. 停止YRFS服务

### 2.1 停止Agent和OSS

在所有节点执行：

```bash
systemctl stop yrfs-agent 2>/dev/null || true
systemctl stop yrfs-oss@oss0 2>/dev/null || true
systemctl stop yrfs-oss@oss1 2>/dev/null || true
```

### 2.2 停止MDS和MGR

在node1、node2执行：

```bash
systemctl stop yrfs-mds@mds0 2>/dev/null || true
systemctl stop yrfs-mgr 2>/dev/null || true
```

### 2.3 检查YRFS服务

在所有节点执行：

```bash
systemctl list-units --type=service --state=active --no-legend |
  awk '$1 ~ /^yrfs/ {print $1}'
```

命令不应输出任何仍在运行的YRFS服务。如果存在输出，应先停止对应服务再继续。

## 3. 清理etcd中的YRCF数据

此时保持node1、node2的etcd服务正常运行。

在任意一个etcd节点执行：

```bash
export ETCDCTL_API=3
export ETCDCTL_ENDPOINTS="http://192.168.255.95:2379,http://192.168.255.96:2379"

etcdctl del /yrcf/ --prefix
```

如果etcd已启用认证：

```bash
etcdctl \
  --user=root:REPLACE_ETCD_ROOT_PASSWORD \
  del /yrcf/ --prefix
```

检查是否仍有YRCF数据：

```bash
etcdctl get /yrcf/ --prefix --keys-only
```

启用认证时：

```bash
etcdctl \
  --user=root:REPLACE_ETCD_ROOT_PASSWORD \
  get /yrcf/ --prefix --keys-only
```

检查命令不应返回任何Key。

## 4. 清理磁盘数据

> 只有确认目录是已挂载的YRCF磁盘后才执行删除，避免误删节点本地目录。

在所有节点执行：

```bash
for dir in /data/mds* /data/oss*; do
  [[ -d "$dir" ]] || continue

  if findmnt -rn -M "$dir" >/dev/null; then
    find "$dir" -mindepth 1 -delete
  else
    echo "SKIP: $dir is not a mounted filesystem"
  fi
done
```

检查目录：

```bash
for dir in /data/mds* /data/oss*; do
  [[ -d "$dir" ]] || continue
  find "$dir" -mindepth 1 -maxdepth 1 -print
done
```

命令不应输出残留文件。

## 5. 卸载磁盘并清理fstab

### 5.1 卸载磁盘

在所有节点执行：

```bash
for dir in /data/mds* /data/oss*; do
  [[ -d "$dir" ]] || continue

  if findmnt -rn -M "$dir" >/dev/null; then
    umount "$dir"
  fi
done
```

确认磁盘已卸载：

```bash
findmnt | grep -E '/data/(mds|oss)' || true
```

不应返回任何MDS或OSS挂载点。

### 5.2 清理fstab

先备份并预览修改结果：

```bash
cp -a /etc/fstab "/etc/fstab.yrcf-backup.$(date +%Y%m%d%H%M%S)"
grep -Ev '(/data/mds|/data/oss)' /etc/fstab
```

确认预览结果正确后执行：

```bash
sed -i '/\/data\/mds/d;/\/data\/oss/d' /etc/fstab
```

检查：

```bash
grep -E '(/data/mds|/data/oss)' /etc/fstab || true
mount -a
```

## 6. 卸载YRFS软件包

在所有节点执行：

```bash
dpkg -P yrfs-oss yrfs-mds yrfs-mgr yrfs-agent
```

检查：

```bash
dpkg -l | awk '$2 ~ /^yrfs-(oss|mds|mgr|agent)$/ {print}'
```

## 7. 清理YRFS生成的配置

在所有节点执行：

```bash
rm -rf /etc/yrfs/oss*.d
rm -rf /etc/yrfs/mds*.d

rm -f /etc/yrfs/net
rm -f /etc/yrfs/net-mgmt
rm -f /etc/yrfs/net-mds
rm -f /etc/yrfs/net-oss
rm -f /etc/yrfs/net-agent
rm -f /etc/yrfs/net_plane.yaml

rm -f /etc/yrfs/ipwhitelist
rm -f /etc/yrfs/ipwhitelist-mgmt
rm -f /etc/yrfs/ipwhitelist-mds*
rm -f /etc/yrfs/ipwhitelist-oss*
rm -f /etc/yrfs/ipwhitelist-agent
```

默认保留以下文件，便于核对或重新部署：

```text
/etc/yrfs/yrfs-deploy.conf
```

如果确认不再需要，可手工删除。

## 8. 卸载etcd

仅在node1、node2执行：

```bash
systemctl disable --now etcd 2>/dev/null || true

rm -f /etc/etcd/etcd.conf
rm -rf /var/lib/etcd
rm -f /usr/lib/systemd/system/etcd.service

systemctl daemon-reload
systemctl reset-failed
```

默认保留`/usr/bin/etcd`、`/usr/bin/etcdctl`和etcd用户，以便重新部署。

如需彻底删除：

```bash
rm -f /usr/bin/etcd /usr/bin/etcdctl
userdel -r etcd 2>/dev/null || true
```

## 9. 卸载结果检查

在所有节点检查：

```bash
# 不应有运行中的YRFS服务
systemctl list-units --type=service --state=active --no-legend |
  awk '$1 ~ /^yrfs/ {print $1}'

# 不应有YRCF磁盘挂载
findmnt | grep -E '/data/(mds|oss)' || true

# fstab中不应有YRCF挂载配置
grep -E '(/data/mds|/data/oss)' /etc/fstab || true
```

在node1、node2检查：

```bash
systemctl status etcd 2>/dev/null || true
test ! -e /usr/lib/systemd/system/etcd.service
test ! -e /var/lib/etcd
```
