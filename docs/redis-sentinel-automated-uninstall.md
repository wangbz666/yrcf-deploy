# Redis Sentinel 自动化卸载

## 1. 说明

自动化卸载使用脚本 `redis-sentinel-uninstall.sh`，读取与部署相同的配置文件：

```text
/etc/redis/redis-sentinel-deploy.conf
```

卸载是破坏性操作：会停止服务并删除 Redis 数据。执行前必须确认已备份、业务已停写。

| 模式 | 作用 | 对应手工卸载 |
|---|---|---|
| `--clean` | 停服务、清数据、删配置，**保留软件包** | 第 2～4 步 |
| `--purge` | 在 `--clean` 基础上再 purge 软件包、清日志/目录 | 彻底卸载 |
| `--check` | 只检查残留，不修改系统 | 验收 |

## 2. 前置条件

```bash
# 控制节点已安装 sshpass
apt install -y sshpass

# 配置文件存在，且含有效 root_password / redis_ip / sentinel_ip
ls -l /etc/redis/redis-sentinel-deploy.conf

# 准备脚本
chmod +x redis-sentinel-uninstall.sh
```

## 3. 必配配置项

卸载脚本只依赖以下配置（复用部署配置文件即可）：

| 配置项 | 是否必配 | 说明 |
|---|---|---|
| `root_password` | 必配 | SSH 登录各节点 |
| `redis_ip` | 必配 | 所有 Redis 节点 |
| `sentinel_ip` | 必配 | 所有 Sentinel 节点 |
| `redis_port` | 可选 | 默认 `6379` |
| `sentinel_port` | 可选 | 默认 `26379`（检查端口用） |

`redis_password` 等其余部署项**可不改、可不关心**，卸载脚本不会读取它们。

## 4. 使用方法

### 4.1 仅清理后准备重部署（推荐）

```bash
# 在控制节点执行
# 流程：读配置 → 打印计划 → SSH 检查 → 二次确认(输入 yes) → 执行卸载
./redis-sentinel-uninstall.sh --clean --debug

# 指定配置文件
./redis-sentinel-uninstall.sh --clean \
  --config /etc/redis/redis-sentinel-deploy.conf \
  --debug

# 跳过二次确认（自动化/非交互场景）
./redis-sentinel-uninstall.sh --clean -f --debug
```

脚本完成：

```text
# 1. 打印卸载计划（节点列表、模式）
# 2. SSH 检查
# 3. 二次确认（输入 yes；加 -f 则跳过）
# 4. 先停所有 Sentinel，再停所有 Redis（不依赖当前 Master 在哪）
# 5. 清空 /var/lib/redis/node*-<port> 数据内容
# 6. 备份并删除 /etc/redis/redis.conf；删除 sentinel.conf
# 7. 检查残留
# 保留：redis / redis-sentinel 软件包、部署配置文件
```

清理后可直接重新跑：

```bash
./redis-sentinel-deploy.sh --debug
```

### 4.2 彻底卸载

```bash
./redis-sentinel-uninstall.sh --purge --debug

# 跳过二次确认
./redis-sentinel-uninstall.sh --purge -f --debug

# 可选：同时删除控制节点上的部署配置和脚本日志
./redis-sentinel-uninstall.sh --purge -f --debug \
  --remove-deploy-conf \
  --remove-script-logs
```

`--purge` 额外完成：

```text
# - apt purge redis-sentinel（Sentinel 节点）
# - apt purge redis（所有 Redis 节点）
# - 删除日志与数据目录本身
# - 可选删除 /etc/redis/redis-sentinel-deploy.conf
# - 可选删除 /var/log/redis-sentinel-deploy.log 和卸载日志
```

彻底卸载后若要再部署：

```bash
# 先按自动化部署文档「部署前准备」重装软件包
apt install -y redis                 # 所有节点
apt install -y redis-sentinel        # node1~node3
# 再准备配置并执行 redis-sentinel-deploy.sh
```

### 4.3 仅检查残留

```bash
# 无二次确认，不会改系统
./redis-sentinel-uninstall.sh --check --debug
```

退出码：

- `0`：无明显残留（`--check` 不要求软件包已卸载）
- `1`：仍有服务 active、端口监听、配置或数据残留

## 5. 脚本流程说明

```text
读配置 → 校验 → 打印计划 → SSH 检查
→（--check：只验收并退出）
→ 二次确认（输入 yes；-f 跳过）
→ 停 Sentinel → 停 Redis
→ 清数据 → 删配置
→（--purge 再卸包、删目录/日志）
→ 残留验收
```

| 步骤 | 已做过会怎样 |
|---|---|
| 停服务 | 服务本就不在，命令忽略错误，继续 |
| 清数据 | 目录不在则跳过；有目录则清空内容 |
| 删配置 | 文件不在则跳过；`redis.conf` 若存在会先备份再删 |
| purge 软件包 | 未安装时 `apt purge` 忽略失败，继续 |
| 重复执行 `--clean` | 可重复，结果应已是干净状态 |
| 二次确认输入非 `yes` | 立即中止，不改节点 |
| 加 `-f` / `--force` | 跳过二次确认，直接卸载 |

## 6. 安全说明

1. **默认二次确认**：`--clean` / `--purge` 在 SSH 检查通过后要求输入 `yes` 才继续。
2. **`-f` 跳过确认**：仅用于自动化或已确认的非交互场景。
3. **先 Sentinel 后 Redis**，降低卸载过程中触发故障转移的概率。
4. **对全部 `redis_ip` 停 Redis**，不假设 Master 仍在 node1。
5. **默认不删部署配置**，避免卸完后配置丢失；需要时显式加 `--remove-deploy-conf`。
6. **生产环境**建议在维护窗口执行；脚本不会通知业务停写。

## 7. 日志

```bash
# 卸载日志
tail -n 100 /var/log/redis-sentinel-uninstall.log
```

## 8. 相关文档

- 手工卸载步骤：[redis-sentinel-uninstall.md](redis-sentinel-uninstall.md)
- 自动化部署：[redis-sentinel-automated-deployment.md](redis-sentinel-automated-deployment.md)
- 手工部署：[redis-sentinel-manual-deployment.md](redis-sentinel-manual-deployment.md)
