# ============================================================
#  校园网自动登录脚本 (锐捷 ePortal 认证系统) - 便携版
#
#  ★ 首次运行会交互式设置: 选择运营商 + 输入账号密码
#  ★ 设置保存在同目录 config.json, 之后运行无需再输入
#  ★ 登录成功后询问是否"开机自动登录"(免管理员, 走启动文件夹)
#
#  分享给同学: 只需发本文件 + 启动.bat 两个文件
#  ⚠ 分享前请删除 config.json(里面是你的账号密码)
#
#  常用参数:
#    -Setup            重新设置(换账号 / 改运营商)
#    -Autostart        手动开启开机自启
#    -RemoveAutostart  关闭开机自启
# ============================================================

param(
    [switch]$Setup,
    [switch]$Autostart,
    [switch]$RemoveAutostart
)

# ---------------- 学校相关配置(同校同学无需修改) ----------------
$portalBase = "http://10.10.9.4/eportal"   # 认证门户地址
$loginUrl   = "$portalBase/InterFace.do?method=login"
# ----------------------------------------------------------------

$maxAttempts = 30   # 最多重试次数
$retryDelay  = 3    # 每次间隔秒数

$configPath = Join-Path $PSScriptRoot "config.json"

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ---------------- 工具函数 ----------------
function JsEncodeURIComponent([string]$str) {
    if ([string]::IsNullOrEmpty($str)) { return "" }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($str)
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        $c = [char]$b
        $unreserved = ($c -ge 'A' -and $c -le 'Z') -or ($c -ge 'a' -and $c -le 'z') -or `
                      ($c -ge '0' -and $c -le '9') -or `
                      $c -in @('-','_','.','!','~','*',"'",'(',')')
        if ($unreserved) { [void]$sb.Append($c) }
        else { [void]$sb.Append('%'); [void]$sb.Append($b.ToString('X2')) }
    }
    return $sb.ToString()
}

function Write-Log([string]$msg) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg)
}

function Test-Internet {
    try {
        # 用 HttpWebRequest 只读状态码、不下载正文, 避免缓存整个页面
        $req = [System.Net.HttpWebRequest]::Create("https://www.baidu.com/")
        $req.Timeout = 2000
        $req.UserAgent = "Mozilla/5.0"
        $resp = $req.GetResponse()
        try { return ([int]$resp.StatusCode -eq 200) }
        finally { try { $resp.Close() } catch {} }
    } catch { return $false }
}

# 判断 WiFi 是否已连上(是否有有效 IPv4)
function Test-NetworkConnected {
    try {
        return [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    } catch { return $false }
}

# 直接从本机 IP + MAC 重建认证参数(不依赖网关重定向, 稳定可靠)
# 用纯 .NET 取 IP/MAC, 避免加载 PowerShell 网络模块(更快)
# 实测: 不带 vid/port/nasportid 也能登录成功, 故此处省略它们
function Get-QueryString {
    try {
        $nics = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()
        foreach ($nic in $nics) {
            if ($nic.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            foreach ($addr in $nic.GetIPProperties().UnicastAddresses) {
                if ($addr.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $addr.Address.ToString()
                if (-not $ip.StartsWith("10.")) { continue }
                $mac = [BitConverter]::ToString($nic.GetPhysicalAddress().GetAddressBytes()).Replace("-", "").ToLower()
                if ([string]::IsNullOrEmpty($mac)) { continue }
                return "wlanuserip=$ip&wlanacname=FSN-XX-Business&ssid=&nasip=10.10.9.1&snmpagentip=&mac=$mac&t=wireless-v2-plain&url=http://www.msftconnecttest.com/redirect&apmac=&nasid=FSN-XX-Business"
            }
        }
    } catch {}
    return $null
}

function Invoke-Login([string]$queryString) {
    $encUserId   = JsEncodeURIComponent (JsEncodeURIComponent $userId)
    $encPassword = JsEncodeURIComponent (JsEncodeURIComponent $password)
    $encService  = JsEncodeURIComponent (JsEncodeURIComponent $service)
    $encQuery    = JsEncodeURIComponent (JsEncodeURIComponent $queryString)
    $body = "userId=$encUserId&password=$encPassword&service=$encService&queryString=$encQuery&operatorPwd=&operatorUserId=&validcode=&passwordEncrypt=false"
    $resp = Invoke-WebRequest -Uri $loginUrl -Method Post -Body $body `
              -ContentType "application/x-www-form-urlencoded; charset=UTF-8" `
              -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    try { return $resp.Content }
    finally { try { $resp.Dispose() } catch {} }
}

function Read-Password([string]$Prompt) {
    Write-Host -NoNewline "$Prompt : "
    $s = Read-Host -AsSecureString
    if ($s.Length -eq 0) { return "" }
    $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Invoke-Setup {
    Write-Host ""
    Write-Host "================ 校园网自动登录 · 首次设置 ================"
    Write-Host "请选择你的运营商:"
    Write-Host "  [1] 移动"
    Write-Host "  [2] 电信"
    Write-Host "  [3] 联通"
    Write-Host "  [4] 校内网 (无运营商 / 校园网直连)"
    $svc = $null
    while ($null -eq $svc) {
        $sel = Read-Host "请输入编号 1-4"
        switch ($sel) {
            "1" { $svc = "移动" }
            "2" { $svc = "电信" }
            "3" { $svc = "联通" }
            "4" { $svc = "校内网" }
            default { Write-Host "输入无效, 请重新输入 1-4" }
        }
    }
    $uid = (Read-Host "请输入账号(学号)").Trim()
    $pwd = Read-Password "请输入密码"
    if ([string]::IsNullOrEmpty($uid) -or [string]::IsNullOrEmpty($pwd)) {
        Write-Log "账号或密码不能为空, 设置未保存。"
        return $null
    }
    $cfg = @{ userId = $uid; password = $pwd; service = $svc }
    [System.IO.File]::WriteAllText($configPath, ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("设置已保存: 运营商={0}, 账号={1}" -f $svc, $uid)
    return $cfg
}

function Get-StartupShortcut {
    return (Join-Path ([Environment]::GetFolderPath("Startup")) "CampusAutoLogin.lnk")
}

function Enable-Autostart {
    try {
        $lnk = Get-StartupShortcut
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = "powershell.exe"
        $sc.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSScriptRoot\campus-login.ps1`""
        $sc.WorkingDirectory = $PSScriptRoot
        $sc.Description = "校园网自动登录"
        $sc.WindowStyle = 7
        $sc.Save()
        Write-Log "已开启开机自动登录(登录 Windows 后自动联网)。"
        return $true
    } catch {
        Write-Log "开启开机自启失败: $($_.Exception.Message)"
        return $false
    }
}

function Disable-Autostart {
    $lnk = Get-StartupShortcut
    if (Test-Path $lnk) {
        Remove-Item $lnk -Force
        Write-Log "已关闭开机自动登录。"
    } else {
        Write-Log "当前未开启开机自动登录。"
    }
}

# ---------------- 主流程 ----------------

if ($Autostart)    { Enable-Autostart; exit 0 }
if ($RemoveAutostart) { Disable-Autostart; exit 0 }

# 加载或创建设置
$cfg = $null
if (-not $Setup -and (Test-Path $configPath)) {
    try {
        $cfg = [System.IO.File]::ReadAllText($configPath) | ConvertFrom-Json
        if ([string]::IsNullOrEmpty($cfg.userId) -or [string]::IsNullOrEmpty($cfg.password) -or [string]::IsNullOrEmpty($cfg.service)) { $cfg = $null }
    } catch { $cfg = $null }
}
$freshSetup = $false
if ($null -eq $cfg) {
    $cfg = Invoke-Setup
    $freshSetup = $true
    if ($null -eq $cfg) { Write-Log "设置失败, 退出。"; exit 2 }
}

$userId   = $cfg.userId
$password = $cfg.password
$service  = $cfg.service

# 登录
if (Test-Internet) {
    Write-Log "已联网, 无需登录。"
} else {
    Write-Log "当前未联网, 开始登录... (运营商: $service)"
    $success = $false
    for ($i = 1; $i -le $maxAttempts; $i++) {
        if ($i -gt 1) { Start-Sleep -Seconds $retryDelay }
        if (-not (Test-NetworkConnected)) {
            Write-Log "第 $i 次: WiFi 尚未连上, 等待网络..."
            continue
        }
        $qs = Get-QueryString
        if (-not $qs) {
            Write-Log "第 $i 次: 未获取到本机网络参数, 稍后重试..."
            continue
        }
        try {
            $content = Invoke-Login $qs
            Write-Log "第 $i 次: 服务器返回 -> $content"
            if ($content -match '"result"\s*:\s*"success"') {
                Start-Sleep -Seconds 1
                if (Test-Internet) {
                    Write-Log "登录成功, 已联网!"
                    $success = $true
                    break
                }
                Write-Log "第 $i 次: 认证成功但尚未生效, 继续重试..."
            }
        } catch {
            Write-Log "第 $i 次: 请求异常 -> $($_.Exception.Message)"
        }
    }
    if (-not $success) {
        Write-Log "多次尝试后仍未联网, 请确认账号/密码/运营商是否正确。"
        exit 1
    }
}

# 首次设置成功后, 询问是否开机自启
if ($freshSetup) {
    Write-Host ""
    $ans = Read-Host "是否开启'开机自动登录'? (Y/N)"
    if ($ans -match '^[Yy]') { Enable-Autostart }
    else { Write-Log "暂未开启。以后可运行: campus-login.ps1 -Autostart 来开启。" }
}
