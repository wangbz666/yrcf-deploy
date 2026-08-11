# YRCF节点环境准备工具

该工具根据一个配置文件，从控制节点集中完成YRCF集群节点的环境配置和检查。

工具只负责节点基础环境，不安装YRFS软件包，也不会格式化磁盘。

## 功能

- 检查操作系统、CPU架构和内存
- 关闭UFW和AppArmor
- 配置主机名和`/etc/hosts`
- 建立所有节点之间的root用户SSH互信
- 生成并应用Ubuntu Netplan网络及策略路由配置
- 检查网卡地址、策略路由和节点间连通性
- 检查预期磁盘是否存在以及是否已被挂载
- 配置集群时钟同步（chrony；软件包需事先手工安装）
- 部署 YRFS/etcd 日志轮询（logrotate；软件包需已安装）
- 自动备份被修改的配置文件
- 将节点执行日志写入`/var/log/yrcf-node-prepare.log`

## 运行要求

控制节点和目标节点应满足：

- Ubuntu系统
- Bash 4.0或更高版本
- 使用root用户执行
- 控制节点能够通过当前IP访问所有目标节点的SSH端口
- 目标节点允许root用户通过SSH登录
- 目标节点已安装并启用Netplan
- 若启用时钟同步（默认开启）：目标节点已事先安装`chrony`（`apt install -y chrony`）
- 若启用日志轮询（默认开启）：目标节点已安装 `logrotate` 与 `cron`（`apt install -y logrotate cron`）
- 配置网络前，应通过服务器带外管理确认具备故障恢复手段

首次运行时，脚本会要求交互式输入各节点的root密码。密码仅用于安装控制节点公钥，不会写入配置文件或日志。

## 配置

复制配置示例：

```bash
cp node-prepare.conf.example /etc/yrfs/node-prepare.conf
```

根据实际节点修改`/etc/yrfs/node-prepare.conf`。每个非`global`节代表一个节点，节名称即最终主机名。未指定`--config`时，脚本默认读取该路径。

主要字段：

- `connect_ip`：执行脚本前已经可用的SSH连接地址
- `hosts_ip`：写入`/etc/hosts`并用于节点间SSH互信的地址
- `interfaces`：需要配置的网卡列表
- `<网卡>_address`：网卡地址和掩码
- `<网卡>_network`：该网卡路由表中的直连网段
- `<网卡>_table`：策略路由表号
- `expected_disks`：预期存在且未挂载的磁盘列表
- `netplan_file_template`：IB 网卡 Netplan 路径模板，`{id}` 为 `connect_ip` 末段（默认 `/etc/netplan/{id}-ib-net.yaml`）
- `netplan_renderer`：每张 IB 网卡的 renderer（默认 `networkd`）
- `sync_time`：是否配置时钟同步（默认 `true`）
- `timezone`：统一时区（默认 `Asia/Shanghai`）
- `ntp_servers`：外部 NTP，逗号分隔；有值时所有节点作客户端
- `ntp_master`：`ntp_servers` 为空时的集群内时间源节点名；两者都空则默认第一个节点
- `max_time_skew_sec`：节点间允许的最大时间偏差秒数（默认 `1`）
- `configure_logrotate`：是否部署 `/etc/logrotate.d/yrfs` 与 `/etc/logrotate.d/etcd`（默认 `true`）

脚本只生成 IB 网卡 Netplan（如 `95-ib-net.yaml`），不配置管理网（如 vlan50 / 192.168.255.x）。

每张网卡的策略路由包含 `from` 与 `to` 两条规则。例如：

```yaml
routing-policy:
  - from: 100.18.60.95/32
    table: 20
  - to: 100.18.60.95/32
    table: 20
```

## 使用

先执行预览，检查配置文件：

```bash
chmod +x yrcf-node-prepare.sh

# 默认读取 /etc/yrfs/node-prepare.conf
./yrcf-node-prepare.sh --dry-run

# 或显式指定配置文件
./yrcf-node-prepare.sh \
  --config /etc/yrfs/node-prepare.conf \
  --dry-run
```

确认无误后执行配置：

```bash
./yrcf-node-prepare.sh --apply
```

仅检查节点，不修改配置：

```bash
./yrcf-node-prepare.sh --check
```

## 执行过程

`--apply`按照以下顺序执行：

1. 校验配置文件。
2. 建立控制节点到各目标节点的SSH访问。
3. 在各节点检查系统和硬件。
4. 关闭安全组件。
5. 配置主机名和`/etc/hosts`。
6. 生成节点SSH密钥。
7. 配置并应用Netplan。
8. 检查网卡、策略路由、网络连通性和磁盘。
9. 汇总所有节点公钥并建立节点间互信。
10. 配置时钟同步（时区 + chrony）。
11. 再次执行全部检查，并校验节点间时间偏差。

其中第 4 步关闭安全组件之后，会部署日志轮询（logrotate 规则 + 每 15 分钟 cron）。

任何节点的系统或硬件预检查失败后，该节点不会继续修改系统。

## 日志轮询（logrotate + cron）

参考现网做法：**logrotate 规则** + **cron 缩短检查间隔**，使 `maxsize` 在日志暴涨时也能及时轮转。配置文件落盘后 **重启仍生效**。

### 自动化脚本会写入

**1. `/etc/logrotate.d/yrfs`**

```text
su root root
compress
/var/log/yrfs*.log {
    rotate 10
    missingok
    compress
    maxsize 1G
    copytruncate
}
```

**2. `/etc/logrotate.d/etcd`**

```text
su root root
compress
/var/log/etcd*.log
/var/log/etcd/*.log {
    rotate 10
    missingok
    compress
    maxsize 100M
    copytruncate
}
```

**3. `/etc/cron.d/yrcf-logrotate`（每 15 分钟）**

```text
*/15 * * * * root /usr/sbin/logrotate /etc/logrotate.d/yrfs /etc/logrotate.d/etcd >/dev/null 2>&1
```

并 `systemctl enable --now cron`。

设 `configure_logrotate=false` 可跳过。

### 手工实现（每台节点）

**1. 安装依赖**

```bash
apt install -y logrotate cron
systemctl enable --now cron
```

**2. 写入 logrotate 规则**

```bash
cat > /etc/logrotate.d/yrfs <<'EOF'
su root root
compress
/var/log/yrfs*.log {
    rotate 10
    missingok
    compress
    maxsize 1G
    copytruncate
}
EOF

cat > /etc/logrotate.d/etcd <<'EOF'
su root root
compress
/var/log/etcd*.log
/var/log/etcd/*.log {
    rotate 10
    missingok
    compress
    maxsize 100M
    copytruncate
}
EOF

chmod 644 /etc/logrotate.d/yrfs /etc/logrotate.d/etcd
logrotate -d /etc/logrotate.d/yrfs
logrotate -d /etc/logrotate.d/etcd
```

**3. 写入 cron（每 15 分钟检查一次）**

```bash
cat > /etc/cron.d/yrcf-logrotate <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/15 * * * * root /usr/sbin/logrotate /etc/logrotate.d/yrfs /etc/logrotate.d/etcd >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/yrcf-logrotate
```

**4. 验收**

```bash
systemctl status cron
cat /etc/cron.d/yrcf-logrotate
logrotate -f /etc/logrotate.d/yrfs    # 可选：立即强制轮一次
ls -lh /var/log/yrfs*.log*
```

要点：

- `copytruncate`：拷贝后清空，yrfs 无需重开日志
- `maxsize` 仅在 logrotate **执行时**检查，故需 cron 每 15 分钟（不能单靠系统默认 daily）
- `rotate 10` + `compress`：保留 10 份历史并压缩

## 手工同步时钟

自动化依赖节点已安装 chrony。若只做手工同步，可按下面步骤操作。

### 准备（每台节点）

```bash
apt install -y chrony
timedatectl set-timezone Asia/Shanghai
systemctl disable --now systemd-timesyncd 2>/dev/null || true
```

### 方案 A：有外部 NTP（对应配置 `ntp_servers`）

在每台节点编辑 `/etc/chrony/chrony.conf`：注释原有 `pool`/`server` 行，并增加例如：

```text
server time.nju.edu.cn iburst
# server ntp.aliyun.com iburst
```

或写入 `/etc/chrony/conf.d/yrcf-time.conf`（需主配置启用 `confdir /etc/chrony/conf.d`）：

```text
server time.nju.edu.cn iburst
```

然后：

```bash
systemctl enable --now chrony
systemctl restart chrony
chronyc -a makestep
chronyc tracking
chronyc sources -v
```

### 方案 B：无外部 NTP，用集群内节点当时间源（对应 `ntp_master`）

假设 `node1`（如 `192.168.255.95`）为时间源。

**node1：**

```text
# /etc/chrony/conf.d/yrcf-time.conf
local stratum 10
allow 192.168.255.95
allow 192.168.255.96
allow 192.168.255.97
allow 192.168.255.98
```

并注释主配置中的 `pool`/`server`。

**其它节点：**

```text
# /etc/chrony/conf.d/yrcf-time.conf
server 192.168.255.95 iburst
```

同样注释主配置中的 `pool`/`server`，然后各节点：

```bash
systemctl enable --now chrony
systemctl restart chrony
chronyc -a makestep
```

### 验收

```bash
timedatectl
chronyc tracking
# 各节点 unix 时间应接近
date -u +%s
```

## 配置备份

脚本在修改文件前生成带时间戳的备份：

```text
/etc/hosts.yrcf-backup.<时间戳>
/etc/netplan/95-ib-net.yaml.yrcf-backup.<时间戳>
```

时钟同步首次修改时还会保留：

```text
/etc/chrony/chrony.conf.yrcf-orig
```

并写入托管文件：

```text
/etc/chrony/conf.d/yrcf-time.conf
```

默认按 `connect_ip` 末段生成 IB Netplan 文件，例如 `192.168.255.95` → `/etc/netplan/95-ib-net.yaml`。

Netplan语法检查或应用失败时，脚本会立即恢复执行前的Netplan文件。

## 注意事项

- 脚本会停止并禁用UFW和AppArmor。
- 脚本会修改主机名、`/etc/hosts`和Netplan配置。
- 脚本会配置 chrony（不安装软件包）；`sync_time=false` 时可跳过。
- `expected_disks`只用于检查，脚本不会清理、挂载或格式化磁盘。
- Netplan会合并`/etc/netplan/`中的配置。脚本只写入 IB 网卡文件，不修改 vlan50 等管理网配置；执行前应确认其他文件未重复配置相同 IB 网卡。
- 网络配置存在导致节点失联的风险，首次执行应通过带外管理观察。
- 不要在配置文件中保存root密码。
