@echo off
setlocal
cd /d "%~dp0"

rem Important:
rem Do NOT use a variable named GIT_DIR.
rem Git treats GIT_DIR as a special environment variable and will break -C repo commands.
set "GIT_DIR="
set "GIT_WORK_TREE="

call :EnsureGit
if errorlevel 1 (
    echo.
    echo [ERROR] git.exe was not found.
    echo Please install Git for Windows, or check GitHub Desktop embedded Git path.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AutoUpdateAll.ps1"
echo.
pause
exit /b %ERRORLEVEL%

:EnsureGit
where git >nul 2>nul
if %ERRORLEVEL%==0 exit /b 0

set "FOUND_GIT_CMD="

if exist "C:\Program Files\Git\cmd\git.exe" (
    set "FOUND_GIT_CMD=C:\Program Files\Git\cmd"
    goto :SetGitPath
)

if exist "C:\Program Files (x86)\Git\cmd\git.exe" (
    set "FOUND_GIT_CMD=C:\Program Files (x86)\Git\cmd"
    goto :SetGitPath
)

if exist "%LocalAppData%\Programs\Git\cmd\git.exe" (
    set "FOUND_GIT_CMD=%LocalAppData%\Programs\Git\cmd"
    goto :SetGitPath
)

for /d %%G in ("%LocalAppData%\GitHubDesktop\app-*") do (
    if exist "%%G\resources\app\git\cmd\git.exe" (
        set "FOUND_GIT_CMD=%%G\resources\app\git\cmd"
        goto :SetGitPath
    )
)

exit /b 1

:SetGitPath
set "PATH=%FOUND_GIT_CMD%;%PATH%"
where git >nul 2>nul
if %ERRORLEVEL%==0 exit /b 0
exit /b 1
