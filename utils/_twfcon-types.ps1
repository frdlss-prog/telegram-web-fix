# Кеш [TwfCon]: сначала utils\twf-console-types-v2.dll (без csc), иначе TEMP или компиляция.
#
# Использование: . "$PSScriptRoot\_twfcon-types.ps1"
# После dot-source доступны: [TwfCon] (P/Invoke методы) и [TwfCon+CONSOLE_FONT_INFOEX] (struct).

$ErrorActionPreference = 'SilentlyContinue'

$global:TwfConDllPath = $null

if (-not ('TwfCon' -as [type])) {
    # Локальная DLL рядом со скриптом: без csc при первом запуске — нет мигания растра ~0.5 с.
    $bundled = Join-Path $PSScriptRoot 'twf-console-types-v2.dll'
    if (Test-Path -LiteralPath $bundled) {
        try { Add-Type -Path $bundled -ErrorAction Stop } catch { }
    }
}

if (-not ('TwfCon' -as [type])) {
    $cacheDir = $env:TEMP
    if (-not $cacheDir -or -not (Test-Path -LiteralPath $cacheDir)) {
        $cacheDir = [System.IO.Path]::GetTempPath()
    }
    $global:TwfConDllPath = Join-Path $cacheDir 'twf-console-types-v2.dll'

    # Попытка загрузить из кеша (csc.exe НЕ запускается).
    if (Test-Path -LiteralPath $global:TwfConDllPath) {
        try {
            Add-Type -Path $global:TwfConDllPath -ErrorAction Stop
        } catch {
            try { Remove-Item -LiteralPath $global:TwfConDllPath -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

if (-not ('TwfCon' -as [type])) {
    $src = @'
using System;
using System.Runtime.InteropServices;
public static class TwfCon {
    public const int STD_OUTPUT_HANDLE = -11;
    public const int STD_INPUT_HANDLE = -10;
    public const uint GENERIC_READ = 0x80000000;
    public const uint GENERIC_WRITE = 0x40000000;
    public const uint OPEN_EXISTING = 3;
    public const uint FILE_SHARE_READ = 1;
    public const uint FILE_SHARE_WRITE = 2;

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool GetConsoleMode(IntPtr h, out uint m);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr CreateFileW(string fn, uint da, uint sm,
        IntPtr sa, uint cd, uint fa, IntPtr tf);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref CONSOLE_FONT_INFOEX f);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref CONSOLE_FONT_INFOEX f);

    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool FlushConsoleInputBuffer(IntPtr h);

    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct CONSOLE_FONT_INFOEX {
        public uint cbSize;
        public uint nFont;
        public short dwFontSizeX;
        public short dwFontSizeY;
        public uint FontFamily;
        public uint FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]
        public string FaceName;
    }
}
'@
    # Первый запуск: компилируем в DLL и кладём в TEMP. csc.exe — единичный спавн на сессию.
    $compiled = $false
    if ($global:TwfConDllPath) {
        try {
            Add-Type -OutputAssembly $global:TwfConDllPath -TypeDefinition $src -ErrorAction Stop
            $compiled = $true
        } catch { }
    }
    if (-not $compiled) {
        # Если в TEMP писать нельзя — компилируем только в память.
        try { Add-Type -TypeDefinition $src -ErrorAction Stop } catch { }
    }
}
