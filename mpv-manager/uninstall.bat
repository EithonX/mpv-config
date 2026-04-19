@echo off
setlocal enabledelayedexpansion

echo ============================================================
echo              MPV Manager Uninstaller
echo ============================================================
echo.

REM Get user home directory
set "HOME=%USERPROFILE%"
set "MPV_DIR=%HOME%\mpv"
set "INSTALLER_DIR=%MPV_DIR%\mpv-manager"
set "PORTABLE_CONFIG=%MPV_DIR%\portable_config"
set "CONFIG_FILE=%PORTABLE_CONFIG%\mpv-manager.json"
set "DESKTOP=%HOME%\Desktop"

REM Get Start Menu path
set "START_MENU=%APPDATA%\Microsoft\Windows\Start Menu\Programs"

echo This script will remove MPV Manager from your system.
echo.
echo The following will be removed:
echo   - MPV Manager directory: %INSTALLER_DIR%
echo   - Desktop shortcut: MPV Manager.lnk
echo   - Start Menu shortcut: MPV.lnk (if created by MPV Manager)
echo   - Configuration file: %CONFIG_FILE%
echo.
echo The following will be PRESERVED:
echo   - MPV installation: %MPV_DIR%\mpv.exe
echo   - MPV configuration: %PORTABLE_CONFIG%
echo   - Your media player settings
echo.

set /p CONFIRM="Do you want to continue? (Y/N): "
if /i not "%CONFIRM%"=="Y" (
    echo.
    echo Uninstall cancelled.
    pause
    exit /b 0
)

echo.
echo ============================================================
echo                    Starting Uninstall
echo ============================================================
echo.

REM 1. Remove MPV Manager directory
if exist "%INSTALLER_DIR%" (
    echo Removing MPV Manager directory...
    rd /s /q "%INSTALLER_DIR%" 2>nul
    if exist "%INSTALLER_DIR%" (
        echo Warning: Could not fully remove: %INSTALLER_DIR%
        echo Some files may be in use. Try closing MPV Manager and running again.
    ) else (
        echo   [OK] Removed: %INSTALLER_DIR%
    )
) else (
    echo   [SKIP] MPV Manager directory not found
)

REM 2. Remove Desktop shortcut
set "DESKTOP_SHORTCUT=%DESKTOP%\MPV Manager.lnk"
if exist "%DESKTOP_SHORTCUT%" (
    echo Removing Desktop shortcut...
    del /f /q "%DESKTOP_SHORTCUT%" 2>nul
    if exist "%DESKTOP_SHORTCUT%" (
        echo Warning: Could not remove: %DESKTOP_SHORTCUT%
    ) else (
        echo   [OK] Removed: %DESKTOP_SHORTCUT%
    )
) else (
    echo   [SKIP] Desktop shortcut not found
)

REM 3. Remove Start Menu shortcut
set "START_MENU_SHORTCUT=%START_MENU%\MPV.lnk"
if exist "%START_MENU_SHORTCUT%" (
    echo Removing Start Menu shortcut...
    del /f /q "%START_MENU_SHORTCUT%" 2>nul
    if exist "%START_MENU_SHORTCUT%" (
        echo Warning: Could not remove: %START_MENU_SHORTCUT%
    ) else (
        echo   [OK] Removed: %START_MENU_SHORTCUT%
    )
) else (
    echo   [SKIP] Start Menu shortcut not found
)

REM 4. Remove config file
if exist "%CONFIG_FILE%" (
    echo Removing configuration file...
    del /f /q "%CONFIG_FILE%" 2>nul
    if exist "%CONFIG_FILE%" (
        echo Warning: Could not remove: %CONFIG_FILE%
    ) else (
        echo   [OK] Removed: %CONFIG_FILE%
    )
) else (
    echo   [SKIP] Configuration file not found
)

REM 5. Also check for config in AppData (legacy location)
set "APPDATA_CONFIG=%APPDATA%\mpv-manager\mpv-manager.json"
if exist "%APPDATA_CONFIG%" (
    echo Removing legacy configuration file...
    del /f /q "%APPDATA_CONFIG%" 2>nul
    if exist "%APPDATA_CONFIG%" (
        echo Warning: Could not remove: %APPDATA_CONFIG%
    ) else (
        echo   [OK] Removed: %APPDATA_CONFIG%
    )
)

REM Remove legacy config directory if empty
set "APPDATA_CONFIG_DIR=%APPDATA%\mpv-manager"
if exist "%APPDATA_CONFIG_DIR%" (
    rd "%APPDATA_CONFIG_DIR%" 2>nul
)

echo.
echo ============================================================
echo                   Uninstall Complete
echo ============================================================
echo.
echo MPV Manager has been removed from your system.
echo.
echo Your MPV installation and settings have been preserved at:
echo   %MPV_DIR%
echo.
echo If you want to completely remove MPV, delete the folder:
echo   %MPV_DIR%
echo.
echo Thank you for using MPV Manager!
echo.
pause
exit /b 0
