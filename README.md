# SSH 登录 Telegram 通知

在 Linux 服务器上发送 SSH 登录成功通知、监控连续认证失败，并查看近 24 小时失败 IP 前 10。入口仍是单文件 **`ssh-tg-notify.sh`**，无需另行下载监控程序。

## 运行

先进入 root shell（已经是 root 可跳过）：

```bash
sudo -i
```

打开管理菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/uyo8os/dltz/main/ssh-tg-notify.sh)
```

也可以先下载、查看脚本，再执行；下载失败时不会继续运行：

```bash
curl -fsSL https://raw.githubusercontent.com/uyo8os/dltz/main/ssh-tg-notify.sh -o ssh-tg-notify.sh && bash ssh-tg-notify.sh
```

以上地址需要仓库的 `main` 分支已经包含此文件。请使用 Bash；不要用 `sh` 或 `curl | bash`。

## 菜单功能

```text
SSH 登录 Telegram 通知
1. 添加 SSH 登录通知
2. 查看通知配置
3. 发送测试通知
4. 开启爆破通知
5. 关闭爆破通知
6. 发送爆破测试通知
7. 查看失败排名
8. 卸载全部
0. 退出
```

- **添加**：输入服务器名称、`TG_BOT_TOKEN`、`TG_CHAT_ID`。服务器名称用于通知显示，回车默认使用主机名；Token 在终端中隐藏输入。脚本先检查 SSH/PAM，再向 Telegram 发送测试消息，成功后才写入安装文件和 PAM 条目。
- **自动检测**：完整安装后再次选择添加，会直接跳过，不重新输入配置，不重复添加。发现残留文件、重复或异常条目时会报错，避免把损坏安装当成成功。
- **查看**：显示服务器名称、**完整** Token、Chat ID 和本地配置状态。该菜单供 root 使用，请留意终端录屏、截图和屏幕共享。
- **发送测试通知**：使用已保存的配置发送登录通知测试消息，报告 Telegram 是否接受请求。
- **开启爆破通知**：先检查 SSH 登录通知是否完整安装，未安装时无法开启。直接复用服务器名称、Token、Chat ID，不重复要求输入。监控作为 systemd 服务运行，退出菜单后继续工作，并设置开机启动；重复开启正在运行的服务不会重置计数。
- **关闭爆破通知**：停止监控并取消其开机启动，保留 SSH 登录成功通知及 Telegram 配置。
- **发送爆破测试通知**：发送包含模拟 IP 和 11 次失败的测试消息，标题标明“测试”，不影响实际计数。需要先添加 SSH 登录通知；不要求爆破监控已经开启。
- **查看失败排名**：按最近 24 小时已有日志统计，显示失败次数最多的 10 个 IP，每行 `800次 66.66.66.61`。不需要先安装通知，也不需要开启监控。
- **卸载全部**：先关闭爆破服务，再删除本脚本的服务文件、计数状态、PAM 标记块、通知程序、配置及安装前备份。保留其他 PAM 配置，包括安装后新增的条目；重复卸载无副作用。配置写错时卸载后重新添加即可。

已有上一版英文脚本安装的 SSH 登录通知时，可以直接运行新版并选择 **4**，继续使用已有配置。

下载到本地后，也支持直接指定功能：

```bash
bash ssh-tg-notify.sh install
bash ssh-tg-notify.sh show
bash ssh-tg-notify.sh test
bash ssh-tg-notify.sh enable-bruteforce
bash ssh-tg-notify.sh disable-bruteforce
bash ssh-tg-notify.sh test-bruteforce
bash ssh-tg-notify.sh rank
bash ssh-tg-notify.sh uninstall
```

## 安装前准备

适用于使用 Linux-PAM 的 OpenSSH Server，采用系统默认的 `/etc/ssh/sshd_config` 和 `/etc/pam.d/sshd`。不适用于 Dropbear、未集成 PAM 的 SSH 服务、Windows 或 macOS。登录成功通知依赖 Bash、curl、GNU coreutils、awk、grep、util-linux 的 flock，以及 `pam_exec.so`。

**爆破通知额外需要 Python 3.8+（含标准库 sqlite3）以及运行中的 systemd/journald。失败排名需要 Python 3.8+，可读取 journald 或传统日志。** `ss`（iproute2）用于查询实际监听端口，没有时会尝试 SSH socket 单元及 SSH 有效配置。无需安装 Python 第三方包。

常见系统安装依赖的示例（按实际发行版选择）：

```bash
# Debian / Ubuntu
apt-get update
apt-get install -y bash curl coreutils gawk grep util-linux libpam-modules python3 iproute2

# Rocky Linux / AlmaLinux / Fedora
dnf install -y bash curl coreutils gawk grep util-linux pam python3 iproute
```

OpenSSH 必须启用 **`UsePAM yes`**。安装器读取 `sshd -T` 的有效配置，而不是只检查一行配置文本。可自行检查：

```bash
sshd -t
sshd -T | grep '^usepam '
```

如果显示 `usepam no`，请在 SSH 的有效配置中启用 `UsePAM yes`，先执行 `sshd -t` 检查，再按发行版重载 `ssh` 或 `sshd` 服务。保持当前连接，另开连接确认登录正常后再关闭旧连接。安装器本身不会修改 SSH 配置或重启服务；默认配置在磁盘上启用 PAM 后，仍需确保运行中的 SSH 服务已加载该设置。

如果 SSH 通过自定义 `-f` 配置文件启动，或 PAM 文件使用符号链接，本脚本会限制或无法正确检查该场景，请先按实际部署调整，不要直接套用。

Telegram 侧需要：

1. 在 [@BotFather](https://t.me/BotFather) 创建机器人，获得 `TG_BOT_TOKEN`。
2. 私聊通知：先向机器人发送 `/start`，准备接收人的数字 Chat ID。
3. 群组通知：先把机器人加入群组并允许发送消息，准备群组数字 Chat ID，常为负数，例如 `-1001234567890`。这里填写 **Chat ID**，不是机器人用户名，也不是群内某个管理员的个人 ID。
4. 服务器能够直接通过 HTTPS 访问 `api.telegram.org`。通知使用系统 CA 并直连 Telegram，不读取代理环境变量；curl 不读取用户 curlrc。请在服务器上确认直连可用。

不支持发送到群组的指定话题（未配置 `message_thread_id`）。Telegram 接口依据 [官方 Bot API 文档](https://core.telegram.org/bots/api#sendmessage)。

## 通知示例与行为

```text
⚠️ SSH 登录成功提醒
• 服务器: VMISS-Tri
• 用户: root
• 来源 IP: 66.66.66.66
• 时间: 2026-10-31 11:14:51 +0800
```

时间使用**服务器本地时区**，附带时区偏移。来源可为 IPv4、IPv6 或 PAM 提供的主机名；为空时显示 `Local / Intranet`。消息使用纯文本和表单编码，服务器名称中的空格、中文、`&`、下划线等不会触发 Markdown 格式错误。

通知在 `sshd` 的 PAM `open_session` 事件触发，适用于已启用 PAM 的密码登录和密钥登录。SSH 远程命令、SFTP/SCP 等创建会话的操作也可能触发；SSH 连接复用下，每个新会话可能产生一条通知。它记录的是会话打开事件，不保证用户随后取得了交互式 shell。

登录成功通知在后台发送，连接超时 3 秒、总超时 8 秒；失败不阻止 SSH 登录。登录成功通知采用尽力发送，不保存队列、不重试；服务器断网、Telegram 拒绝或后台进程被系统终止时可能漏报。

安装和卸载不需要重启 SSH。安装后请保留当前连接，新开 SSH 会话验证真实通知；安装测试只验证 Telegram 通道，不代表 SSH 已实际触发 PAM。

## 爆破通知

```text
🚨 SSH 爆破提醒
• 服务器: VMISS-Tri
• 用户: root
• 来源 IP: 66.66.66.66
• 失败次数：11
• 端口：22、2324、23555
• 时间: 2026-10-31 11:14:51 +0800
```

- 按**来源 IP**累计连续失败次数，切换用户名仍累计；其他 IP 的活动不会打断该 IP 的连续计数。
- 第 10 次不提醒，**第 11 次提醒一次**，同一轮第 12 次及以后不重复刷屏。该 IP 出现 `Accepted` 成功认证记录时清零；此后再次连续失败 11 次会再次提醒。没有成功认证时不会仅因经过一天而清零。
- 用户为触发第 11 次时的用户名；时间为该次失败日志的时间，采用服务器本地时区。
- “端口”优先列出当前 SSH 监听端口，去重后用 `、` 分隔；支持多个端口、IPv6 监听和 systemd socket 激活。无法读取监听信息时回退到 SSH 有效配置，仍无法检测时显示“未知”。**认证失败日志中的 `port` 是客户端来源端口，不能当作服务器 SSH 端口。这里展示服务器的 SSH 监听端口列表，不代表已确定每次攻击的目标端口。**
- 开启或关闭后重新开启，从新日志开始统计，不补发关闭期间的历史攻击。正常服务重启、崩溃重启会保存并恢复计数及日志游标；若日志已轮转删除、旧游标无法恢复，则重置连续计数并从当前日志继续，服务日志中会记录该情况。
- 达到阈值后，将通知事件保存在本地 SQLite 待发队列，网络发送与日志读取独立进行。发送失败按 5 秒起、最长 5 分钟间隔重试；正常重启保留待发通知，关闭后重新开启或卸载会清空。请求已被 Telegram 接受但响应丢失时，重试可能造成重复投递。

爆破功能只发送提醒，不修改防火墙、不封禁 IP。

## 近 24 小时失败排名

选择 **7** 或执行 `bash ssh-tg-notify.sh rank`，有记录时只输出前 10 行，例如：

```text
800次 66.66.66.61
100次 66.66.66.62
```

使用从执行时刻往前推 **24 小时**的滚动时间范围，不是自然日，也不是简单统计日志文件的全部内容。支持 IPv4/IPv6。同一 IP 的不同用户名、不同 SSH 端口会合并统计；成功登录不会扣减排名中的历史失败次数。

排名与连续失败监控使用相同的 OpenSSH 认证失败格式 `Failed … for … from IP port … ssh2`，支持密码、公钥和交互式认证等方法。`Invalid user`、PAM `authentication failure`、`maximum authentication attempts` 等附加或汇总行不另加次数，避免同一次认证失败被重复统计。连接中断或没有形成这类认证失败记录的扫描不会计入；默认日志级别下某些公钥失败也可能未记录，工具只能统计系统实际保存的记录。

排名优先读取 `sshd`、`sshd-session`、`sshd-auth` 的 journald 日志；近 24 小时没有相关 journal 记录时，尝试 `/var/log/auth.log` 或 `/var/log/secure`，包含数字轮转、日期轮转以及 `.gz` 历史文件。不会把 journal 和传统文件中的同一批日志叠加。传统 syslog 的无年份时间戳按邻近年份解释，支持跨年。journal 时间筛选和游标恢复依据 [systemd journalctl 文档](https://www.freedesktop.org/software/systemd/man/latest/journalctl.html)。

如果日志保留不足 24 小时，只能统计现存记录；例如非持久 journal 在重启后可能不包含重启前的记录。没有记录时显示提示，不能据此保证没有发生过失败尝试。

## 文件与 PAM 管理

| 路径 | 用途 |
| --- | --- |
| `/etc/ssh-tg-notify/config` | 服务器名称、Token、Chat ID，权限 `600`，作为纯文本解析，不执行 |
| `/etc/ssh-tg-notify/notify.sh` | PAM 调用的通知程序，权限 `700` |
| `/etc/ssh-tg-notify/managed` | 安装归属标记 |
| `/etc/ssh-tg-notify/sshd.pam.backup` | 安装前 PAM 备份，权限 `600`，卸载时一并删除 |
| `/etc/ssh-tg-notify/guard.py` | 开启爆破通知时由入口脚本生成的 Python 监控程序 |
| `/etc/systemd/system/ssh-tg-notify-bruteforce.service` | 爆破监控 systemd 服务 |
| `/var/lib/ssh-tg-notify/` | 连续计数、日志游标及待发队列，目录权限 `700` |
| `/run/ssh-tg-notify.lock` | 操作互斥锁；文件可保留，进程退出后自动释放锁 |

安装目录权限为 `700`，配置仅由 root 访问。脚本不会把 Token 放进 curl 的命令行或错误日志。PAM 通过保留原权限、属主及扩展属性的临时文件原子替换；写入失败时清理本次安装文件，发现其他程序同时改动 PAM 时取消提交。

`/etc/pam.d/sshd` 中由本脚本管理的内容为：

```text
# BEGIN ssh-tg-notify
session optional pam_exec.so quiet type=open_session /etc/ssh-tg-notify/notify.sh
# END ssh-tg-notify
```

卸载过滤当前文件中的标记块，不会用旧备份覆盖当前 PAM 文件。请保留这些标记且不要复制该条目。PAM 配置依据 [Linux-PAM pam_exec 文档](https://github.com/linux-pam/linux-pam/blob/master/modules/pam_exec/pam_exec.8.xml)，`UsePAM` 行为参见 [OpenSSH Portable 配置文档](https://github.com/openssh/openssh-portable/blob/master/sshd_config.5)。

## 排查与旧版迁移

- **安装测试失败**：检查 Token 是否完整、Chat ID 是否填错、是否先私聊启动机器人或已加入群组，以及是否被禁言。还需要检查服务器到 Telegram 的 DNS、出站 HTTPS 和 CA 证书。失败时不会添加 PAM 条目。
- **测试成功但实际登录没有通知**：确认运行中的 SSH 服务已启用 PAM、新开了会话、PAM 标记块存在。启用 SELinux/AppArmor 的系统还需检查审计日志和安全策略。不要通过关闭访问控制来排查。
- **通知发送失败日志**：查看 `journalctl -t ssh-tg-notify`；未使用 journald 的系统检查系统日志。日志只记录通用失败提示，不含 Token。
- **爆破监控状态与日志**：使用 `systemctl status ssh-tg-notify-bruteforce.service` 和 `journalctl -u ssh-tg-notify-bruteforce.service`。菜单 2 也显示监控状态。开启失败时会尝试停用服务，SSH 登录成功通知保留。
- **没有爆破提醒**：先用菜单 6 检查 Telegram，再用菜单 7 和原始 SSH 日志确认有实际 `Failed` 认证记录。确认是在开启后同一 IP 连续失败超过 10 次，其间没有成功认证；同一轮只提醒一次。
- **配置损坏或残留安装文件**：先选择查看，再选择卸载后重新添加。卸载不要求配置文件能被正常解析。安装归属标记缺失、路径被替换为符号链接或 PAM 标记块被修改时会拒绝自动删除，需要 root 检查实际内容。
- **PAM 条目被修改或重复**：先备份 `/etc/pam.d/sshd`，核对本脚本的标记块和通知路径，修正为上方唯一完整的三行后再卸载。不要直接恢复安装前备份覆盖别人后来改动的配置。
- **旧版脚本**：如果安装过最初的 `/etc/pam.scripts/tg_ssh_alert.sh`，新版会识别其有效 PAM 条目并跳过，避免双重通知。迁移时，先备份 `/etc/pam.d/sshd`，手动移除指向该旧路径的 `session ... pam_exec.so ...` 条目，随后删除旧通知脚本和旧版使用的 `/etc/pam.scripts/tg_ssh_alert.conf`（如果存在），再用新版添加。其他 PAM 条目、目录内其他脚本应保留。

## 开发验证

```bash
bash -n ssh-tg-notify.sh
bash tests/test-ssh-tg-notify.sh
python3 tests/test_guard.py
```

回归测试使用临时目录、模拟 systemctl 和模拟 Telegram API，不需要 root、不操作 `/etc`、不访问 Telegram。Python 测试执行入口脚本内嵌的实际监控代码，覆盖第 11 次阈值、按 IP 清零、游标恢复、队列重试、24 小时窗口、前 10 排名、轮转及压缩日志、IPv6 和监听端口识别。真实 systemd、SSH/PAM 集成和 Telegram 投递仍需在目标 Linux 服务器上验证。
