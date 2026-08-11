# YRCF 集群自动化卸载

## 1. 说明

自动化卸载使用脚本 `yrfs-uninstall.sh`，读取与部署相同的配置文件：

```text
/etc/yrfs/yrfs-deploy.conf
```

卸载会停止 YRFS 服务并删除集群数据，执行前必须确认已备份、业务已停写。

| 模式 | 作用 | 对应手工卸载 |
|---|---|---|
| `--clean` | 停 YRFS → 卸 etcd（服务/配置/数据/日志）→ 清已挂载数据 → 清全部生成配置（公共配置 `net` / `net_plane.yaml` / `ipwhitelist`、`ipwhitelist-mgmt` / `net-mgmt`、MDS/OSS/Agent 实例配置）；**保留**软件包、挂载/fstab、`yrfs-mgr.conf`、部署配置 | 清理后可再跑自动化部署脚本 |
| `--purge` | 在 `--clean` 上再 umount+清 fstab → 删 `yrfs-mgr.conf` → 卸 yrfs 包（etcd 二进制默认保留） | 彻底卸载 |
| `--check` | 只检查残留，不修改系统 | 验收 |

交互模式与 Redis 卸载一致：读配置 → 打印计划 → SSH 检查 → 二次确认（输入 `yes`）；加 `-f` 跳过确认。

## 2. 前置条件

```bash
# 控制节点已安装 sshpass
apt install -y sshpass

# 配置文件存在
ls -l /etc/yrfs/yrfs-deploy.conf

# 准备脚本
chmod +x yrfs-uninstall.sh
```

## 3. 配置项说明

| 配置项 | 是否必配 | 说明 |
|---|---|---|
| `root_password` | 必配 | SSH 登录 |
| `oss_ip` | 必配 | 推导全部存储节点（每组首个 IP 用于 SSH） |
| `mds_ip` | 必配 | MDS 节点 |
| `mgr_ip` | 必配 | MGR 节点 |
| `etcd_ip` | 必配 | etcd 节点；决定在哪些节点卸载 etcd |
| `agent_ip` | 可选 | 有则按该列表停 Agent；无则对所有 `oss_ip` 节点尝试停 Agent |

其余部署项（磁盘、白名单等）卸载脚本不读取。

## 4. 使用方法

### 4.1 仅清理后准备重部署（推荐）

```bash
# 流程：读配置 → 打印计划 → SSH 检查 → 输入 yes → 执行
./yrfs-uninstall.sh --clean --debug

# 跳过二次确认
./yrfs-uninstall.sh --clean -f --debug

# 指定配置文件
./yrfs-uninstall.sh --clean --config /etc/yrfs/yrfs-deploy.conf --debug
```

`--clean` 完成：

```text
# 1. 停 Agent / OSS / MDS / MGR（并兜底扫剩余 yrfs 服务）
# 2. 卸载 etcd：stop + disable --now，删除 /etc/etcd/etcd.conf、
#    /var/lib/etcd、/var/log/etcd、/usr/lib/systemd/system/etcd.service，
#    daemon-reload + reset-failed（etcd 二进制保留）
# 3. 仅对已挂载的 /data/mds* /data/oss* 清空内容（findmnt 判断）
# 4. 删除全部生成配置：
#    - oss*.d / mds*.d / yrfs-agent.conf
#    - net-mds / net-oss / net-agent / ipwhitelist-mds* / ipwhitelist-oss* / ipwhitelist-agent
#    - net / net_plane.yaml / ipwhitelist（公共配置）
#    - ipwhitelist-mgmt / net-mgmt
# 保留：
# - yrfs 软件包、磁盘挂载与 fstab
# - yrfs-mgr.conf
# - yrfs-deploy.conf
```

### 4.2 彻底卸载

```bash
./yrfs-uninstall.sh --purge --debug

# 跳过确认
./yrfs-uninstall.sh --purge -f --debug

# 可选：删部署配置、脚本日志、etcd 二进制与用户
./yrfs-uninstall.sh --purge -f --debug \
  --remove-deploy-conf \
  --remove-script-logs \
  --remove-etcd-binaries
```

这三个参数只能与 `--purge` 一起使用：

| 参数 | 作用 |
|---|---|
| `--remove-deploy-conf` | 删除运行脚本的控制节点上的部署配置文件；默认是 `/etc/yrfs/yrfs-deploy.conf`，若使用了 `--config FILE`，则删除该指定文件。默认不删除，便于后续参考或重新部署 |
| `--remove-script-logs` | `--purge` 验收成功后，删除控制节点上的 etcd、磁盘格式化、MGR/MDS/OSS/Agent 部署日志以及本次卸载日志。若验收失败则保留日志，便于排查 |
| `--remove-etcd-binaries` | 在各 etcd 节点额外删除 `/usr/bin/etcd`、`/usr/bin/etcdctl` 和 `etcd` 用户；不加此参数时只删除 etcd 服务、配置、数据和日志 |

其中，`--remove-deploy-conf` 和 `--remove-script-logs` 只清理执行卸载脚本的控制节点，不会通过 SSH 删除其他节点上的同名文件。

`--purge` 额外完成：

```text
# - umount /data/mds* /data/oss*
# - 备份并清理 /etc/fstab 中对应行
# - 删除 yrfs-mgr.conf
# - dpkg -P yrfs-oss yrfs-mds yrfs-mgr yrfs-agent
# - 默认保留 /usr/bin/etcd、etcdctl、etcd 用户
#   （加 --remove-etcd-binaries 才删除）
```

### 4.3 仅检查残留

```bash
./yrfs-uninstall.sh --check --debug
```

`--check` 按 **clean 标准**检查（服务停干净、挂载点内无数据、生成配置已删、etcd 服务/配置/数据/日志已删）。  
若刚做完 `--purge`，还可用同一命令查看整体残留；挂载/fstab/软件包/`yrfs-mgr.conf` 是否清干净以脚本 `--purge` 结束时的验收输出为准。

## 5. 脚本流程

```text
读配置 → 校验 → 打印计划 → SSH 检查
→（--check：验收并退出）
→ 二次确认（yes / -f 跳过）
→ 停 Agent → 停 OSS → 停 MDS → 停 MGR → 兜底停剩余 yrfs
→ 卸载 etcd（stop/disable + 删 conf/数据/日志/unit + daemon-reload）
→ 清已挂载数据目录内容
→ 清全部生成配置（保留 yrfs-mgr.conf 与 yrfs-deploy.conf）
→（--purge：umount+fstab → 卸包 + 删 yrfs-mgr.conf →（可选）删 etcd 二进制）
→ 残留验收
```

| 步骤 | 已做过会怎样 |
|---|---|
| 停服务 | 不存在则忽略，继续 |
| 卸 etcd | 服务/文件不存在则忽略 |
| 清数据 | 未挂载目录跳过，不误删本地空目录 |
| 删配置 | 文件不在则跳过 |
| umount/fstab | 未挂载则跳过；fstab 先备份再删行 |
| 卸包 | 不存在则忽略 |
| 确认输入非 `yes` | 立即中止 |
| `-f` | 跳过确认 |

## 6. 安全说明

1. **默认二次确认**，自动化场景用 `-f`。
2. **清磁盘必须已挂载**：用 `findmnt` 判断，降低误删风险。
3. **先停业务组件再卸 etcd/清数据**。
4. **默认保留** `yrfs-deploy.conf` 与 etcd 二进制，便于重装。
5. **生产环境**在维护窗口执行；脚本不会通知业务停写。

## 7. 日志

```bash
tail -n 100 /var/log/yrfs-uninstall.log
```

## 8. 相关文档

- 手工卸载：[yrcf-uninstall.md](yrcf-uninstall.md)
- 自动化部署：[yrcf-automated-deployment.md](yrcf-automated-deployment.md)
- 手工部署：[yrcf-manual-deployment.md](yrcf-manual-deployment.md)
