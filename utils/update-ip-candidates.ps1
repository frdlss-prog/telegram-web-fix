# Rebuild lists/telegram-ip-candidates.txt from official Telegram IPv4 CIDRs.
# Sources: Telegram site (direct + DoH) -> community mirrors (daily) -> bundled file.
param(
    [string]$CidrUrl = 'https://core.telegram.org/resources/cidr.txt'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

try {
    $px = [System.Net.WebRequest]::DefaultWebProxy
    if ($null -ne $px) {
        $px.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }
} catch {}

$ttfHelper = Join-Path $PSScriptRoot 'ensure-console-ttf.ps1'
if (Test-Path -LiteralPath $ttfHelper) { . $ttfHelper }

$Root = Split-Path -Parent $PSScriptRoot
$OutFile = Join-Path $Root 'lists\telegram-ip-candidates.txt'
$FailedFile = Join-Path $Root 'lists\telegram-ip-failed.txt'
$BundledCidr = Join-Path $Root 'lists\telegram-cidr-official.txt'
$ListDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $ListDir)) {
    New-Item -ItemType Directory -Path $ListDir -Force | Out-Null
}

function ConvertTo-UInt32IPv4([string]$s) {
    $a = $s.Split('.')
    return [uint32]([uint32]$a[0] * 16777216 + [uint32]$a[1] * 65536 + [uint32]$a[2] * 256 + [uint32]$a[3])
}

function ConvertTo-StringIPv4([uint32]$u) {
    $a0 = [int](($u -shr 24) -band 0xFF)
    $a1 = [int](($u -shr 16) -band 0xFF)
    $a2 = [int](($u -shr 8) -band 0xFF)
    $a3 = [int]($u -band 0xFF)
    return '{0}.{1}.{2}.{3}' -f $a0, $a1, $a2, $a3
}

function Get-CidrSampleIPv4s {
    param([string]$CidrStr)
    if ($CidrStr -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') { return @() }
    $netStr = $Matches[1]
    $pref = [int]$Matches[2]
    if ($pref -lt 8 -or $pref -gt 32) { return @() }
    $ipUint = ConvertTo-UInt32IPv4 $netStr
    $hostBits = 32 - $pref
    if ($hostBits -le 0) {
        return @(ConvertTo-StringIPv4 $ipUint)
    }
    [uint64]$size = 1
    for ($i = 0; $i -lt $hostBits; $i++) { $size = $size * 2 }
    [uint32]$mask = 0
    for ($i = 0; $i -lt $pref; $i++) {
        $mask = [uint32](([uint64]$mask -shl 1) -bor 1)
    }
    for ($i = 0; $i -lt $hostBits; $i++) {
        $mask = [uint32]([uint64]$mask -shl 1)
    }
    $net = [uint32]($ipUint -band $mask)
    $last = [uint32](([uint64]$net + $size - 1) -band 0xFFFFFFFF)

    $offsets = New-Object 'System.Collections.Generic.HashSet[uint64]'
    foreach ($x in @(1, 2, 5, 10, 15, 20, 30, 40, 50, 60, 70, 80, 90, 100, 120, 150, 200, 250, 300, 400, 500, 600, 700, 800, 900, 1000, 1500, 2000, 2500, 3000)) {
        $xu = [uint64]$x
        if ($xu -lt $size) { [void]$offsets.Add($xu) }
    }
    if ($size -gt 2) { [void]$offsets.Add($size - 2) }
    $step = [uint64][math]::Max(1, [math]::Floor([double]$size / 40))
    for ([uint64]$o = 0; $o -lt $size; $o += $step) {
        if ($o -gt 0 -and $o -lt $size - 1) { [void]$offsets.Add($o) }
    }

    $out = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($off in $offsets) {
        if ($off -ge $size) { continue }
        $u = [uint32](([uint64]$net + $off) -band 0xFFFFFFFF)
        if ($u -ge $net -and $u -le $last) {
            [void]$out.Add((ConvertTo-StringIPv4 $u))
        }
    }
    return @($out)
}

function Test-CidrText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $n = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t -or $t -match '^\s*#') { continue }
        if ($t -match '::') { continue }
        if ($t -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') { $n++ }
    }
    return ($n -gt 0)
}

function Get-IPv4CidrRowsFromText([string]$Text) {
    return @(
        ($Text -split "`r?`n") | ForEach-Object {
            $t = $_.Trim()
            if ($t -match '^\s*#' -or $t.Length -lt 7) { return }
            if ($t -match '::') { return }
            if ($t -match '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') { $t }
        } | Select-Object -Unique
    )
}

function Invoke-TwfHttpGet {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec = 12
    )
    try {
        $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -Method Get
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300 -and $resp.Content) {
            return [string]$resp.Content
        }
    } catch {}

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) { return $null }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tg-curl-{0}.txt" -f [Guid]::NewGuid().ToString('n'))
    try {
        & $curl --ssl-no-revoke -fsSL --max-time $TimeoutSec -o $tmp $Uri 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)) {
            return [System.IO.File]::ReadAllText($tmp)
        }
    } catch {} finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    return $null
}

$script:TwfDohProviders = @(
    @{ Id = 'cf'; Base = 'https://cloudflare-dns.com/dns-query' },
    @{ Id = 'gg'; Base = 'https://dns.google/resolve' },
    @{ Id = 'q9'; Base = 'https://dns.quad9.net/dns-query' },
    @{ Id = 'ad'; Base = 'https://dns.adguard-dns.com/dns-query' },
    @{ Id = 'od'; Base = 'https://doh.opendns.com/dns-query' }
)

function Get-DohAnswerRecords {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][hashtable]$Provider,
        [ValidateSet('A', 'AAAA')][string]$QueryType = 'A'
    )
    $base = [string]$Provider.Base
    $sep = if ($base -match '\?') { '&' } else { '?' }
    $typeNum = if ($QueryType -eq 'AAAA') { 28 } else { 1 }
    $uri = $base + $sep + 'name=' + [uri]::EscapeDataString($Domain) + '&type=' + $typeNum
    try {
        $resp = Invoke-WebRequest -Uri $uri -Headers @{ Accept = 'application/dns-json' } -UseBasicParsing -TimeoutSec 6 -Method Get
        $j = $resp.Content | ConvertFrom-Json
        if ($null -eq $j -or $j.Status -ne 0 -or -not $j.Answer) { return @{ A = @(); Cname = @() } }
        $a = @()
        $cname = @()
        foreach ($ans in $j.Answer) {
            if ($null -eq $ans) { continue }
            $t = [int]$ans.type
            $d = [string]$ans.data
            if ($t -eq 1 -and $d -match '^\d{1,3}(\.\d{1,3}){3}$') {
                $a += $d.Trim()
            } elseif ($t -eq 5 -and $d) {
                $cname += $d.Trim().TrimEnd('.')
            }
        }
        return @{ A = @($a | Select-Object -Unique); Cname = @($cname | Select-Object -Unique) }
    } catch {
        return @{ A = @(); Cname = @() }
    }
}

function Resolve-DohIpv4 {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][hashtable]$Provider,
        [int]$Depth = 0
    )
    if ($Depth -gt 6) { return @() }
    $ans = Get-DohAnswerRecords -Domain $Domain -Provider $Provider -QueryType 'A'
    if ($ans.A.Count -gt 0) { return @($ans.A) }
    $found = @()
    foreach ($cn in $ans.Cname) {
        $found += @(Resolve-DohIpv4 -Domain $cn -Provider $Provider -Depth ($Depth + 1))
    }
    return @($found | Select-Object -Unique)
}

function Get-DohARecords {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][hashtable]$Provider
    )
    return @(Resolve-DohIpv4 -Domain $Domain -Provider $Provider)
}

function Get-DohARecordsAnyProvider {
    param([Parameter(Mandatory)][string[]]$Domains)
    $ips = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($dom in $Domains) {
        if (-not $dom) { continue }
        foreach ($prov in $script:TwfDohProviders) {
            foreach ($ip in (Get-DohARecords -Domain $dom -Provider $prov)) {
                [void]$ips.Add($ip)
            }
            if ($ips.Count -gt 0) { break }
        }
        if ($ips.Count -gt 0) { break }
    }
    return @($ips)
}

function Invoke-TwfHttpGetViaDohResolve {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$TimeoutSec = 8
    )
    $parsed = [uri]$Uri
    $hostName = $parsed.Host
    if (-not $hostName) { return $null }

    $lookupNames = @($hostName)
    if ($hostName -ne 'telegram.org') { $lookupNames += 'telegram.org' }

    $ips = @(Get-DohARecordsAnyProvider -Domains $lookupNames)
    if ($ips.Count -eq 0) {
        Write-Host '  [update] skip: official-doh (DoH: no A record)' -ForegroundColor DarkGray
        return $null
    }

    Write-Host ("  [update] try: {0} via DoH -> {1}" -f $hostName, ($ips -join ', ')) -ForegroundColor Cyan

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) {
        Write-Host '  [update] skip: official-doh (curl.exe not found)' -ForegroundColor DarkGray
        return $null
    }

    foreach ($ip in ($ips | Select-Object -First 6)) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tg-cidr-doh-{0}.txt" -f [Guid]::NewGuid().ToString('n'))
        try {
            $resolve = ('{0}:443:{1}' -f $hostName, $ip)
            & $curl --ssl-no-revoke -fsSL --max-time $TimeoutSec --resolve $resolve -o $tmp $Uri 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)) {
                $text = [System.IO.File]::ReadAllText($tmp)
                if (Test-CidrText $text) { return $text }
            }
        } catch {} finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host '  [update] skip: official-doh (TCP/TLS to resolved IP failed)' -ForegroundColor DarkGray
    return $null
}

function Test-ShouldRefreshBundledCidr {
    param([string]$SourceId)
    return @(
        'official', 'official-doh',
        'fernvenue-gh', 'fernvenue-gl', 'fernvenue-cdn',
        'cloudranges-gh', 'cloudranges-cdn'
    ) -contains $SourceId
}

function Save-BundledCidrSnapshot {
    param([string]$Text)
    if (-not (Test-CidrText $Text)) { return }
    try {
        $norm = (($Text -replace "`r`n", "`n") -replace "`r", "`n").Trim()
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText($BundledCidr, ($norm + "`r`n"), $utf8)
        Write-Host '  [update] saved fresh cidr -> lists\telegram-cidr-official.txt' -ForegroundColor DarkGray
    } catch {}
}

function Get-TelegramCidrContent {
    param([string]$PrimaryUrl)

    # Community mirrors sync from core.telegram.org daily (fernvenue/telegram-cidr-list).
    $attempts = @(
        @{ Id = 'official'; Kind = 'direct'; Uri = $PrimaryUrl },
        @{ Id = 'official-doh'; Kind = 'doh'; Uri = $PrimaryUrl },
        @{ Id = 'fernvenue-gh'; Kind = 'remote'; Uri = 'https://raw.githubusercontent.com/fernvenue/telegram-cidr-list/master/CIDR.txt' },
        @{ Id = 'fernvenue-gl'; Kind = 'remote'; Uri = 'https://gitlab.com/fernvenue/telegram-cidr-list/-/raw/master/CIDR.txt' },
        @{ Id = 'fernvenue-cdn'; Kind = 'remote'; Uri = 'https://cdn.jsdelivr.net/gh/fernvenue/telegram-cidr-list@master/CIDR.txt' },
        @{ Id = 'cloudranges-gh'; Kind = 'remote'; Uri = 'https://raw.githubusercontent.com/disposable/cloud-ip-ranges/master/txt/telegram.txt' },
        @{ Id = 'cloudranges-cdn'; Kind = 'remote'; Uri = 'https://cdn.jsdelivr.net/gh/disposable/cloud-ip-ranges@master/txt/telegram.txt' },
        @{ Id = 'repo-gh'; Kind = 'remote'; Uri = 'https://raw.githubusercontent.com/frdlss/telegram-web-hosts-fix/main/lists/telegram-cidr-official.txt' },
        @{ Id = 'repo-cdn'; Kind = 'remote'; Uri = 'https://cdn.jsdelivr.net/gh/frdlss/telegram-web-hosts-fix@main/lists/telegram-cidr-official.txt' },
        @{ Id = 'bundled'; Kind = 'local'; Uri = $BundledCidr }
    )

    foreach ($src in $attempts) {
        $text = $null
        if ($src.Kind -eq 'local') {
            if (Test-Path -LiteralPath $src.Uri) {
                Write-Host ("  [update] try: local {0}" -f (Split-Path -Leaf $src.Uri)) -ForegroundColor Cyan
                $text = [System.IO.File]::ReadAllText($src.Uri)
            }
        } elseif ($src.Kind -eq 'doh') {
            $text = Invoke-TwfHttpGetViaDohResolve -Uri $src.Uri -TimeoutSec 8
        } else {
            Write-Host ("  [update] try: {0}" -f $src.Uri) -ForegroundColor Cyan
            $text = Invoke-TwfHttpGet -Uri $src.Uri -TimeoutSec 8
        }

        if ($text -and (Test-CidrText $text)) {
            switch ($src.Id) {
                'official' {
                    Write-Host '  [update] source: core.telegram.org (direct)' -ForegroundColor Green
                }
                'official-doh' {
                    Write-Host '  [update] source: core.telegram.org (DoH + IP)' -ForegroundColor Green
                }
                'fernvenue-gh' { Write-Host '  [update] source: mirror fernvenue (GitHub, daily sync)' -ForegroundColor Green }
                'fernvenue-gl' { Write-Host '  [update] source: mirror fernvenue (GitLab, daily sync)' -ForegroundColor Green }
                'fernvenue-cdn' { Write-Host '  [update] source: mirror fernvenue (jsDelivr)' -ForegroundColor Green }
                'cloudranges-gh' { Write-Host '  [update] source: mirror cloud-ip-ranges (GitHub)' -ForegroundColor Green }
                'cloudranges-cdn' { Write-Host '  [update] source: mirror cloud-ip-ranges (jsDelivr)' -ForegroundColor Green }
                'repo-gh' { Write-Host '  [update] source: mirror repo (GitHub)' -ForegroundColor Yellow }
                'repo-cdn' { Write-Host '  [update] source: mirror repo (jsDelivr)' -ForegroundColor Yellow }
                'bundled' { Write-Host '  [update] source: bundled lists\telegram-cidr-official.txt' -ForegroundColor Yellow }
                default { Write-Host ("  [update] source: {0}" -f $src.Id) -ForegroundColor Yellow }
            }
            if (Test-ShouldRefreshBundledCidr $src.Id) {
                Save-BundledCidrSnapshot $text
            }
            return @{ Text = $text; SourceId = $src.Id }
        }
        if ($src.Kind -ne 'doh') {
            Write-Host ("  [update] skip: {0} (no IPv4 CIDR or timeout)" -f $src.Id) -ForegroundColor DarkGray
        }
    }

    return $null
}

$fetch = Get-TelegramCidrContent -PrimaryUrl $CidrUrl
if (-not $fetch) {
    Write-Host '  [update] ERROR: cidr.txt unavailable (official, mirrors, bundled file)' -ForegroundColor Red
    if (Test-Path -LiteralPath $ttfHelper) { . $ttfHelper }
    exit 1
}

$cidrRows = Get-IPv4CidrRowsFromText $fetch.Text
if (-not $cidrRows -or $cidrRows.Count -eq 0) {
    Write-Host '  [update] ERROR: no IPv4 CIDR lines in cidr.txt' -ForegroundColor Red
    if (Test-Path -LiteralPath $ttfHelper) { . $ttfHelper }
    exit 1
}

$seed = @(
    '149.154.175.50', '149.154.175.100', '149.154.175.209', '149.154.170.96',
    '149.154.167.40', '149.154.167.50', '149.154.167.51', '149.154.167.91',
    '149.154.167.99', '149.154.167.220', '149.154.168.98', '149.154.172.98',
    '91.108.56.100', '91.108.56.130', '91.108.56.181', '185.76.151.43'
)

$all = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($s in $seed) { [void]$all.Add($s) }

foreach ($row in $cidrRows) {
    foreach ($ip in (Get-CidrSampleIPv4s $row)) {
        [void]$all.Add($ip)
    }
}

function Sort-IPv4Strings {
    param([string[]]$Ips)
    return @(
        $Ips | Sort-Object {
            $p = $_.Split('.')
            [uint32]([uint32]$p[0] * 16777216 + [uint32]$p[1] * 65536 + [uint32]$p[2] * 256 + [uint32]$p[3])
        }
    )
}

$seedOrdered = @($seed | Where-Object { $all.Contains($_) })
$rest = @($all | Where-Object { $seedOrdered -notcontains $_ })
$restSorted = Sort-IPv4Strings $rest
$ordered = @($seedOrdered) + @($restSorted)

$built = (Get-Date).ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
$sourceNote = switch ($fetch.SourceId) {
    'official' { 'https://core.telegram.org/resources/cidr.txt' }
    'official-doh' { 'https://core.telegram.org/resources/cidr.txt (DoH resolve + direct IP)' }
    'fernvenue-gh' { 'mirror: github.com/fernvenue/telegram-cidr-list (daily)' }
    'fernvenue-gl' { 'mirror: gitlab.com/fernvenue/telegram-cidr-list (daily)' }
    'fernvenue-cdn' { 'mirror: cdn.jsdelivr.net/gh/fernvenue/telegram-cidr-list' }
    'cloudranges-gh' { 'mirror: github.com/disposable/cloud-ip-ranges' }
    'cloudranges-cdn' { 'mirror: cdn.jsdelivr.net/gh/disposable/cloud-ip-ranges' }
    'repo-gh' { 'mirror: github.com/frdlss/telegram-web-hosts-fix' }
    'repo-cdn' { 'mirror: cdn.jsdelivr.net/gh/frdlss/telegram-web-hosts-fix' }
    'bundled' { 'bundled: lists/telegram-cidr-official.txt' }
    default { 'unknown' }
}
$header = @(
    '# Telegram Web Fix — IPv4 candidates for menu [4]',
    "# Source: $sourceNote",
    '# Refresh: menu [5] or: powershell -File utils\update-ip-candidates.ps1',
    ('# twf-build {0} | CIDR blocks: {1} | unique IPv4: {2} (seed + CIDR only, no merge with old file)' -f $built, $cidrRows.Count, $ordered.Count),
    ''
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
$body = ($ordered -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($OutFile, (($header -join "`r`n") + $body), $utf8)

if (Test-Path -LiteralPath $FailedFile) {
    Remove-Item -LiteralPath $FailedFile -Force -ErrorAction SilentlyContinue
    Write-Host '  [update] сброшен кэш lists\telegram-ip-failed.txt (старые неудачи не мешают новому списку)' -ForegroundColor DarkGray
}

Write-Host ("  [update] OK -> {0}" -f $OutFile) -ForegroundColor Green
Write-Host ("  [update] CIDR lines: {0} | IPs written: {1}" -f $cidrRows.Count, $ordered.Count) -ForegroundColor Gray

if (Test-Path -LiteralPath $ttfHelper) { . $ttfHelper }

exit 0
