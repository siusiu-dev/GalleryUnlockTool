@echo off
setlocal EnableExtensions EnableDelayedExpansion
title NTRMAN Gallery Unlocker

cd /d "%~dp0"

if not exist "%~dp0GalleryUnlock.ps1" (
    echo   [X] Khong thay GalleryUnlock.ps1.
    pause & exit /b 1
)
if not exist "%~dp0GalleryUnlockPlugin.dll" (
    echo   [X] Khong thay GalleryUnlockPlugin.dll.
    pause & exit /b 1
)

if not "%~1"=="" goto :passthrough

cls
echo.
echo  ==============================================
echo    NTRMAN Gallery Unlocker  v1.3
echo  ==============================================
echo.

set "DRIVE_DISPLAY="
set "DRIVE_ROOTS="
for /f "usebackq delims=" %%d in (`powershell -NoProfile -Command "(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3').Name" ^<nul`) do (
    set "DRIVE_DISPLAY=!DRIVE_DISPLAY! %%d\  "
    if defined DRIVE_ROOTS (set "DRIVE_ROOTS=!DRIVE_ROOTS!;%%d") else (set "DRIVE_ROOTS=%%d")
)

if not defined DRIVE_ROOTS (
    echo   [!] Khong tim thay o cung ghi nao.
    pause & exit /b 1
)

echo   O cung ghi: !DRIVE_DISPLAY!
echo.
echo  ---------------------------------------------
echo   1^) Quet TAT CA o cung            ^(cham nhat^)
echo   2^) Quet MOT o cung
echo   3^) Quet MOT thu muc
echo   4^) Chi dinh thu muc game         ^(khong quet de quy^)
echo   5^) Quet NHIEU muc / o cung       ^(tach bang dau cham ^; ^)
echo   Q^) Thoat
echo  ---------------------------------------------
echo.

:pick
set "CHOICE="
set /p "CHOICE=Chon [1-5/Q]: "
if not defined CHOICE goto :pick
set "CHOICE=!CHOICE: =!"

if /i "!CHOICE!"=="Q" exit /b 0

set "SCANROOT="
set "GAMEDIR="

if "!CHOICE!"=="1" (
    set "SCANROOT=!DRIVE_ROOTS!"
    goto :asklaunch
)

if "!CHOICE!"=="2" (
    echo.
    set "DRV="
    set /p "DRV=Nhap o cung, VD: C  -> "
    if not defined DRV goto :pick
    set "DRV=!DRV:"=!"
    set "DRV=!DRV: =!"
    for /l %%l in (1,1,10) do (
        if "!DRV:~-1!"=="\" set "DRV=!DRV:~0,-1!"
    )
    if not "!DRV:~-1!"==":" set "DRV=!DRV!:"
    if not exist "!DRV!\" (
        echo   [!] Khong thay o "!DRV!\"
        set "DRV="
        goto :pick
    )
    set "SCANROOT=!DRV!"
    goto :asklaunch
)

if "!CHOICE!"=="3" (
    echo.
    set "DIR="
    set /p "DIR=Nhap thu muc can quet, VD: D:\Games  -> "
    if not defined DIR goto :pick
    set "DIR=!DIR:"=!"
    for /f "tokens=* delims= " %%a in ("!DIR!") do set "DIR=%%a"
    for /l %%l in (1,1,10) do (
        if "!DIR:~-1!"==" " set "DIR=!DIR:~0,-1!"
        if "!DIR:~-1!"=="\" set "DIR=!DIR:~0,-1!"
    )
    if "!DIR:~-1!"==":" (
        if not exist "!DIR!\" (
            echo   [!] Khong thay o "!DIR!\"
            set "DIR="
            goto :pick
        )
    ) else (
        if not exist "!DIR!" (
            echo   [!] Khong thay thu muc "!DIR!"
            set "DIR="
            goto :pick
        )
    )
    set "SCANROOT=!DIR!"
    goto :asklaunch
)

if "!CHOICE!"=="4" (
    echo.
    echo   Nhap thu muc GAME. Nhieu muc tach bang dau cham ^;
    echo   Script dung thang thu muc do, khong quet de quy.
    echo.
    set "GAMEDIR_INPUT="
    set /p "GAMEDIR_INPUT=Duong dan: "
    if not defined GAMEDIR_INPUT goto :pick
    set "GAMEDIR_INPUT=!GAMEDIR_INPUT:"=!"
    set "BAD="
    set "CLEAN_DIRS="
    for %%g in ("!GAMEDIR_INPUT:;=" "!") do (
        set "ITEM=%%~g"
        for /f "tokens=* delims= " %%a in ("!ITEM!") do set "ITEM=%%a"
        for /l %%l in (1,1,10) do (
            if "!ITEM:~-1!"==" " set "ITEM=!ITEM:~0,-1!"
            if "!ITEM:~-1!"=="\" set "ITEM=!ITEM:~0,-1!"
        )
        if "!ITEM:~-1!"==":" (
            if not exist "!ITEM!\" (
                echo   [!] Khong thay thu muc: %%~g
                set "BAD=1"
            )
        ) else (
            if not exist "!ITEM!" (
                echo   [!] Khong thay thu muc: %%~g
                set "BAD=1"
            )
        )
        if defined CLEAN_DIRS (set "CLEAN_DIRS=!CLEAN_DIRS!;!ITEM!") else (set "CLEAN_DIRS=!ITEM!")
    )
    if defined BAD goto :pick
    if not defined CLEAN_DIRS goto :pick
    set "GAMEDIR=!CLEAN_DIRS!"
    goto :asklaunch
)

if "!CHOICE!"=="5" (
    echo.
    echo   VD:  C:;D:\Games;E:\VN
    echo.
    set "SCANROOT_INPUT="
    set /p "SCANROOT_INPUT=Nhap danh sach: "
    if not defined SCANROOT_INPUT goto :pick
    set "SCANROOT_INPUT=!SCANROOT_INPUT:"=!"
    set "BAD="
    set "CLEAN_ROOTS="
    for %%g in ("!SCANROOT_INPUT:;=" "!") do (
        set "ITEM=%%~g"
        for /f "tokens=* delims= " %%a in ("!ITEM!") do set "ITEM=%%a"
        for /l %%l in (1,1,10) do (
            if "!ITEM:~-1!"==" " set "ITEM=!ITEM:~0,-1!"
            if "!ITEM:~-1!"=="\" set "ITEM=!ITEM:~0,-1!"
        )
        if "!ITEM:~-1!"==":" (
            if not exist "!ITEM!\" (
                echo   [!] Khong thay o / thu muc: %%~g
                set "BAD=1"
            )
        ) else (
            if not exist "!ITEM!" (
                echo   [!] Khong thay o / thu muc: %%~g
                set "BAD=1"
            )
        )
        if defined CLEAN_ROOTS (set "CLEAN_ROOTS=!CLEAN_ROOTS!;!ITEM!") else (set "CLEAN_ROOTS=!ITEM!")
    )
    if defined BAD goto :pick
    if not defined CLEAN_ROOTS goto :pick
    set "SCANROOT=!CLEAN_ROOTS!"
    goto :asklaunch
)

echo   [!] Lua chon khong hop le.
goto :pick

:asklaunch
echo.
set "ANS="
set /p "ANS=Chay game de kiem tra ^(Y/N^)? [N]: "
set "LAUNCH="
if /i "!ANS!"=="Y" set "LAUNCH=-Launch"

cls
echo.
echo  ==============================================
echo    Chuan bi chay
echo  ==============================================
echo    Pham vi   : !SCANROOT!!GAMEDIR!
if defined LAUNCH (echo    Verify    : CO - se chay game roi tu dong dong) else (echo    Verify    : KHONG)
echo.

if defined SCANROOT if "!SCANROOT:~-1!"=="\" set "SCANROOT=!SCANROOT:~0,-1!"
if defined GAMEDIR if "!GAMEDIR:~-1!"=="\" set "GAMEDIR=!GAMEDIR:~0,-1!"

set "ARGS="
if defined SCANROOT set "ARGS=!ARGS! -ScanRoot "!SCANROOT!""
if defined GAMEDIR set "ARGS=!ARGS! -Path "!GAMEDIR!""
if defined LAUNCH  set "ARGS=!ARGS! !LAUNCH!"
echo    lenh      : GalleryUnlock.ps1!ARGS!
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0GalleryUnlock.ps1"!ARGS!
set "RC=!ERRORLEVEL!"

echo.
echo  ==============================================
if "!RC!"=="0" (
    echo    Khong phat hien van de ^(exit !RC!^)
) else (
    echo    Co canh bao ^(exit !RC!^)
)
echo  ==============================================
echo.
pause
exit /b !RC!

:passthrough
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0GalleryUnlock.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
pause
exit /b %RC%