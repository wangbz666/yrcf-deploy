# Redis Sentinel 卸载

## 1. 操作说明

本操作将停止 Redis 和 Sentinel 服务，并删除 Redis 数据及自定义配置。执行后 Redis 中的数据无法恢复。

执行前必须确认：

- 已备份需要保留的 Redis 数据。
- 当前操作节点属于待卸载的 Redis 集群。
- 已停止依赖 Redis 的业务访问。
- 了解当前 Master 可能因故障转移已不在 node1。

卸载分两类：

- **仅清理数据后重新部署**：执行第 2～4 步即可，保留软件包；之后直接重新跑自动化脚本或按手工部署配置启动。
- **彻底卸载**：执行全部步骤；重新部署前需按自动化文档「部署前准备」或手工部署重新安装 `redis` / `redis-sentinel`。

也可使用自动化卸载脚本（推荐批量操作）：

- 使用说明：[redis-sentinel-automated-uninstall.md](redis-sentinel-automated-uninstall.md)
- 脚本：`scripts/redis-sentinel-uninstall.sh`

```bash
# 仅清理后重部署（默认会二次确认，输入 yes）
./redis-sentinel-uninstall.sh --clean --debug

# 彻底卸载
./redis-sentinel-uninstall.sh --purge --debug

# 跳过二次确认
./redis-sentinel-uninstall.sh --clean -f --debug
```

## 2. 停止 Sentinel 和 Redis 服务

以下步骤应在**每个节点同步执行**：所有节点完成当前步骤后，再进入下一步。

```bash
# 2.1 停止 Sentinel（node1、node2、node3）
systemctl stop redis-sentinel 2>/dev/null || true
systemctl disable redis-sentinel 2>/dev/null || true

# 2.2 停止 Redis（所有节点）
systemctl stop redis-server 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true

# 2.3 检查服务状态（node1、node2、node3）
systemctl is-active redis-server redis-sentinel 2>/dev/null || true

# 2.3 检查服务状态（所有节点）
systemctl is-active redis-server 2>/dev/null || true

# 预期：均返回 inactive 或提示服务不存在
```

## 3. 清理 Redis 数据

```bash
# 在所有节点执行
for dir in /var/lib/redis/node1-6379 \
           /var/lib/redis/node2-6379 \
           /var/lib/redis/node3-6379 \
           /var/lib/redis/node4-6379; do
  [[ -d "$dir" ]] || continue
  find "$dir" -mindepth 1 -delete
  ls -la "$dir"
done

# 检查目录
for dir in /var/lib/redis/node*-6379; do
  [[ -d "$dir" ]] || continue
  find "$dir" -mindepth 1 -maxdepth 1 -print
done

# 预期：不应输出残留数据文件
```

## 4. 清理配置文件

```bash
# 4.1 清理 Redis 配置（所有节点）
# 如需保留 apt 默认配置，可先备份
cp -a /etc/redis/redis.conf "/etc/redis/redis.conf.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
rm -f /etc/redis/redis.conf

# 4.2 清理 Sentinel 配置（node1、node2、node3）
# Sentinel 运行后可能向 sentinel.conf 追加运行时配置，删除后可避免旧监控信息干扰重新部署
rm -f /etc/redis/sentinel.conf
```

## 5. 重新部署说明

如果只清理数据后重新部署，执行完第 2～4 步后：

1. 按手工部署文档或自动化脚本重新配置并启动服务。
2. 初始 Master 仍应规划为 node1（`192.168.255.95`）。
3. 若之前发生过故障转移，重新部署前必须完成服务停止和数据清理，不要直接覆盖运行中的集群。

---

以下步骤用于**彻底卸载**，仅在确认不再需要 Redis 时执行。

## 6. 卸载软件包

```bash
# 6.1 卸载 Sentinel（node1、node2、node3）
apt purge -y redis-sentinel

# 6.2 卸载 Redis（所有节点）
apt purge -y redis

# 检查
dpkg -l | awk '$2 ~ /^redis(-sentinel)?$/ {print}'

# 预期：不应输出已安装的 redis 或 redis-sentinel 包
```

## 7. 清理日志和残留目录

```bash
# 7.1 清理日志（所有节点）
rm -f /var/log/redis/redis.log
rm -f /var/log/redis/sentinel.log

# 7.2 清理数据目录（所有节点）
rm -rf /var/lib/redis/node1-6379
rm -rf /var/lib/redis/node2-6379
rm -rf /var/lib/redis/node3-6379
rm -rf /var/lib/redis/node4-6379

# 如果 /var/lib/redis 已为空，可删除
rmdir /var/lib/redis 2>/dev/null || true
```

## 8. 清理自动化部署文件

```bash
# 在控制节点执行
rm -f /etc/redis/redis-sentinel-deploy.conf

# 如果部署脚本放在自定义目录，进入该目录后删除
rm -f redis-sentinel-deploy.sh

# 默认保留 /var/log/redis-sentinel-deploy.log 便于排查；确认不需要后可删除
rm -f /var/log/redis-sentinel-deploy.log
```

## 9. 卸载结果检查

```bash
# 在 node1、node2、node3 执行
systemctl status redis-server 2>/dev/null || true
systemctl status redis-sentinel 2>/dev/null || true
ss -lntp | grep -E ':6379|:26379' || true

# 在所有节点执行
systemctl status redis-server 2>/dev/null || true
ss -lntp | grep ':6379' || true
test ! -d /var/lib/redis/node1-6379
test ! -f /etc/redis/redis.conf

# 在 node1、node2、node3 额外检查
test ! -f /etc/redis/sentinel.conf

# 预期：
# - 无运行中的 redis 或 redis-sentinel 服务
# - 无进程监听 6379、26379
# - 数据目录和自定义配置已删除
```

## 10. 注意事项

1. **先停 Sentinel 再停 Redis**：避免卸载过程中触发自动故障转移。
2. **当前 Master 可能不是 node1**：故障转移后，需在所有节点停止 Redis，不要只停原 Master。
3. **与 YRCF 独立**：本卸载不影响 YRCF/YRFS 服务；但 node1 同时承担两类服务时，操作前需确认影响范围。
4. **软件包由部署前准备安装**：自动化脚本不再安装软件包。彻底卸载后重新部署，需先手工执行 `apt install redis` 和 `apt install redis-sentinel`，再跑部署脚本。
