@echo off
rem Без прав — сразу скрытый запрос UAC и выход. Это окно не рисуем и не держим.
if /i "%~1"=="__run" goto :prep
if /i "%~1"=="enable-silent" goto :prep
if /i "%~1"=="disable-silent" goto :prep
fltmc >nul 2>&1
if %errorlevel% equ 0 goto :prep
start "" wscript.exe //nologo //B "%~dp0utils\elevate.vbs" "%~f0"
exit /b 0
:prep
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul 2>&1
cd /d "%~dp0"
title Telegram Web Fix
set "TWF_COLS=100"
set "TWF_LINES=40"
rem 32-bit cmd на 64-bit Windows: System32 → SysWOW64, реального hosts там нет.
set "HOSTS=%SystemRoot%\System32\drivers\etc\hosts"
if exist "%SystemRoot%\Sysnative\drivers\etc\hosts" set "HOSTS=%SystemRoot%\Sysnative\drivers\etc\hosts"
if not exist "%HOSTS%" if exist "%SystemRoot%\Sysnative\drivers\etc" set "HOSTS=%SystemRoot%\Sysnative\drivers\etc\hosts"
set "MARKER=# telegram-web-fix"
set "MARKER_LEGACY=# zapret-telegram-web-fix"
set "CFG=%~dp0telegram-web-ip.cfg"
set "PS_DETECT=%~dp0utils\telegram-autodetect.ps1"
set "PS_UPDATE=%~dp0utils\update-ip-candidates.ps1"
set "PS_HOSTS=%~dp0utils\tg-hosts.ps1"
set "DOMAINS=%~dp0lists\telegram-hosts-domains.txt"
set "BACKUP=%~dp0backup"
if /i "%~1"=="enable-silent" goto :enable_cli
if /i "%~1"=="disable-silent" goto :disable_cli
if /i "%~1"=="__run" (
    shift /1
    goto :bootstrap
)
goto :bootstrap
:bootstrap
@echo off
chcp 65001 >nul 2>&1
rem Шрифт в реестре до первого powershell: иначе каждый пункт на полсекунды падает в растр.
call :pin_console_font
rem Шрифт/layout до init_esc: for /f для ESC раньше давал лишний «миг» после chcp.
call :setup_console
rem ESC-коды один раз: переменные R/GRN/... сохраняются на всю сессию.
call :init_esc
call :load_ip
goto :menu
:enable_cli
fltmc >nul 2>&1
if %errorlevel% neq 0 exit /b 1
call :require_cfg
if errorlevel 1 exit /b 2
call :apply_hosts
exit /b %errorlevel%
:disable_cli
fltmc >nul 2>&1
if %errorlevel% neq 0 exit /b 1
call :hosts_has_fix_marker
if "!FIX_ON!"=="0" exit /b 0
call :disable_hosts_silent
if "!DH_OK!"=="0" (
    ipconfig /flushdns >nul
    exit /b 0
)
exit /b 1
:run_ps_hidden
rem Inline-запуск без start/-WindowStyle Hidden: не создаём отдельное окно conhost (это и давало «прыг»).
rem call перепарсивает строку — иначе кавычки внутри !PS_CMD! ломают редирект (cmd: Win32 error 123).
call !PS_CMD! >nul 2>&1
set "PS_EXIT=!errorlevel!"
exit /b 0
:run_ps_hosts
rem tg-hosts.ps1: stderr в файл — на экране показываем причину (доступ, read-only, антивирус).
set "HOSTS_ERR=%TEMP%\twf_hosts_err.log"
del "!HOSTS_ERR!" >nul 2>&1
call !PS_CMD! 1>nul 2>"!HOSTS_ERR!"
set "PS_EXIT=!errorlevel!"
exit /b 0
:run_ps_visible
rem Вывод в этом же окне (меню [5]): без >nul — видно ход обновления и TTF/CONOUT$ в дочернем PS совпадают с родителем.
call !PS_CMD!
set "PS_EXIT=!errorlevel!"
exit /b 0
:run_ps_scan_console
rem Поиск IP: без Hidden — построчный вывод PowerShell в ЭТОМ же окне cmd
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "!PS_DETECT!" -LogFile "!SCAN_LOG!" -ShowProgress
set "PS_EXIT=!errorlevel!"
exit /b 0
:fix_after_hidden_ps
rem Скрытый PS мог сбить шрифт. Только восстановление TTF: без mode и без Clear-Host (чтобы не стирать вывод).
if exist "%~dp0utils\set-console-ttf.ps1" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\set-console-ttf.ps1" -RemountFont 2>nul
)
exit /b 0
:setup_console
rem Один вызов PS: mode + TTF + внутренний второй Try-SetFace (set-console-ttf.ps1) — меньше дёрганий окна.
if exist "%~dp0utils\set-console-ttf.ps1" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\set-console-ttf.ps1" -LayoutCols !TWF_COLS! -LayoutRows !TWF_LINES! -BufferLines 3000 2>nul
)
exit /b 0
:restore_console_font
rem Совместимость со старыми вызовами: эквивалент :fix_after_hidden_ps.
if exist "%~dp0utils\set-console-ttf.ps1" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\set-console-ttf.ps1" -RemountFont 2>nul
)
exit /b 0
:wait_any_key
rem pause сам забирает клавишу. powershell здесь не запускаем:
rem его старт переключал уже нарисованный экран на растровый шрифт.
pause >nul
exit /b 0
:pin_console_font
rem Consolas 20 для этого окна и для powershell.exe. Иначе дочерний PS
rem при старте ставит точечный Terminal, и кадр мигает на каждом пункте.
reg add "HKCU\Console" /v ForceV2 /t REG_DWORD /d 1 /f >nul 2>&1
call :pin_font_key "HKCU\Console"
call :pin_font_key "HKCU\Console\Telegram Web Fix"
call :pin_font_key "HKCU\Console\Administrator: Telegram Web Fix"
call :pin_font_key "HKCU\Console\Администратор: Telegram Web Fix"
call :pin_font_key "HKCU\Console\Администратор: Administrator: Telegram Web Fix"
call :pin_font_exe "%SystemRoot%\System32\cmd.exe"
call :pin_font_exe "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
exit /b 0
:pin_font_exe
set "TWF_EXE=%~1"
set "TWF_TAIL=!TWF_EXE:~3!"
set "TWF_TAIL=!TWF_TAIL:\=_!"
call :pin_font_key "HKCU\Console\!TWF_EXE:~0,1!:_!TWF_TAIL!"
set "TWF_EXE=" & set "TWF_TAIL="
exit /b 0
:pin_font_key
reg add "%~1" /v FaceName /t REG_SZ /d "Consolas" /f >nul 2>&1
reg add "%~1" /v FontFamily /t REG_DWORD /d 54 /f >nul 2>&1
reg add "%~1" /v FontWeight /t REG_DWORD /d 400 /f >nul 2>&1
reg add "%~1" /v FontSize /t REG_DWORD /d 1310720 /f >nul 2>&1
exit /b 0
:init_esc
set "S92="
for /l %%I in (1,1,92) do set "S92=!S92! "
set "ESC="
for /F "tokens=1,2 delims=#" %%a in ('"prompt #$H#$E# & echo on & for %%b in (1) do rem"') do set "ESC=%%b"
if not defined ESC (
    set "R=" & set "GRN=" & set "RED=" & set "YLW=" & set "GRY=" & set "CYN=" & set "WHT=" & set "DIM="
    exit /b 0
)
set "R=!ESC![0m"
set "GRN=!ESC![92m"
set "RED=!ESC![91m"
set "YLW=!ESC![93m"
set "GRY=!ESC![90m"
set "CYN=!ESC![96m"
set "WHT=!ESC![97m"
set "DIM=!ESC![2m"
exit /b 0
:pad92_len
rem Вход: %~1 = длина (0..92), результат в _P92 (без call set — совместимо со всеми cmd)
set "_P92="
if "%~1"=="" exit /b 0
set /a _PN=%~1 2>nul
if not defined _PN exit /b 0
if !_PN! lss 0 set /a _PN=0
if !_PN! gtr 92 set /a _PN=92
if "!_PN!"=="0" exit /b 0
for %%A in (!_PN!) do set "_P92=!S92:~0,%%A!"
exit /b 0
:strlen
rem Длина !имя! в символах, результат в _LEN. Без powershell: его старт сбрасывал шрифт на растр.
set "_ss=!%~1!"
set /a _LEN=0
:strlen_l
if not defined _ss exit /b 0
set "_ss=!_ss:~1!"
set /a _LEN+=1
if !_LEN! geq 400 exit /b 0
goto :strlen_l
:cls_ui
rem mode/font уже настроены при старте (setup_console). Здесь только очистка экрана — без лишних дёрганий.
cls
exit /b 0
:load_ip
set "TG_IP="
if not exist "%CFG%" exit /b 0
for /f "usebackq tokens=*" %%a in (`findstr /R /C:"[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" "%CFG%" 2^>nul`) do set "TG_IP=%%a"
exit /b 0
:hosts_has_fix_marker
set "FIX_ON=0"
if not exist "%HOSTS%" exit /b 0
findstr /C:"%MARKER%" "%HOSTS%" >nul 2>&1
if not errorlevel 1 set "FIX_ON=1"
if "!FIX_ON!"=="0" (
    findstr /C:"%MARKER_LEGACY%" "%HOSTS%" >nul 2>&1
    if not errorlevel 1 set "FIX_ON=1"
)
exit /b 0
:require_cfg
call :load_ip
if not exist "%CFG%" exit /b 1
if not defined TG_IP exit /b 1
exit /b 0
:apply_hosts
if not exist "%PS_HOSTS%" exit /b 1
if not exist "%DOMAINS%" exit /b 1
set "HOSTS_ERR=%TEMP%\twf_hosts_err.log"
del "!HOSTS_ERR!" >nul 2>&1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%PS_HOSTS%" -Action Apply -Ip "%TG_IP%" -DomainsFile "%DOMAINS%" -BackupDir "%BACKUP%" 1>nul 2>"!HOSTS_ERR!"
set "PS_EXIT=!errorlevel!"
if not "!PS_EXIT!"=="0" exit /b 1
ipconfig /flushdns >nul
exit /b 0
:disable_hosts_silent
set "DH_OK=1"
if not exist "%PS_HOSTS%" exit /b 1
set "HOSTS_ERR=%TEMP%\twf_hosts_err.log"
del "!HOSTS_ERR!" >nul 2>&1
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%PS_HOSTS%" -Action Remove -DomainsFile "%DOMAINS%" 1>nul 2>"!HOSTS_ERR!"
set "PS_EXIT=!errorlevel!"
if not "!PS_EXIT!"=="0" exit /b 1
rem Verify после Remove убран: при успешном удалении он часто давал exit 1
rem (кодировка/чужие строки в hosts), bat показывал «Нет доступа», хотя fix уже снят.
set "DH_OK=0"
exit /b 0
:header
call :cls_ui
call :draw_main
exit /b 0
:draw_main
echo.
echo   !CYN!╔════════════════════════════════════════════════════════════════════════════════════════════╗!R!
echo   !CYN!║!R!                                     !GRN!TELEGRAM WEB FIX!R!                                       !CYN!║!R!
echo   !CYN!║!R!                            !DIM!web.telegram.org / t.me через hosts!R!                             !CYN!║!R!
echo   !CYN!╚════════════════════════════════════════════════════════════════════════════════════════════╝!R!
echo.
call :status_line
call :menu_body
exit /b 0
:status_line
call :hosts_has_fix_marker
if "!FIX_ON!"=="1" (
    set "FIX_T=!GRN!вкл !R!"
    goto :st_fix_done
)
set "FIX_T=!YLW!выкл!R!"
:st_fix_done
call :box_top "Состояние"
set /a _bxp=65
call :pad92_len !_bxp!
echo   !GRY!│!R!  Фикс ............... !FIX_T!!_P92!!GRY!│!R!
if defined TG_IP goto :st_has_ip
set /a _bxp=62
call :pad92_len !_bxp!
echo   !GRY!│!R!  IP ................ !GRY!не задан!R!!_P92!!GRY!│!R!
set /a _bxp=59
call :pad92_len !_bxp!
echo   !GRY!│!R!  Конфиг ............ !GRY!сначала [4]!R!!_P92!!GRY!│!R!
goto :st_after_ip
:st_has_ip
set "IPX=!TG_IP!              "
set "IPX=!IPX:~0,15!"
set /a _bxp=54
call :pad92_len !_bxp!
echo   !GRY!│!R!  IP ................ !CYN! !IPX!!R!!_P92!!GRY!│!R!
set /a _bxp=51
call :pad92_len !_bxp!
echo   !GRY!│!R!  Конфиг ............ !WHT!telegram-web-ip.cfg!R!!_P92!!GRY!│!R!
:st_after_ip
set /a _bxp=48
call :pad92_len !_bxp!
echo   !GRY!│!R!  Домены ............ !DIM!Web + t.me + WebSocket!R!!_P92!!GRY!│!R!
call :box_bottom
echo.
exit /b 0
:menu_body
call :box_top "Меню"
set /a _bxp=92
call :pad92_len !_bxp!
echo   !GRY!│!R!!_P92!!GRY!│!R!
if defined TG_IP goto :mn_item1_ok
set /a _g=14 & set /a _t=51
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !GRY![1]!R!  !GRY!Включить!R!!_gsp!!DIM!сначала [4]!R!!_tr!!GRY!│!R!
goto :mn_after1
:mn_item1_ok
set /a _g=14 & set /a _t=40
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !GRN![1]!R!  !WHT!Включить!R!!_gsp!!DIM!- записать fix в hosts!R!!_tr!!GRY!│!R!
:mn_after1
if "!FIX_ON!"=="1" (
    set /a _g=13 & set /a _t=33
    call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
    echo   !GRY!│!R!   !RED![2]!R!  !WHT!Выключить!R!!_gsp!!DIM!- убрать наши строки из hosts!R!!_tr!!GRY!│!R!
) else (
    set /a _g=13 & set /a _t=38
    call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
    echo   !GRY!│!R!   !GRY![2]!R!  !GRY!Выключить!R!!_gsp!!DIM!- !GRY!нечего: fix не включён!R!!_tr!!GRY!│!R!
)
set /a _g=14 & set /a _t=46
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !CYN![3]!R!  !WHT!Просмотр!R!!_gsp!!DIM!- строки в hosts!R!!_tr!!GRY!│!R!
set /a _g=14 & set /a _t=44
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !GRN![4]!R!  !WHT!Поиск IP!R!!_gsp!!DIM!- проверка DC :443!R!!_tr!!GRY!│!R!
set /a _g=4 & set /a _t=41
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !CYN![5]!R!  !WHT!Обновить список IP!R!!_gsp!!DIM!- cidr.txt с Telegram!R!!_tr!!GRY!│!R!
set /a _g=17 & set /a _t=62
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !GRY![0]!R!  !WHT!Выход!R!!_gsp!!_tr!!GRY!│!R!
set /a _bxp=92
call :pad92_len !_bxp!
echo   !GRY!│!R!!_P92!!GRY!│!R!
if defined TG_IP goto :mn_hint_ok
set /a _g=1 & set /a _t=48
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !YLW!Сначала [4] Поиск IP, потом [1] Включить!R!!_gsp!!_tr!!GRY!│!R!
goto :mn_hint_done
:mn_hint_ok
set /a _g=7 & set /a _t=62
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !GRY!Дальше: [1] Включить!R!!_gsp!!_tr!!GRY!│!R!
set /a _g=1 & set /a _t=41
call :pad92_len !_g!
set "_gsp=!_P92!"
call :pad92_len !_t!
set "_tr=!_P92!"
echo   !GRY!│!R!   !DIM![1] сохраняется после перезагрузки, пока не [2]!R!!_gsp!!_tr!!GRY!│!R!
:mn_hint_done
call :box_bottom
echo.
exit /b 0
:box_top
set "BOXTITLE=%~1"
call :strlen BOXTITLE
set /a _bxp=90-_LEN
if !_bxp! lss 0 set /a _bxp=0
call :pad92_len !_bxp!
echo   !GRY!┌────────────────────────────────────────────────────────────────────────────────────────────┐!R!
echo   !GRY!│!R!  !WHT!!BOXTITLE!!R!!_P92!!GRY!│!R!
echo   !GRY!├────────────────────────────────────────────────────────────────────────────────────────────┤!R!
set "_P92=" & set "_bxw=" & set "BOXTITLE="
exit /b 0
:box_bottom
echo   !GRY!└────────────────────────────────────────────────────────────────────────────────────────────┘!R!
exit /b 0
:section
echo.
call :box_top "%~1"
exit /b 0
:wait
call :box_bottom
echo.
echo   !DIM!  Любая клавиша — в меню...!R!
rem См. :wait_any_key (timeout + сброс буфера клавиш).
call :wait_any_key
echo.
exit /b 0
:line_ok
set "E2=%~1"
call :strlen E2
set /a _tp=92-9-_LEN
if !_tp! lss 0 set /a _tp=0
call :pad92_len !_tp!
echo   !GRY!│!R!   !GRN![OK]!R!  !E2!!_P92!!GRY!│!R!
exit /b 0
:line_fail
rem ^^!^^! — двойной caret экранирует ! при delayed expansion (иначе [!!]!R! схлопывается в "[R").
set "E2=%~1"
call :strlen E2
rem Префикс как у [OK]: 3 пробела + «[!]» (3) + 3 пробела до текста = 9 видимых колонок.
set /a _tp=92-9-_LEN
if !_tp! lss 0 set /a _tp=0
call :pad92_len !_tp!
echo   !GRY!│!R!   !RED![^^!^^!]!R!   !E2!!_P92!!GRY!│!R!
exit /b 0
:line_info
set "E2=%~1"
call :strlen E2
rem «[i]» короче «[OK]» — 4 пробела до E2, чтобы колонка текста совпала с line_ok/line_fail (всего 10 колонок до E2).
set /a _tp=92-10-_LEN
if !_tp! lss 0 set /a _tp=0
call :pad92_len !_tp!
echo   !GRY!│!R!   !GRY![i]!R!    !E2!!_P92!!GRY!│!R!
exit /b 0
:banner_ok
set /a _bxp=92
call :pad92_len !_bxp!
echo   !GRY!│!R!!_P92!!GRY!│!R!
set "E2=%~1"
call :strlen E2
set /a _tp=92-6-_LEN
if !_tp! lss 0 set /a _tp=0
call :pad92_len !_tp!
echo   !GRY!│!R!   !GRN!^>^> !E2!!R!!_P92!!GRY!│!R!
set /a _bxp=92
call :pad92_len !_bxp!
echo   !GRY!│!R!!_P92!!GRY!│!R!
exit /b 0
:banner_fail
set /a _bxp=92
call :pad92_len !_bxp!
echo   !GRY!│!R!!_P92!!GRY!│!R!
set "E2=%~1"
call :strlen E2
set /a _tp=92-6-_LEN
if !_tp! lss 0 set /a _tp=0
call :pad92_len !_tp!
echo   !GRY!│!R!   !RED!^>^> !E2!!R!!_P92!!GRY!│!R!
set /a _bxp=92
call :pad92_len !_bxp!
echo   !GRY!│!R!!_P92!!GRY!│!R!
exit /b 0
:scan_show_log
set "RPT_DNS=0"
set "RPT_SITES=0"
set "RPT_Q="
set "RPT_MS="
set "RPT_DNS_IP="
set "SCAN_PROG2="
for /f "usebackq tokens=1,2,3 delims=|" %%a in ("%~1") do call :scan_line "%%a" "%%b" "%%c"
if "!RPT_DNS!"=="0" echo   !GRY!  DNS ................... нет данных!R!
exit /b 0
:scan_line
if "%~1"=="SEC" echo   !CYN!  --- %~2 ---!R!
if "%~1"=="SEC" exit /b 0
if "%~1"=="DR" call :scan_dr "%~2" "%~3"
if "%~1"=="DR" exit /b 0
if "%~1"=="DS" call :scan_ds "%~2" "%~3"
if "%~1"=="DS" exit /b 0
if "%~1"=="SRC" echo   !GRY!  Очередь TCP .......... из файла lists\telegram-ip-candidates.txt: %~2 IPv4, всего с DNS в проверке: %~3!R!
if "%~1"=="SRC" exit /b 0
if "%~1"=="SKIP" if /i "%~2"=="failed_tcp" echo   !GRY!  Пропуск по кэшу .... lists\telegram-ip-failed.txt: %~3 IP - не повторяем TCP :443!R!
if "%~1"=="SKIP" exit /b 0
if "%~1"=="WARN" if /i "%~2"=="failed_cache_reset" echo   !YLW!  Кэш неудач сброшен - иначе список был бы пуст ^(%~3 IP в кэше^)!R!
if "%~1"=="WARN" exit /b 0
if "%~1"=="DSN" echo   !GRY!  ... плюс %~2 доменов в очереди!R!
if "%~1"=="DSN" exit /b 0
if "%~1"=="DOH" if /i "%~2"=="merged" if not "%~3"=="0" echo   !GRY!  DoH ^(DNS по HTTPS^) ..... !GRN!+%~3 новых IP в очередь!R!
if "%~1"=="DOH" if /i "%~2"=="merged" if "%~3"=="0" echo   !GRY!  DoH ^(DNS по HTTPS^) ..... ответ есть, новых IP нет!R!
if "%~1"=="DOH" if /i "%~2"=="skip" echo   !YLW!  DoH недоступен — без HTTPS-DNS ^(%~3^)!R!
if "%~1"=="DOH" exit /b 0
if "%~1"=="TLS" if /i "%~2"=="ok" echo   !GRY!  TLS ^(SNI^) .......... !GRN!OK для %~3!R!
if "%~1"=="TLS" if /i "%~2"=="warn" echo   !YLW!  TLS ^(SNI^) .......... предупреждение: %~3 ^(IP как по TCP^)!R!
if "%~1"=="TLS" if /i "%~2"=="skip" echo   !GRY!  TLS ................... пропуск ^(%~3^)!R!
if "%~1"=="TLS" exit /b 0
if "%~1"=="Q" if not defined RPT_Q echo   !GRY!  В очереди .............. %~2 IP, параллельно %~3!R!
if "%~1"=="Q" set "RPT_Q=1"
if "%~1"=="Q" exit /b 0
if "%~1"=="MS" if not defined RPT_MS echo   !GRY!  Таймаут TCP ........... %~2 мс!R!
if "%~1"=="MS" set "RPT_MS=1"
if "%~1"=="MS" exit /b 0
if "%~1"=="PROG" call :scan_live_prog "%~2" "%~3"
if "%~1"=="PROG" exit /b 0
if "%~1"=="LIVE" if /i "%~2"=="ok" echo   !GRN!  ^>^> Открыт: %~3!R!
if "%~1"=="LIVE" if /i "%~2"=="ok2" echo   !GRN!  ^>^> Открыт (TNC): %~3!R!
if "%~1"=="LIVE" exit /b 0
if "%~1"=="ADDED" echo   !DIM!  В lists/telegram-ip-candidates.txt добавлено: %~2 IP!R!
if "%~1"=="ADDED" exit /b 0
if "%~1"=="DONE" exit /b 0
if "%~1"=="MSG" if not "%~2"=="" if defined TG_SCAN_VERBOSE_LOG call :scan_echo_dim "%~2"
if "%~1"=="MSG" exit /b 0
if "%~1"=="DNS" if not defined RPT_DNS_IP echo   !YLW!  web.telegram.org ...... %~2  !DIM!(часто не открывается^)!R!
if "%~1"=="DNS" set "RPT_DNS_IP=1"
if "%~1"=="DNS" exit /b 0
if "%~1"=="NODNS" if not defined RPT_DNS_IP echo   !YLW!  web.telegram.org ...... DNS не ответил!R!
if "%~1"=="NODNS" set "RPT_DNS_IP=1"
if "%~1"=="NODNS" exit /b 0
if "%~1"=="COUNT" if not defined RPT_Q echo   !GRY!  В очереди .............. %~2 IP!R!
if "%~1"=="COUNT" set "RPT_Q=1"
if "%~1"=="COUNT" exit /b 0
if "%~1"=="PASS2" echo   !YLW!  Повторная проверка .... Test-NetConnection!R!
if "%~1"=="PASS2" exit /b 0
if "%~1"=="N" if "%~2"=="diag" echo   !CYN!  --- если IP не найден ---!R!
if "%~1"=="N" if "%~2"=="cand" echo   !GRY!    в очереди: %~3!R!
if "%~1"=="N" if "%~2"=="file" echo   !GRY!    из файла: %~3!R!
if "%~1"=="N" if "%~2"=="dnsA" echo   !GRY!    DNS-записей: %~3!R!
if "%~1"=="N" if "%~2"=="dnsSrv" echo   !GRY!    DNS с ответом: %~3 из 4!R!
if "%~1"=="N" if "%~2"=="tcpTry" echo   !GRY!    проверок TCP: %~3!R!
if "%~1"=="N" if "%~2"=="tncTry" echo   !GRY!    проверок TNC: %~3!R!
if "%~1"=="N" exit /b 0
if "%~1"=="NET" if /i "%~2"=="up" call :scan_net_up "%~3"
if "%~1"=="NET" if /i "%~2"=="down" echo   !YLW!  Контроль 1.1.1.1, 8.8.8.8, 9.9.9.9:443 .. тоже не открылся — проверьте исходящий интернет!R!
if "%~1"=="NET" exit /b 0
if "%~1"=="ROW" exit /b 0
if "%~1"=="ERR" if "%~2"=="empty_list" echo   !RED!  Список пуст: lists\telegram-ip-candidates.txt!R!
if "%~1"=="ERR" if "%~2"=="no_reply" call :scan_err_no_reply
if "%~1"=="ERR" exit /b 0
if "%~1"=="FOUND" echo   !GRN!  Сохранён в telegram-web-ip.cfg: %~2!R!
if "%~1"=="FOUND" set "RPT_FOUND=%~2"
if "%~1"=="FOUND" exit /b 0
exit /b 0
:scan_dr
set "RPT_DNS=1"
if /i "%~2"=="ok" echo   !GRY!  DNS %~1  !GRN!A-запись!R!
if /i "%~2"=="empty" echo   !GRY!  DNS %~1  !YLW!нет A!R!
if /i "%~2"=="timeout" echo   !GRY!  DNS %~1  !YLW!таймаут!R!
exit /b 0
:scan_ds
set /a RPT_SITES+=1
if "%~3"=="-" echo   !GRY!  %~2  —!R!
if not "%~3"=="-" echo   !GRY!  %~2  %~3!R!
exit /b 0
:scan_echo_dim
set "SCAN_T=%~1"
set "SCAN_T=!SCAN_T:>=^>!"
set "SCAN_T=!SCAN_T:<=^<!"
set "SCAN_T=!SCAN_T:&=^&!"
set "SCAN_T=!SCAN_T:|=^|!"
echo   !DIM!    !SCAN_T!!R!
exit /b 0
:scan_err_no_reply
echo   !RED!  Ни один IP не ответил на TCP 443.!R!
echo   !GRY!  До дата-центров Telegram пакеты не доходят, hosts это не чинит.!R!
echo   !GRY!  Нужна другая сеть, раздача с телефона или VPN со split-tunnel для браузера.!R!
echo   !GRY!  Подсети: !R!!CYN!https://core.telegram.org/resources/cidr.txt!R!
exit /b 0
:scan_net_up
for /f "tokens=1,2 delims=/" %%i in ("%~1") do echo   !YLW!  Контроль %%i:443 .. открыт за %%j мс — интернет есть, молчит путь к Telegram!R!
exit /b 0
:scan_live_prog
if "!SCAN_PROG2!"=="%~1" exit /b 0
set "SCAN_PROG2=%~1"
set "SCAN_PROGT=%~2"
echo   !GRY!  TCP :443 .............. [!SCAN_PROG2!/!SCAN_PROGT!]!R!
exit /b 0
:menu
call :load_ip
call :header
set "choice="
set /p "choice=  Выбор: > "
if not defined choice goto :menu
set "choice=!choice: =!"
if "!choice!"=="1" goto :enable
if "!choice!"=="2" goto :disable
if "!choice!"=="3" goto :show
if "!choice!"=="4" goto :autodetect
if "!choice!"=="5" goto :update_candidates
if "!choice!"=="0" goto :bye
goto :menu
:update_candidates
call :cls_ui
call :section "Обновление списка IP"
if not exist "%PS_UPDATE%" goto :up_no_script
call :line_info "Источник: Telegram, DoH, зеркала GitHub/GitLab/jsDelivr, локальная копия"
call :box_bottom
echo.
set "PS_CMD=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_UPDATE%""
call :run_ps_visible
set "UP_OK=!PS_EXIT!"
rem update-ip-candidates.ps1 сам перед exit делает remount шрифта (dot-source ensure-console-ttf).
rem Лишний :fix_after_hidden_ps убран — он спавнил ещё один powershell.exe без необходимости.
if "!UP_OK!"=="0" (
    call :line_ok "Файл lists\telegram-ip-candidates.txt обновлён"
    call :banner_ok "Дальше: [4] Поиск IP"
) else (
    call :line_fail "Не удалось получить cidr.txt — сайт Telegram, зеркала, lists\telegram-cidr-official.txt"
    call :line_info "Проверьте интернет; при блокировке РКН сработает локальная копия в lists"
)
call :wait
goto :menu
:up_no_script
call :line_fail "Нет utils\update-ip-candidates.ps1"
call :wait
goto :menu
:autodetect
call :cls_ui
call :section "Поиск IP"
if not exist "%PS_DETECT%" goto :ad_no_detect
call :line_info "Список: lists\telegram-ip-candidates.txt (+ адреса из DNS → общая очередь)"
call :box_bottom
echo.
echo   !CYN!Поиск рабочего IP :443 для web.telegram.org по списку candidates + DNS...!R!
echo   !DIM!Подробности шагов — в консоли; краткая сводка — в блоке «Отчёт» ниже.!R!
echo.
set "SCAN_LOG=%TEMP%\telegram-web-fix-scan.log"
del "%SCAN_LOG%" 2>nul
call :run_ps_scan_console
rem telegram-autodetect.ps1 сам перед exit делает remount шрифта (Exit-Scan → dot-source ensure-console-ttf).
rem Лишний :fix_after_hidden_ps убран — он спавнил ещё один powershell.exe без необходимости.
set "DETECT_OK=!PS_EXIT!"
call :load_ip
echo.
if exist "%SCAN_LOG%" (
    echo   !GRY!├────────────────────────────────────────────────────────────────────────────────────────────┤!R!
    set "BOXTITLE=Отчёт"
    call :strlen BOXTITLE
    set /a _bxp=90-_LEN
    if !_bxp! lss 0 set /a _bxp=0
    call :pad92_len !_bxp!
    echo   !GRY!│!R!  !WHT!!BOXTITLE!!R!!_P92!!GRY!│!R!
    set "BOXTITLE="
    echo   !GRY!├────────────────────────────────────────────────────────────────────────────────────────────┤!R!
    call :scan_show_log "%SCAN_LOG%"
    echo   !GRY!└────────────────────────────────────────────────────────────────────────────────────────────┘!R!
) else (
    echo   !RED!Скан не записал лог — %TEMP%!R!
)
echo.
if defined TG_IP echo   !GRN!^>^>^> Рабочий IP: !TG_IP!!R!
if not defined TG_IP if not "!DETECT_OK!"=="0" echo   !RED!^>^> IP не найден!R!
if not defined TG_IP if not "!DETECT_OK!"=="0" if not exist "%SCAN_LOG%" echo   !RED!Скан не записал лог — %TEMP%!R!
if defined TG_IP echo   !GRN!Дальше: [1] Включить  —  затем web.telegram.org/k/!R!
echo.
echo   !WHT!Готово.!R!
echo   !DIM!  Нажмите любую клавишу, чтобы вернуться в меню...!R!
rem См. :wait_any_key (timeout + сброс буфера клавиш).
call :wait_any_key
goto :menu
:ad_no_detect
call :line_fail "Нет utils\telegram-autodetect.ps1"
call :wait
goto :menu
:enable
call :require_cfg
if errorlevel 1 goto :en_no_cfg
call :cls_ui
if not exist "%PS_HOSTS%" goto :en_no_hosts
call :apply_hosts
set "EN_ERR=!errorlevel!"
call :section "Включение"
if not "!EN_ERR!"=="0" goto :en_apply_fail
call :line_ok "hosts обновлен"
call :line_ok "DNS сброшен"
call :line_info "Корень web.telegram.org/ — старый Webogram (серый экран). Нужен /k/ или /a/"
call :banner_ok "Включено - открываем web.telegram.org/k/"
start "" "https://web.telegram.org/k/"
call :wait
goto :menu
:en_no_cfg
call :cls_ui
call :section "Включение"
call :line_fail "Сначала [4] Поиск IP"
call :wait
goto :menu
:en_no_hosts
call :cls_ui
call :section "Включение"
call :line_fail "Нет utils\tg-hosts.ps1"
call :wait
goto :menu
:en_apply_fail
call :line_fail "Не удалось записать hosts (код !PS_EXIT!)"
call :show_hosts_ps_err
call :wait
goto :menu
:show_hosts_ps_err
set "HOSTS_MSG="
if exist "!HOSTS_ERR!" (
    for /f "usebackq delims=" %%L in ("!HOSTS_ERR!") do (
        echo %%L | findstr /i /c:"tg-hosts:" >nul 2>&1
        if not errorlevel 1 (
            set "HOSTS_MSG=%%L"
            goto :show_hosts_ps_err_done
        )
    )
    for /f "usebackq delims=" %%L in ("!HOSTS_ERR!") do (
        echo %%L | findstr /b /c:"At " >nul 2>&1
        if errorlevel 1 (
            echo %%L | findstr /b /c:"+" >nul 2>&1
            if errorlevel 1 (
                set "HOSTS_MSG=%%L"
                goto :show_hosts_ps_err_done
            )
        )
    )
)
:show_hosts_ps_err_done
if defined HOSTS_MSG (
    call :line_info "!HOSTS_MSG!"
) else (
    call :line_info "Нужен запуск от администратора; hosts не read-only; антивирус может блокировать запись"
)
exit /b 0
:disable
call :cls_ui
call :hosts_has_fix_marker
if not "!FIX_ON!"=="1" goto :disable_none
rem Скрытый PS до рамки: иначе conhost уходит в растр и первая отрисовка «ломается».
call :disable_hosts_silent
call :cls_ui
call :section "Выключение"
if "!DH_OK!"=="0" (
    call :hosts_has_fix_marker
    if "!FIX_ON!"=="1" (
        call :line_fail "В hosts остались наши строки"
        call :line_info "Проверьте файл hosts вручную (маркер # telegram-web-fix)"
    ) else (
        call :line_ok "Записи удалены"
        ipconfig /flushdns >nul
        call :line_ok "DNS сброшен"
        call :banner_ok "Выключено"
    )
) else (
    call :line_fail "Не удалось изменить hosts (код !PS_EXIT!)"
    call :show_hosts_ps_err
)
call :wait
goto :menu
:disable_none
call :section "Выключение"
call :line_info "В hosts нет наших строк - нечего выключать."
call :line_info "[2] снимает только блок с маркером # telegram-web-fix"
call :wait
goto :menu
:show
call :cls_ui
call :section "Файл hosts"
set "found=0"
for /f "tokens=*" %%L in ('findstr /I "telegram" "%HOSTS%" 2^>nul') do (
    set "HROW=%%L"
    call :hosts_echo_row
    set "found=1"
)
if "!found!"=="0" (
    call :line_info "Записей Telegram в hosts нет."
    call :line_info "Сначала [4] Поиск IP, потом [1] Включить."
)
call :wait
goto :menu
:hosts_echo_row
call :strlen HROW
set /a _hp=92-3-_LEN
if !_hp! lss 0 set /a _hp=0
call :pad92_len !_hp!
echo   !GRY!│!R!   !DIM!!HROW!!R!!_P92!!GRY!│!R!
exit /b 0
:bye
call :header
echo     !GRY!Пока.!R!
echo.
timeout /t 1 >nul
exit /b 0
