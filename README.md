# SSH 登录 Telegram 通知

在 Linux 服务器上通过 PAM 监听 SSH 会话，向 Telegram 发送登录通知。单文件管理脚本：**`ssh-tg-notify.sh`**。

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
3. 卸载通知
4. 发送测试通知
0. 退出
```

- **添加**：输入服务器名称、`TG_BOT_TOKEN`、`TG_CHAT_ID`。服务器名称用于通知显示，回车默认使用主机名；Token 在终端中隐藏输入。脚本先检查 SSH/PAM，再向 Telegram 发送测试消息，成功后才写入安装文件和 PAM 条目。
- **自动检测**：完整安装后再次选择添加，会直接跳过，不重新输入配置，不重复添加。发现残留文件、重复或异常条目时会报错，避免把损坏安装当成成功。
- **查看**：显示服务器名称、**完整** Token、Chat ID 和本地配置状态。该菜单供 root 使用，请留意终端录屏、截图和屏幕共享。
- **卸载**：移除本脚本的 PAM 标记块、通知程序、配置及安装前备份。保留其他 PAM 配置，包括安装后新增的条目；重复卸载无副作用。配置写错时卸载后重新添加即可。
- **测试**：使用已保存的配置发送测试消息，报告 Telegram 是否接受请求。

下载到本地后，也支持直接指定功能：

```bash
bash ssh-tg-notify.sh install
bash ssh-tg-notify.sh show
bash ssh-tg-notify.sh test
bash ssh-tg-notify.sh uninstall
```

## 安装前准备

适用于使用 Linux-PAM 的 OpenSSH Server，采用系统默认的 `/etc/ssh/sshd_config` 和 `/etc/pam.d/sshd`。不适用于 Dropbear、未集成 PAM 的 SSH 服务、Windows 或 macOS。依赖 Bash、curl、GNU coreutils、awk、grep、util-linux 的 flock，以及 `pam_exec.so`。

常见系统安装依赖的示例（按实际发行版选择）：

```bash
# Debian / Ubuntu
apt-get update
apt-get install -y bash curl coreutils gawk grep util-linux libpam-modules

# Rocky Linux / AlmaLinux / Fedora
dnf install -y bash curl coreutils gawk grep util-linux pam
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
4. 服务器能够直接通过 HTTPS 访问 `api.telegram.org`。安装测试和实际通知都使用系统 CA、关闭用户 curlrc，并使用清理后的网络环境，不读取代理环境变量；请在服务器上确认直连可用。

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

网络发送在后台执行，连接超时 3 秒、总超时 8 秒；失败不阻止 SSH 登录。采用尽力发送，不保存队列、不重试；服务器断网、Telegram 拒绝或后台进程被系统终止时可能漏报。这是登录提醒工具，无法检测所有未授权访问，也不会阻止登录。

安装和卸载不需要重启 SSH。安装后请保留当前连接，新开 SSH 会话验证真实通知；安装测试只验证 Telegram 通道，不代表 SSH 已实际触发 PAM。

## 文件与 PAM 管理

| 路径 | 用途 |
| --- | --- |
| `/etc/ssh-tg-notify/config` | 服务器名称、Token、Chat ID，权限 `600`，作为纯文本解析，不执行 |
| `/etc/ssh-tg-notify/notify.sh` | PAM 调用的通知程序，权限 `700` |
| `/etc/ssh-tg-notify/managed` | 安装归属标记 |
| `/etc/ssh-tg-notify/sshd.pam.backup` | 安装前 PAM 备份，权限 `600`，卸载时一并删除 |
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
- **配置损坏或残留安装文件**：先选择查看，再选择卸载后重新添加。卸载不要求配置文件能被正常解析。安装归属标记缺失、路径被替换为符号链接或 PAM 标记块被修改时会拒绝自动删除，需要 root 检查实际内容。
- **PAM 条目被修改或重复**：先备份 `/etc/pam.d/sshd`，核对本脚本的标记块和通知路径，修正为上方唯一完整的三行后再卸载。不要直接恢复安装前备份覆盖别人后来改动的配置。
- **旧版脚本**：如果安装过最初的 `/etc/pam.scripts/tg_ssh_alert.sh`，新版会识别其有效 PAM 条目并跳过，避免双重通知。迁移时，先备份 `/etc/pam.d/sshd`，手动移除指向该旧路径的 `session ... pam_exec.so ...` 条目，随后删除旧通知脚本和旧版使用的 `/etc/pam.scripts/tg_ssh_alert.conf`（如果存在），再用新版添加。其他 PAM 条目、目录内其他脚本应保留。

## 开发验证

```bash
bash -n ssh-tg-notify.sh
bash tests/test-ssh-tg-notify.sh
```

回归测试使用临时目录和模拟 Telegram API，不需要 root、不操作 `/etc`、不访问 Telegram。覆盖重复安装、失败回滚、配置解析、PAM 冲突、卸载保留其他配置及通知事件筛选。真实 SSH/PAM 集成和 Telegram 投递仍需在目标 Linux 服务器上验证。
