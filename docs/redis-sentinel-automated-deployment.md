# Redis Sentinel 自动化部署

## 1. 部署说明

自动化部署使用脚本 `redis-sentinel-deploy.sh`，读取统一配置文件：

```text
/etc/redis/redis-sentinel-deploy.conf
```

部署形态与手工部署一致：

| 配置项 | node1 | node2 | node3 | node4 |
|---|---|---|---|---|
| TCP IP | 192.168.255.95 | 192.168.255.96 | 192.168.255.97 | 192.168.255.98 |
| Redis 角色 | **Master** | Slave | Slave | Slave |
| Sentinel 实例 | 1 | 1 | 1 | 0 |
| maxmemory | 4gb | 4gb | 4gb | 4gb |

软件包安装放在部署前准备中手工完成。脚本在控制节点执行，通过 SSH 远程完成：

- 检查 `redis`、`redis-sentinel` 是否已安装
- 创建数据目录和日志目录
- 下发 `redis.conf`、`sentinel.conf`
- 启动服务并做基础验收

```bash
# 配置文件包含明文密码，建议限制访问权限
chmod 600 /etc/redis/redis-sentinel-deploy.conf
```

## 2. 部署配置文件

```bash
# 在控制节点创建配置文件
mkdir -p /etc/redis
cp redis-sentinel-deploy.conf.example /etc/redis/redis-sentinel-deploy.conf
vim /etc/redis/redis-sentinel-deploy.conf
```

```ini
# 所有节点的 root SSH 密码
root_password=Passw0rd

# Redis 连接密码；requirepass、masterauth、sentinel auth-pass 使用同一值
redis_password=Passw0rd

# 4 个 Redis 节点，依次为 node1~node4；首个 IP 为初始 Master（node1）
redis_ip=192.168.255.95:192.168.255.96:192.168.255.97:192.168.255.98

# 3 个 Sentinel 节点，部署在 node1~node3
sentinel_ip=192.168.255.95:192.168.255.96:192.168.255.97

master_name=mymaster
master_ip=192.168.255.95
master_port=6379
sentinel_quorum=2
redis_port=6379
sentinel_port=26379
maxmemory=4gb
down_after_milliseconds=30000
failover_timeout=180000
parallel_syncs=1
```

配置规则：

- `:` 分隔节点
- `redis_ip` 中第一个 IP 为初始 Master（node1）
- `sentinel_ip` 中的 IP 必须都出现在 `redis_ip` 中
- `redis_password` 同时用于 `requirepass`、`masterauth`、`sentinel auth-pass`

## 3. 部署前准备

```bash
# 选择一台能够通过 TCP 网访问所有节点的服务器作为控制节点

# 控制节点安装 sshpass
apt install -y sshpass

# 所有节点安装 redis
apt install -y redis

# node1、node2、node3 安装 redis-sentinel
apt install -y redis-sentinel

# 检查安装
redis-server --version
redis-cli --version
# 仅 Sentinel 节点执行
redis-sentinel --version

# 准备部署脚本
chmod +x redis-sentinel-deploy.sh

# 部署前确认：
# - root_password 能登录所有节点
# - 所有节点已完成环境准备（主机名、hosts、SSH 互信或密码登录）
# - 所有 Redis 节点已安装 redis
# - node1~node3 已安装 redis-sentinel
# - 若节点上已有旧 Redis 集群，应先执行卸载文档中的清理步骤
```

## 4. 执行部署

```bash
# 在控制节点执行
./redis-sentinel-deploy.sh --debug

# 如需指定配置文件路径
./redis-sentinel-deploy.sh --config /etc/redis/redis-sentinel-deploy.conf --debug

# 脚本完成：
# - 检查 redis / redis-sentinel 是否已安装（未安装则报错退出）
# - 创建 /var/lib/redis/nodeX-6379 和 /var/log/redis
# - 下发 Master/Slave 配置
# - 下发 Sentinel 配置
# - 先启动从节点 Redis，再启动 Master，最后启动 Sentinel
# - 检查主从复制和 Sentinel 状态
#
# 注意：脚本不会自动停止业务写入，生产环境建议在维护窗口执行
```

## 5. 部署后检查

### 5.1 检查主从复制

```bash
# 在 node1 执行
redis-cli -a REPLACE_REDIS_PASSWORD INFO replication

# 预期
# role:master
# connected_slaves:3
```

### 5.2 检查 Sentinel

```bash
# 在 node1、node2 或 node3 执行
redis-cli -p 26379 INFO sentinel
redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# 预期
# sentinel_masters:1
# master0:name=mymaster,status=ok,address=192.168.255.95:6379,slaves=3,sentinels=3
```

### 5.3 检查日志

```bash
# 在控制节点执行
tail -n 50 /var/log/redis-sentinel-deploy.log
```

## 6. 重新部署

```bash
# 若仅需清理数据后重新部署：
# 1. 执行自动化卸载（保留软件包；默认二次确认输入 yes，或加 -f 跳过）
./redis-sentinel-uninstall.sh --clean --debug
# 2. 保留或更新 /etc/redis/redis-sentinel-deploy.conf
# 3. 重新执行
./redis-sentinel-deploy.sh --debug

# 若需彻底卸载后重装：
# 1. ./redis-sentinel-uninstall.sh --purge --debug
# 2. 按「部署前准备」重新安装 redis / redis-sentinel / sshpass
# 3. 再执行自动化部署脚本
```

## 7. 注意事项

1. **先装包再跑脚本**：脚本不安装软件包；未安装时会检查失败并退出。
2. **密码一致**：`redis_password` 会写入 Redis 和 Sentinel 配置，必须保持一致。
3. **初始 Master 固定 node1**：`master_ip` 默认 `192.168.255.95`；故障转移后的拓扑不会自动回切。
4. **客户端接入**：应用应连接 Sentinel（node1~node3 的 `26379`），不要写死 Master IP。
5. **重复执行**：脚本会覆盖 `/etc/redis/redis.conf` 和 `/etc/redis/sentinel.conf` 并重启服务；已有业务数据时需先备份。
6. **与 YRCF 共存**：Redis 使用 `6379`、`26379` 端口，与 YRFS 无端口冲突。

## 8. 相关文档

- 手工部署：[redis-sentinel-manual-deployment.md](redis-sentinel-manual-deployment.md)
- 手工卸载：[redis-sentinel-uninstall.md](redis-sentinel-uninstall.md)
- 自动化卸载：[redis-sentinel-automated-uninstall.md](redis-sentinel-automated-uninstall.md)
