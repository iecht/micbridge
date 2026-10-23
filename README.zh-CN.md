# MicBridge

[English](README.md) | 简体中文

用一台 Mac（比如 MacBook Air）的麦克风，给局域网里另一台没有麦克风的 Mac（比如 Mac mini）当音频输入设备。在 Mac mini 上一开始录音，就会自动调用 Air 的麦克风。

## 工作原理

```
Mac mini 上某个 App 开始从 BlackHole 录音
  → Receiver 检测到（Core Audio 按进程的录音状态）
  → 通过常驻的 TCP 连接通知 Air 打开麦克风
  → Air 上的 Sender 推送 16-bit PCM 音频
  → Receiver 把音频写进 BlackHole → App 录到的就是 Air 麦克风的声音
App 停止录音 3 秒后 → 通知 Air 关闭麦克风（橙色指示灯熄灭）
```

- 两台 Mac 通过 Bonjour 自动发现对方，不用填 IP。
- 连接常驻，开始录音后通常 0.4–1 秒就能收到声音。
- 不录音时 Air 的麦克风是关闭的。

## 要求

- 两台 Mac 都是 macOS 14.2 或更新版本，并且在同一个局域网里。
- 安装了 Xcode Command Line Tools（`xcode-select --install`），用来编译。
- 接收端（没有麦克风的那台）需要安装虚拟声卡 [BlackHole](https://existential.audio/blackhole/)。

## 安装

**接收端（Mac mini）**

```bash
brew install --cask blackhole-2ch
git clone https://github.com/iecht/micbridge.git && cd micbridge
./install.sh receiver
```

- 会把 BlackHole 2ch 设为系统默认输入设备。如果安装后看不到 BlackHole，运行 `sudo killall coreaudiod` 重启音频服务。
- 如果 Bonjour 找不到发送端，可以直接指定 IP：`./install.sh receiver --host 192.168.x.x`
- 也可以改用其他虚拟设备，比如 Rogue Amoeba Loopback：`./install.sh receiver --device "Loopback Audio"`

**发送端（MacBook Air）**

```bash
git clone https://github.com/iecht/micbridge.git && cd micbridge
./install.sh sender
```

第一次运行时会弹出 **麦克风** 和 **本地网络** 两个权限请求，都要点「允许」。

两端都会作为登录项在后台运行，开机自动启动，崩溃了会自动重启。卸载：在对应的机器上运行 `./install.sh uninstall`。

## 使用

在 Mac mini 上打开任何需要麦克风的 App（会议、听写、录音软件），把输入设备选为 **BlackHole 2ch**（默认已经是了），直接开始用就行。

## 接收端参数

| 参数 | 作用 |
|---|---|
| `--host IP` | 不用 Bonjour，直接连接这个地址 |
| `--port N` | 端口（默认 50555，两端要一致） |
| `--device NAME` | 写入哪个虚拟设备（默认 BlackHole） |
| `--always-on` | 让发送端的麦克风一直开着，开始录音时零等待 |
| `--no-set-default` | 不修改系统默认输入设备 |

## 日志

- 发送端：`~/Library/Logs/micbridge-sender.log`
- 接收端：`~/Library/Logs/micbridge-receiver.log`

## 已知限制

- MacBook **合上盖子时麦克风会被硬件禁用**，睡眠时也连不上。用的时候要开着盖子、保持唤醒（推流期间程序会阻止 Air 自动睡眠）。
- 连接是常驻的，App 开始录音后只需等发送端的麦克风启动（通常 0.4–1 秒）。想完全零等待可以用 `--always-on`，但发送端的麦克风指示灯会一直亮着。
- 端到端延迟大约 50–150 ms，适合语音、会议、听写，不适合实时监听乐器演奏。
- 音频在局域网里不加密传输。

## 许可

MIT
