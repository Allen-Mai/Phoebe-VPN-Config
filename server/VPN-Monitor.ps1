<#
.SYNOPSIS
    Phoebe VPN 监控面板（单实例 + 系统托盘 + 连接日志/错误码）
.DESCRIPTION
    - 同一时间只允许运行一个面板（重复双击会提示并退出）
    - 点 X 隐藏到托盘，VPN 继续运行；托盘菜单可恢复/启动/停止/退出
    - 实时显示服务状态、RAS 端口、在线客户端
    - 下方"连接日志"区显示认证成功/失败事件，失败带原因码与中文说明
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- 管理员自提升
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`"" `
            -Verb RunAs
    } catch { }
    exit
}

# ---------------------------------------------------------------- 单实例
$mutex = New-Object System.Threading.Mutex($false, 'Global\PhoebeVpnMonitor')
$showEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Global\PhoebeVpnShow')
if (-not $mutex.WaitOne(0)) {
    # 已经有一个面板在运行：通知它把窗口显示出来，然后安静退出
    try { [void]$showEvent.Set() } catch { }
    exit
}

$script:LogFile = 'C:\VPN\监控面板.log'
function Write-Log([string]$m) {
    try { Add-Content -Path $script:LogFile -Value ("{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch { }
}

$script:ServerAddress = '<VPN_SERVER_IP>'
$script:UserName      = '<VPN_USER>'
$script:Exiting       = $false

try { Import-Module RemoteAccess -SkipEditionCheck -ErrorAction SilentlyContinue } catch { }

# ---------------------------------------------------------------- 服务控制
function Start-VpnServices {
    foreach ($s in @('RasMan', 'SstpSvc', 'RemoteAccess')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.Status -ne 'Running') {
            try { Start-Service -Name $s -ErrorAction Stop; Write-Log "启动服务 $s" } catch { Write-Log "启动 $s 失败: $($_.Exception.Message)" }
            Start-Sleep -Milliseconds 600
        }
    }
    Start-Sleep -Seconds 3
    Write-Log 'VPN 服务启动流程完成'
}

function Stop-VpnServices {
    foreach ($s in @('RemoteAccess', 'SstpSvc', 'RasMan')) {
        $svc = Get-Service -Name $s -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.Status -eq 'Running') {
            try { Stop-Service -Name $s -Force -ErrorAction Stop; Write-Log "停止服务 $s" } catch { Write-Log "停止 $s 失败: $($_.Exception.Message)" }
        }
    }
    Write-Log 'VPN 服务已停止'
}

function Get-VpnSnapshot {
    $ra = Get-Service -Name RemoteAccess -ErrorAction SilentlyContinue
    $running = ($ra -and $ra.Status -eq 'Running')
    $ports = 0
    if ($running) {
        $out = (netsh ras show status 2>&1 | Out-String)
        if ($out -match '(Total Ports|端口总数)\s*[:：]\s*(\d+)') { $ports = [int]$Matches[2] }
    }
    $clients = @()
    if ($running) {
        try { $clients = @(Get-RemoteAccessConnectionStatistics -ErrorAction Stop) } catch { $clients = @() }
    }
    [pscustomobject]@{ Running = $running; Ports = $ports; Clients = $clients }
}

# ---------------------------------------------------------------- 日志采集
$script:SeenKeys  = New-Object 'System.Collections.Generic.HashSet[string]'
$script:Since     = (Get-Date).AddSeconds(-20)
$script:LastError = ''
$script:PrevClients = @{}
$script:LastIkeAlert = [datetime]::MinValue

$reasonMap = @{
    16   = '凭据错误（用户名/密码或证书无效）'
    18   = '连接被策略拒绝'
    65   = '访问被安全策略拒绝'
    66   = '该用户没有拨入权限'
    67   = '没有匹配的远程访问策略'
    265  = 'EAP 认证失败'
    266  = 'EAP 类型不被支持'
    4128 = '客户端证书无效或不受信任'
    4132 = '证书链验证失败'
    4149 = '证书已过期'
}

function Get-ReasonCode([string]$msg) {
    if ($msg -match '(?:原因代码|Reason Code|原因)[^0-9A-Fa-f]{0,12}(0x[0-9A-Fa-f]{1,8})') { return $Matches[1] }
    if ($msg -match '0x([0-9A-Fa-f]{1,8})') { return "0x$($Matches[1])" }
    return ''
}

function Get-UserNameFromMsg([string]$msg) {
    if ($msg -match '(?:用户名|User Name|用户)\s*[:：]\s*([^\s,，;；]+)') { return $Matches[1] }
    return ''
}

function New-LogRow($e) {
    $time = $e.TimeCreated.ToString('HH:mm:ss')
    $msg  = ($e.Message -replace "`r?`n", ' ')
    $kind = '信息'
    $desc = ''

    switch ($e.Id) {
        6272 {
            $kind = '成功'
            $u = Get-UserNameFromMsg $msg
            $desc = '认证通过' + $(if ($u) { "：$u" } else { '' })
        }
        6273 {
            $kind = '失败'
            $u  = Get-UserNameFromMsg $msg
            $rc = Get-ReasonCode $msg
            $num = 0
            if ($rc) { try { $num = [Convert]::ToInt32($rc.Replace('0x', ''), 16) } catch { $num = 0 } }
            $cn = if ($reasonMap.ContainsKey($num)) { $reasonMap[$num] } else { '认证被拒绝' }
            $desc = "$cn" + $(if ($u) { "（用户 $u）" } else { '' }) + $(if ($rc) { " 原因码 $rc" } else { '' })
        }
        6274 {
            $kind = '失败'
            $desc = '账号被锁定'
        }
        default {
            if ($e.LevelDisplayName -match '错误|Error') { $kind = '失败' }
            elseif ($e.LevelDisplayName -match '警告|Warning') { $kind = '警告' }
            $short = if ($msg.Length -gt 110) { $msg.Substring(0, 110) + '…' } else { $msg }
            $desc = "[$($e.Id)] $short"
        }
    }
    [pscustomobject]@{ Time = $time; Kind = $kind; EventId = $e.Id; Desc = $desc }
}

function Get-NewLogRows {
    $rows = @()
    $specs = @(
        @{ Log = 'Security'; Ids = @(6272, 6273, 6274) },
        @{ Log = 'Microsoft-Windows-RemoteAccess-RemoteAccessServer/Admin'; Ids = $null },
        @{ Log = 'Microsoft-Windows-RemoteAccess-RemoteAccessServer/Operational'; Ids = $null },
        @{ Log = 'Microsoft-Windows-IKE/Operational'; Ids = $null }
    )
    foreach ($spec in $specs) {
        try {
            $filter = @{ LogName = $spec.Log; StartTime = $script:Since }
            if ($spec.Ids) { $filter.Id = $spec.Ids }
            $evts = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop
        } catch { continue }
        foreach ($e in $evts) {
            $key = "$($spec.Log)|$($e.RecordId)"
            if ($script:SeenKeys.Add($key)) {
                if ($spec.Log -like '*IKE*' -and $e.Id -eq 1013) { continue }
                $rows += New-LogRow $e
            }
        }
    }
    $script:Since = (Get-Date).AddSeconds(-20)
    return $rows
}

# ---------------------------------------------------------------- 界面
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Phoebe VPN - 监控面板'
$form.ClientSize = New-Object System.Drawing.Size(780, 730)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(246, 247, 249)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Top'
$header.Height = 76
$header.BackColor = [System.Drawing.Color]::FromArgb(10, 89, 247)
$form.Controls.Add($header)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Phoebe VPN  监控面板'
$title.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = [System.Drawing.Color]::White
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(18, 12)
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = "服务器 $script:ServerAddress    协议 SSTP/TCP 443 + IKEv2/UDP 500,4500 + L2TP    账号 $script:UserName"
$subtitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$subtitle.ForeColor = [System.Drawing.Color]::FromArgb(210, 225, 255)
$subtitle.AutoSize = $true
$subtitle.Location = New-Object System.Drawing.Point(20, 46)
$header.Controls.Add($subtitle)

$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(18, 92)
$card.Size = New-Object System.Drawing.Size(744, 86)
$card.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($card)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Text = '● 检测中...'
$lblState.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$lblState.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
$lblState.AutoSize = $true
$lblState.Location = New-Object System.Drawing.Point(16, 10)
$card.Controls.Add($lblState)

$lblPorts = New-Object System.Windows.Forms.Label
$lblPorts.Text = 'RAS 端口：-'
$lblPorts.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$lblPorts.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$lblPorts.AutoSize = $true
$lblPorts.Location = New-Object System.Drawing.Point(18, 52)
$card.Controls.Add($lblPorts)

$lblOnline = New-Object System.Windows.Forms.Label
$lblOnline.Text = '在线客户端：-'
$lblOnline.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$lblOnline.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
$lblOnline.AutoSize = $true
$lblOnline.Location = New-Object System.Drawing.Point(215, 52)
$card.Controls.Add($lblOnline)

$lblErr = New-Object System.Windows.Forms.Label
$lblErr.Text = ''
$lblErr.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9, [System.Drawing.FontStyle]::Bold)
$lblErr.ForeColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
$lblErr.AutoSize = $true
$lblErr.Location = New-Object System.Drawing.Point(420, 52)
$card.Controls.Add($lblErr)

$lblRefresh = New-Object System.Windows.Forms.Label
$lblRefresh.Text = ''
$lblRefresh.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$lblRefresh.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
$lblRefresh.AutoSize = $true
$lblRefresh.Location = New-Object System.Drawing.Point(610, 16)
$card.Controls.Add($lblRefresh)

$lblList = New-Object System.Windows.Forms.Label
$lblList.Text = '在线客户端'
$lblList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$lblList.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$lblList.AutoSize = $true
$lblList.Location = New-Object System.Drawing.Point(20, 188)
$form.Controls.Add($lblList)

$list = New-Object System.Windows.Forms.ListView
$list.Location = New-Object System.Drawing.Point(18, 212)
$list.Size = New-Object System.Drawing.Size(744, 160)
$list.View = 'Details'
$list.FullRowSelect = $true
$list.HeaderStyle = 'Nonclickable'
$list.BorderStyle = 'FixedSingle'
$list.BackColor = [System.Drawing.Color]::White
[void]$list.Columns.Add('用户', 150)
[void]$list.Columns.Add('客户端 IP', 170)
[void]$list.Columns.Add('外部地址', 170)
[void]$list.Columns.Add('连接时长', 200)
$form.Controls.Add($list)

$empty = New-Object System.Windows.Forms.Label
$empty.Text = '暂无客户端连接'
$empty.ForeColor = [System.Drawing.Color]::FromArgb(160, 160, 160)
$empty.AutoSize = $true
$empty.Location = New-Object System.Drawing.Point(330, 280)
$form.Controls.Add($empty)
$empty.BringToFront()

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '连接日志（认证成功/失败与错误码）'
$lblLog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$lblLog.ForeColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$lblLog.AutoSize = $true
$lblLog.Location = New-Object System.Drawing.Point(20, 380)
$form.Controls.Add($lblLog)

$logList = New-Object System.Windows.Forms.ListView
$logList.Location = New-Object System.Drawing.Point(18, 404)
$logList.Size = New-Object System.Drawing.Size(744, 230)
$logList.View = 'Details'
$logList.FullRowSelect = $true
$logList.HeaderStyle = 'Nonclickable'
$logList.BorderStyle = 'FixedSingle'
$logList.BackColor = [System.Drawing.Color]::White
[void]$logList.Columns.Add('时间', 70)
[void]$logList.Columns.Add('类型', 60)
[void]$logList.Columns.Add('事件', 70)
[void]$logList.Columns.Add('说明 / 错误码', 530)
$form.Controls.Add($logList)

function New-Btn([string]$text, [int]$x, [int]$w, [System.Drawing.Color]$bg, [System.Drawing.Color]$fg) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object System.Drawing.Point($x, 646)
    $b.Size = New-Object System.Drawing.Size($w, 40)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $bg
    $b.ForeColor = $fg
    $b.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $b
}

$btnStart = New-Btn '启动 VPN' 18 130 ([System.Drawing.Color]::FromArgb(22, 163, 74)) ([System.Drawing.Color]::White)
$btnStop  = New-Btn '停止 VPN' 158 130 ([System.Drawing.Color]::FromArgb(220, 38, 38)) ([System.Drawing.Color]::White)
$btnHide  = New-Btn '隐藏到托盘' 298 140 ([System.Drawing.Color]::FromArgb(235, 238, 242)) ([System.Drawing.Color]::FromArgb(40, 40, 40))
$btnClear = New-Btn '清空日志' 448 120 ([System.Drawing.Color]::FromArgb(235, 238, 242)) ([System.Drawing.Color]::FromArgb(40, 40, 40))
$form.Controls.Add($btnStart); $form.Controls.Add($btnStop); $form.Controls.Add($btnHide); $form.Controls.Add($btnClear)
$btnStop.Enabled = $false

$hint = New-Object System.Windows.Forms.Label
$hint.Text = '关闭窗口不会断开 VPN，可从右下角托盘恢复；重复打开只会运行一个面板'
$hint.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$hint.ForeColor = [System.Drawing.Color]::FromArgb(140, 140, 140)
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(20, 696)
$form.Controls.Add($hint)

# ---------------------------------------------------------------- 托盘
$trayIcon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\System32\imageres.dll")
if (-not $trayIcon) { $trayIcon = [System.Drawing.SystemIcons]::Shield }

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen  = $menu.Items.Add('打开监控面板')
$menu.Items.Add('-') | Out-Null
$miStart = $menu.Items.Add('启动 VPN')
$miStop  = $menu.Items.Add('停止 VPN')
$menu.Items.Add('-') | Out-Null
$miQuitKeep = $menu.Items.Add('退出（VPN 继续运行）')
$miQuitStop = $menu.Items.Add('退出并停止 VPN')

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $trayIcon
$notify.Text = 'Phoebe VPN 监控'
$notify.Visible = $true
$notify.ContextMenuStrip = $menu

# ---------------------------------------------------------------- 刷新逻辑
$script:Refresh = {
    $snap = Get-VpnSnapshot
    if ($snap.Running) {
        $lblState.Text = '● 运行中'
        $lblState.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
        $btnStart.Enabled = $false; $btnStop.Enabled = $true
        $miStart.Enabled = $false; $miStop.Enabled = $true
        $notify.Text = "Phoebe VPN 运行中（$($snap.Clients.Count) 个连接）"
    } else {
        $lblState.Text = '● 已停止'
        $lblState.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
        $btnStart.Enabled = $true; $btnStop.Enabled = $false
        $miStart.Enabled = $true; $miStop.Enabled = $false
        $notify.Text = 'Phoebe VPN 已停止'
    }
    $lblPorts.Text = "RAS 端口：$($snap.Ports)"
    $lblOnline.Text = "在线客户端：$($snap.Clients.Count)"
    $lblRefresh.Text = '刷新于 ' + (Get-Date).ToString('HH:mm:ss')

    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($c in $snap.Clients) {
        $u = "$($c.UserName)"; $ip = "$($c.ClientIPAddress)"; $ext = "$($c.ClientExternalAddress)"; $dur = "$($c.Duration)"
        if ([string]::IsNullOrWhiteSpace($ip)) { $ip = '-' }
        if ([string]::IsNullOrWhiteSpace($ext)) { $ext = '-' }
        if ([string]::IsNullOrWhiteSpace($dur)) { $dur = '-' }
        $it = New-Object System.Windows.Forms.ListViewItem($u)
        [void]$it.SubItems.Add($ip)
        [void]$it.SubItems.Add($ext)
        [void]$it.SubItems.Add($dur)
        [void]$list.Items.Add($it)
    }
    $list.EndUpdate()
    $empty.Visible = ($snap.Clients.Count -eq 0)

    $now = @{}
    foreach ($c in $snap.Clients) { $now["$($c.UserName)|$($c.ClientIPAddress)"] = $c }
    foreach ($k in $now.Keys) {
        if (-not $script:PrevClients.ContainsKey($k)) {
            Add-LogRow (Get-Date).ToString('HH:mm:ss') '成功' '上线' "客户端已连接：$k"
        }
    }
    foreach ($k in $script:PrevClients.Keys) {
        if (-not $now.ContainsKey($k)) {
            Add-LogRow (Get-Date).ToString('HH:mm:ss') '警告' '下线' "客户端已断开：$k"
        }
    }
    $script:PrevClients = $now
}

function Add-LogRow([string]$time, [string]$kind, [string]$id, [string]$desc) {
    $item = New-Object System.Windows.Forms.ListViewItem($time)
    [void]$item.SubItems.Add($kind)
    [void]$item.SubItems.Add($id)
    [void]$item.SubItems.Add($desc)
    if ($kind -eq '失败') {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
        $script:LastError = "$time $desc"
        $lblErr.Text = '最近错误：' + $script:LastError
    } elseif ($kind -eq '成功') {
        $item.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
    }
    $logList.Items.Insert(0, $item)
    while ($logList.Items.Count -gt 200) { $logList.Items.RemoveAt($logList.Items.Count - 1) }
}

$script:RefreshLogs = {
    $rows = Get-NewLogRows
    foreach ($r in $rows) { Add-LogRow $r.Time $r.Kind "$($r.EventId)" $r.Desc }

    # IKE 协商终止且没有在线客户端 -> 判定为一次连接失败（Windows 未给出更细的原因码）
    try {
        $ikeEvts = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-IKE/Operational'; Id = 1013; StartTime = (Get-Date).AddSeconds(-20) } -ErrorAction Stop
        $n = @($ikeEvts).Count
        if ($n -gt 0 -and ((Get-Date) - $script:LastIkeAlert).TotalSeconds -gt 60) {
            $snapNow = Get-VpnSnapshot
            if ($snapNow.Clients.Count -eq 0) {
                $script:LastIkeAlert = Get-Date
                Add-LogRow (Get-Date).ToString('HH:mm:ss') '失败' '1013' "IKE 协商终止且未建立连接（多为认证失败：证书/账号）。近 20 秒内 $n 次"
            }
        }
    } catch { }
}

$script:ShowWindow = {
    $form.Show(); $form.WindowState = 'Normal'; $form.Activate(); $form.BringToFront()
}

$btnStart.Add_Click({
    $btnStart.Enabled = $false
    $lblState.Text = '● 正在启动...'
    $lblState.ForeColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
    $form.Refresh()
    Start-VpnServices
    & $script:Refresh
})
$btnStop.Add_Click({
    $btnStop.Enabled = $false
    $lblState.Text = '● 正在停止...'
    $lblState.ForeColor = [System.Drawing.Color]::FromArgb(217, 119, 6)
    $form.Refresh()
    Stop-VpnServices
    & $script:Refresh
})
$btnHide.Add_Click({ $form.Hide(); $notify.ShowBalloonTip(1500, 'Phoebe VPN', '已隐藏到托盘，VPN 继续运行', [System.Windows.Forms.ToolTipIcon]::Info) })
$btnClear.Add_Click({ $logList.Items.Clear(); $lblErr.Text = ''; $script:LastError = ''
$script:PrevClients = @{}
$script:LastIkeAlert = [datetime]::MinValue })

$miOpen.Add_Click({ & $script:ShowWindow })
$miStart.Add_Click({ Start-VpnServices; & $script:Refresh })
$miStop.Add_Click({ Stop-VpnServices; & $script:Refresh })
$miQuitKeep.Add_Click({ $script:Exiting = $true; $notify.Visible = $false; $form.Close() })
$miQuitStop.Add_Click({
    $script:Exiting = $true
    Stop-VpnServices
    $notify.Visible = $false
    $form.Close()
})
$notify.Add_MouseDoubleClick({ & $script:ShowWindow })

$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:Exiting) {
        $e.Cancel = $true
        $form.Hide()
        $notify.ShowBalloonTip(1500, 'Phoebe VPN', '窗口已隐藏，VPN 仍在运行。右键托盘图标可停止。', [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ & $script:Refresh })
$timer.Start()

$logTimer = New-Object System.Windows.Forms.Timer
$logTimer.Interval = 5000
$logTimer.Add_Tick({ & $script:RefreshLogs })
$logTimer.Start()

$showTimer = New-Object System.Windows.Forms.Timer
$showTimer.Interval = 700
$showTimer.Add_Tick({ try { if ($showEvent.WaitOne(0)) { & $script:ShowWindow } } catch { } })
$showTimer.Start()

# ---------------------------------------------------------------- 启动
try {
    Add-Type -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);' -Name Con -Namespace Phoebe
    [Phoebe.Con]::ShowWindow([Phoebe.Con]::GetConsoleWindow(), 0) | Out-Null
} catch { }

Write-Log '监控面板启动'
& $script:Refresh
if (-not (Get-VpnSnapshot).Running) { Write-Log '检测到 VPN 未运行，自动启动'; Start-VpnServices }
& $script:Refresh
& $script:RefreshLogs

[System.Windows.Forms.Application]::Run($form)

$timer.Stop(); $logTimer.Stop()
$notify.Visible = $false
$notify.Dispose()
try { $mutex.ReleaseMutex() } catch { }
$mutex.Dispose()
Write-Log '监控面板退出'
