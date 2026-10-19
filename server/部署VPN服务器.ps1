<#
================================================================================
 RRAS VPN 服务器 —— 一键部署脚本 (Windows Server 2022)
================================================================================
 用途：系统重装后，用一条命令把 VPN 服务器完整建起来。

 在管理员 PowerShell 中运行：
     pwsh -NoProfile -ExecutionPolicy Bypass -File .\部署VPN服务器.ps1

 可选参数：
     -ServerAddress <VPN_SERVER_IP>    公网 IP（会写进证书 SAN 和客户端配置）
     -VpnUser <VPN_USER>                拨入账号名
     -VpnPassword 'xxx'              账号密码（不填则随机生成）
     -CertPassword 'xxx'             客户端证书 .p12 密码（不填则随机生成）
     -RebootAfter                    配置完成后自动重启

 它会完成：
   1. 检查/安装 RemoteAccess + DirectAccess-VPN + Routing 角色
   2. 校验 RasMan 是否正常（关键前置条件），异常会明确报错
   3. 建立私有根 CA (Phoebe Root CA)
   4. 签发服务器证书 (含 SAN: DNS+IP) 并绑定 443
   5. 签发客户端证书 (供手机/笔记本用)
   6. 配置 RRAS：SSTP + IKEv2，静态地址池
   7. 建立拨入账号并授权
   8. 放行防火墙端口
   9. 生成 vpn_start.cmd / watchdog / heartbeat（按需启动，关窗即停）
  10. 输出 phone_vpn\ 给你手机用

 重装后请先确认：RasMan 能启动。若这一步就失败，别继续，先反馈。
================================================================================
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ServerAddress = '<VPN_SERVER_IP>',
    [string]$VpnUser       = '<VPN_USER>',
    [string]$VpnPassword   = $null,
    [string]$CertPassword  = $null,
    [string]$OutDir        = 'C:\VPN',
    [switch]$RebootAfter
)

$ErrorActionPreference = 'Stop'
$script:Log = @()

function Say($msg, $color = 'Gray') {
    $line = "{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $msg
    Write-Host $line -ForegroundColor $color
    $script:Log += $line
}
function Head($t) { Write-Host ""; Write-Host ("=" * 70) -ForegroundColor White; Write-Host "  $t" -ForegroundColor White; Write-Host ("=" * 70) -ForegroundColor White }
function Ok($t)   { Say "[OK]   $t" 'Green' }
function Warn($t) { Say "[WARN] $t" 'Yellow' }
function Die($t)  { Say "[FAIL] $t" 'Red'; Say "已中止。请把上面的错误反馈回来。" 'Red'; exit 1 }

# ============================== 0. 前置检查 ==================================
Head "0. 前置检查"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Die "需要管理员权限，请用管理员 PowerShell 运行。" }

$os = Get-CimInstance Win32_OperatingSystem
Say "系统: $($os.Caption) build $($os.BuildNumber)"

if (-not $VpnPassword) {
    $VpnPassword = 'Vpn-' + (Get-Random -Minimum 100000 -Maximum 999999)
    Warn "未指定账号密码，已随机生成: $VpnPassword"
}
if (-not $CertPassword) {
    $CertPassword = 'Cert-' + (Get-Random -Minimum 100000 -Maximum 999999)
    Warn "未指定证书密码，已随机生成: $CertPassword"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $OutDir 'phone_vpn') -Force | Out-Null
Ok "工作目录: $OutDir"

# ============================== 1. 安装角色 ==================================
Head "1. 安装 RemoteAccess 角色"

$need = Get-WindowsFeature RemoteAccess, RemoteAccessServer, DirectAccess-VPN, Routing, RasRoutingProtocols -ErrorAction SilentlyContinue
$missing = $need | Where-Object { $_.InstallState -ne 'Installed' }
if ($missing) {
    Say "需要安装: $($missing.Name -join ', ')"
    $r = Install-WindowsFeature RemoteAccess, DirectAccess-VPN, Routing -IncludeManagementTools
    if (-not $r.Success) { Die "角色安装失败: $($r.ExitCode)" }
    if ($r.RestartNeeded -eq 'Yes') {
        Warn "安装角色需要重启。正在重启，请重启后重新运行本脚本。"
        Restart-Computer -Force
        exit 0
    }
    Ok "角色安装完成"
} else {
    Ok "角色已就绪"
}

Import-Module RemoteAccess -SkipEditionCheck -ErrorAction SilentlyContinue

# ============================== 2. 校验 RasMan (关键) ========================
Head "2. 校验 RasMan —— 这是整个方案的前提"

foreach ($s in @('SstpSvc','RasMan','IKEEXT')) {
    $cur = (Get-Service $s -ErrorAction SilentlyContinue).StartType
    if ($cur -ne 'Automatic') { sc.exe config $s start= auto | Out-Null }
}
sc.exe config RasMan start= auto | Out-Null     # RRAS 需要 RasMan 常驻（见下方说明）
Start-Sleep -Seconds 1

$started = $false
for ($i = 1; $i -le 3; $i++) {
    if ((Get-Service RasMan).Status -ne 'Running') { net start RasMan 2>&1 | Out-Null }
    Start-Sleep -Seconds 2
    if ((Get-Service RasMan).Status -eq 'Running') { $started = $true; break }
}

if (-not $started) {
    Say "RasMan 启动失败。最近的相关事件：" 'Red'
    Get-WinEvent -LogName System -MaxEvents 200 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -eq 7024 } | Select-Object -First 3 |
        ForEach-Object { Say ("  " + (($_.Message -split "`r?`n") -join ' ')) 'Red' }
    Die "RasMan 无法启动。重装后的系统不应出现这种情况 —— 请把这段输出反馈回来。"
}
Ok "RasMan 正常运行"

# ====================== 2.5 关闭 RRAS「现代栈」(关键修复) ====================
Head "2.5 关闭 RRAS 现代栈 (ModernStackEnabled=0)"

# 这台机器上的实测结论：RRAS VPN 角色安装后会把 ModernStackEnabled 置 1，
# 此时 RasMan 启动即报 711 {TDI 事件尚未完成} 并退出，导致 netsh 报
# Total Ports: 0、客户端连不上。把它改成 0（传统栈）后 RasMan 正常工作、
# 端口恢复为 SSTP/PPTP/IKEv2 各 128 个。此设置重装系统后同样需要。
$raKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\RemoteAccess\Parameters'
$cur = (Get-ItemProperty -Path $raKey -Name ModernStackEnabled -ErrorAction SilentlyContinue).ModernStackEnabled
if ($cur -ne 0) {
    Say "ModernStackEnabled = $cur -> 0（开启后将导致 RasMan 711）" 'Yellow'
    Set-ItemProperty -Path $raKey -Name ModernStackEnabled -Value 0 -Type DWord
    Ok "已切回传统栈"
} else {
    Ok "已在传统栈"
}

# ============================== 3. 建立根 CA =================================
Head "3. 建立私有根 CA"

$caSubject = 'CN=Phoebe Root CA'
$ca = Get-ChildItem Cert:\LocalMachine\My |
      Where-Object { $_.Subject -eq $caSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddYears(2) } |
      Select-Object -First 1

if ($ca) {
    Ok "已存在根 CA: $($ca.Thumbprint)"
} else {
    Say "创建新的根 CA ..."
    $ca = New-SelfSignedCertificate `
        -Subject $caSubject `
        -KeyUsage CertSign, CRLSign, DigitalSignature `
        -KeyAlgorithm RSA -KeyLength 4096 `
        -HashAlgorithm SHA256 `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(10) `
        -TextExtension @('2.5.29.19={critical}{text}ca=1&pathlength=1')
    Ok "根 CA 已创建: $($ca.Thumbprint)"
}

# 根 CA 装入受信任根存储
if (-not (Test-Path "Cert:\LocalMachine\Root\$($ca.Thumbprint)")) {
    $tmp = Join-Path $env:TEMP 'phoebe-ca.cer'
    [System.IO.File]::WriteAllBytes($tmp, $ca.Export('Cert'))
    Import-Certificate -FilePath $tmp -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
    Remove-Item $tmp -Force
    Ok "根 CA 已加入受信任根存储"
} else {
    Ok "根 CA 已在受信任根存储"
}

# ============================== 4. 服务器证书 ================================
Head "4. 签发服务器证书并绑定 443"

$serverCert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object {
        $_.Subject -eq "CN=$ServerAddress" -and $_.HasPrivateKey -and
        $_.Issuer -match 'Phoebe Root CA' -and $_.NotAfter -gt (Get-Date).AddYears(1)
    } | Sort-Object NotAfter -Descending | Select-Object -First 1

if ($serverCert) {
    Ok "已存在服务器证书: $($serverCert.Thumbprint)"
} else {
    Say "签发服务器证书 (SAN 含 DNS 和 IP) ..."
    $serverCert = New-SelfSignedCertificate `
        -Subject "CN=$ServerAddress" `
        -Signer $ca `
        -KeyAlgorithm RSA -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(3) `
        -TextExtension @(
            "2.5.29.17={text}DNS=$ServerAddress&IPAddress=$ServerAddress",
            '2.5.29.37={text}1.3.6.1.5.5.7.3.1'
        )
    Ok "服务器证书已签发: $($serverCert.Thumbprint)"
}

# 绑定到 443（SSTP 用）
netsh http delete sslcert ipport=0.0.0.0:443 2>&1 | Out-Null
netsh http delete sslcert ipport='[::]:443'  2>&1 | Out-Null
$bind = netsh http add sslcert ipport=0.0.0.0:443 `
    certhash=$($serverCert.Thumbprint) `
    appid='{ba195980-cd49-458b-9e23-c84ee0adcd75}' certstorename=MY 2>&1 | Out-String
if ($bind -match 'successfully|成功') { Ok "443 证书绑定成功" } else { Warn "443 绑定返回: $($bind.Trim())" }

# ============================== 5. 客户端证书 ================================
Head "5. 签发客户端证书"

$clientCert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq 'CN=Phoebe-Phone' -and $_.HasPrivateKey -and $_.Issuer -match 'Phoebe Root CA' } |
    Select-Object -First 1

if ($clientCert) {
    Ok "已存在客户端证书: $($clientCert.Thumbprint)"
} else {
    $clientCert = New-SelfSignedCertificate `
        -Subject 'CN=Phoebe-Phone' `
        -Signer $ca `
        -KeyAlgorithm RSA -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -NotAfter (Get-Date).AddYears(3) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.2')
    Ok "客户端证书已签发: $($clientCert.Thumbprint)"
}

# ============================== 6. 配置 RRAS =================================
Head "6. 配置 RRAS (SSTP + IKEv2)"

$vpnInstalled = $false
try { $vpnInstalled = ((Get-RemoteAccess -ErrorAction Stop).VpnStatus -eq 'Installed') } catch { }

if (-not $vpnInstalled) {
    Say "安装 VPN 角色 ..."
    Install-RemoteAccess -VpnType Vpn | Out-Null
    Start-Sleep -Seconds 8
    Ok "VPN 角色安装完成"

    # 安装后 RRAS 可能会再次把 RasMan 关掉，这里兜底拉起（端口由 RasMan 创建）
    sc.exe config RasMan start= auto | Out-Null
    if ((Get-Service RasMan).Status -ne 'Running') {
        net start RasMan 2>&1 | Out-Null
        Start-Sleep -Seconds 5
    }
    if ((Get-Service RasMan).Status -eq 'Running') { Ok "RasMan 运行中" } else { Warn "RasMan 未运行，端口可能为 0" }
} else {
    Ok "VPN 角色已安装"
}

Say "设置地址池 10.10.10.10 - 10.10.10.200 ..."
Set-VpnIPAddressAssignment -IPAssignmentMethod StaticPool `
    -IPAddressRange '10.10.10.10','10.10.10.200' -ErrorAction SilentlyContinue | Out-Null

Say "设置端口数 (SSTP 128 / IKEv2 128 / L2TP 0) ..."
Set-VpnServerConfiguration -TunnelType Ikev2 -Ikev2Ports 128 -ErrorAction SilentlyContinue | Out-Null
Set-VpnServerConfiguration -TunnelType L2tp  -L2tpPorts  0   -ErrorAction SilentlyContinue | Out-Null

# 重启 RRAS 让配置生效
Restart-Service RemoteAccess -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6

$status = netsh ras show status 2>&1 | Out-String
$total = ($status | Select-String -Pattern 'Total Ports\s*:\s*(\d+)').Matches
$portCount = if ($total) { [int]$total.Groups[1].Value } else { -1 }
if ($portCount -gt 0) {
    Ok "RAS 端口可用: $portCount 个"
} else {
    Warn "RAS 端口为 0 —— RRAS 可能仍不正常，请反馈"
}

# ============================== 7. 拨入账号 ==================================
Head "7. 建立拨入账号"

if (Get-LocalUser -Name $VpnUser -ErrorAction SilentlyContinue) {
    Say "账号已存在，更新密码 ..."
    Set-LocalUser -Name $VpnUser -Password (ConvertTo-SecureString $VpnPassword -AsPlainText -Force)
} else {
    New-LocalUser -Name $VpnUser `
        -Password (ConvertTo-SecureString $VpnPassword -AsPlainText -Force) `
        -PasswordNeverExpires -Description 'VPN dial-in account' | Out-Null
}
Start-Sleep -Seconds 2
netsh ras set user $VpnUser permit | Out-Null
Ok "账号 $VpnUser 已就绪并授予拨入权限"

# ============================== 8. 防火墙 ====================================
Head "8. 放行防火墙端口"

$rules = @(
    @{n='VPN-SSTP-TCP443'; p='TCP'; port=443},
    @{n='VPN-PPTP-TCP1723'; p='TCP'; port=1723},
    @{n='VPN-L2TP-UDP1701'; p='UDP'; port=1701},
    @{n='VPN-IKE-UDP500'; p='UDP'; port=500},
    @{n='VPN-NATT-UDP4500'; p='UDP'; port=4500},
    @{n='VPN-GRE'; p='GRE'; port=$null}
)
foreach ($r in $rules) {
    if (Get-NetFirewallRule -DisplayName $r.n -ErrorAction SilentlyContinue) { continue }
    if ($r.p -eq 'GRE') {
        New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol 47 -Action Allow | Out-Null
    } else {
        New-NetFirewallRule -DisplayName $r.n -Direction Inbound -Protocol $r.p `
            -LocalPort $r.port -Action Allow | Out-Null
    }
}
Ok "防火墙规则已建立 (6 条)"

# ============================== 9. 按需启动脚本 ==============================
Head "9. 生成按需启动的 BAT"

$hb = @'
param([Parameter(Mandatory=$true)][string]$StateFile)
$ErrorActionPreference = 'SilentlyContinue'
while ($true) {
    try { [System.IO.File]::WriteAllText($StateFile, [datetime]::UtcNow.ToString('o')) } catch { }
    Start-Sleep -Seconds 3
}
'@
[System.IO.File]::WriteAllText((Join-Path $OutDir 'vpn_heartbeat.ps1'), $hb, (New-Object System.Text.UTF8Encoding($false)))

$wd = @'
param([Parameter(Mandatory=$true)][string]$StateFile)
$ErrorActionPreference = 'SilentlyContinue'
$svcs = @('RemoteAccess','SstpSvc','RasMan')
$staleSeconds = 20
$graceSeconds = 15
$log = Join-Path (Split-Path -Parent $StateFile) 'vpn_watchdog.log'
function Log($m) { try { Add-Content -Path $log -Value ("{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $m) -Encoding UTF8 } catch { } }
function Stop-Vpn { foreach ($s in $svcs) { $b = (Get-Service -Name $s).Status; Stop-Service -Name $s -Force -ErrorAction SilentlyContinue; Log ("  {0}: {1} -> {2}" -f $s, $b, (Get-Service -Name $s).Status) } }
$deadline = (Get-Date).AddSeconds($graceSeconds)
while ($true) {
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath $StateFile)) {
        if ((Get-Date) -gt $deadline) { break } else { continue }
    }
    $stamp = $null
    try { $stamp = [datetime]::Parse((Get-Content -LiteralPath $StateFile -Raw).Trim(),
              [System.Globalization.CultureInfo]::InvariantCulture) } catch { $stamp = $null }
    if ($null -eq $stamp) { if ((Get-Date) -gt $deadline) { break } else { continue } }
    $age = ([datetime]::UtcNow - $stamp.ToUniversalTime()).TotalSeconds
    if ($age -gt $staleSeconds) { break }
}
Stop-Vpn
Log 'VPN stopped (window closed)'
'@
[System.IO.File]::WriteAllText((Join-Path $OutDir 'vpn_watchdog.ps1'), $wd, (New-Object System.Text.UTF8Encoding($false)))

$bat = @'
@echo off
title VPN Server (RRAS SSTP) - closing this window stops the VPN
setlocal EnableExtensions
set "SVC_LIST=RasMan RemoteAccess SstpSvc"
set "BASE=%~dp0"
set "STATE=%BASE%vpn_heartbeat.txt"
set "TASK=VPN_RRAS_Watchdog"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

echo ============================================================
echo   RRAS VPN Server  -  on-demand launcher
echo   Server : __SERVER__      Protocol : SSTP (TCP 443)
echo   Account: __USER__
echo   Closing this window STOPS the VPN and releases TCP 443.
echo ============================================================
echo.

net session >nul 2>&1
if errorlevel 1 ( echo [ERROR] Run as administrator. & pause & exit /b 1 )

echo [1/4] Starting services ...
for %%S in (%SVC_LIST%) do (
    sc query %%S | find /i "RUNNING" >nul 2>&1
    if not errorlevel 1 ( echo       - %%S : already running ) else (
        sc start %%S >nul 2>&1
        if errorlevel 1 ( echo       - %%S : FAILED ) else ( echo       - %%S : started )
    )
)

echo.
echo [2/4] Waiting for TCP 443 ...
set /a _t=0
:wp
set /a _t+=1
netstat -ano -p TCP | findstr /r /c:"LISTENING" | findstr /r /c:":443 " >nul 2>&1
if not errorlevel 1 goto pok
if %_t% GEQ 30 goto pfail
timeout /t 1 /nobreak >nul
goto wp
:pok
echo       - SSTP listener UP. VPN ONLINE.
goto arm
:pfail
echo       - WARNING: TCP 443 not up in 30s. Run: Get-RemoteAccessHealth

:arm
echo.
echo [3/4] Arming watchdog ...
del "%BASE%vpn_watchdog.log" >nul 2>&1
> "%STATE%" echo 1970-01-01T00:00:00Z
start "" /b "%PS%" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%BASE%vpn_heartbeat.ps1" -StateFile "%STATE%"
set "WDCMD=%PS% -NoProfile -ExecutionPolicy Bypass -File '%BASE%vpn_watchdog.ps1' -StateFile '%STATE%'"
schtasks /delete /tn "%TASK%" /f >nul 2>&1
schtasks /create /tn "%TASK%" /tr "%WDCMD%" /sc once /st 23:59 /ru SYSTEM /f >nul 2>&1
schtasks /run /tn "%TASK%" >nul 2>&1
echo       - watchdog armed (Session 0)

echo.
echo [4/4] KEEP THIS WINDOW OPEN. Close it to stop the VPN.
echo.
:loop
timeout /t 5 /nobreak >nul
goto loop
'@

$bat = $bat.Replace('__SERVER__', $ServerAddress).Replace('__USER__', $VpnUser)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'vpn_start.cmd'), $bat, [System.Text.Encoding]::ASCII)
Ok "已生成: vpn_start.cmd / vpn_watchdog.ps1 / vpn_heartbeat.ps1"

# ============================== 10. 手机文件 =================================
Head "10. 生成手机配置文件"

$phoneDir = Join-Path $OutDir 'phone_vpn'
[System.IO.File]::WriteAllBytes((Join-Path $phoneDir 'Phoebe-Root-CA.crt'), $ca.Export('Cert'))

$pfx = $clientCert.Export('Pfx', $CertPassword)
[System.IO.File]::WriteAllBytes((Join-Path $phoneDir 'Phoebe-Phone.p12'), $pfx)

$rootB64   = [Convert]::ToBase64String($ca.Export('Cert'))
$clientB64 = [Convert]::ToBase64String($pfx)
$u1 = [guid]::NewGuid().ToString().ToUpper()
$u2 = [guid]::NewGuid().ToString().ToUpper()
$u3 = [guid]::NewGuid().ToString().ToUpper()
$u4 = [guid]::NewGuid().ToString().ToUpper()

$mc = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadCertificateFileName</key><string>Phoebe-Root-CA.crt</string>
			<key>PayloadContent</key><data>
$rootB64
			</data>
			<key>PayloadDisplayName</key><string>Phoebe Root CA</string>
			<key>PayloadIdentifier</key><string>com.phoebe.vpn.rootca</string>
			<key>PayloadType</key><string>com.apple.security.root</string>
			<key>PayloadUUID</key><string>$u1</string>
			<key>PayloadVersion</key><integer>1</integer>
		</dict>
		<dict>
			<key>PayloadCertificateFileName</key><string>Phoebe-Phone.p12</string>
			<key>PayloadContent</key><data>
$clientB64
			</data>
			<key>Password</key><string>$CertPassword</string>
			<key>PayloadDisplayName</key><string>Phoebe-Phone 客户端证书</string>
			<key>PayloadIdentifier</key><string>com.phoebe.vpn.clientcert</string>
			<key>PayloadType</key><string>com.apple.security.pkcs12</string>
			<key>PayloadUUID</key><string>$u2</string>
			<key>PayloadVersion</key><integer>1</integer>
		</dict>
		<dict>
			<key>UserDefinedName</key><string>Phoebe VPN</string>
			<key>PayloadDisplayName</key><string>Phoebe VPN</string>
			<key>PayloadIdentifier</key><string>com.phoebe.vpn.ikev2</string>
			<key>PayloadType</key><string>com.apple.vpn.managed</string>
			<key>PayloadUUID</key><string>$u3</string>
			<key>PayloadVersion</key><integer>1</integer>
			<key>VPNType</key><string>IKEv2</string>
			<key>IKEv2</key>
			<dict>
				<key>AuthenticationMethod</key><string>Certificate</string>
				<key>RemoteAddress</key><string>$ServerAddress</string>
				<key>LocalIdentifier</key><string>CN=Phoebe-Phone</string>
				<key>RemoteIdentifier</key><string>$ServerAddress</string>
				<key>PayloadCertificateAnchorUUID</key><array><string>$u1</string></array>
				<key>ServerCertificateIssuerCommonName</key><string>Phoebe Root CA</string>
				<key>ExtendedAuthEnabled</key><integer>0</integer>
				<key>EnablePFS</key><integer>1</integer>
			</dict>
		</dict>
	</array>
	<key>PayloadDisplayName</key><string>Phoebe VPN 配置</string>
	<key>PayloadIdentifier</key><string>com.phoebe.vpn.profile</string>
	<key>PayloadOrganization</key><string>Phoebe</string>
	<key>PayloadRemovalDisallowed</key><false/>
	<key>PayloadType</key><string>Configuration</string>
	<key>PayloadUUID</key><string>$u4</string>
	<key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
"@
[System.IO.File]::WriteAllText((Join-Path $phoneDir 'VPN.mobileconfig'), $mc, (New-Object System.Text.UTF8Encoding($false)))

$readme = @"
================================================================
 华为 Mate 70 连接 Phoebe VPN
================================================================
服务器   : $ServerAddress
协议     : IKEv2（证书认证）
账号     : $VpnUser / $VpnPassword
证书密码 : $CertPassword

安装顺序（不能变）：
  1. Phoebe-Root-CA.crt        设置 -> 安全 -> 加密和凭据 -> 安装 CA 证书
  2. Phoebe-Phone.p12          同路径 -> 安装 VPN/客户端证书，密码 $CertPassword
  3. VPN.mobileconfig          安装描述文件（若装不上，见下方手动配置）

手动配置（描述文件装不上时用）：
  设置 -> 更多连接 -> VPN -> 添加 VPN 网络
    名称        : Phoebe VPN
    类型        : IKEv2
    服务器地址  : $ServerAddress
    IPsec 标识符: $ServerAddress
    用户证书    : Phoebe-Phone
    IKEv2 认证  : 证书

注意：连接前需先在服务器上双击 vpn_start.cmd 启动 VPN。
      服务器没启动时端口是关闭的，连不上是正常的。
================================================================
"@
[System.IO.File]::WriteAllText((Join-Path $phoneDir '安装说明.txt'), $readme, (New-Object System.Text.UTF8Encoding($true)))
Ok "手机文件已生成: $phoneDir"

# ============================== 汇总 =========================================
Head "部署完成"

$summary = @"

------------------------------------------------------------
  服务器地址 : $ServerAddress
  VPN 协议   : SSTP (TCP 443) + IKEv2
  地址池     : 10.10.10.10 - 10.10.10.200
  账号       : $VpnUser
  账号密码   : $VpnPassword
  证书密码   : $CertPassword
  RAS 端口   : $portCount
------------------------------------------------------------
  启动 VPN   : 双击 $OutDir\vpn_start.cmd
  关闭 VPN   : 关闭那个窗口（约 20 秒后自动停止）
  手机文件   : $phoneDir
------------------------------------------------------------

  别忘了在腾讯云控制台放行：TCP 443、UDP 500、UDP 4500
------------------------------------------------------------
"@
Write-Host $summary -ForegroundColor Cyan

$script:Log += $summary
[System.IO.File]::WriteAllLines((Join-Path $OutDir '部署报告.txt'), $script:Log, (New-Object System.Text.UTF8Encoding($true)))
Ok "部署报告: $OutDir\部署报告.txt"

if ($RebootAfter) {
    Warn "10 秒后重启 ..."
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
