# Clash for Linux - 增强版

基于 [wnlen/clash-for-linux](https://github.com/wnlen/clash-for-linux) 的增强版本，添加了自动化配置和订阅管理功能。

## ✨ 新增功能

### 🎯 自动化配置脚本 (`auto_proxy.sh`)

一个强大的交互式脚本，自动化完成 Clash 的配置和管理：

#### 主要特性：

1. **📋 订阅管理**
   - 支持多个订阅地址保存和切换
   - 自动验证订阅地址有效性
   - 显示流量使用情况和过期时间
   - 支持添加、选择、删除订阅

2. **🔐 自动化 Secret 管理**
   - 自动捕获并保存 Secret
   - 持久化存储到 `~/.clash_secret`
   - 自动加载到 `.bashrc`，下次登录自动可用

3. **🌐 智能节点选择**
   - 显示所有可用代理节点
   - 显示节点延迟信息
   - 支持多种配置文件格式
   - 交互式选择节点

4. **⚙️ 代理模式选择**
   - Rule - 规则模式（根据规则自动选择）
   - Global - 全局代理（所有流量走代理）
   - Direct - 直连模式（所有流量直连）

5. **✅ 连接测试**
   - 自动测试 Google 连接
   - 显示响应时间
   - 失败时提供重试选项

## 🚀 快速开始

### 安装

```bash
git clone https://github.com/ZhengkaiZhao/clash-for-linux-enhanced.git
cd clash-for-linux-enhanced
```

### 使用自动化脚本

```bash
sudo bash auto_proxy.sh
```

脚本会引导你完成：
1. 订阅地址管理（添加、选择、删除）
2. 自动启动 Clash 服务
3. 选择代理节点
4. 选择代理模式
5. 测试连接

ps:第一次连接可能出现找不到订阅选项，确保链接正确的前提下，可以重新运行脚本即可解决问题sudo bash auto_proxy.sh

### 传统使用方式

仍然支持原有的使用方式：

```bash
# 编辑配置
vim .env

# 启动服务
sudo bash start.sh

# 加载环境变量
source /etc/profile.d/clash.sh
proxy_on

# 停止服务
sudo bash shutdown.sh
proxy_off
```

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

请选择代理节点编号 [1-4] (直接回车跳过):
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

### 环境变量管理

```bash
# 开启系统代理
proxy_on

# 关闭系统代理
proxy_off

# 查看代理状态
env | grep -E 'http_proxy|https_proxy'
```

### 访问 Dashboard

```
http://127.0.0.1:9090/ui
```

## 📁 文件说明

- `auto_proxy.sh` - 自动化配置脚本（新增）
- `start.sh` - 启动 Clash 服务
- `shutdown.sh` - 停止 Clash 服务
- `restart.sh` - 重启 Clash 服务
- `.env` - 配置文件
- `conf/config.yaml` - Clash 配置文件
- `~/.clash_secret` - 保存的 Secret（自动生成）
- `~/.clash_subscriptions` - 保存的订阅信息（自动生成）

## 🛡️ 安全提示

- `.env` 文件包含订阅地址，已自动添加到 `.gitignore`
- Secret 保存在用户目录，权限为 600
- 订阅信息保存在 `~/.clash_subscriptions`，权限为 600

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
