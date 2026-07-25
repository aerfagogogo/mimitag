# 个人版本维护说明

## 只需要记住两条分支

- `author/main`：原作者代码镜像，只跟踪 `upstream/main`，不放个人签名和个人修改。
- `personal/stable`：自己的稳定版本。平时编译、安装和测试都使用这条分支。

当前个人版本使用：

- Apple Team：`CHK3SLQ5JM`
- App Bundle ID：`com.sunyiting.mimiremote`
- Tests Bundle ID：`com.sunyiting.mimiremoteTests`

`ios/MimiRemote/project.yml` 是签名和 Bundle ID 的配置来源；重新生成 Xcode
工程时要同时保留它，不能只改 `.xcodeproj`。

## 平时编译

```bash
git switch personal/stable
```

然后打开 `ios/MimiRemote/MimiRemote.xcodeproj`，选择自己的 iPhone 或 iPad，
点击 Xcode 的运行按钮。

## 跟进原作者更新

先让原作者分支快进到最新版：

```bash
git fetch upstream
git switch author/main
git merge --ff-only upstream/main
```

确认原作者版本后，再把它合入个人稳定版：

```bash
git switch personal/stable
git merge author/main
```

如果合并出现冲突，先停止，不要用强制覆盖命令。个人签名、Bundle ID 和断线恢复
修复都应保留在 `personal/stable`。

## 本次稳定性修复

本次修复处理了两个不同问题：

1. Codex app-server 的临时网络错误使用 `willRetry=true`。旧客户端只读取
   `retryable`，所以把“正在自动重试”误判成了“会话失败”，并连续显示红色错误卡。
   个人版现在兼容两个字段；重试过程只记日志，真正重试失败后才显示失败。
2. 手机到 Mac 的实时连接断开后，旧客户端会先等待会话快照和历史记录，再恢复
   WebSocket。个人版改为先立即恢复实时事件连接，再在后台静默校准快照和历史。

这能让短暂断网自动恢复，并避免把可恢复的 Codex 重试显示成终态失败。它不能消除
代理节点、蜂窝网络或 Tailscale 本身的物理断网；这些网络真的不可达时，底层仍会重试。

## Vibe Island 的启发与 SSH

Vibe Island 看起来稳定，主要因为它通过 Codex 本地 hooks、本地 Unix socket 和
`~/.codex/sessions` 监测会话状态。它监测的是本机已发生的事件，不负责承载完整的
模型对话网络，因此不能直接消除 Codex 到服务端的网络抖动。

它的 SSH 功能用于监测“另一台远程电脑”上运行的 AI CLI。小型 helper 通过用户已有
的 SSH 隧道回传状态，适合远程开发机；对于当前 iPhone 连接同一台 Mac 的完整聊天链路，
再加 SSH 不会更稳，反而多一层连接。

值得继续借鉴的是：

- 把状态监测和完整对话数据分开；
- 本地持久记录关键事件；
- 断线后按游标补放事件，而不是把断线直接当成会话失败。

当前项目已经具备事件回放水位和会话恢复，本次又补上了“实时连接优先恢复”。如果以后
仍存在状态丢失，再考虑增加独立的本地事件日志通道，不需要现在先引入 SSH。
