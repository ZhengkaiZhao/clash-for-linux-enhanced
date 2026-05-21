# Clash for Linux - 增强版

基于 [wnlen/clash-for-linux](https://github.com/wnlen/clash-for-linux) 的增强版本，添加了自动化配置和订阅管理功能。

## ✨ 新增功能

### 🆕 2026-05 更新（稳定性与脚本一致性）

- 修复 `start.sh` 中代理节点 JSON 解析的问题，避免正常 API 返回下仍拿不到节点列表。
- 节点切换请求会正确转义节点名，兼容包含引号、反斜杠或特殊字符的节点名称。
- 启动、停止、重启时只清理当前项目目录下的 Clash 进程，避免误伤系统中其他 Clash 实例。
- GPT/Codex/Google 连通性测试改为多次采样探测，明确区分“当前采样失败”和“网络一定不可达”。
- `shutdown.sh` / `restart.sh` 已按增强版逻辑整理，支持无残留进程时正常退出，并提供更明确的错误提示。
- README 补充本地配置模式、入口脚本职责和常见排查路径。

### 🆕 2026-04 更新（`start.sh` 交互增强）

- `start.sh` 现为推荐入口：支持启动前自动清理遗留代理状态和残留进程。
- 新增 `shell_proxy.sh`：可从 `~/.bashrc` / `~/.zshrc` 引入，自动检测 Clash 是否运行；运行时为终端/Codex/Git 注入 `http_proxy` / `https_proxy` / `ALL_PROXY`，关闭后自动清除代理环境变量。
- 新增 `clashctl.sh`：Clash 运行中可在任意终端查看状态、切换节点、切换 Rule/Global/Direct 模式、输出代理环境变量和执行分项连通性诊断。
- 订阅管理支持命名、切换、删除，并在切换前验证有效性与流量/过期信息。
- 节点选择支持延迟展示，要求明确选择节点（仅一个可用节点时自动选择）。
- 启动完成后进入运行中控制台，可在不重启 `start.sh` 的情况下重新选择节点、切换代理策略、重新测试连接、查看状态。
- 新增代理策略选择：
   - 系统代理（System Proxy + Rule）
   - 全局代理（System Proxy + Global）
   - 直连模式（关闭系统代理 + Direct）
- API 鉴权失败（`Unauthorized`）时，会自动尝试读取当前 `config.yaml` 的 `secret` 重试。
- 启动末尾自动执行 `curl -x` 代理连通测试，默认测试 GPT/Codex（OpenAI API + ChatGPT Web），也可选择 Google 204 或全部测试。

## 项目结构与入口

当前推荐入口是 `source ./start.sh`。它负责订阅管理、配置生成、本地配置加载、启动 Clash、选择节点、切换模式、连通性测试和退出清理。

`clashctl.sh` 是运行中控制脚本，适合在另一个终端查看状态、切换节点、切换模式或输出代理环境变量。

`shell_proxy.sh` 负责让新终端自动同步代理环境变量。`start.sh` 会把它写入 `~/.bashrc` / `~/.zshrc`。

`auto_proxy.sh` 是早期自动化脚本，仍保留用于兼容；新功能优先维护在 `start.sh` 和 `clashctl.sh`。

## 🚀 快速开始

### 安装

```bash
git clone https://github.com/ZhengkaiZhao/clash-for-linux-enhanced.git
cd clash-for-linux-enhanced
```

### 使用自动化脚本

```bash
source ./start.sh
```

脚本会引导你完成：
1. 订阅地址管理（添加、选择、删除）
2. 自动启动 Clash 服务
3. 选择代理节点
4. 选择代理模式
5. 测试连接
6. 进入运行中控制台，可随时重新选择节点或切换模式

如果没有订阅，或订阅地址暂时不可达，可以把 Clash YAML 配置放到 `conf/`、`config/` 或项目根目录，启动时选择本地模式。

### 传统使用方式

仍然支持原有的使用方式：

```bash
# 编辑配置
cp .env.example .env
vim .env

# 启动服务
source start.sh

# 可选：手动控制当前终端代理
proxy_on

# 停止服务并清理当前终端代理变量
source shutdown.sh
```

说明：`start.sh` 需要使用 `source`（或 `. start.sh`）执行，才能在当前 Shell 中正确应用和清理代理环境变量。

## 📖 使用示例

### 订阅管理界面

```
已保存的订阅列表：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[1] 订阅A
    流量: 25.86GB/300.00GB (剩余274.14GB)
    过期: 2026-03-12 14:36:43
    [当前使用]

[2] 订阅B
    流量: 50.00GB/500.00GB (剩余450.00GB)
    过期: 2026-04-01 23:59:59

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[0] 添加新的订阅地址
[d] 删除订阅（输入 d[编号]，如 d1）

请选择订阅 [0-2] 或 d[编号]删除 或直接回车:
```

### 节点选择

```
可用的代理节点：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[1] 香港节点1 (150ms)
[2] 美国节点1 (250ms)
[3] 日本节点1 (100ms)
[4] 新加坡节点1 (80ms)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

请选择代理节点编号 [1-4]（必须选择，不可跳过）:
```

## 🔧 高级功能

### 手动测试代理

```bash
# 测试 HTTP 代理
curl -x http://127.0.0.1:7890 https://www.google.com

# 测试 HTTPS 代理
curl -x http://127.0.0.1:7890 https://www.youtube.com

# 查看当前 IP
curl -x http://127.0.0.1:7890 https://api.ip.sb/ip
```

### 连通性测试说明

`start.sh` 和 `clashctl.sh test` 的 GPT/Codex/Google 测试只是采样探测，不是数学意义上的可达性证明。Clash 节点、DNS、远端限流、出口 IP 风控和瞬时网络波动都可能导致某一次测试失败。

默认每个目标探测 3 次。你可以按需要调整：

```bash
# 每个目标探测 5 次，每次间隔 2 秒
CLASH_TEST_ATTEMPTS=5 CLASH_TEST_DELAY=2 ./clashctl.sh test
```

结果含义：

- `3/3 次探测通过`：当前采样窗口内比较稳定。
- `1/3 次探测通过`：至少有过可达，说明链路可能波动，不宜直接判定不可用。
- `0/3 次探测未通过`：当前采样窗口内未探测到成功，但仍不能证明目标永久不可达。
- `HTTP 403`：通常表示网络链路有响应，但当前节点 IP/地区被目标服务拒绝。

### API 鉴权排查

当代理 `curl -x` 成功但 API 测试失败时，通常是 `secret` 不一致导致：

- 代理测试走的是 `7890` 端口的数据转发链路；
- API 测试走的是 `9090` 控制面链路，必须携带正确 `secret`。

脚本已内置自动回退重试逻辑；若仍失败，可查看：

```bash
grep -E '^secret:' conf/config.yaml
cat ~/.clash_secret
```

### 本地配置模式

当订阅不可用，或你已经有完整 Clash 配置文件时，可以使用本地模式：

```bash
# 任意一种位置均可
cp your-config.yaml conf/
# 或 mkdir -p config && cp your-config.yaml config/
# 或 cp your-config.yaml .

source ./start.sh
```

启动时选择 `L` 后，脚本会先用当前架构的 Clash 二进制校验配置，再写入 `conf/config.yaml` 并注入 Dashboard 和 API `secret`。

### 环境变量管理

```bash
# 自动同步当前终端代理状态（推荐写入 ~/.bashrc）
source /path/to/clash-for-linux-enhanced/shell_proxy.sh

# 开启系统代理
proxy_on

# 关闭系统代理
proxy_off

# 查看代理状态
env | grep -E 'http_proxy|https_proxy'
```

`start.sh` 会自动把 `shell_proxy.sh` 写入 `~/.bashrc` 和 `~/.zshrc`。之后只要 Clash 正在运行，新打开的终端会自动带上：

```bash
http_proxy=http://127.0.0.1:7890
https_proxy=http://127.0.0.1:7890
ALL_PROXY=socks5h://127.0.0.1:7891
```

这可以避免 Codex、Claude Code、Git、npm 等 CLI 工具因没有代理环境变量而直连失败。`socks5h` 会把域名解析交给代理端，适合排查 `Name does not resolve` 类问题。

### 运行中控制

```bash
# 查看 Clash/API/当前模式
clashctl status

# 查看可切换策略组
clashctl groups

# 查看默认策略组节点
clashctl nodes

# 查看指定策略组节点
clashctl nodes AI_Services_ChatGPT_Claude

# 交互式切节点
clashctl switch

# 指定策略组和节点切换
clashctl switch AI_Services_ChatGPT_Claude "🇨🇳 Taiwan | 01"

# 切换代理模式
clashctl mode rule
clashctl mode global
clashctl mode direct

# OpenAI/ChatGPT/Google 分项测试
clashctl test

# 当前终端临时注入代理变量
eval "$(/path/to/clash-for-linux-enhanced/clashctl.sh env)"
```

如果 `clashctl test` 中 Google 可达但 OpenAI/ChatGPT 返回 403，通常说明当前节点地区或 IP 被 OpenAI 服务端拒绝。优先切换到 TW/JP/SG/US 等可用节点，再测试 Codex。

`source ./start.sh` 启动完成后也会停留在运行中控制台，不需要另开终端即可操作：

```text
[1] 重新选择代理节点
[2] 切换代理策略（Rule / Global / Direct）
[3] 重新测试 GPT/Codex / Google 连接
[4] 查看当前状态
[5] 查看可用策略组
[6] 查看当前策略组节点
[q] 退出 Clash 并清理代理
```

### 访问 Dashboard

```
http://127.0.0.1:9090/ui
```

## 📁 文件说明

- `auto_proxy.sh` - 早期自动化配置脚本，保留兼容；推荐优先使用 `start.sh`
- `clashctl.sh` - 运行中控制脚本：状态、策略组、节点、模式、连通性诊断、代理环境变量
- `start.sh` - 推荐入口：订阅/本地配置、启动、节点选择、策略切换、测试和运行中控制台
- `shell_proxy.sh` - 终端代理自动同步脚本
- `shutdown.sh` - 停止当前项目的 Clash 服务；通过 `source shutdown.sh` 可同步清理当前 Shell 代理变量
- `restart.sh` - 使用现有 `conf/config.yaml` 重启当前项目的 Clash 服务
- `.env.example` - 配置模板
- `.env` - 本地配置文件（不提交）
- `conf/config.yaml` - Clash 运行配置文件（不提交）
- `~/.clash_secret` - 保存的 Secret（自动生成）
- `~/.clash_subscriptions` - 保存的订阅信息（自动生成）

## 🛡️ 安全提示

- `.env` 文件包含订阅地址，已自动添加到 `.gitignore`
- Secret 保存在用户目录，权限为 600
- 订阅信息保存在 `~/.clash_subscriptions`，权限为 600
- `external-controller` 默认监听 `0.0.0.0:9090`。如果机器暴露在不可信网络中，建议在 `.env` 中改为 `127.0.0.1:9090`，或确保防火墙阻止外部访问。

## 🤝 贡献

基于 [wnlen/clash-for-linux](https://github.com/wnlen/clash-for-linux) 项目。

### 主要改进：
- 添加自动化配置脚本
- 订阅管理功能
- Secret 持久化
- 智能节点选择
- 连接测试

## 📄 许可证

与原项目保持一致。

## ⚠️ 免责声明

本项目仅供学习交流使用，请遵守当地法律法规。
