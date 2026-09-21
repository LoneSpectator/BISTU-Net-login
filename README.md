# BISTU 校园网自动登录容器

一个面向北京信息科技大学（BISTU）校园网认证环境的轻量级 Docker 自动登录容器。

项目使用 BusyBox 作为基础镜像，不依赖 cron、Python、curl 等额外运行环境。容器启动后由一个常驻 Shell 脚本循环检查互联网连通性，在检测到离线时自动获取校园网出口 IP/MAC、拼接认证请求并尝试重新登录。

## 功能特点

- **轻量化**：基于 `busybox:1.38.0-musl`，适合 OpenWrt、软路由和其他嵌入式 Linux 设备。
- **无需 cron**：PID 1 直接运行检测 → 登录 → `sleep` 循环，不依赖额外定时服务。
- **多架构镜像**：GitHub Actions 自动构建 `amd64`、`arm64`、`arm/v7` 和 `arm/v6` 镜像。
- **自动检测 IP/MAC**：根据到认证服务器的实际路由自动判断出口接口、IPv4 地址和 MAC 地址。
- **支持强制覆盖**：`CLIENT_IP` 和 `CLIENT_MAC` 可以分别覆盖自动检测结果。
- **外部配置文件**：统一从 `/data/login.conf` 读取配置。
- **双路日志**：日志同时输出到容器标准输出和 `/data/log/YYYY-MM-DD.log`。
- **自动日志清理**：默认保留最近 7 天的日志，可配置。
- **调试模式**：开启后记录更详细的检测和认证信息，并保存最后一次认证返回内容及 `wget` stderr。
- **减少闪存写入**：普通模式仅在网络状态变化、执行认证或出现异常时记录关键日志。
- **最小权限运行**：根文件系统只读，仅保留 `ping` 所需的 `NET_RAW` capability。

## 目录结构

```text
.
├── .github/
│   └── workflows/
│       └── docker-image.yml
├── data/
│   └── .gitkeep
├── .dockerignore
├── .gitignore
├── Dockerfile
├── docker-compose.yml
├── login.conf.example
├── login.sh
└── README.md
```

`data/login.conf`、运行日志和调试返回数据都已通过 `.gitignore` 排除，不应提交到 GitHub。

## 快速开始

### 1. 创建配置文件

```sh
cp login.conf.example data/login.conf
```

编辑：

```sh
vi data/login.conf
```

最简单的配置只需要：

```ini
USERNAME=your_username
PASSWORD=your_password
```

### 2. 从源码构建并启动

```sh
docker compose up -d --build
```

旧版 Docker Compose 可以使用：

```sh
docker-compose up -d --build
```

### 3. 查看日志

容器控制台：

```sh
docker logs -f bistu-login
```

持久化日志：

```text
/data/log/YYYY-MM-DD.log
```

宿主机使用当前项目目录时对应：

```text
./data/log/YYYY-MM-DD.log
```

## 使用预构建的镜像

项目已发布到 GitHub Container Registry（GHCR）：

```text
ghcr.io/lonespectator/bistu-net-login:latest
```

直接运行：

```sh
docker run -d \
    --name bistu-login \
    --restart unless-stopped \
    --network host \
    --read-only \
    --tmpfs /tmp:size=1m,mode=1777 \
    --cap-drop ALL \
    --cap-add NET_RAW \
    --security-opt no-new-privileges:true \
    -v "$(pwd)/data:/data" \
    ghcr.io/lonespectator/bistu-net-login:latest
```

也可以继续使用本项目的 `docker-compose.yml`，通过环境变量指定预构建镜像：

```sh
BISTU_LOGIN_IMAGE=ghcr.io/lonespectator/bistu-net-login:latest \
    docker compose up -d --no-build
```

## 配置说明

只有 `USERNAME` 和 `PASSWORD` 是必填项，其余配置都有默认值。

**认证服务器IP默认为无线网配置，有线网需修改AUTH_SERVER_IP=10.144.0.3！**

| 配置项 | 默认值 | 说明 |
| --- | --- | --- |
| `USERNAME` | 无 | 校园网用户名，必填 |
| `PASSWORD` | 无 | 校园网密码，必填 |
| `AUTH_SERVER_IP` | `10.144.49.2` | 校园网认证服务器 IP ，默认为新校区无线网，新校区有线网修改为10.144.0.3。老校区有线：192.168.211.3；老校区无线：10.1.206.13。 |
| `AUTH_SERVER_PORT` | `802` | 服务器认证端口，非必要勿修改 |
| `LOOP_INTERVAL_SECONDS` | `60` | 两次联网状态检测之间的间隔秒数 |
| `PING_IP` | `223.6.6.6` | 用于判断互联网是否已经连通的目标 IP |
| `LOG_RETENTION_DAYS` | `7` | 日志保留天数 |
| `DEBUG` | `false` | 是否开启详细调试日志 |
| `CLIENT_IP` | 自动检测 | 强制指定提交给认证服务器的客户端 IPv4 地址 |
| `CLIENT_MAC` | 自动检测 | 强制指定提交给认证服务器的客户端 MAC 地址 |

完整示例：

```ini
USERNAME=your_username
PASSWORD=your_password

# 以下配置均可省略
# AUTH_SERVER_IP=10.144.49.2
# AUTH_SERVER_PORT=802
# LOOP_INTERVAL_SECONDS=60
# PING_IP=223.6.6.6
# LOG_RETENTION_DAYS=7
# DEBUG=false

# 留空或不填写时自动检测
# CLIENT_IP=10.153.123.123
# CLIENT_MAC=9f:c5:a6:0c:61:9b
```

`CLIENT_IP` 和 `CLIENT_MAC` 可以独立设置。例如，只指定 MAC 而让脚本自动检测 IP：

```ini
CLIENT_MAC=9f:c5:a6:0c:61:9b
```

MAC 地址中的 `:`、`-` 或 `.` 会在发送认证请求前自动去除并转换为小写格式。

## IP/MAC 自动检测

脚本首先查询到认证服务器的实际路由：

```sh
ip route get 10.144.49.2
```

然后获取：

- 出口网络接口；
- 对应 IPv4 source address；
- 对应接口的 MAC 地址。

由于校园网认证请求中需要使用真实校园网侧客户端 IP/MAC，因此默认使用：

```yaml
network_mode: host
```

如果使用普通 Docker bridge 网络，容器通常只能检测到 Docker 虚拟接口及其内部地址，可能导致校园网认证失败。

如果 OpenWrt 的 VLAN、Bridge、多 WAN、策略路由等配置导致自动检测结果不符合实际认证要求，可以在 `login.conf` 中使用 `CLIENT_IP` 和/或 `CLIENT_MAC` 强制覆盖。

## 日志

日志同时写到标准输出和每日文件。

示例：

```text
2026-08-25 19:35:02 [INFO] BISTU login service started.
2026-08-25 19:35:02 [INFO] Internet connection is available.
```

因此既可以使用：

```sh
docker logs -f bistu-login
```

也可以查看：

```sh
tail -f data/log/$(date +%Y-%m-%d).log
```

默认情况下不会每个检测周期都写一条“网络正常”，从而减少 OpenWrt、eMMC、SD 卡等设备上的无意义闪存写入。

## Debug 模式

在 `login.conf` 中设置：

```ini
DEBUG=true
```

开启后会额外记录：

- 每轮联网检测结果；
- 检测到的出口接口；
- 最终使用的客户端 IP/MAC；
- IP/MAC 是否来自手动覆盖；
- 认证服务器及用户名；
- `wget` 请求退出状态；
- 认证服务器返回数据大小。

密码不会写入日志。

最后一次认证请求的原始返回内容及 `wget` stderr会保存到：

```text
/data/last_response.txt
/data/last_wget_stderr.txt
```

关闭 Debug 并重新启动容器后，上述文件会自动删除。

## 安全设计

容器默认采用以下限制：

```yaml
read_only: true
cap_drop:
    - ALL
cap_add:
    - NET_RAW
security_opt:
    - no-new-privileges:true
```

`NET_RAW` 仅用于执行 `ping`。脚本不需要 `NET_ADMIN`，也不会修改 OpenWrt 路由、防火墙或网络接口配置。

`/tmp` 使用 1 MiB tmpfs，认证过程中的临时返回文件不会持久写入容器根文件系统。

真实 `data/login.conf` 包含校园网账号密码，请不要提交、截图或公开该文件。

## OpenWrt 建议

推荐使用 host 网络运行，并在第一次部署时临时开启：

```ini
DEBUG=true
```

重点确认日志中的自动检测 IP/MAC 与 OpenWrt 宿主机执行以下命令的结果一致：

```sh
ip route get 10.144.49.2
```

确认认证流程正常后，可将 `DEBUG` 改回 `false`，减少日志量和持久存储写入。

## 注意事项

本项目针对当前使用的 BISTU 校园网 Portal 请求方式实现。如果学校认证服务器地址、接口参数或认证协议发生变化，可能需要同步修改脚本。

请仅在本人有权使用的校园网账号和网络环境中使用本项目。项目不会绕过账号认证、访问控制或校园网计费策略。

## AI 编码声明

> **本项目由 AI 编码。** 项目代码、Docker 配置、GitHub Actions 工作流及 README 文档主要由 OpenAI ChatGPT 根据项目需求生成和整理，并由项目维护者负责实际测试、审核、部署与后续维护。
