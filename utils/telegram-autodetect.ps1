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

function Test-Tnc443 {
    param([Parameter(Mandatory)][string]$Ip)
    try {
        $r = Test-NetConnection -ComputerName $Ip -Port 443 -WarningAction SilentlyContinue
        return ($r -and $r.TcpTestSucceeded)
    } catch {
        return $false
    }
}

function Get-TlsWebCheckHosts {
    # Минимум для Telegram Web: страница + WebSocket (QR/сессия).
    return @('web.telegram.org', 'kws2.web.telegram.org')
}

function Test-IpPassesTlsForWeb {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][int]$TcpTimeoutMs,
        [Parameter(Mandatory)][int]$TlsTimeoutMs
    )
    foreach ($hostName in (Get-TlsWebCheckHosts)) {
        $tlsR = Test-TlsClient443 -Ip $Ip -HostName $hostName -TcpTimeoutMs $TcpTimeoutMs -TlsTimeoutMs $TlsTimeoutMs
        if (-not $tlsR.Ok) {
            return @{ Ok = $false; Reason = [string]$tlsR.Reason; Host = $hostName }
        }
    }
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
        [void]$Set.Add($Ip.Trim())
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
    if (-not (Test-Path -LiteralPath $FailedFile)) { return $s }
    foreach ($line in (Get-Content -LiteralPath $FailedFile -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if (-not $t -or $t -match '^\s*#') { continue }
        if ($t -match '^\d{1,3}(\.\d{1,3}){3}$') { [void]$s.Add($t) }
    }
    return $s
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
            Add-Ipv4ToSet $dnsSet $r.IPAddress
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
            Add-Ipv4ToSet $dnsSet $a
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
        Add-Ipv4ToSet $dnsSet $ip
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

$queue = New-Object System.Collections.ArrayList
foreach ($ip in $fileList) {
    if (-not $dnsSet.Contains($ip)) { [void]$queue.Add($ip) }
}
foreach ($ip in $fileList) {
    if ($dnsSet.Contains($ip)) { [void]$queue.Add($ip) }
}
foreach ($ip in $dnsSet) {
    if ($fileList -notcontains $ip) { [void]$queue.Add($ip) }
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

$TcpTimeoutMs = 3000
if ($candidates.Count -gt 400) { $TcpTimeoutMs = 1700 }
elseif ($candidates.Count -gt 250) { $TcpTimeoutMs = 2000 }
elseif ($candidates.Count -gt 120) { $TcpTimeoutMs = 2400 }

Emit 'SRC' ([string]$fileList.Count) ([string]$candidates.Count)
Emit 'Q' ([string]$candidates.Count) ([string]$Parallel)
Emit 'MS' ([string]$TcpTimeoutMs)

Emit 'SEC' 'TCP — порт 443'
Write-ScanStep ("Шаг 4. TCP :443 — очередь из lists\telegram-ip-candidates.txt + DNS (из файла {0}, всего {1}; по {2} параллельно)" -f $fileList.Count, $candidates.Count, $Parallel)
Write-ScanInfo ("  Таймаут на группу: до {0} мс." -f $TcpTimeoutMs)

$found = $null
$tcpProbed = 0
$total = $candidates.Count
$idx = 0
$progWave = 0
$tcpProbeFailAccum = New-Object 'System.Collections.Generic.HashSet[string]'

Write-ScanDim ("  Ожидайте: проверка {0} адресов (обычно 30–90 с, при блокировке сети — до 2 мин.)…" -f $total)

while ($idx -lt $total -and -not $found) {
    $waveSize = [Math]::Min($Parallel, $total - $idx)
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
        Emit 'PROG' ([string]$toN) ([string]$total)
        $acceptHit = $true
        if (-not $SkipPostTls) {
            $tlsTcpMs = [Math]::Min(2800, $TcpTimeoutMs)
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
            $acceptPass2 = $true
            if (-not $SkipPostTls) {
                $tlsTcpMs = [Math]::Min(2800, $TcpTimeoutMs)
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
    Append-FailedTcpProbes $tcpProbeFailAccum
    Emit 'ERR' 'no_reply'
    Emit 'DONE' '1'
    if ($ShowProgress) {
        Write-ScanUi ''
        Write-ScanFail '  Подходящий адрес не найден. Попробуйте [5], другую сеть или VPN.'
        Write-ScanDim '  Если VPN включён: отключите на минуту или включите split-tunnel для браузера — иначе TCP к DC может не дойти.'
    }
    Exit-Scan 1
}

Emit 'SEC' 'TLS — HTTPS и сертификат'
if ($SkipPostTls) {
    Emit 'TLS' 'skip' 'TG_POST_TLS_OFF'
    Write-ScanDim '  TLS не проверяли (TG_POST_TLS_OFF=1) — только открытый порт 443.'
} else {
    Write-ScanStep 'Шаг 5. Итог: TLS для web.telegram.org и kws2.web.telegram.org'
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
    Write-ScanInfo '  В меню: [1] Включить, затем web.telegram.org в браузере.'
    Write-ScanUi ''
}
Exit-Scan 0
