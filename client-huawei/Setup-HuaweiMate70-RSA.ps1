<#
.SYNOPSIS
    生成华为 Mate 70 的 VPN 安装包（2026 证书版），并可启动临时下载页。
.DESCRIPTION
    把「证书」里的两个证书 + 安装指引 复制到「安装包-RSA-2026」，
    可选启动临时 HTTP 下载页给手机直接下载。
.EXAMPLE
    .\Setup-HuaweiMate70-RSA.ps1
    .\Setup-HuaweiMate70-RSA.ps1 -Serve -Minutes 60
#>
param(
    [switch]$Serve,
    [int]$Port = 8080,
    [int]$Minutes = 60
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$src  = Join-Path $root '证书'
$out  = Join-Path $root '安装包-RSA-2026'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

Say '====================================================' 'Cyan'
Say '  Phoebe VPN · 华为 Mate 70 安装包（2026 版）' 'Cyan'
Say '  IKEv2/IPSec RSA · 服务器 <VPN_SERVER_IP>' 'Cyan'
Say '====================================================' 'Cyan'
Say ''

$caFile  = Join-Path $src 'PhoebeVPN-RootCA-2026.crt'
$p12File = Join-Path $src 'PhoebePhone-2026.p12'
if (-not (Test-Path $caFile))  { Say "缺少根证书：$caFile" 'Red'; exit 1 }
if (-not (Test-Path $p12File)) { Say "缺少客户端证书：$p12File" 'Red'; exit 1 }

New-Item -ItemType Directory -Path $out -Force | Out-Null
Copy-Item "$src\*" $out -Recurse -Force
Copy-Item (Join-Path $root '安装指引-RSA.html') (Join-Path $out 'install-2026.html') -Force
Copy-Item (Join-Path $root '安装说明-RSA.txt')  (Join-Path $out '安装说明-2026.txt') -Force

Say '[1/2] 安装包已生成：' 'Green'
Get-ChildItem $out -File | ForEach-Object { "        $($_.Name)  ($([math]::Round($_.Length/1KB,1)) KB)" }
Say ''

Say '[2/2] 手机安装步骤（详细见 install-2026.html）' 'Green'
Say '   1) 装根证书     PhoebeVPN-RootCA-2026.crt -> 选「CA 证书」' 'White'
Say '   2) 装客户端证书 PhoebePhone-2026.p12      -> 选「VPN 和应用程序用户证书」，密码 <REDACTED>' 'White'
Say '   3) 添加 VPN     类型 IKEv2/IPSec RSA' 'White'
Say '      服务器 <VPN_SERVER_IP> / IPSec 标识符 <VPN_SERVER_IP>' 'White'
Say '      CA 证书 = Phoebe VPN Root CA 2026' 'White'
Say '      用户证书 = Phoebe-Phone-2026' 'White'
Say ''

if ($Serve) {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object {
               $_.IPAddress -ne '127.0.0.1' -and
               $_.IPAddress -notlike '169.254.*' -and
               $_.IPAddress -notlike '10.10.10.*' -and
               $_.InterfaceAlias -notmatch 'RAS|VPN|Phoebe'
           } | Select-Object -ExpandProperty IPAddress -Unique

    Say '============ 临时下载页已启动 ============' 'Cyan'
    foreach ($ip in $ips) { Say "    http://${ip}:$Port/" 'Green' }
    Say "    http://<VPN_SERVER_IP>:$Port/" 'Green'
    Say ''
    Say "    持续 $Minutes 分钟，Ctrl+C 结束；公网地址需腾讯云放行 TCP $Port" 'Gray'
    Say ''

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
    try { $listener.Start() } catch { Say "端口 $Port 监听失败：$($_.Exception.Message)" 'Red'; exit 1 }

    $types = @{ '.crt'='application/x-x509-ca-cert'; '.pem'='application/x-pem-file'; '.p12'='application/x-pkcs12'; '.html'='text/html; charset=utf-8'; '.txt'='text/plain; charset=utf-8' }
    $deadline = (Get-Date).AddMinutes($Minutes)

    while ((Get-Date) -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 150; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
            $requestLine = $reader.ReadLine()
            while ($true) { $l = $reader.ReadLine(); if ($null -eq $l -or $l -eq '') { break } }

            $path = 'install-2026.html'
            if ($requestLine -match '^GET\s+(\S+)') { $path = $Matches[1].Split('?')[0] }
            $path = [uri]::UnescapeDataString($path).TrimStart('/')
            if ([string]::IsNullOrWhiteSpace($path)) { $path = 'install-2026.html' }

            $file = Join-Path $out ($path -replace '/', '\')
            if (Test-Path -LiteralPath $file -PathType Leaf) {
                $bytes = [System.IO.File]::ReadAllBytes($file)
                $ext = [System.IO.Path]::GetExtension($file).ToLower()
                $ct = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
                $head = "HTTP/1.1 200 OK`r`nContent-Type: $ct`r`nContent-Length: $($bytes.Length)`r`nContent-Disposition: attachment; filename=`"$([System.IO.Path]::GetFileName($file))`"`r`nConnection: close`r`n`r`n"
                $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($hb, 0, $hb.Length)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                Say ("   [{0}] 已下载 {1}" -f (Get-Date -Format 'HH:mm:ss'), $path) 'DarkGray'
            } else {
                $body = [System.Text.Encoding]::UTF8.GetBytes('404 Not Found')
                $head = "HTTP/1.1 404 Not Found`r`nContent-Type: text/plain`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($hb, 0, $hb.Length)
                $stream.Write($body, 0, $body.Length)
                $stream.Flush()
            }
        } catch { }
        finally { $client.Close() }
    }
    $listener.Stop()
    Say ''
    Say "下载页已结束，文件仍在：$out" 'Yellow'
} else {
    Say '未启动下载页。需要手机直接下载时运行：' 'Yellow'
    Say '    .\Setup-HuaweiMate70-RSA.ps1 -Serve' 'Yellow'
}
