# Safe hosts apply/remove for Telegram Web Fix only.
# Does NOT change proxy, firewall, or other apps - hosts file only.
param(
    [Parameter(Mandatory)][ValidateSet('Apply', 'Remove', 'Verify')][string]$Action,
    [string]$Ip = '',
    [string]$HostsPath = "$env:SystemRoot\System32\drivers\etc\hosts",
    [string]$Marker = '# telegram-web-fix',
    [string]$DomainsFile = '',
    [string]$BackupDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $DomainsFile) { throw 'DomainsFile required' }
if (-not (Test-Path -LiteralPath $DomainsFile)) { throw "Domains file not found: $DomainsFile" }

$domains = Get-Content -LiteralPath $DomainsFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^\s*#' }

if (-not $domains) { throw 'No domains in list' }

$domainAlt = ($domains | ForEach-Object { [regex]::Escape($_) }) -join '|'
$lineRe = "^\s*\d{1,3}(?:\.\d{1,3}){3}\s+(?:$domainAlt)\s*$"
$MarkerLegacy = '# zapret-telegram-web-fix'

function Get-NormalLine {
    param([string]$Line)
    if ($null -eq $Line) { return '' }
    return $Line.TrimStart([char]0xFEFF).TrimEnd("`r").Trim()
}

function Unlock-HostsFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        $fi = Get-Item -LiteralPath $Path -Force
        if ($fi.IsReadOnly) { $fi.IsReadOnly = $false }
    } catch {}
    try {
        $null = & cmd.exe /c "attrib -R `"$Path`"" 2>$null
    } catch {}
}

function Read-HostsLines {
    if (-not (Test-Path -LiteralPath $HostsPath)) { return @() }
    Unlock-HostsFile $HostsPath
    try {
        return [string[]][System.IO.File]::ReadAllLines($HostsPath, [System.Text.Encoding]::UTF8)
    } catch {
        try {
            return [string[]][System.IO.File]::ReadAllLines($HostsPath)
        } catch {
            return [string[]](Get-Content -LiteralPath $HostsPath -ErrorAction Stop)
        }
    }
}

function New-LineList {
    $list = New-Object System.Collections.ArrayList
    foreach ($l in (Read-HostsLines)) {
        [void]$list.Add([string]$l)
    }
    return $list
}

function Remove-OurLines([System.Collections.ArrayList]$lines) {
    $removed = 0
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in $lines) {
        $n = Get-NormalLine $l
        if ($n -eq $Marker -or $n -eq $MarkerLegacy) { $removed++; continue }
        if ($n -match $lineRe) { $removed++; continue }
        [void]$keep.Add([string]$l)
    }
    return @{ Keep = $keep; Removed = $removed }
}

function Write-Lines([System.Collections.ArrayList]$lines) {
    if (-not (Test-Path -LiteralPath $HostsPath)) {
        throw "Hosts not found: $HostsPath"
    }
    Unlock-HostsFile $HostsPath
    $text = ($lines.ToArray() -join "`r`n").TrimEnd() + "`r`n"
    try {
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($HostsPath, $text, $enc)
    } catch {
        try {
            [System.IO.File]::WriteAllText($HostsPath, $text, [System.Text.Encoding]::ASCII)
        } catch {
            throw "Cannot write hosts ($HostsPath): $($_.Exception.Message)"
        }
    }
}

function Backup-Hosts {
    if (-not $BackupDir) { return }
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $dest = Join-Path $BackupDir 'hosts.backup'
    if (-not (Test-Path -LiteralPath $dest)) {
        Copy-Item -LiteralPath $HostsPath -Destination $dest -Force
    }
}

trap {
    $msg = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $_.ToString() }
    if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240).TrimEnd() }
    [Console]::Error.WriteLine("tg-hosts: $msg")
    exit 1
}

switch ($Action) {
    'Apply' {
        if (-not $Ip -or $Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Invalid IP: $Ip" }
        if (-not (Test-Path -LiteralPath $HostsPath)) { throw "Hosts not found: $HostsPath" }
        Backup-Hosts
        $lines = New-LineList
        $r = Remove-OurLines $lines
        [void]$r.Keep.Add('')
        [void]$r.Keep.Add($Marker)
        foreach ($d in $domains) { [void]$r.Keep.Add("$Ip $d") }
        Write-Lines $r.Keep
        exit 0
    }
    'Remove' {
        if (-not (Test-Path -LiteralPath $HostsPath)) { throw "Hosts not found: $HostsPath" }
        $lines = New-LineList
        $r = Remove-OurLines $lines
        Write-Lines $r.Keep
        # Диагностика: не считаем ошибкой (не exit 1) — иначе cmd ломался у части пользователей,
        # а ложные «остатки» возможны из‑за кодировки/пробелов в hosts.
        $left = 0
        if (Test-Path -LiteralPath $HostsPath) {
            foreach ($l in Get-Content -LiteralPath $HostsPath) {
                $n = Get-NormalLine $l
                if ($n -eq $Marker -or $n -eq $MarkerLegacy) { $left++; continue }
                if ($n -match $lineRe) { $left++ }
            }
        }
        if ($left -gt 0) {
            [Console]::Error.WriteLine("tg-hosts: после Remove осталось строк с маркером/доменами: $left (проверьте hosts вручную)")
        }
        exit 0
    }
    'Verify' {
        if (-not (Test-Path -LiteralPath $HostsPath)) { exit 0 }
        $left = 0
        foreach ($l in Get-Content -LiteralPath $HostsPath) {
            $n = Get-NormalLine $l
            if ($n -eq $Marker -or $n -eq $MarkerLegacy) { $left++; continue }
            if ($n -match $lineRe) { $left++ }
        }
        if ($left -gt 0) { exit 1 }
        exit 0
    }
}
