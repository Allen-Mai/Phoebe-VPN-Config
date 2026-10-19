<#
.SYNOPSIS
    一键配置 Windows 客户端 VPN（SSTP），适用于 Win7/Win10/Win11/Server。

.DESCRIPTION
    在【客户端电脑】上、以管理员身份运行。脚本会：
      1. 安装 Phoebe Root CA 根证书（不装会报「证书不受信任」）
      2. 创建名为 "Phoebe VPN" 的 SSTP 连接
      3. 用内置账号自动拨号，并显示拿到的内网 IP

.PARAMETER FullTunnel
    默认是「拆分隧道」：只有访问服务器/内网的流量走 VPN，上网照旧。
    加上此开关后所有流量都走 VPN（服务器在海外时可用）。

.PARAMETER SkipDial
    只创建连接，不自动拨号。

.EXAMPLE
    .\Setup-WindowsClient.ps1
    .\Setup-WindowsClient.ps1 -FullTunnel
    .\Setup-WindowsClient.ps1 -ServerAddress <VPN_SERVER_IP> -UserName <VPN_USER> -Password <REDACTED>
#>
[CmdletBinding()]
param(
    [string]$ServerAddress  = '<VPN_SERVER_IP>',
    [string]$ConnectionName = 'Phoebe VPN',
    [string]$UserName       = '<VPN_USER>',
    [string]$Password       = '<见服务器 C:\VPN\部署报告.txt>',
    [switch]$FullTunnel,
    [switch]$SkipDial
)

$ErrorActionPreference = 'Continue'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Fail([string]$m) { Say ""; Say $m 'Red'; Say ""; exit 1 }

Say "================================================================" 'Cyan'
Say "   Phoebe VPN  -  Windows 客户端一键配置" 'Cyan'
Say "   服务器: $ServerAddress    协议: SSTP (TCP 443)" 'Cyan'
Say "================================================================" 'Cyan'
Say ""

# ---------------------------------------------------------------- 1. 管理员（自动提权）
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say '需要管理员权限，正在弹出 UAC 授权窗口...' 'Yellow'
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    } catch {
        Fail '提权被取消。请右键本脚本 -> 「以管理员身份运行」。'
    }
    exit
}
Say "[1/5] 管理员权限检查通过" 'Green'

# ---------------------------------------------------------------- 2. 根证书
$cerPath = Join-Path $PSScriptRoot '证书\PhoebeVPN-RootCA-2026.crt'
if (-not (Test-Path -LiteralPath $cerPath)) {
    Fail "找不到根证书文件：$cerPath`n请确认脚本和「证书」文件夹在一起。"
}
try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($cerPath)
} catch {
    Fail "根证书读取失败：$($_.Exception.Message)"
}

if (Test-Path "Cert:\LocalMachine\Root\$($cert.Thumbprint)") {
    Say "[2/5] 根证书已存在（$($cert.Thumbprint.Substring(0,8))...），跳过" 'Green'
} else {
    Import-Certificate -FilePath $cerPath -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
    Say "[2/5] 根证书已安装到「受信任的根证书颁发机构」" 'Green'
}

# ---------------------------------------------------------------- 3. 建连接
if (Get-VpnConnection -Name $ConnectionName -ErrorAction SilentlyContinue) {
    Remove-VpnConnection -Name $ConnectionName -Force -ErrorAction SilentlyContinue
    Say "[3/5] 已删除旧的同名连接，准备重建" 'Yellow'
}

try {
    Add-VpnConnection -Name $ConnectionName -ServerAddress $ServerAddress `
        -TunnelType Sstp -AuthenticationMethod MSChapv2 `
        -RememberCredential -SplitTunneling:(-not $FullTunnel) -Force -ErrorAction Stop
    $mode = if ($FullTunnel) { '全局流量' } else { '拆分隧道（仅内网）' }
    Say "[3/5] 连接已创建：$ConnectionName  ->  $ServerAddress  [$mode]" 'Green'
} catch {
    Fail "创建 VPN 连接失败：$($_.Exception.Message)"
}

if ($SkipDial) {
    Say ""
    Say "已按要求跳过拨号。可到「设置 -> 网络和 Internet -> VPN」手动连接。" 'Yellow'
    exit 0
}

# ---------------------------------------------------------------- 4. 拨号
Say "[4/5] 正在拨号（通常 3-10 秒）..." 'Yellow'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$out = (rasdial $ConnectionName $UserName $Password 2>&1 | Out-String).Trim()
$code = $LASTEXITCODE
$sw.Stop()

if ($code -ne 0) {
    Say ""
    if ($out) { Say $out 'Red' }
    Say ""
    Say "拨号失败（错误码 $code），常见原因：" 'Yellow'
    switch ($code) {
        691 { Say "  691  用户名或密码错误（当前：$UserName）" }
        812 { Say "  812  被服务器的远程访问策略拒绝（检查账号拨入权限）" }
        868 { Say "  868  无法解析服务器地址（DNS 或网络不通）" }
        809 { Say "  809  服务器无响应：服务器上的 VPN 没启动，或 TCP 443 被防火墙拦截" }
        789 { Say "  789  L2TP/IPsec 协商失败（本连接用的是 SSTP，不该出现）" }
        720 { Say "  720  没有可用的 PPP/EAP 设备（重启后重试）" }
        default { Say "  请把上面完整输出发给管理员排查" }
    }
    Say ""
    Say "排查提示：" 'DarkGray'
    Say "  - 服务器端需要先双击桌面「启动VPN.cmd」把 VPN 服务拉起来" 'DarkGray'
    Say "  - 腾讯云防火墙需放行 TCP 443" 'DarkGray'
    exit 1
}

Say ("[4/5] 拨号成功，用时 {0:N1} 秒" -f $sw.Elapsed.TotalSeconds) 'Green'

# ---------------------------------------------------------------- 5. 验证
$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
       Where-Object { $_.IPAddress -like '10.10.10.*' } |
       Where-Object { $_.InterfaceAlias -notmatch 'RAS \(Dial In\)' }
Say ""
if ($ips) {
    foreach ($ip in $ips) {
        Say ("[5/5] 已获得内网地址：{0}（{1}）" -f $ip.IPAddress, $ip.InterfaceAlias) 'Green'
    }
} else {
    Say "[5/5] 已连接，但未读到 10.10.10.x 地址，请用 ipconfig 复核" 'Yellow'
}

# 让图形界面也能直接连接（保存凭据）
cmdkey /generic:$ConnectionName /user:$UserName /pass:$Password 2>&1 | Out-Null

Say ""
Say "================================================================" 'Cyan'
Say "  连接成功！" 'Green'
Say "  - 以后连接：设置 -> 网络和 Internet -> VPN -> $ConnectionName" 'Cyan'
Say "  - 断开    ：rasdial `"$ConnectionName`" /disconnect" 'Cyan'
Say "  - 查看状态：Get-VpnConnection -Name `"$ConnectionName`"" 'Cyan'
Say "================================================================" 'Cyan'
