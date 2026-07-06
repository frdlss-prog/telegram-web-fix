# Принудительно ставим Consolas TTF в текущей консоли через SetCurrentConsoleFontEx.
# Используется через dot-source: . "$PSScriptRoot\ensure-console-ttf.ps1"
#
# ВАЖНО: НЕ проверяем GetCurrentConsoleFontEx — он врёт.
# После CP65001 + Write-Host с кириллицей conhost рендерит растровый "Terminal",
# а API всё ещё возвращает FaceName='Consolas' и бит TMPF_TRUETYPE.
# Поэтому всегда форсируем SetCurrentConsoleFontEx.
#
# P/Invoke берём из кеша (_twfcon-types.ps1) → csc.exe НЕ запускается на каждый вызов.

try {
    $ttfTypes = Join-Path $PSScriptRoot '_twfcon-types.ps1'
    if (Test-Path -LiteralPath $ttfTypes) { . $ttfTypes }

    if ('TwfCon' -as [type]) {
        $hOut = [TwfCon]::GetStdHandle([TwfCon]::STD_OUTPUT_HANDLE)
        $modeProbe = [uint32]0
        $hOpened = $false
        if ($hOut -eq [IntPtr]::Zero -or $hOut -eq [IntPtr]::new(-1) -or -not [TwfCon]::GetConsoleMode($hOut, [ref]$modeProbe)) {
            $hOut = [TwfCon]::CreateFileW('CONOUT$',
                [TwfCon]::GENERIC_READ -bor [TwfCon]::GENERIC_WRITE,
                [TwfCon]::FILE_SHARE_READ -bor [TwfCon]::FILE_SHARE_WRITE,
                [IntPtr]::Zero, [TwfCon]::OPEN_EXISTING, 0, [IntPtr]::Zero)
            $hOpened = $true
        }
        if ($hOut -ne [IntPtr]::Zero -and $hOut -ne [IntPtr]::new(-1)) {
            $cf = [TwfCon+CONSOLE_FONT_INFOEX]::new()
            $cf.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf([Type][TwfCon+CONSOLE_FONT_INFOEX])
            $cf.FaceName = 'Consolas'
            $cf.nFont = 0
            $cf.dwFontSizeX = 0
            $cf.dwFontSizeY = 20
            # FF_MODERN(0x30) | TMPF_VECTOR(0x02) | TMPF_TRUETYPE(0x04) = 0x36 = 54
            $cf.FontFamily = 54
            $cf.FontWeight = 400
            # Без проверки API: всегда применяем. Два захода — некоторые билды Windows
            # реально применяют только при MaximumWindow=$true, другие — только при $false.
            [void][TwfCon]::SetCurrentConsoleFontEx($hOut, $false, [ref]$cf)
            [void][TwfCon]::SetCurrentConsoleFontEx($hOut, $true,  [ref]$cf)
            if ($hOpened) { [void][TwfCon]::CloseHandle($hOut) }
        }
    }
} catch { }
