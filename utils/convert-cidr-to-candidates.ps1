# Expand official Telegram IPv4 CIDR blocks into lists/telegram-ip-candidates-from-cidr.txt
# Usage: powershell -File utils\convert-cidr-to-candidates.ps1
# Friend renames/copies output to lists\telegram-ip-candidates.txt

param(
    [string[]]$Cidr = @(
        '91.108.56.0/22',
        '91.108.4.0/22',
        '91.108.8.0/22',
        '91.108.16.0/22',
        '91.108.12.0/22',
        '149.154.160.0/20',
        '91.105.192.0/23',
        '91.108.20.0/22',
        '185.76.151.0/24'
    )
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$OutFile = Join-Path $Root 'lists\telegram-ip-candidates-from-cidr.txt'

function ConvertTo-UInt32IPv4([string]$s) {
    $a = $s.Split('.')
    return [uint32]([uint32]$a[0] * 16777216 + [uint32]$a[1] * 65536 + [uint32]$a[2] * 256 + [uint32]$a[3])
}

function ConvertTo-StringIPv4([uint32]$u) {
    return '{0}.{1}.{2}.{3}' -f (($u -shr 24) -band 0xFF), (($u -shr 16) -band 0xFF), (($u -shr 8) -band 0xFF), ($u -band 0xFF)
}

function Get-CidrSampleIPv4s {
    param([string]$CidrStr)
    if ($CidrStr -notmatch '^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/(\d{1,2})$') { return @() }
    $netStr = $Matches[1]
    $pref = [int]$Matches[2]
    if ($pref -lt 8 -or $pref -gt 32) { return @() }
    $ipUint = ConvertTo-UInt32IPv4 $netStr
    $hostBits = 32 - $pref
    if ($hostBits -le 0) { return @(ConvertTo-StringIPv4 $ipUint) }
    [uint64]$size = 1
    for ($i = 0; $i -lt $hostBits; $i++) { $size = $size * 2 }
    [uint32]$mask = 0
    for ($i = 0; $i -lt $pref; $i++) { $mask = [uint32](([uint64]$mask -shl 1) -bor 1) }
    for ($i = 0; $i -lt $hostBits; $i++) { $mask = [uint32]([uint64]$mask -shl 1) }
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

$seed = @(
    '149.154.175.50', '149.154.175.100', '149.154.175.209', '149.154.170.96',
    '149.154.167.40', '149.154.167.50', '149.154.167.51', '149.154.167.91',
    '149.154.167.99', '149.154.167.220', '149.154.168.98', '149.154.172.98',
    '91.108.56.100', '91.108.56.130', '91.108.56.181', '185.76.151.43'
)

$all = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($s in $seed) { [void]$all.Add($s) }
foreach ($row in $Cidr) {
    foreach ($ip in (Get-CidrSampleIPv4s $row)) { [void]$all.Add($ip) }
}

$rest = @($all | Where-Object { $seed -notcontains $_ } | Sort-Object {
    $p = $_.Split('.')
    [uint32]([uint32]$p[0] * 16777216 + [uint32]$p[1] * 65536 + [uint32]$p[2] * 256 + [uint32]$p[3])
})
$ordered = @($seed) + @($rest)

$header = @(
    '# Telegram Web Fix — IPv4 candidates (converted from official CIDR)',
    '# Source blocks: https://core.telegram.org/resources/cidr.txt',
    '# IPv6 lines from cidr.txt are ignored (this tool uses IPv4 only)',
    ('# twf-manual-cidr | CIDR blocks: {0} | unique IPv4: {1}' -f $Cidr.Count, $ordered.Count),
    '# Copy/rename to lists\telegram-ip-candidates.txt, then menu [4] -> [1]',
    ''
)

$utf8 = [System.Text.UTF8Encoding]::new($false)
$body = ($ordered -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($OutFile, (($header -join "`r`n") + $body), $utf8)

Write-Host ("OK: {0} IPv4 -> {1}" -f $ordered.Count, $OutFile) -ForegroundColor Green
exit 0
