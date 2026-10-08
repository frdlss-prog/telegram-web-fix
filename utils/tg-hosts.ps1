# Safe hosts apply/remove for Telegram Web Fix only.
# Does NOT change proxy, firewall, or other apps - hosts file only.
param(
    [Parameter(Mandatory)][ValidateSet('Apply', 'Remove', 'Verify')][string]$Action,
    [string]$Ip = '',
    [string]$HostsPath = '',
    [string]$Marker = '# telegram-web-fix',
    [string]$DomainsFile = '',
    [string]$BackupDir = ''
)

$ErrorActionPreference = 'Stop'

# До любой другой работы: powershell.exe при старте мог поставить растровый шрифт.
$ttfHelper = Join-Path $PSScriptRoot 'ensure-console-ttf.ps1'
if (Test-Path -LiteralPath $ttfHelper) { . $ttfHelper }

if (-not $DomainsFile) { throw 'DomainsFile required' }
if (-not (Test-Path -LiteralPath $DomainsFile)) { throw "Domains file not found: $DomainsFile" }

$domains = Get-Content -LiteralPath $DomainsFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^\s*#' }

if (-not $domains) { throw 'No domains in list' }

$domainAlt = ($domains | ForEach-Object { [regex]::Escape($_) }) -join '|'
# Строка нашего блока: IPv4 фикса или ::1, чтобы AAAA не уводил браузер мимо hosts.
$lineRe = "^\s*(?:\d{1,3}(?:\.\d{1,3}){3}|::1)\s+(?:$domainAlt)\s*$"
$MarkerLegacy = '# zapret-telegram-web-fix'

function Resolve-HostsPath {
    param([string]$Preferred = '')
    $default32 = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $sysnative = Join-Path $env:SystemRoot 'Sysnative\drivers\etc\hosts'

    # Явный кастомный путь (тесты/override) — не перенаправляем.
    if ($Preferred -and ($Preferred -ne $default32) -and ($Preferred -ne $sysnative)) {
        return $Preferred
    }

    # 32-bit PS на 64-bit Windows: System32 редиректится в SysWOW64 — реальный hosts через Sysnative.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        if (Test-Path -LiteralPath $sysnative) { return $sysnative }
        $sysnativeDir = Split-Path -Parent $sysnative
        if (Test-Path -LiteralPath $sysnativeDir) { return $sysnative }
    }

    if ($Preferred) { return $Preferred }
    return $default32
}

$HostsPath = Resolve-HostsPath -Preferred $HostsPath

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

function Ensure-HostsFile {
    if (Test-Path -LiteralPath $HostsPath) { return }
    $dir = Split-Path -Parent $HostsPath
    if (-not (Test-Path -LiteralPath $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        } catch {
            throw "Cannot create hosts directory ($dir): $($_.Exception.Message)"
        }
    }
    # Minimal default like a fresh Windows hosts (file often deleted by cleaners).
    $seed = @(
        '# Copyright (c) 1993-2009 Microsoft Corp.',
        '#',
        '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.',
        '#',
        '# localhost name resolution is handled within DNS itself.',
        '#	127.0.0.1       localhost',
        '#	::1             localhost',
        ''
    ) -join "`r`n"
    try {
        $enc = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($HostsPath, $seed + "`r`n", $enc)
    } catch {
        throw "Cannot create hosts ($HostsPath): $($_.Exception.Message). Запустите от администратора; антивирус может блокировать создание файла."
    }
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
    # Только блок под маркером. Чужая строка «IP t.me» без маркера остаётся.
    $removed = 0
    $keep = New-Object System.Collections.ArrayList
    $inBlock = $false
    foreach ($l in $lines) {
        $n = Get-NormalLine $l
        if ($n -eq $Marker -or $n -eq $MarkerLegacy) {
            $inBlock = $true
            $removed++
            continue
        }
        if ($inBlock) {
            if ($n -match $lineRe) {
                $removed++
                continue
            }
            $inBlock = $false
        }
        [void]$keep.Add([string]$l)
    }
    return @{ Keep = $keep; Removed = $removed }
}

function Write-Lines([System.Collections.ArrayList]$lines) {
    Ensure-HostsFile
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
    if (-not (Test-Path -LiteralPath $HostsPath)) { return }
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    $last = Join-Path $BackupDir 'hosts-last.backup'
    Copy-Item -LiteralPath $HostsPath -Destination $last -Force
    $dest = Join-Path $BackupDir 'hosts.backup'
    if (-not (Test-Path -LiteralPath $dest)) {
        Copy-Item -LiteralPath $HostsPath -Destination $dest -Force
    }
}

trap {
    $msg = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $_.ToString() }
    if ($msg -match '(?i)access|denied|отказано|запрещен|Unauthorized') {
        $msg = "нет доступа к hosts — запустите bat от имени администратора (UAC)"
    }
    if ($msg.Length -gt 240) { $msg = $msg.Substring(0, 240).TrimEnd() }
    [Console]::Error.WriteLine("tg-hosts: $msg")
    exit 1
}

switch ($Action) {
    'Apply' {
        if (-not $Ip -or $Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Invalid IP: $Ip" }
        # Hosts часто удаляют «чистильщики» — создаём заново, не падаем с «Hosts not found».
        Ensure-HostsFile
        Backup-Hosts
        $lines = New-LineList
        $r = Remove-OurLines $lines
        [void]$r.Keep.Add('')
        [void]$r.Keep.Add($Marker)
        foreach ($d in $domains) { [void]$r.Keep.Add("$Ip $d") }
        # Иначе браузер берёт AAAA из DNS и обходит IPv4-запись в hosts.
        foreach ($d in $domains) { [void]$r.Keep.Add("::1 $d") }
        Write-Lines $r.Keep
        exit 0
    }
    'Remove' {
        # Нет файла — нечего снимать.
        if (-not (Test-Path -LiteralPath $HostsPath)) { exit 0 }
        $lines = New-LineList
        $r = Remove-OurLines $lines
        Write-Lines $r.Keep
        # Диагностика: не считаем ошибкой (не exit 1) — иначе cmd ломался у части пользователей,
        # а ложные «остатки» возможны из‑за кодировки/пробелов в hosts.
        $left = 0
        if (Test-Path -LiteralPath $HostsPath) {
            foreach ($l in Get-Content -LiteralPath $HostsPath) {
                $n = Get-NormalLine $l
                if ($n -eq $Marker -or $n -eq $MarkerLegacy) { $left++ }
            }
        }
        if ($left -gt 0) {
            [Console]::Error.WriteLine("tg-hosts: после Remove маркер остался в hosts ($left). Проверьте файл вручную.")
        }
        exit 0
    }
    'Verify' {
        if (-not (Test-Path -LiteralPath $HostsPath)) { exit 0 }
        $left = 0
        foreach ($l in Get-Content -LiteralPath $HostsPath) {
            $n = Get-NormalLine $l
            if ($n -eq $Marker -or $n -eq $MarkerLegacy) { $left++ }
        }
        if ($left -gt 0) { exit 1 }
        exit 0
    }
}
