@echo off
setlocal enabledelayedexpansion

:: ==================================================
:: SandBox Multi Repo Updater
:: - Find git.exe automatically
:: - Update root repo
:: - Update repos inside Assets
:: - Show new commits / changed files / summary
:: ==================================================

call :FindGit
if errorlevel 1 (
    echo [ERROR] git.exe not found.
    echo Please install Git for Windows or add Git to PATH.
    echo Recommended Git install option:
    echo "Git from the command line and also from 3rd-party software"
    pause
    exit /b 1
)

echo [Git Found] "%GIT%"
"%GIT%" --version

set "HAS_ERROR="

echo.
echo ==================================================
echo STEP 1: Root Repo Update
echo ==================================================
call :UpdateRepo "."
if errorlevel 1 set "HAS_ERROR=1"

echo.
echo ==================================================
echo STEP 2: Assets Sub-repo Update
echo ==================================================

if not exist "Assets" (
    echo [ERROR] No Assets folder found.
    pause
    exit /b 1
)

pushd "Assets"

for /d %%i in (*) do (
    if exist "%%i\.git" (
        echo.
        call :UpdateRepo "%%i"
        if errorlevel 1 set "HAS_ERROR=1"
    )
)

popd

echo.
echo ==================================================
if defined HAS_ERROR (
    echo PROCESS DONE WITH ERRORS.
    echo Some repositories failed to update.
) else (
    echo ALL PROCESS DONE.
)
echo ==================================================

pause
exit /b 0


:: ==================================================
:: Function: UpdateRepo
:: ==================================================
:UpdateRepo
set "REPO=%~1"

echo [Target]: %REPO%

pushd "%REPO%" >nul 2>nul
if errorlevel 1 (
    echo [FAIL] %REPO%: Cannot enter folder.
    exit /b 1
)

"%GIT%" rev-parse --is-inside-work-tree >nul 2>nul
if errorlevel 1 (
    echo [FAIL] %REPO%: Not a git repository.
    popd
    exit /b 1
)

:: Save current HEAD
set "OLD_HEAD="
for /f "delims=" %%H in ('"%GIT%" rev-parse HEAD 2^>nul') do (
    set "OLD_HEAD=%%H"
)

if not defined OLD_HEAD (
    echo [FAIL] %REPO%: Cannot read current HEAD.
    popd
    exit /b 1
)

:: Prefer upstream if it exists, otherwise use origin
set "REMOTE="

"%GIT%" remote get-url upstream >nul 2>nul
if not errorlevel 1 (
    set "REMOTE=upstream"
) else (
    "%GIT%" remote get-url origin >nul 2>nul
    if not errorlevel 1 (
        set "REMOTE=origin"
    )
)

if not defined REMOTE (
    echo [FAIL] %REPO%: No upstream or origin remote found.
    popd
    exit /b 1
)

echo Remote: !REMOTE!

"%GIT%" fetch !REMOTE!
if errorlevel 1 (
    echo [FAIL] %REPO%: Fetch failed.
    popd
    exit /b 1
)

:: Detect main or master
set "BRANCH="

"%GIT%" show-ref --verify --quiet "refs/remotes/!REMOTE!/main"
if not errorlevel 1 (
    set "BRANCH=main"
) else (
    "%GIT%" show-ref --verify --quiet "refs/remotes/!REMOTE!/master"
    if not errorlevel 1 (
        set "BRANCH=master"
    )
)

if not defined BRANCH (
    echo [FAIL] %REPO%: Cannot find !REMOTE!/main or !REMOTE!/master.
    popd
    exit /b 1
)

echo Merge: !REMOTE!/!BRANCH!

:: Safety check: warn if current branch is not main/master
set "CURRENT_BRANCH="
for /f "delims=" %%B in ('"%GIT%" rev-parse --abbrev-ref HEAD 2^>nul') do (
    set "CURRENT_BRANCH=%%B"
)

if /i not "!CURRENT_BRANCH!"=="!BRANCH!" (
    echo [WARN] %REPO%: Current branch is "!CURRENT_BRANCH!", remote target is "!BRANCH!".
    echo [WARN] Merge will be attempted with --ff-only only.
)

:: Fast-forward only
"%GIT%" merge --ff-only !REMOTE!/!BRANCH!
if errorlevel 1 (
    echo [FAIL] %REPO%: Merge failed.
    echo Reason may be local changes, conflicts, or divergent commits.
    echo Check this repo manually:
    echo   cd %CD%
    echo   git status
    popd
    exit /b 1
)

:: Save new HEAD
set "NEW_HEAD="
for /f "delims=" %%H in ('"%GIT%" rev-parse HEAD 2^>nul') do (
    set "NEW_HEAD=%%H"
)

if /i "!OLD_HEAD!"=="!NEW_HEAD!" (
    echo [OK] %REPO%: Already up to date.
) else (
    echo [OK] %REPO%: Updated from !REMOTE!/!BRANCH!
    echo.
    echo ---- New Commits ----
    "%GIT%" log --oneline --decorate !OLD_HEAD!..!NEW_HEAD!

    echo.
    echo ---- Changed Files ----
    "%GIT%" diff --name-status !OLD_HEAD! !NEW_HEAD!

    echo.
    echo ---- Summary ----
    "%GIT%" diff --stat !OLD_HEAD! !NEW_HEAD!
)

popd
exit /b 0


:: ==================================================
:: Function: FindGit
:: ==================================================
:FindGit

:: 1. PATH
where git >nul 2>nul
if not errorlevel 1 (
    for /f "delims=" %%G in ('where git 2^>nul') do (
        set "GIT=%%G"
        exit /b 0
    )
)

:: 2. Git for Windows registry - HKCU
for /f "tokens=2,*" %%A in ('reg query "HKCU\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
    if exist "%%B\cmd\git.exe" (
        set "GIT=%%B\cmd\git.exe"
        exit /b 0
    )
)

:: 3. Git for Windows registry - HKLM
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i "InstallPath"') do (
    if exist "%%B\cmd\git.exe" (
        set "GIT=%%B\cmd\git.exe"
        exit /b 0
    )
)

:: 4. Common Git install paths
if exist "%ProgramFiles%\Git\cmd\git.exe" (
    set "GIT=%ProgramFiles%\Git\cmd\git.exe"
    exit /b 0
)

if exist "%ProgramFiles(x86)%\Git\cmd\git.exe" (
    set "GIT=%ProgramFiles(x86)%\Git\cmd\git.exe"
    exit /b 0
)

if exist "%LocalAppData%\Programs\Git\cmd\git.exe" (
    set "GIT=%LocalAppData%\Programs\Git\cmd\git.exe"
    exit /b 0
)

:: 5. GitHub Desktop embedded Git
for /d %%D in ("%LocalAppData%\GitHubDesktop\app-*") do (
    if exist "%%D\resources\app\git\cmd\git.exe" (
        set "GIT=%%D\resources\app\git\cmd\git.exe"
        exit /b 0
    )

    if exist "%%D\resources\app\git\mingw64\bin\git.exe" (
        set "GIT=%%D\resources\app\git\mingw64\bin\git.exe"
        exit /b 0
    )
)

:: 6. SourceTree embedded Git
if exist "%LocalAppData%\Atlassian\SourceTree\git_local\cmd\git.exe" (
    set "GIT=%LocalAppData%\Atlassian\SourceTree\git_local\cmd\git.exe"
    exit /b 0
)

if exist "%LocalAppData%\Atlassian\SourceTree\git_local\mingw32\bin\git.exe" (
    set "GIT=%LocalAppData%\Atlassian\SourceTree\git_local\mingw32\bin\git.exe"
    exit /b 0
)

:: 7. Scoop
if exist "%USERPROFILE%\scoop\shims\git.exe" (
    set "GIT=%USERPROFILE%\scoop\shims\git.exe"
    exit /b 0
)

:: 8. Chocolatey
if exist "%ProgramData%\chocolatey\bin\git.exe" (
    set "GIT=%ProgramData%\chocolatey\bin\git.exe"
    exit /b 0
)

exit /b 1