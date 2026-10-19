# 微软原生 VPN（Windows RRAS）配置存档 · 2026

> 服务器：`<VPN_SERVER_IP>`（内网 `<SERVER_INTERNAL_IP>`，Windows Server 2022 Datacenter，腾讯云上海）
> 时间：2026-10-17 ~ 2026-10-19
> 结论：**Windows 客户端（SSTP）完全可用；华为 HarmonyOS 手机未能接入**（原因见第五节）

---

## 一、目标与技术路线

目标：在 Windows Server 上重建"原生"VPN（不引入 OpenVPN/WireGuard 等第三方服务端），
让 Windows 电脑与华为手机都能拨入，并由服务器转发上网。

技术路线（自下而上）：

```
用户身份/加密
  └─ 私有 PKI（自签 CA → 服务器证书 → 客户端证书）
传输隧道
  └─ RRAS：SSTP(TCP 443) / IKEv2(UDP 500,4500) / L2TP / PPTP
地址与路由
  └─ RRAS 静态地址池 10.10.10.10–200 → IPv4 路由 → WinNAT 出公网
客户端交付
  └─ Windows 一键脚本（SSTP）/ 华为安装包（IKEv2 证书）
运维与观测
  └─ 按需启动 BAT + watchdog、WinForms 监控面板、pktmon 抓包
```

---

## 二、用到的工具

| 工具 | 用途 |
|---|---|
| `Install-WindowsFeature` / `Install-RemoteAccess` | 安装 RRAS 角色、启用 VPN |
| `New-SelfSignedCertificate` + 证书存储 | 构建私有 CA、签发服务器/客户端证书 |
| `netsh ras` | 端口、地址池、认证方式、跟踪、状态 |
| `netsh http sslcert` | SSTP 的 443 证书绑定 |
| `netsh ras set type` | 启用 IPv4 路由（LAN and demand-dial） |
| `New-NetNat`（WinNAT） | VPN 客户端出公网地址转换 |
| `RemoteAccess` PowerShell 模块 | 配置 IKEv2 策略、认证方式、证书绑定 |
| `pktmon` + `etl2pcap` | 抓 IKE 报文，定位协商失败点 |
| Process Monitor（Sysinternals） | 抓 `RasMan` 启动失败的确切位置 |
| OpenSSL（Git 自带） | 计算证书 `subject_hash`，核对手机端证书 |
| Windows Forms + NotifyIcon | 监控面板（单实例、托盘、连接日志） |
| `rasdial` / `Add-VpnConnection` | 客户端拨号与本地回归测试 |
| Git / GitHub CLI | 配置与记录存档 |

---

## 三、服务端配置要点

| 项目 | 值 |
|---|---|
| 角色 | RemoteAccess / DirectAccess-VPN / Routing |
| 端口 | SSTP 128、IKEv2 128、L2TP 64、PPTP 128（Total 449） |
| 地址池 | `10.10.10.10 – 10.10.10.200` |
| 账号 | `<VPN_USER>`（本地账户，拨入 permit） |
| IKEv2 算法 | AES128 / SHA256 / DH14 / PFS2048（自定义策略） |
| 认证 | 隧道 = Certificates；用户 = EAP / MsChapv2 / Certificate |
| 证书 | CA `CN=Phoebe VPN Root CA 2026`；服务器 `CN=<VPN_SERVER_IP>`（SAN 含 IP）；客户端 `CN=Phoebe-Phone-2026` |
| 路由 | `IPv4 Router = LAN and demand-dial routing` |
| NAT | `PhoebeVpnNat` → `10.10.10.0/24` |
| 防火墙 | TCP 443、UDP 500/4500/1701、GRE（6 条入站规则） |
| 启动方式 | 服务为手动，BAT/面板按需启动；关窗由 watchdog 自动停服 |

### 关键修复：`ModernStackEnabled`

历史会话把 `RasMan` 的 **711**（`{TDI 事件尚未完成}`）判定为"RAS 栈损坏、只能重装系统"，实测为误判：

- 重装系统后、装 RRAS 之前 `RasMan` 正常
- `Install-RemoteAccess` 之后 `RasMan` 被置为"已禁用"，强启报 711
- Process Monitor 显示：`RasMan` 的 ServiceMain 加载 `rasmans.dll` 后读取
  `HKLM\...\RemoteAccess\Parameters\ModernStackEnabled = 1`，随即退出
- 改为 `0`（传统栈）后 `RasMan` 正常，`Total Ports` 由 `0` 恢复为 385/449

```powershell
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\RemoteAccess\Parameters' -Name ModernStackEnabled -Value 0 -Type DWord
```

> 该修复已固化进 `server/部署VPN服务器.ps1`。

### 关键修复：缺失的转发与 NAT

只装 VPN 角色时 `IPv4 Router = Not Enabled`，客户端拿到 `10.10.10.x` 也无法上网：

```powershell
netsh ras set type ipv4rtrtype=lananddd ipv6rtrtype=none rastype=IPv4
New-NetNat -Name 'PhoebeVpnNat' -InternalIPInterfaceAddressPrefix '10.10.10.0/24'
```

---

## 四、客户端交付

### Windows（已验证可用）

`client-windows/Setup-WindowsClient-2026.ps1`

- 自动提权 → 安装根证书 → 创建 SSTP 连接 → 拨号 → 输出内网 IP
- 实测：拨号 5 秒，获得 `10.10.10.11`
- 失败时会翻译错误码（691 / 809 / 868 / 812）

### 华为 Mate 70（未成功）

`client-huawei/Setup-HuaweiMate70-RSA.ps1`

- 生成安装包（根证书 + 客户端证书 + 图文指引）
- 可选启动临时 HTTP 下载页
- 手机端目标配置：类型 `IKEv2/IPSec RSA`、CA = `Phoebe VPN Root CA 2026`、用户证书 = `Phoebe-Phone-2026`

---

## 五、失败原因分析（华为手机）

### 阶段 1：IKE_SA_INIT 算法不匹配（已解决）

抓包：手机首个 `IKE_SA_INIT` 用 **DH Group 19（ECP-256）**，服务器回 `INVALID_KE_PAYLOAD`；
手机改用 **DH 14（MODP-2048）** 重发后，服务器返回 492 字节正常响应。

手机提议：AES-CBC-128/192、SHA2-256/384/512、MODP-2048/3072/4096、PRF SHA1/SHA2。
RRAS 默认策略使用 DH2（1024）+ SHA1，两边无交集 → 必须改成现代参数（见第三节）。

### 阶段 2：手机不信任服务器证书（已解决）

- 手机 VPN 的「IPSec CA 证书」为 `ucs_alias_rootkeyf`（华为自带根）
- 服务器证书签发者不在手机信任列表 → 手机收到证书后直接放弃，循环重连

核对方法：Android/HarmonyOS 用户 CA 文件名为 `user:<subject_hash_old>.0`，
`openssl x509 -subject_hash_old` 与手机显示一致才说明是同一张。

### 阶段 3：服务器把 CA 证书当成服务器证书候选（已解决）

`LocalMachine\My` 下两张证书都满足"含私钥 + serverAuth EKU"：

```
CN=Phoebe Root CA    EKU: 客户端+服务器身份验证   HasPrivateKey: True   ← 问题
CN=<VPN_SERVER_IP>     EKU: 服务器身份验证          HasPrivateKey: True
```

CA 证书由 `New-SelfSignedCertificate` 生成时未限定 EKU，默认带 serverAuth，因而被 IKEv2 视作候选，
可能把 `CN=Phoebe Root CA` 发给客户端（CN 与地址不符 → 客户端拒绝）。

处理：将 CA 从 `My` 移除（保留在 `Root` 信任库），2026 套件显式限定签名用途。

### 阶段 4：认证方式不匹配（已定位）

| 手机类型 | 服务器当时配置 | 结果 |
|---|---|---|
| IKEv2/IPSec MSCHAPv2 | 隧道认证 = Certificates | IKE_AUTH 被拒（服务器回 1488 字节含证书），客户端不带证书 |
| IKEv2/IPSec PSK | 隧道认证 = PreSharedKey | 服务器回 80 字节认证失败 |
| IKEv2/IPSec RSA（带证书） | 隧道认证 = Certificates | **IKE/IPsec 建立成功** |

附注：
- `Set-VpnAuthProtocol -SharedSecret` 在本机**只改认证模式、不写入密钥**（本地 L2TP+PSK 测试始终 789，
  注册表与 `ias.xml` 中均无密钥），必须在 RRAS 控制台「安全」选项卡手工填入
- `UserAuthProtocolAccepted` 允许值为 `EAP / Certificate / MsChapv2 / Chap / PAP / PreSharedKey`，
  可分别与 PSK、证书客户端对齐

### 阶段 5：最终阻塞点 —— PPP 阶段（未解决）

手机使用 `IKEv2/IPSec RSA` + 客户端证书后，服务器日志出现：

```
RasMan 20209: 已建立 VPN 服务器与 VPN 客户端 <CLIENT_PUBLIC_IP> 之间的连接，
              但是无法完成 VPN 连接。
```

含义：**IKE 协商成功、IPsec 隧道建立、客户端证书被接受**，但随后的 **PPP 协商失败**。
抓包中 IKE_AUTH 之后双方停留在 ESP/PPP 数据上，服务器等不到 PPP 完成即超时。

结论：Windows RRAS 的 IKEv2 在隧道建立后依赖 **PPP** 完成地址分配与会话收尾，
HarmonyOS 的 `IKEv2/IPSec RSA` 客户端在这套流程中未配合 —— **协议实现层面的不兼容**，
继续调整 RRAS 参数收益很低。

### 失败原因汇总

| # | 原因 | 影响 | 状态 |
|---|---|---|---|
| 1 | `ModernStackEnabled=1` 导致 `RasMan` 711、端口为 0 | 服务端整体不可用 | 已修复 |
| 2 | 缺少 IPv4 路由与 NAT | 能连上但无网络 | 已修复 |
| 3 | IKEv2 默认策略（DH2/SHA1）与手机无交集 | 协商失败 | 已修复 |
| 4 | 手机不信任私有 CA | IKE_AUTH 前放弃 | 已修复（需装 CA） |
| 5 | CA 证书误入服务器证书候选 | 可能发错证书 | 已修复 |
| 6 | MSCHAPv2 客户端不满足证书隧道认证 | IKE_AUTH 被拒 | 已定位 |
| 7 | PSK 仅改模式未落库 | PSK 认证失败 | 已定位（需控制台设置） |
| 8 | **RRAS IKEv2 依赖 PPP，鸿蒙客户端不配合** | **PPP 超时（20209）** | **未解决** |

---

## 六、现状与后续建议

| 项目 | 状态 |
|---|---|
| RRAS 服务 | Running，Total Ports 449 |
| 443 / 500 / 4500 / 1701 | 正常监听 |
| 证书 | 2026 套件已就位 |
| Windows 客户端（SSTP） | ✅ 可用 |
| 华为手机 | ❌ 卡在 PPP |

后续建议（按性价比排序）：

1. 手机端改用其他接入方式（不在本文档展开）
2. 换服务端协议（SoftEther / OpenVPN / WireGuard）+ 对应手机 App
3. 若必须 Windows 原生：尝试 L2TP/IPSec PSK（华为官方文档支持该类型，取决于系统版本）

---

## 七、文件说明

```
vpn-config-2026/
├── server/
│   ├── 部署VPN服务器.ps1     一键重建（含 ModernStackEnabled 修复）
│   └── VPN-Monitor.ps1       监控面板（单实例 + 托盘 + 连接日志）
├── client-windows/
│   └── Setup-WindowsClient-2026.ps1   一键装证书 + 建连接 + 拨号
├── client-huawei/
│   └── Setup-HuaweiMate70-RSA.ps1     生成手机安装包 + 临时下载页
└── (证书文件未包含在仓库中，避免泄露服务器地址)
```

**未上传的安全内容**：

- 客户端证书私钥（`.p12`）—— 含私钥，不入库
- CA 私钥 —— 仅存在于服务器证书存储与受控备份
- VPN 账号密码 / 证书密码 —— 脚本中已替换为 `<REDACTED>`
- **服务器公网 IP / 内网 IP / 账号名** —— 已替换为 `<VPN_SERVER_IP>` / `<SERVER_INTERNAL_IP>` / `<VPN_USER>`
- **全部证书文件** —— 服务器证书含 IP，整个 certs 目录未入库

---

## 八、复现步骤

```powershell
# 1. 装角色
Install-WindowsFeature RemoteAccess, DirectAccess-VPN, Routing -IncludeManagementTools

# 2. 修 RasMan 711（必须，否则端口恒为 0）
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\RemoteAccess\Parameters' -Name ModernStackEnabled -Value 0 -Type DWord

# 3. 一键部署（CA、证书、443 绑定、地址池、账号、防火墙、启动脚本）
.\部署VPN服务器.ps1 -ServerAddress <VPN_SERVER_IP>

# 4. 开路由与 NAT（否则客户端无网络）
netsh ras set type ipv4rtrtype=lananddd ipv6rtrtype=none rastype=IPv4
New-NetNat -Name 'PhoebeVpnNat' -InternalIPInterfaceAddressPrefix '10.10.10.0/24'

# 5. 验证
netsh ras show status          # Total Ports 应为 4xx
Get-VpnServerConfiguration     # 算法策略
Get-VpnAuthProtocol            # 认证方式
```