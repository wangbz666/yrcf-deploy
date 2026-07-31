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
10. 再次执行全部检查。

任何节点的系统或硬件预检查失败后，该节点不会继续修改系统。

## 配置备份

脚本在修改文件前生成带时间戳的备份：

```text
/etc/hosts.yrcf-backup.<时间戳>
/etc/netplan/95-ib-net.yaml.yrcf-backup.<时间戳>
```

默认按 `connect_ip` 末段生成 IB Netplan 文件，例如 `192.168.255.95` → `/etc/netplan/95-ib-net.yaml`。

Netplan语法检查或应用失败时，脚本会立即恢复执行前的Netplan文件。

## 注意事项

- 脚本会停止并禁用UFW和AppArmor。
- 脚本会修改主机名、`/etc/hosts`和Netplan配置。
- `expected_disks`只用于检查，脚本不会清理、挂载或格式化磁盘。
- Netplan会合并`/etc/netplan/`中的配置。脚本只写入 IB 网卡文件，不修改 vlan50 等管理网配置；执行前应确认其他文件未重复配置相同 IB 网卡。
- 网络配置存在导致节点失联的风险，首次执行应通过带外管理观察。
- 不要在配置文件中保存root密码。
