# Redis Sentinel 手工部署

## 1. 部署说明

本章基于已完成节点环境准备的 4 节点环境，部署 **Redis Sentinel 模式**（1 主 + 3 从 + 3 哨兵）。

| 配置项 | node1 | node2 | node3 | node4 |
|---|---|---|---|---|
| TCP IP | 192.168.255.95 | 192.168.255.96 | 192.168.255.97 | 192.168.255.98 |
| ib0 IP | 100.18.60.95 | 100.18.60.96 | 100.18.60.97 | 100.18.60.98 |
| ib1 IP | 100.18.60.195 | 100.18.60.196 | 100.18.60.197 | 100.18.60.198 |
| Redis 角色 | **Master** | Slave | Slave | Slave |
| Sentinel 实例 | 1 | 1 | 1 | 0 |
| Redis 端口 | 6379 | 6379 | 6379 | 6379 |
| Sentinel 端口 | 26379 | 26379 | 26379 | — |
| 数据目录 | `/var/lib/redis/node1-6379` | `/var/lib/redis/node2-6379` | `/var/lib/redis/node3-6379` | `/var/lib/redis/node4-6379` |

约定如下：

- 初始 Master 固定在 **node1**（`192.168.255.95:6379`）
- Sentinel 部署在 **node1、node2、node3**，`quorum=2`
- 每节点 `maxmemory` 为 **4gb**
- Redis 主从通信使用 TCP 管理网 `192.168.255.0/24`
- 应用客户端应通过 Sentinel 查询当前 Master，不要写死 Master IP

> 文档中的 `REPLACE_REDIS_PASSWORD` 为必须根据现场环境替换的占位符，不能直接执行。

## 2. 安装 Redis

```bash
# 在所有节点执行
apt install redis -y

# 检查安装
redis-server --version
systemctl status redis-server
```

## 3. 安装 Sentinel

```bash
# 在 node1、node2、node3 执行
apt install redis-sentinel -y

# 检查安装
redis-sentinel --version
systemctl status redis-sentinel
```

## 4. 创建数据目录和日志目录

```bash
# 所有节点
mkdir -p /var/log/redis
chown redis:redis /var/log/redis

# node1
mkdir -p /var/lib/redis/node1-6379
chown redis:redis /var/lib/redis/node1-6379

# node2
mkdir -p /var/lib/redis/node2-6379
chown redis:redis /var/lib/redis/node2-6379

# node3
mkdir -p /var/lib/redis/node3-6379
chown redis:redis /var/lib/redis/node3-6379

# node4
mkdir -p /var/lib/redis/node4-6379
chown redis:redis /var/lib/redis/node4-6379
```

## 5. 配置 Redis Master（node1）

```bash
# 在 node1 编辑 /etc/redis/redis.conf
vim /etc/redis/redis.conf
```

```conf
# node1 Master 配置
bind 0.0.0.0
port 6379
daemonize yes
protected-mode no

dir /var/lib/redis/node1-6379
logfile /var/log/redis/redis.log

maxmemory 4gb
maxmemory-policy allkeys-lru

appendonly yes
appendfilename "node1-6379-appendonly.aof"
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
save 900 1

replica-read-only yes
min-replicas-to-write 1
min-replicas-max-lag 10

requirepass REPLACE_REDIS_PASSWORD
masterauth REPLACE_REDIS_PASSWORD
```

## 6. 配置 Redis Slave

### 6.1 node2

```conf
# node2 Slave 配置，编辑 /etc/redis/redis.conf
bind 0.0.0.0
port 6379
daemonize yes
protected-mode no

dir /var/lib/redis/node2-6379
logfile /var/log/redis/redis.log

maxmemory 4gb
maxmemory-policy allkeys-lru

replicaof 192.168.255.95 6379
replica-read-only yes

appendonly yes
appendfilename "node2-6379-appendonly.aof"
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
save 900 1

min-replicas-to-write 1
min-replicas-max-lag 10

requirepass REPLACE_REDIS_PASSWORD
masterauth REPLACE_REDIS_PASSWORD
```

### 6.2 node3

```conf
# node3 Slave 配置，编辑 /etc/redis/redis.conf
bind 0.0.0.0
port 6379
daemonize yes
protected-mode no

dir /var/lib/redis/node3-6379
logfile /var/log/redis/redis.log

maxmemory 4gb
maxmemory-policy allkeys-lru

replicaof 192.168.255.95 6379
replica-read-only yes

appendonly yes
appendfilename "node3-6379-appendonly.aof"
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
save 900 1

min-replicas-to-write 1
min-replicas-max-lag 10

requirepass REPLACE_REDIS_PASSWORD
masterauth REPLACE_REDIS_PASSWORD
```

### 6.3 node4

```conf
# node4 Slave 配置，编辑 /etc/redis/redis.conf
bind 0.0.0.0
port 6379
daemonize yes
protected-mode no

dir /var/lib/redis/node4-6379
logfile /var/log/redis/redis.log

maxmemory 4gb
maxmemory-policy allkeys-lru

replicaof 192.168.255.95 6379
replica-read-only yes

appendonly yes
appendfilename "node4-6379-appendonly.aof"
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
save 900 1

min-replicas-to-write 1
min-replicas-max-lag 10

requirepass REPLACE_REDIS_PASSWORD
masterauth REPLACE_REDIS_PASSWORD
```

## 7. 配置 Sentinel（node1、node2、node3）

```bash
# 在 node1、node2、node3 分别编辑 /etc/redis/sentinel.conf，三台配置内容相同
vim /etc/redis/sentinel.conf
```

```conf
# 注意：不要写 daemonize yes，apt 的 systemd 服务以前台模式运行
# sentinel monitor 中的 192.168.255.95 6379 是初始 Master 地址
# quorum=2 表示 3 个 Sentinel 中至少 2 个同意，才认定 Master 客观下线
bind 0.0.0.0
port 26379
protected-mode no

pidfile /var/run/redis-sentinel.pid
logfile /var/log/redis/sentinel.log
dir /tmp

sentinel monitor mymaster 192.168.255.95 6379 2
sentinel auth-pass mymaster REPLACE_REDIS_PASSWORD
sentinel down-after-milliseconds mymaster 30000
sentinel failover-timeout mymaster 180000
sentinel parallel-syncs mymaster 1

sentinel deny-scripts-reconfig yes
```

## 8. 启动服务

```bash
# 建议从节点先启动、主节点后启动，避免短暂复制异常

# 在 node2、node3、node4 执行
systemctl restart redis-server
systemctl enable redis-server
systemctl status redis-server

# 在 node1 执行
systemctl restart redis-server
systemctl enable redis-server
systemctl status redis-server

# 在 node1、node2、node3 执行
systemctl restart redis-sentinel
systemctl enable redis-sentinel
systemctl status redis-sentinel
```

## 9. 部署验收

### 9.1 检查主从复制

```bash
# 在 node1 执行
redis-cli -a REPLACE_REDIS_PASSWORD INFO replication

# 预期关键字段
# role:master
# connected_slaves:3
# min_slaves_good_slaves:3
# slave0:ip=192.168.255.96,port=6379,state=online,...
# slave1:ip=192.168.255.97,port=6379,state=online,...
# slave2:ip=192.168.255.98,port=6379,state=online,...

# 在任意从节点执行
redis-cli -a REPLACE_REDIS_PASSWORD INFO replication

# 预期关键字段
# role:slave
# master_host:192.168.255.95
# master_port:6379
# master_link_status:up
```

### 9.2 检查 Sentinel 集群

```bash
# 在 node1、node2 或 node3 执行
redis-cli -p 26379 INFO sentinel

# 预期关键字段
# sentinel_masters:1
# master0:name=mymaster,status=ok,address=192.168.255.95:6379,slaves=3,sentinels=3

# 查询当前 Master 地址
redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# 预期返回
# 1) "192.168.255.95"
# 2) "6379"
```

### 9.3 检查读写

```bash
# 在任意节点执行
redis-cli -h 192.168.255.95 -p 6379 -a REPLACE_REDIS_PASSWORD SET deploy:test ok
redis-cli -h 192.168.255.96 -p 6379 -a REPLACE_REDIS_PASSWORD GET deploy:test
redis-cli -h 192.168.255.97 -p 6379 -a REPLACE_REDIS_PASSWORD GET deploy:test
redis-cli -h 192.168.255.98 -p 6379 -a REPLACE_REDIS_PASSWORD GET deploy:test

# 预期：写入 Master 成功，3 个从节点均可读到 ok

# 读写验证通过后，删除测试 key 并确认删除成功
redis-cli -h 192.168.255.95 -p 6379 -a REPLACE_REDIS_PASSWORD DEL deploy:test
redis-cli -h 192.168.255.95 -p 6379 -a REPLACE_REDIS_PASSWORD GET deploy:test
redis-cli -h 192.168.255.96 -p 6379 -a REPLACE_REDIS_PASSWORD GET deploy:test
redis-cli -h 192.168.255.97 -p 6379 -a REPLACE_REDIS_PASSWORD GET deploy:test
redis-cli -h 192.168.255.98 -p 6379 -a REPLACE_REDIS_PASSWORD GET deploy:test

# 预期：DEL 返回 1；Master 与 3 个从节点 GET deploy:test 均返回 (nil)
```

### 9.4 检查内存配置

```bash
# 在 node1 执行
redis-cli -h 192.168.255.95 -p 6379 -a REPLACE_REDIS_PASSWORD INFO memory | grep -E 'used_memory_human|maxmemory_human'

# 预期：maxmemory_human 约为 4.00G
```

## 10. 常用运维命令

```bash
# 查询当前 Master
redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# 查询从节点列表
redis-cli -p 26379 SENTINEL replicas mymaster

# 查询 Sentinel 节点列表
redis-cli -p 26379 SENTINEL sentinels mymaster

# 查看内存使用
redis-cli -h 192.168.255.95 -p 6379 -a REPLACE_REDIS_PASSWORD INFO memory | grep used_memory_human
redis-cli -h 192.168.255.95 -p 6379 -a REPLACE_REDIS_PASSWORD INFO memory | grep maxmemory_human

# 查看服务状态
systemctl status redis-server
systemctl status redis-sentinel
```

## 11. 故障转移验证（可选）

仅在测试环境执行，用于验证 Sentinel 自动切换能力。

```bash
# 11.1 模拟 Master 故障：在 node1 执行
systemctl stop redis-server

# 在 node2 或 node3 执行
redis-cli -p 26379 SENTINEL get-master-addr-by-name mymaster

# 预期：新 Master 地址不再是 192.168.255.95，应为 node2、node3 或 node4 之一

# 11.2 恢复原 Master：在 node1 执行
systemctl start redis-server
redis-cli -a REPLACE_REDIS_PASSWORD INFO replication | grep -E 'role|master_host|master_port'

# 预期：node1 自动降级为 Slave，并指向新的 Master
```

### 11.3 恢复原拓扑（测试后）

若需恢复“node1 为 Master”的初始拓扑，需在维护窗口手工执行计划内切换，或按卸载后重新部署处理。生产环境不建议在业务运行时强行改回初始 Master。

## 12. 部署注意事项

1. **密码一致**：`requirepass`、`masterauth`、`sentinel auth-pass` 必须使用同一密码。
2. **客户端接入**：应用应配置 Sentinel 地址列表（node1~node3 的 `26379`），通过 `mymaster` 发现当前主节点。
3. **与 YRCF 共存**：Redis 使用独立端口和数据目录，不与 YRFS 端口冲突；但 node1 同时承担 YRCF Master 与 Redis Master，规划变更时需一并评估。
4. **数据一致性**：Sentinel 基于异步复制，Master 故障时仍可能丢失未同步数据；强一致场景需在应用层使用 `WAIT` 等机制。
5. **防火墙**：若节点启用了防火墙，需放行 `6379` 和 `26379`。
