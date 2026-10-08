# Auto-detect reachable Telegram DC IP, port 443 (log for telegram-web-fix.bat)
param(
    [Parameter(Mandatory = $true)]
    [string]$LogFile,

    [Parameter(Mandatory = $false)]
    [int]$Parallel = -1,

    # Построчный вывод в консоль (меню [4] в bat вызывает с этим флагом)
    [Parameter(Mandatory = $false)]
    [switch]$ShowProgress
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

$Root = Split-Path -Parent $PSScriptRoot
if (-not $Root) { $Root = (Get-Location).Path }

$CfgFile = Join-Path $Root 'telegram-web-ip.cfg'
$ListFile = Join-Path $Root 'lists\telegram-ip-candidates.txt'
$DomainsFile = Join-Path $Root 'lists\telegram-hosts-domains.txt'
# Только папка проекта: кэш IP с неудачным TCP :443 в прошлых запусках [4] (не трогает систему).
$FailedFile = Join-Path $Root 'lists\telegram-ip-failed.txt'
$FailedFileMaxIps = 512

# Системный прокси для DoH (Invoke-WebRequest) в этом процессе — без правок VPN/IE и других программ.
try {
    $px = [System.Net.WebRequest]::DefaultWebProxy
    if ($null -ne $px) {
        $px.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }
} catch {}

$VerboseLog = ($env:TG_SCAN_VERBOSE_LOG -eq '1')
if ($Parallel -lt 1 -or $Parallel -gt 32) {
    $pEnv = 0
    if ([int]::TryParse($env:TG_SCAN_PARALLEL, [ref]$pEnv) -and $pEnv -ge 1 -and $pEnv -le 32) {
        $Parallel = $pEnv
    } else {
        $Parallel = 28
    }
}

$EnablePass2 = ($env:TG_SCAN_PASS2 -eq '1')
$SkipPostTls = ($env:TG_POST_TLS_OFF -eq '1')

# Не трогаем [Console]::OutputEncoding при выводе в консоль: на классическом conhost это
# часто сбрасывает шрифт на растр на время скана. Кодировка UTF-8 уже задаётся в bat (chcp 65001).
# Сам старт powershell.exe всё равно иногда переключает conhost на растр — поэтому ниже
# в самом начале (при -ShowProgress) принудительно ставим TrueType через SetCurrentConsoleFontEx.

$script:LogUtf8 = [System.Text.UTF8Encoding]::new($false)

if ($ShowProgress) {
    $ttfHelper = Join-Path $PSScriptRoot 'ensure-console-ttf.ps1'
    if (Test-Path -LiteralPath $ttfHelper) { . $ttfHelper }
}

function Sanitize-LogField([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $t = ($s -replace "[\r\n\t]", ' ').Trim()
    if ($t.Length -gt 500) { $t = $t.Substring(0, 500).TrimEnd() }
    # Символы, опасные для cmd с EnableDelayedExpansion и for /f (ломают разбор лога → вылет окна).
    return ($t -replace '[!^`|%&<>()]', '_')
}

function Emit([string]$Code, [string]$Arg1 = '', [string]$Arg2 = '') {
    $a1 = Sanitize-LogField $Arg1
    $a2 = Sanitize-LogField $Arg2
    $line = if ($a2) { "$Code|$a1|$a2" } elseif ($a1) { "$Code|$a1" } else { $Code }
    [System.IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, $script:LogUtf8)
}

function Write-ScanUi {
    param(
        [string]$Line,
        [string]$Color = ''
    )
    if (-not $ShowProgress) { return }
    if ($Color) {
        try { Write-Host $Line -ForegroundColor $Color; return } catch { }
    }
    Write-Host $Line
}

function Write-ScanStep([string]$Title) {
    if (-not $ShowProgress) { return }
    Write-Host ''
    Write-Host ("  --- {0} ---" -f $Title) -ForegroundColor Cyan
}

function Write-ScanOk([string]$Line)    { Write-ScanUi $Line 'Green' }
function Write-ScanWarn([string]$Line)  { Write-ScanUi $Line 'Yellow' }
function Write-ScanFail([string]$Line)  { Write-ScanUi $Line 'Red' }
function Write-ScanDim([string]$Line)   { Write-ScanUi $Line 'DarkGray' }
function Write-ScanInfo([string]$Line)  { Write-ScanUi $Line 'Gray' }

function Write-ScanSpinner {
    param(
        [string]$Label,
        [int]$Index,
        [int]$Total
    )
    if (-not $ShowProgress) { return }
    $frames = @('|', '/', '-', '\')
    $ch = $frames[[Math]::Abs($Index) % $frames.Count]
    $line = if ($Total -gt 0) {
        ("  {0} {1} ({2}/{3})" -f $ch, $Label, $Index, $Total)
    } else {
        ("  {0} {1}" -f $ch, $Label)
    }
    if ($line.Length -gt 78) { $line = $line.Substring(0, 78) }
    Write-Host ("`r{0,-78}" -f $line) -NoNewline -ForegroundColor DarkGray
}

function Clear-ScanSpinnerLine {
    if (-not $ShowProgress) { return }
    Write-Host ("`r{0}" -f (' ' * 78)) -NoNewline
    Write-Host ''
}

function Clear-ConsoleKeyBuffer {
    if (-not $ShowProgress) { return }
    try {
        while ([Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
        }
    } catch {}
}

function Exit-Scan([int]$Code) {
    Clear-ConsoleKeyBuffer
    # Финальный remount: после всех Write-Host conhost мог уйти в растр.
    # Возврат в bat увидит уже корректный TTF — :fix_after_hidden_ps работает в дополнение.
    if ($ShowProgress) {
        $ttfFinal = Join-Path $PSScriptRoot 'ensure-console-ttf.ps1'
        if (Test-Path -LiteralPath $ttfFinal) { . $ttfFinal }
    }
    exit $Code
}

function Write-VerboseLine([string]$Message) {
    if (-not $VerboseLog) { return }
    $t = $Message
    if ($null -eq $t) { return }
    $t = $t.TrimEnd()
    if ($t.Length -eq 0) { return }
    Emit 'MSG' $t
}

function Test-WaveTcp443 {
    param(
        [Parameter(Mandatory)][string[]]$Ips,
        [Parameter(Mandatory)][int]$TimeoutMs
    )
    if (-not $Ips -or $Ips.Count -eq 0) { return $null }

    $items = @(
        foreach ($ip in $Ips) {
            $c = [System.Net.Sockets.TcpClient]::new()
            try {
                $iar = $c.BeginConnect($ip, 443, $null, $null)
                [PSCustomObject]@{ Client = $c; Iar = $iar; Ip = $ip; Handled = $false }
            } catch {
                try { $c.Dispose() } catch {}
                $null
            }
        }
    ) | Where-Object { $_ }

    if (-not $items) { return $null }

    $deadline = [Environment]::TickCount64 + $TimeoutMs
    $winner = $null
    while ([Environment]::TickCount64 -lt $deadline -and -not $winner) {
        $stillPending = $false
        foreach ($s in $items) {
            if ($s.Handled) { continue }
            if (-not $s.Iar.IsCompleted) {
                $stillPending = $true
                continue
            }
            $s.Handled = $true
            try {
                $s.Client.EndConnect($s.Iar)
                if ($s.Client.Connected) { $winner = $s.Ip }
            } catch {}
        }
        if ($winner) { break }
        if (-not $stillPending) { break }
        Start-Sleep -Milliseconds 10
    }

    foreach ($s in $items) {
        try {
            if ($s.Client.Connected) { $s.Client.Close() }
        } catch {}
        try { $s.Client.Dispose() } catch {}
    }

    return $winner
}

function Open-Tcp443 {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][int]$TimeoutMs
    )
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $addr = $null
        try { $addr = [System.Net.IPAddress]::Parse($Ip) } catch { $addr = $null }
        if ($null -eq $addr) {
            try { $client.Dispose() } catch {}
            return $null
        }
        $iar = $client.BeginConnect($addr, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            try { $client.Dispose() } catch {}
            return $null
        }
        try { $client.EndConnect($iar) } catch {
            try { $client.Dispose() } catch {}
            return $null
        }
        if (-not $client.Connected) {
            try { $client.Dispose() } catch {}
            return $null
        }
        return $client
    } catch {
        try { if ($null -ne $client) { $client.Dispose() } } catch {}
        return $null
    }
}

function Test-Tnc443 {
    param([Parameter(Mandatory)][string]$Ip)
    try {
        $r = Test-NetConnection -ComputerName $Ip -Port 443 -WarningAction SilentlyContinue
        return ($r -and $r.TcpTestSucceeded)
    } catch {
        return $false
    }
}

function Test-ControlTcp443 {
    param([int]$TimeoutMs = 1200)
    $candidates = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
    foreach ($ip in $candidates) {
        $client = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $iar = $client.BeginConnect($ip, 443, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs)) { continue }
            try { $client.EndConnect($iar) } catch { continue }
            if ($client.Connected) {
                return @{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds; Ip = $ip }
            }
        } catch {
        } finally {
            try { if ($null -ne $client) { $client.Dispose() } } catch {}
        }
    }
    return @{ Ok = $false; Ms = 0; Ip = '' }
}

function Get-TlsWebCheckHosts {
    # Страница + WebSocket (QR) + короткие ссылки telegram.me / t.me на том же DC.
    return @('web.telegram.org', 'kws2.web.telegram.org', 'telegram.me', 't.me')
}

function Test-TlsOnLiveClient {
    param(
        [Parameter(Mandatory)]$Client,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$TlsTimeoutMs
    )
    $ssl = $null
    try {
        if (-not $Client.Connected) {
            return @{ Ok = $false; Reason = 'tcp_no' }
        }
        $ssl = New-Object System.Net.Security.SslStream($Client.GetStream(), $false)
        $ar = $ssl.BeginAuthenticateAsClient($HostName, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TlsTimeoutMs)) {
            return @{ Ok = $false; Reason = 'tls_timeout' }
        }
        $ssl.EndAuthenticateAsClient($ar)
        if (-not $ssl.IsAuthenticated) {
            return @{ Ok = $false; Reason = 'tls_not_authenticated' }
        }
        return @{ Ok = $true; Reason = '' }
    } catch {
        return @{ Ok = $false; Reason = ('tls_' + $_.Exception.GetType().Name) }
    } finally {
        try { if ($null -ne $ssl) { $ssl.Dispose() } } catch {}
        try { if ($null -ne $Client) { $Client.Dispose() } } catch {}
    }
}

function Test-IpPassesTlsForWeb {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][int]$TcpTimeoutMs,
        [Parameter(Mandatory)][int]$TlsTimeoutMs,
        $LiveClient
    )
    # Обязательна только страница web.telegram.org на уже открытом сокете.
    # kws2 / telegram.me / t.me часто не открывают следующий SYN на 149.154.167.220.
    # Обрыв — не чужой сертификат, адрес не выбрасываем.
    $names = @(Get-TlsWebCheckHosts)
    $live = $LiveClient
    for ($n = 0; $n -lt $names.Count; $n++) {
        $hostName = $names[$n]
        $required = ($n -eq 0)
        $attempts = 3
        if (-not $required) { $attempts = 1 }
        $tlsR = $null
        for ($try = 1; $try -le $attempts; $try++) {
            if ($null -ne $live) {
                $tlsR = Test-TlsOnLiveClient -Client $live -HostName $hostName -TlsTimeoutMs $TlsTimeoutMs
                $live = $null
            } else {
                $tlsR = Test-TlsClient443 -Ip $Ip -HostName $hostName -TcpTimeoutMs $TcpTimeoutMs -TlsTimeoutMs $TlsTimeoutMs
            }
            if ($tlsR.Ok) { break }
            $reason = [string]$tlsR.Reason
            if ($reason -notmatch 'tcp_timeout|tcp_fail|tcp_no') { break }
            if ($try -lt $attempts) { Start-Sleep -Milliseconds 350 }
        }
        if ($tlsR.Ok) { continue }
        $reason = [string]$tlsR.Reason
        if (-not $required -and $reason -match 'tcp_timeout|tcp_fail|tcp_no') { break }
        try { if ($null -ne $live) { $live.Dispose() } } catch {}
        return @{ Ok = $false; Reason = $reason; Host = $hostName }
    }
    try { if ($null -ne $live) { $live.Dispose() } } catch {}
    return @{ Ok = $true; Reason = ''; Host = '' }
}

function Test-TlsClient443 {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$TcpTimeoutMs,
        [Parameter(Mandatory)][int]$TlsTimeoutMs
    )
    $client = $null
    $ssl = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $iar = $client.BeginConnect($Ip, 443, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TcpTimeoutMs)) {
            return @{ Ok = $false; Reason = 'tcp_timeout' }
        }
        try {
            $client.EndConnect($iar)
        } catch {
            return @{ Ok = $false; Reason = 'tcp_fail' }
        }
        if (-not $client.Connected) {
            return @{ Ok = $false; Reason = 'tcp_no' }
        }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false)
        $ar = $null
        try {
            $ar = $ssl.BeginAuthenticateAsClient($HostName, $null, $null)
            if (-not $ar.AsyncWaitHandle.WaitOne($TlsTimeoutMs)) {
                return @{ Ok = $false; Reason = 'tls_timeout' }
            }
            $ssl.EndAuthenticateAsClient($ar)
        } catch {
            $name = $_.Exception.GetType().Name
            return @{ Ok = $false; Reason = ('tls_' + $name) }
        }
        if (-not $ssl.IsAuthenticated) {
            return @{ Ok = $false; Reason = 'tls_not_authenticated' }
        }
        return @{ Ok = $true; Reason = '' }
    } finally {
        try { if ($null -ne $ssl) { $ssl.Dispose() } } catch {}
        try {
            if ($null -ne $client) {
                if ($client.Connected) { $client.Close() }
                $client.Dispose()
            }
        } catch {}
    }
}

function Add-Ipv4ToSet([System.Collections.Generic.HashSet[string]]$Set, [string]$Ip) {
    if ($Ip -and $Ip -match '^\d{1,3}(\.\d{1,3}){3}$') {
        return [bool]$Set.Add($Ip.Trim())
    }
    return $false
}

function Add-DnsIpv4($Set, $Order, [string]$Ip) {
    # Без [HashSet]/[ArrayList] в param(): у advanced-функции пустая коллекция
    # не привязывается («пустая коллекция»), и первый адрес DNS/DoH никогда не попадает в очередь.
    if (Add-Ipv4ToSet $Set $Ip) {
        [void]$Order.Add($Ip.Trim())
    }
}

function Resolve-NameA([string]$Name) {
    $ips = New-Object 'System.Collections.Generic.HashSet[string]'
    try {
        $addrs = [System.Net.Dns]::GetHostAddresses($Name)
        foreach ($a in $addrs) {
            if ($a.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                [void]$ips.Add($a.ToString())
            }
        }
    } catch {}
    return @($ips)
}

function Get-FailedTcpIpSet {
    $s = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path -LiteralPath $FailedFile) {
        foreach ($line in (Get-Content -LiteralPath $FailedFile -ErrorAction SilentlyContinue)) {
            $t = $line.Trim()
            if (-not $t -or $t -match '^\s*#') { continue }
            if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') { [void]$s.Add($t) }
        }
    }
    # Запятая обязательна: иначе PowerShell разворачивает HashSet в вывод,
    # пустой набор становится $null и кэш неудач записывается как «entries 0».
    return ,$s
}

function Remove-IpFromFailedFile([string]$Ip) {
    if (-not $Ip -or -not (Test-Path -LiteralPath $FailedFile)) { return }
    $ip = $Ip.Trim()
    if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return }
    $lines = @(Get-Content -LiteralPath $FailedFile -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return }
    $out = [System.Collections.ArrayList]@()
    $removed = $false
    foreach ($ln in $lines) {
        $t = $ln.Trim()
        if ($t -eq $ip) { $removed = $true; continue }
        [void]$out.Add($ln)
    }
    if (-not $removed) { return }
    if ($out.Count -eq 0 -or (($out | Where-Object { $_.Trim() -match '^\d{1,3}(\.\d{1,3}){3}$' }).Count -eq 0)) {
        Remove-Item -LiteralPath $FailedFile -Force -ErrorAction SilentlyContinue
        return
    }
    [System.IO.File]::WriteAllLines($FailedFile, @($out), $script:LogUtf8)
}

function Sort-Ipv4Strings([string[]]$Ips) {
    return @(
        $Ips | Sort-Object {
            $p = $_.Split('.')
            [uint32]([uint32]$p[0] * 16777216 + [uint32]$p[1] * 65536 + [uint32]$p[2] * 256 + [uint32]$p[3])
        }
    )
}

function Append-FailedTcpProbes([System.Collections.Generic.HashSet[string]]$Probed) {
    if (-not $Probed -or $Probed.Count -eq 0) { return }
    $merged = Get-FailedTcpIpSet
    foreach ($x in $Probed) {
        $t = $x.Trim()
        if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') { [void]$merged.Add($t) }
    }
    $ordered = Sort-Ipv4Strings @($merged)
    if ($ordered.Count -gt $FailedFileMaxIps) {
        $ordered = @($ordered | Select-Object -First $FailedFileMaxIps)
    }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    $hdr = @(
        '# telegram-web-fix — IP с неоткрытым TCP :443 в прошлых сканах [4] (файл в папке проекта, не система)',
        ('# updated {0} | entries {1} max {2}' -f $stamp, $ordered.Count, $FailedFileMaxIps),
        ''
    )
    $body = $ordered -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($FailedFile, (($hdr -join [Environment]::NewLine) + $body + [Environment]::NewLine), $script:LogUtf8)
}

function Add-IpsToCandidateFile([string[]]$Ips) {
    if (-not $Ips -or $Ips.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $ListFile)) { return }
    $header = [System.Collections.ArrayList]@()
    $existing = [System.Collections.ArrayList]@()
    foreach ($line in (Get-Content -LiteralPath $ListFile)) {
        $t = $line.Trim()
        if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') {
            [void]$existing.Add($t)
        } elseif ($t) {
            [void]$header.Add($line)
        }
    }
    $seen = @{}
    foreach ($e in $existing) { $seen[$e] = $true }
    $prepend = [System.Collections.ArrayList]@()
    foreach ($ip in $Ips) {
        $ip = $ip.Trim()
        if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$' -and -not $seen.ContainsKey($ip)) {
            [void]$prepend.Add($ip)
            $seen[$ip] = $true
        }
    }
    if ($prepend.Count -eq 0) { return }
    $out = @($header) + @($prepend) + @($existing)
    [System.IO.File]::WriteAllLines($ListFile, $out, $script:LogUtf8)
    Emit 'ADDED' ([string]$prepend.Count)
}

if (Test-Path -LiteralPath $LogFile) {
    Remove-Item -LiteralPath $LogFile -Force
}

Clear-ConsoleKeyBuffer
Emit 'SEC' 'DNS — внешние резолверы'
Write-ScanStep 'Шаг 1. DNS: узнаём адреса имён (в т.ч. web.telegram.org)'

$dnsServerList = @('1.1.1.1', '1.0.0.1', '8.8.8.8', '9.9.9.9')
$dnsJobs = @()
for ($ji = 0; $ji -lt $dnsServerList.Count; $ji++) {
    $srvOne = $dnsServerList[$ji]
    $dnsJobs += Start-Job -Name ("tgDns{0}" -f $ji) -ScriptBlock {
        param($QueryName, $Srv)
        try {
            Resolve-DnsName -Name $QueryName -Server $Srv -Type A -DnsOnly -ErrorAction Stop
        } catch {
            $null
        }
    } -ArgumentList 'web.telegram.org', $srvOne
}

$null = Wait-Job -Job $dnsJobs -Timeout 3
foreach ($j in $dnsJobs) {
    if ($j.State -eq 'Running') {
        Stop-Job -Job $j -ErrorAction SilentlyContinue
    }
}

$dnsSet = New-Object 'System.Collections.Generic.HashSet[string]'
$dnsOrder = New-Object System.Collections.ArrayList
$dnsFirst = $null
$dnsServersOk = 0

for ($ji = 0; $ji -lt $dnsServerList.Count; $ji++) {
    $srv = $dnsServerList[$ji]
    $j = Get-Job -Name ("tgDns{0}" -f $ji) -ErrorAction SilentlyContinue
    $dnsOut = $null
    if ($j -and $j.State -eq 'Completed') {
        try {
            $dnsOut = Receive-Job -Job $j -ErrorAction SilentlyContinue
        } catch { }
    }
    $anyA = $false
    if ($dnsOut) {
        foreach ($r in ($dnsOut | Where-Object { $_.IPAddress -match '^\d+\.' })) {
            $anyA = $true
            Add-DnsIpv4 -Set $dnsSet -Order $dnsOrder -Ip $r.IPAddress
            if (-not $dnsFirst) { $dnsFirst = $r.IPAddress.Trim() }
        }
    }
    if ($anyA) { $dnsServersOk++ }
    $st = if ($anyA) { 'ok' } elseif ($j -and $j.State -eq 'Completed') { 'empty' } else { 'timeout' }
    Emit 'DR' $srv $st
    $stRu = switch ($st) {
        'ok' { 'есть ответ' }
        'empty' { 'пусто' }
        default { 'таймаут' }
    }
    $dnsColor = if ($anyA) { 'Green' } elseif ($st -eq 'timeout') { 'Yellow' } else { 'DarkGray' }
    Write-ScanUi ("  DNS {0,-12}  {1}" -f $srv, $stRu) $dnsColor
    if ($j) {
        Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
    }
}

if ($dnsFirst) {
    Emit 'DNS' $dnsFirst
    Emit 'DS' 'web.telegram.org' $dnsFirst
} else {
    Emit 'NODNS'
    Emit 'DS' 'web.telegram.org' '-'
}
if ($dnsFirst) {
    Write-ScanOk ("  web.telegram.org — первый адрес: {0}" -f $dnsFirst)
} else {
    Write-ScanWarn '  web.telegram.org — ответа DNS нет'
}

$extraResolve = @(
    'pluto.web.telegram.org',
    'kws2.web.telegram.org',
    'zws2.web.telegram.org',
    'venus.web.telegram.org'
)
if (Test-Path -LiteralPath $DomainsFile) {
    $fromFile = @(Get-Content -LiteralPath $DomainsFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -notmatch '^\s*#' -and $_ -match '\.' })
    foreach ($d in $fromFile) {
        if ($extraResolve -notcontains $d) {
            $extraResolve += $d
        }
    }
}
$extraResolve = @($extraResolve | Select-Object -Unique)
$dsShown = 0
$dsMaxShow = 2
Emit 'SEC' 'DNS — домены из Windows и файла'
Write-ScanStep 'Шаг 2. DNS: остальные домены (как в Windows)'
foreach ($name in $extraResolve) {
    if ($name -eq 'web.telegram.org') { continue }
    $addrs = Resolve-NameA $name
    if ($addrs.Count -gt 0) {
        foreach ($a in $addrs) {
            Add-DnsIpv4 -Set $dnsSet -Order $dnsOrder -Ip $a
        }
        if ($dsShown -lt $dsMaxShow) {
            Write-ScanOk ("  {0,-28}  ->  {1}" -f $name, ($addrs -join ', '))
            Emit 'DS' $name ($addrs[0])
            $dsShown++
        }
    } else {
        if ($dsShown -lt $dsMaxShow) {
            Write-ScanDim ("  {0,-28}  ->  (нет адреса)" -f $name)
            Emit 'DS' $name '-'
            $dsShown++
        }
    }
}
$dsHidden = ($extraResolve.Count - 1) - $dsShown
if ($dsHidden -gt 0) {
    Write-ScanDim ("  … ещё {0} доменов (кратко в отчёте ниже)" -f $dsHidden)
    Emit 'DSN' ([string]$dsHidden)
}

# DNS over HTTPS — всегда (без флагов): при сбое просто пропускаем этот шаг.
function Get-DohARecords {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][hashtable]$Provider
    )
    $base = [string]$Provider.Base
    $sep = if ($base -match '\?') { '&' } else { '?' }
    $uri = $base + $sep + 'name=' + [uri]::EscapeDataString($Domain) + '&type=A'
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers @{ Accept = 'application/dns-json' } -UseBasicParsing -TimeoutSec 1 -Method Get
        $j = $resp.Content | ConvertFrom-Json
        if ($null -eq $j -or $j.Status -ne 0) { return @() }
        if (-not $j.Answer) { return @() }
        $out = @()
        foreach ($a in $j.Answer) {
            if ($null -eq $a) { continue }
            $t = $a.type
            if ($null -ne $t -and [int]$t -ne 1) { continue }
            $d = [string]$a.data
            if ($d -match '^\d{1,3}(\.\d{1,3}){3}$') {
                $out += $d.Trim()
            }
        }
        return @($out | Select-Object -Unique)
    } catch {
        return @()
    }
}

$dohProviders = @(
    @{ Id = 'cf';  Base = 'https://cloudflare-dns.com/dns-query' },
    @{ Id = 'gg'; Base = 'https://dns.google/resolve' }
)
$dohNames = @('web.telegram.org') + @($extraResolve | Where-Object { $_ -and $_ -ne 'web.telegram.org' }) | Select-Object -Unique
if ($dohNames.Count -gt 28) {
    $dohNames = @($dohNames | Select-Object -First 28)
}

$dohJsonOk = 0
$dohBefore = $dnsSet.Count
Emit 'SEC' 'DoH — DNS по HTTPS'
Write-ScanStep 'Шаг 3. Запасной DNS через HTTPS (если сеть пускает)'
$dohTotal = $dohNames.Count
$dohNum = 0
if ($ShowProgress -and $dohTotal -gt 0) {
    Write-ScanSpinner -Label 'DoH: подключение к серверам DNS…' -Index 0 -Total $dohTotal
}
foreach ($dohDomain in $dohNames) {
    $dohNum++
    if ($ShowProgress) {
        $shortDom = $dohDomain
        if ($shortDom.Length -gt 36) { $shortDom = $shortDom.Substring(0, 33) + '...' }
        Write-ScanSpinner -Label ("DoH: {0}" -f $shortDom) -Index $dohNum -Total $dohTotal
    }
    $got = @()
    $usedProv = ''
    $provTry = 0
    foreach ($prov in $dohProviders) {
        $provTry++
        if ($ShowProgress) {
            $shortDom = $dohDomain
            if ($shortDom.Length -gt 28) { $shortDom = $shortDom.Substring(0, 25) + '...' }
            Write-ScanSpinner -Label ("DoH [{0}] {1}" -f $prov.Id, $shortDom) -Index ($dohNum * 2 + $provTry) -Total ($dohTotal * 2)
        }
        $got = @(Get-DohARecords -Domain $dohDomain -Provider $prov)
        if ($got.Count -gt 0) {
            $dohJsonOk++
            $usedProv = [string]$prov.Id
            Write-VerboseLine ("  DoH [{0}] {1} -> {2}" -f $prov.Id, $dohDomain, ($got -join ', '))
            break
        }
    }
    foreach ($ip in $got) {
        Add-DnsIpv4 -Set $dnsSet -Order $dnsOrder -Ip $ip
    }
}
Clear-ScanSpinnerLine
$dohAdded = $dnsSet.Count - $dohBefore
if ($dohJsonOk -gt 0) {
    Emit 'DOH' 'merged' ([string]$dohAdded)
} else {
    Emit 'DOH' 'skip' 'no_doh_response'
}
$dohSummaryColor = if ($dohAdded -gt 0) { 'Green' } else { 'Gray' }
Write-ScanUi ("  DoH: проверено имён {0}, с ответом {1}, новых IP в очередь: {2}" -f $dohNames.Count, $dohJsonOk, $dohAdded) $dohSummaryColor

$fileList = @()
if (Test-Path -LiteralPath $ListFile) {
    $fileList = @(Get-Content -LiteralPath $ListFile |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
}

# DNS/DoH IP — в начало очереди: чаще живой DC, иначе полный список тянется минутами.
$queue = New-Object System.Collections.ArrayList
foreach ($ip in $dnsOrder) {
    [void]$queue.Add($ip)
}
foreach ($ip in $fileList) {
    if (-not $dnsSet.Contains($ip)) { [void]$queue.Add($ip) }
}

$seen = @{}
$candidates = @(
    foreach ($ip in $queue) {
        if ($seen.ContainsKey($ip)) { continue }
        $seen[$ip] = $true
        $ip
    }
)

if (-not $candidates) {
    Emit 'ERR' 'empty_list'
    if ($ShowProgress) {
        Write-ScanUi ''
        Write-ScanFail '  Список lists/telegram-ip-candidates.txt пуст — сначала [5] Обновить список IP.'
    }
    Exit-Scan 1
}

$candidatesAll = @($candidates)
$failedSkipSet = Get-FailedTcpIpSet
$skippedFailed = 0
if ($failedSkipSet.Count -gt 0) {
    $beforeF = $candidates.Count
    $candidates = @($candidates | Where-Object { -not $failedSkipSet.Contains($_) })
    $skippedFailed = $beforeF - $candidates.Count
    if ($skippedFailed -gt 0) {
        Emit 'SKIP' 'failed_tcp' ([string]$skippedFailed)
        if ($ShowProgress) {
            Write-ScanDim ("  Пропуск по кэшу lists\telegram-ip-failed.txt: {0} IP (не бегаем по уже проверенным :443)." -f $skippedFailed)
        }
    }
    if ($candidates.Count -eq 0 -and $beforeF -gt 0) {
        try { Remove-Item -LiteralPath $FailedFile -Force -ErrorAction Stop } catch {}
        Emit 'WARN' 'failed_cache_reset' ([string]$failedSkipSet.Count)
        if ($ShowProgress) {
            Write-ScanWarn '  Кэш неудач исключил всю очередь — сброшен lists\telegram-ip-failed.txt, повтор без пропуска.'
        }
        $candidates = $candidatesAll
        $skippedFailed = 0
    }
}

$TcpTimeoutMs = 800
$waveParallel = 48

Emit 'SRC' ([string]$fileList.Count) ([string]$candidates.Count)

$found = $null
$tcpProbed = 0
$tcpOpen = 0
$tcpProbeFailAccum = New-Object 'System.Collections.Generic.HashSet[string]'

# 149.154.167.220 отвечает по одному, а в пачке из 28 часто теряется.
$priorityOrder = @(
    '149.154.167.220', '149.154.167.91', '149.154.167.51', '149.154.175.100',
    '91.108.56.130', '149.154.167.99', '149.154.175.50', '149.154.175.209',
    '149.154.170.96', '149.154.167.40', '149.154.167.50', '149.154.168.98',
    '149.154.172.98', '91.108.56.100', '91.108.56.181', '185.76.151.43'
)
if (Test-Path -LiteralPath $CfgFile) {
    $prevIp = ''
    try { $prevIp = ([string](Get-Content -LiteralPath $CfgFile -TotalCount 1)).Trim() } catch {}
    if ($prevIp -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $priorityOrder = @($prevIp) + @($priorityOrder | Where-Object { $_ -ne $prevIp })
    }
}
$candSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($c in $candidates) { [void]$candSet.Add([string]$c) }
$priority = @($priorityOrder | Where-Object { $candSet.Contains($_) })

Emit 'SEC' 'TCP — известные адреса'
Write-ScanStep ("Шаг 4. Сначала {0} известных адресов DC, по одному" -f $priority.Count)
$pIdx = 0
foreach ($ip in $priority) {
    if ($found) { break }
    $pIdx++
    if ($ShowProgress) {
        Write-ScanDim ("  [{0}/{1}] {2}" -f $pIdx, $priority.Count, $ip)
    }
    $live = $null
    $tries = 1
    $oneMs = 900
    # Первый адрес — тот, что уже открывал web.telegram.org. SYN до него часто теряется,
    # две попытки по 2 с его пропускали, и поиск уходил на мёртвые DC.
    if ($pIdx -eq 1) { $tries = 6; $oneMs = 3000 }
    $acceptHit = $false
    for ($try = 1; $try -le $tries; $try++) {
        if ($try -gt 1) {
            Start-Sleep -Milliseconds 400
            if ($ShowProgress) {
                Write-ScanDim ("  {0}  ещё попытка {1}/{2}" -f $ip, $try, $tries)
            }
        }
        $live = Open-Tcp443 -Ip $ip -TimeoutMs $oneMs
        if ($null -eq $live) { continue }
        $tcpOpen++
        $acceptHit = $true
        if (-not $SkipPostTls) {
            $tlsCheck = Test-IpPassesTlsForWeb -Ip $ip -TcpTimeoutMs 4000 -TlsTimeoutMs 8000 -LiveClient $live
            $live = $null
            if (-not $tlsCheck.Ok) {
                $acceptHit = $false
                $reason = [string]$tlsCheck.Reason
                $retryTls = ($pIdx -eq 1) -and ($reason -match 'tcp_|tls_timeout') -and ($try -lt $tries)
                if (-not $retryTls) {
                    if ($reason -match '\|') { $reason = $reason.Replace('|', '_') }
                    Emit 'TLS' 'reject' ("{0}|{1}" -f [string]$tlsCheck.Host, $reason)
                    if ($ShowProgress) {
                        Write-ScanDim ("  {0,-15}  порт 443 открыт, TLS для {1} — нет ({2})" -f $ip, $tlsCheck.Host, $reason)
                    }
                    break
                }
            }
        } else {
            try { $live.Dispose() } catch {}
        }
        if ($acceptHit) { break }
    }
    if (-not $acceptHit) { continue }
    if ($acceptHit) {
        $found = $ip
        Emit 'LIVE' 'ok' $ip
        Emit 'ROW' $ip 'ok'
        if ($ShowProgress) {
            Write-ScanOk ("  {0,-15}  порт 443: открыт" -f $ip)
        }
    }
}

if (-not $found) {
    $priSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($p in $priority) { [void]$priSet.Add([string]$p) }
    $candidates = @($candidates | Where-Object { -not $priSet.Contains([string]$_) })
    Emit 'Q' ([string]$candidates.Count) ([string]$waveParallel)
    Emit 'MS' ([string]$TcpTimeoutMs)
    Emit 'SEC' 'TCP — остальные адреса'
    if ($ShowProgress -and $candidates.Count -gt 0) {
        Write-ScanStep ("Дальше остальные {0} адресов, по {1}, таймаут {2} мс" -f $candidates.Count, $waveParallel, $TcpTimeoutMs)
    }
}

$total = $candidates.Count
$idx = 0
$progWave = 0

while ($idx -lt $total -and -not $found) {
    $waveSize = [Math]::Min($waveParallel, $total - $idx)
    $wave = @($candidates[$idx..($idx + $waveSize - 1)])
    $idx += $waveSize
    $tcpProbed += $wave.Count

    $toN = $idx
    $progWave++
    $emitProg = ($toN -eq $total) -or (($progWave % 2) -eq 0)
    if ($emitProg) {
        Emit 'PROG' ([string]$toN) ([string]$total)
    }
    if ($ShowProgress -and ($emitProg -or $progWave -eq 1)) {
        Write-ScanDim ("  TCP :443 .............. [{0}/{1}]" -f $toN, $total)
    }
    Write-VerboseLine ("  [{0}/{1}] TCP :443 — {2}" -f $toN, $total, ($wave -join ', '))

    $hit = Test-WaveTcp443 -Ips $wave -TimeoutMs $TcpTimeoutMs
    if ($hit) {
        $tcpOpen++
        Emit 'PROG' ([string]$toN) ([string]$total)
        $acceptHit = $true
        if (-not $SkipPostTls) {
            $tlsTcpMs = 5000
            $tlsHsMs = 8000
            $tlsCheck = Test-IpPassesTlsForWeb -Ip $hit -TcpTimeoutMs $tlsTcpMs -TlsTimeoutMs $tlsHsMs
            if (-not $tlsCheck.Ok) {
                $acceptHit = $false
                [void]$tcpProbeFailAccum.Add($hit)
                $reason = [string]$tlsCheck.Reason
                if ($reason -match '\|') { $reason = $reason.Replace('|', '_') }
                Emit 'TLS' 'reject' ("{0}|{1}" -f [string]$tlsCheck.Host, $reason)
                if ($ShowProgress) {
                    Write-ScanDim ("  {0,-15}  порт 443 открыт, TLS для {1} — нет ({2}); ищем дальше…" -f $hit, $tlsCheck.Host, $reason)
                }
            }
        }
        if ($acceptHit) {
            $found = $hit
            Emit 'LIVE' 'ok' $hit
            Emit 'ROW' $hit 'ok'
            if ($ShowProgress) {
                Write-ScanOk ("  {0,-15}  порт 443: открыт" -f $hit)
            }
            if ($VerboseLog) {
                foreach ($ip in $wave) {
                    if ($ip -ne $hit) { Emit 'ROW' $ip 'fail' }
                }
            }
            break
        }
    }
    foreach ($ip in $wave) { [void]$tcpProbeFailAccum.Add($ip) }
    if ($VerboseLog) {
        foreach ($ip in $wave) {
            Emit 'ROW' $ip 'fail'
        }
    }
}

$ranPass2 = $false
$tncProbed = 0

if (-not $found -and $EnablePass2) {
    Emit 'PASS2' 'tnc'
    $ranPass2 = $true
    Write-ScanStep 'Доп. проверка порта (TG_SCAN_PASS2=1)'
    $pass2Max = [Math]::Min(48, $candidates.Count)
    $i = 0
    foreach ($ip in ($candidates | Select-Object -First $pass2Max)) {
        $i++
        Emit 'PROG' ([string]$i) ([string]$total)
        Write-VerboseLine ("  [фаза 2] [{0}/{1}] {2}" -f $i, $total, $ip)
        $tncProbed++
        if (Test-Tnc443 -Ip $ip) {
            $tcpOpen++
            $acceptPass2 = $true
            if (-not $SkipPostTls) {
                $tlsTcpMs = 5000
                $tlsHsMs = 8000
                $tlsCheck = Test-IpPassesTlsForWeb -Ip $ip -TcpTimeoutMs $tlsTcpMs -TlsTimeoutMs $tlsHsMs
                if (-not $tlsCheck.Ok) {
                    $acceptPass2 = $false
                    [void]$tcpProbeFailAccum.Add($ip)
                }
            }
            if ($acceptPass2) {
                Emit 'LIVE' 'ok2' $ip
                Emit 'ROW' $ip 'ok2'
                if ($ShowProgress) { Write-ScanOk ("  {0,-15}  доп.проверка: открыт" -f $ip) }
                $found = $ip
                break
            }
        }
        [void]$tcpProbeFailAccum.Add($ip)
        if ($VerboseLog) { Emit 'ROW' $ip 'fail2' }
    }
}

if (-not $found) {
    Emit 'N' 'diag' '1'
    Emit 'N' 'cand' ([string]$candidates.Count)
    Emit 'N' 'file' ([string]$fileList.Count)
    Emit 'N' 'dnsA' ([string]$dnsSet.Count)
    Emit 'N' 'dnsSrv' ([string]$dnsServersOk)
    Emit 'N' 'tcpTry' ([string]$tcpProbed)
    Emit 'N' 'tncTry' ([string]$tncProbed)
    Emit 'N' 'ms' ([string]$TcpTimeoutMs)
    Emit 'N' 'parallel' ([string]$Parallel)
    Emit 'N' 'pass2' $(if ($ranPass2) { '1' } else { '0' })
    if ($tcpOpen -gt 0) {
        Append-FailedTcpProbes $tcpProbeFailAccum
    } else {
        # Ни одного TCP-ответа: это обрыв пути, а не «мёртвые» DC.
        # Запись их в кэш заставила бы следующий запуск (уже с VPN) пропустить живые адреса.
        if (Test-Path -LiteralPath $FailedFile) {
            Remove-Item -LiteralPath $FailedFile -Force -ErrorAction SilentlyContinue
        }
    }
    $ctrl = Test-ControlTcp443
    if ($ctrl.Ok) {
        Emit 'NET' 'up' ("{0}/{1}" -f $ctrl.Ip, $ctrl.Ms)
    } else {
        Emit 'NET' 'down' '1.1.1.1 8.8.8.8 9.9.9.9'
    }
    Emit 'ERR' 'no_reply'
    Emit 'DONE' '1'
    if ($ShowProgress) {
        Write-ScanUi ''
        if ($ctrl.Ok) {
            Write-ScanFail ("  Подходящий адрес не найден. {0}:443 открыт за {1} мс — интернет есть, молчат адреса Telegram." -f $ctrl.Ip, $ctrl.Ms)
            Write-ScanDim '  hosts это не обходит. Нужна другая сеть, раздача с телефона или VPN со split-tunnel для браузера.'
        } else {
            Write-ScanFail '  Подходящий адрес не найден. Контроль 1.1.1.1, 8.8.8.8 и 9.9.9.9:443 тоже не открылся.'
            Write-ScanDim '  Проверьте исходящий интернет. Если VPN включён целиком в туннель — отключите на минуту или включите split-tunnel.'
        }
    }
    Exit-Scan 1
}

Emit 'SEC' 'TLS — HTTPS и сертификат'
if ($SkipPostTls) {
    Emit 'TLS' 'skip' 'TG_POST_TLS_OFF'
    Write-ScanDim '  TLS не проверяли (TG_POST_TLS_OFF=1) — только открытый порт 443.'
} else {
    Write-ScanStep 'Шаг 5. Итог: TLS для web, kws2, telegram.me и t.me'
    Emit 'TLS' 'ok' $found
    Write-ScanOk ("  HTTPS + WebSocket-хосты на {0} — сертификат принят" -f $found)
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($CfgFile, "$found`r`n", $utf8NoBom)
Remove-IpFromFailedFile $found
$toAdd = @($found) + @($dnsSet)
Add-IpsToCandidateFile $toAdd
Emit 'FOUND' $found
Emit 'DONE' '0'
if ($ShowProgress) {
    Write-ScanUi ''
    Write-ScanOk  '  ========== Готово =========='
    Write-ScanOk  ("  Рабочий IP:  {0}" -f $found)
    Write-ScanInfo '  Записан в telegram-web-ip.cfg рядом с bat.'
    Write-ScanInfo '  В меню: [1] Включить — откроется web.telegram.org/k/ (корень / без пути — старый Webogram, серый экран).'
    Write-ScanUi ''
}
Exit-Scan 0
