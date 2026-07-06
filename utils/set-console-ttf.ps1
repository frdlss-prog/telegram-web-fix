# Один проход: при -LayoutCols при необходимости mode + TTF + Clear-Host (без отдельного mode/cls в bat).
# При -RemountFont — только Try-SetFace (после видимого/скрытого PS conhost мог уйти в растр).
#
# P/Invoke берём из кеша (_twfcon-types.ps1) → csc.exe запускается ОДИН раз за всю сессию.
# Это ключевая часть: именно csc.exe из Add-Type сбрасывает шрифт conhost на растр при каждом вызове.

param(
    [int]$LayoutCols = 0,
    [int]$LayoutRows = 0,
    [int]$BufferLines = 3000,
    [switch]$RemountFont,
    # Принудительный Clear-Host в конце даже при -RemountFont. Нужен для второго прохода
    # в :setup_console: после первого прохода csc.exe мог оставить растр; Clear-Host
    # форсирует conhost перерисовать всё уже установленным TTF-шрифтом.
    [switch]$ForceClear
)

$ErrorActionPreference = 'Stop'

# Подгружаем [TwfCon] (P/Invoke) из общего кеша.
$ttfTypes = Join-Path $PSScriptRoot '_twfcon-types.ps1'
if (Test-Path -LiteralPath $ttfTypes) { . $ttfTypes }

if (-not ('TwfCon' -as [type])) {
    # Если по какой-то причине [TwfCon] не загрузился — выходим тихо, без поломки.
    exit 0
}

function Get-CmdExeConsoleRegPath {
    $exe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    if ($exe.Length -lt 4) { return $null }
    $tail = $exe.Substring(3).Replace('\', '_')
    return $exe[0] + ':_' + $tail
}

function Apply-ConsoleRegistryFont {
    param(
        [Parameter(Mandatory)][string]$Face,
        [Parameter(Mandatory)][string]$RegPath
    )
    if (-not (Test-Path -LiteralPath $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $RegPath -Name 'FaceName' -Value $Face -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $RegPath -Name 'FontFamily' -Value 54 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $RegPath -Name 'FontWeight' -Value 400 -Type DWord -Force -ErrorAction SilentlyContinue
    # Явный FontSize: high word = pixel height (20), low word = 0 (auto).
    # Без него conhost при холодном старте может пасть на растр 8x12.
    Set-ItemProperty -LiteralPath $RegPath -Name 'FontSize' -Value 0x00140000 -Type DWord -Force -ErrorAction SilentlyContinue
}

function Apply-ConsoleWindowGeometry {
    param([Parameter(Mandatory)][string]$RegPath)
    if (-not (Test-Path -LiteralPath $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }
    $cols = 100
    $rows = 40
    $bufH = if ($null -ne $BufferLines -and [int]$BufferLines -gt 0) {
        [Math]::Min([int]$BufferLines, 32767)
    } else { 3000 }
    $win = ($rows -shl 16) -bor ($cols -band 0xFFFF)
    $buf = ($bufH -shl 16) -bor ($cols -band 0xFFFF)
    Set-ItemProperty -LiteralPath $RegPath -Name 'WindowSize' -Value $win -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $RegPath -Name 'ScreenBufferSize' -Value $buf -Type DWord -Force -ErrorAction SilentlyContinue
}

function Invoke-TwfLayoutModeIfNeeded {
    param([int]$cols, [int]$rows)
    if ($cols -le 0 -or $rows -le 0) { return }
    $need = $true
    try {
        if ($null -ne $Host.UI -and $null -ne $Host.UI.RawUI) {
            $rw = $Host.UI.RawUI.WindowSize
            if ([int]$rw.Width -eq $cols -and [int]$rw.Height -eq $rows) { $need = $false }
        }
    } catch { }
    if (-not $need) { return }
    $cmdPath = Join-Path $env:WINDIR 'System32\cmd.exe'
    & $cmdPath /c "mode con: cols=$cols lines=$rows >nul 2>&1"
}

$root = 'HKCU:\Console'
if (-not (Test-Path -LiteralPath $root)) {
    New-Item -Path $root -Force | Out-Null
}
Set-ItemProperty -LiteralPath $root -Name 'ForceV2' -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

$cmdSub = Get-CmdExeConsoleRegPath
$regTargets = @($root)
if ($cmdSub) {
    $regTargets += (Join-Path $root $cmdSub)
}

if (-not $RemountFont) {
    Invoke-TwfLayoutModeIfNeeded -cols $LayoutCols -rows $LayoutRows
}

# Получаем хэндл консоли (через STD_OUTPUT, иначе через CONOUT$).
$hStd = [TwfCon]::GetStdHandle([TwfCon]::STD_OUTPUT_HANDLE)
$h = [IntPtr]::Zero
$mode = [uint32]0
if ($hStd -ne [IntPtr]::Zero -and $hStd -ne [IntPtr]::new(-1)) {
    if ([TwfCon]::GetConsoleMode($hStd, [ref]$mode)) { $h = $hStd }
}
if ($h -eq [IntPtr]::Zero) {
    $h = [TwfCon]::CreateFileW(
        'CONOUT$',
        [TwfCon]::GENERIC_READ -bor [TwfCon]::GENERIC_WRITE,
        [TwfCon]::FILE_SHARE_READ -bor [TwfCon]::FILE_SHARE_WRITE,
        [IntPtr]::Zero,
        [TwfCon]::OPEN_EXISTING,
        0,
        [IntPtr]::Zero)
}
if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]::new(-1)) { exit 0 }

$size = [uint32][Runtime.InteropServices.Marshal]::SizeOf([Type][TwfCon+CONSOLE_FONT_INFOEX])

function Try-SetFace {
    param([string]$face, [int]$fontY)
    foreach ($reg in $regTargets) {
        try {
            Apply-ConsoleRegistryFont -Face $face -RegPath $reg
        } catch { }
    }

    $t = [TwfCon+CONSOLE_FONT_INFOEX]::new()
    $t.cbSize = $size
    # Не доверяем результату GetCurrentConsoleFontEx (часто врёт при растре на экране).
    [void][TwfCon]::GetCurrentConsoleFontEx($h, $false, [ref]$t)

    $t.FaceName = $face
    $t.nFont = 0
    $t.dwFontSizeX = 0
    $t.dwFontSizeY = [int16]$fontY
    $t.FontFamily = 54
    $t.FontWeight = 400

    # Применяем оба варианта (некоторые сборки Windows честно ставят шрифт только при MaxWin=$true).
    $okAny = $false
    foreach ($max in @($false, $true)) {
        if ([TwfCon]::SetCurrentConsoleFontEx($h, $max, [ref]$t)) {
            $okAny = $true
        }
    }
    return $okAny
}

function Invoke-TwfClearIfLayout {
    if ($ForceClear) {
        try { Clear-Host } catch { }
        return
    }
    if ($RemountFont) { return }
    if ($LayoutCols -le 0) { return }
    try { Clear-Host } catch { }
}

# НИКАКИХ early-exit на проверке API.
# GetCurrentConsoleFontEx после csc.exe (Add-Type) или mode con: возвращает FaceName='Consolas'
# и бит TMPF_TRUETYPE, при этом conhost рендерит растровый "Terminal".
# Поэтому всегда проходим через Try-SetFace — это форсирует SetCurrentConsoleFontEx
# и реально перезаряжает шрифт в conhost. Один Win32-вызов, мгновенно.

if (-not $RemountFont) {
    foreach ($reg in $regTargets) {
        try { Apply-ConsoleWindowGeometry -RegPath $reg } catch { }
    }
}

$faces = @(
    @{ N = 'Consolas'; Y = 20 },
    @{ N = 'Consolas'; Y = 18 },
    @{ N = 'Consolas'; Y = 16 },
    @{ N = 'Consolas'; Y = 22 },
    @{ N = 'Lucida Console'; Y = 20 },
    @{ N = 'Lucida Console'; Y = 18 },
    @{ N = 'Lucida Console'; Y = 16 },
    @{ N = 'Cascadia Mono'; Y = 20 },
    @{ N = 'Cascadia Mono'; Y = 18 },
    @{ N = 'Cascadia Code'; Y = 20 },
    @{ N = 'Segoe UI Mono'; Y = 20 },
    @{ N = 'Courier New'; Y = 20 }
)

foreach ($item in $faces) {
    if (Try-SetFace -face $item.N -fontY $item.Y) {
        Invoke-TwfClearIfLayout
        # Один процесс bootstrap: после первого успешного Set (и csc при первом старте) conhost
        # может оставить растр — второй быстрый Try-SetFace + Clear без второго powershell.exe.
        if (-not $RemountFont -and $LayoutCols -gt 0) {
            foreach ($item2 in $faces) {
                if (Try-SetFace -face $item2.N -fontY $item2.Y) { break }
            }
            try { Clear-Host } catch { }
        }
        exit 0
    }
}

Invoke-TwfClearIfLayout
exit 0
