param(
    [string]$RootPath = $PSScriptRoot,
    [int]$MaxDepth = 8,
    [switch]$NoAutoTrustSafeDirectory,

    # "auto"이면 fork 구조 기준으로 upstream을 우선 사용합니다.
    # upstream이 없거나 현재 브랜치에 맞지 않으면 tracking/origin으로 fallback합니다.
    [string]$UpdateRemote = "auto",

    # 기본값: origin에 push할 커밋이 있으면 자동 push합니다.
    # 확인을 받고 싶으면 -AskBeforePushOrigin 옵션을 붙이세요.
    [switch]$AskBeforePushOrigin,

    # 기본값: 로컬 변경사항은 자동 stash 후 업데이트합니다.
    # 확인을 받고 싶으면 -AskBeforeStash 옵션을 붙이세요.
    [switch]$AskBeforeStash,

    # 기본값: ff-only merge 실패 시 자동 rebase를 시도합니다.
    # 확인을 받고 싶으면 -AskBeforeRebase 옵션을 붙이세요.
    [switch]$AskBeforeRebase,

    # 충돌 발생 시 기본값은 멈춰서 사용자의 선택을 받습니다.
    # 자동 작업을 계속 돌리고 싶으면 -ContinueOnConflict 옵션을 붙이세요.
    [switch]$ContinueOnConflict,

    # 기본값: upstream 동기화 전/후로 origin/current branch도 자동 동기화합니다.
    # 원하지 않으면 -SkipOriginPull 옵션을 붙이세요.
    [switch]$SkipOriginPull
)

$ErrorActionPreference = "Continue"
$env:GIT_PAGER = ""

function Write-Section($text) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host $text
    Write-Host "============================================================"
}

function Test-GitInstalled {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Host "[ERROR] git command was not found. Check Git for Windows or PATH." -ForegroundColor Red
        return $false
    }

    $ver = & git --version 2>&1
    Write-Host "[GIT] $ver"
    return $true
}

function Test-GhInstalled {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    return ($null -ne $gh)
}

function Invoke-Git {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string[]]$Args,
        [switch]$Quiet
    )

    $output = & git --no-pager -C $Repo @Args 2>&1
    $code = $LASTEXITCODE

    if (-not $Quiet -and $output) {
        $output | ForEach-Object { Write-Host $_ }
    }

    return [PSCustomObject]@{
        Code = $code
        Output = @($output)
    }
}

function Invoke-GitGlobal {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [switch]$Quiet
    )

    $output = & git --no-pager @Args 2>&1
    $code = $LASTEXITCODE

    if (-not $Quiet -and $output) {
        $output | ForEach-Object { Write-Host $_ }
    }

    return [PSCustomObject]@{
        Code = $code
        Output = @($output)
    }
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory=$true)][string]$Repo,
        [Parameter(Mandatory=$true)][string[]]$Args
    )

    Push-Location $Repo
    try {
        $output = & gh @Args 2>&1
        $code = $LASTEXITCODE
        if ($output) { $output | ForEach-Object { Write-Host $_ } }
        return [PSCustomObject]@{ Code = $code; Output = @($output) }
    }
    finally {
        Pop-Location
    }
}

function Test-DubiousOwnershipMessage {
    param([object[]]$Output)

    $text = ($Output | ForEach-Object { $_.ToString() }) -join "`n"
    return (
        $text -match "dubious ownership" -or
        $text -match "safe\.directory" -or
        $text -match "detected dubious ownership"
    )
}

function Add-SafeDirectory {
    param([string]$RepoPath)

    if ($NoAutoTrustSafeDirectory) {
        Write-Host "[SAFE DIR] Auto trust disabled. Skipping safe.directory registration." -ForegroundColor Yellow
        return $false
    }

    Write-Host "[SAFE DIR] Registering safe.directory: $RepoPath" -ForegroundColor Yellow
    $add = Invoke-GitGlobal -Args @("config", "--global", "--add", "safe.directory", $RepoPath)
    return ($add.Code -eq 0)
}

function Get-RepoCandidates {
    param(
        [string]$Root,
        [int]$MaxDepth = 8
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = (Get-Location).Path
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        Write-Host "[ERROR] RootPath does not exist: $Root" -ForegroundColor Red
        return @()
    }

    $rootFullPath = (Resolve-Path -LiteralPath $Root).Path

    Write-Host "[ROOT] auto scan root: $rootFullPath"
    Write-Host "[SCAN] searching child Git repositories..."

    $skipFolderNames = @(
        ".git",
        "Library",
        "Temp",
        "Obj",
        "obj",
        "Build",
        "Builds",
        "Logs",
        ".vs",
        ".idea",
        "node_modules"
    )

    $result = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([PSCustomObject]@{
        Path = $rootFullPath
        Depth = 0
    })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $dir = $current.Path
        $depth = [int]$current.Depth

        if ($depth -gt $MaxDepth) {
            continue
        }

        $gitMarker = Join-Path $dir ".git"

        if (Test-Path -LiteralPath $gitMarker) {
            $key = $dir.ToLowerInvariant()

            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                $result.Add($dir)
            }
        }

        $children = Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue

        foreach ($child in $children) {
            if ($skipFolderNames -contains $child.Name) {
                continue
            }

            $queue.Enqueue([PSCustomObject]@{
                Path = $child.FullName
                Depth = $depth + 1
            })
        }
    }

    if ($result.Count -eq 0) {
        Write-Host "[WARN] no Git repositories found." -ForegroundColor Yellow
    }
    else {
        Write-Host "[FOUND] Git repositories: $($result.Count)"
        foreach ($repo in $result) {
            Write-Host " - $repo"
        }
    }

    return @($result)
}

function Resolve-GitRoot {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "[SKIP] path does not exist: $Path" -ForegroundColor Yellow
        return $null
    }

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path

    $inside = Invoke-Git -Repo $resolvedPath -Args @("rev-parse", "--is-inside-work-tree") -Quiet

    if ($inside.Code -ne 0 -and (Test-DubiousOwnershipMessage -Output $inside.Output)) {
        Write-Host "[WARN] Git rejected this repo because of safe.directory / ownership." -ForegroundColor Yellow
        $ok = Add-SafeDirectory -RepoPath $resolvedPath

        if ($ok) {
            $inside = Invoke-Git -Repo $resolvedPath -Args @("rev-parse", "--is-inside-work-tree") -Quiet
        }
    }

    if ($inside.Code -ne 0) {
        Write-Host "[SKIP] git rev-parse failed: $resolvedPath" -ForegroundColor Yellow
        if ($inside.Output.Count -gt 0) {
            Write-Host "[GIT OUTPUT]"
            $inside.Output | ForEach-Object { Write-Host $_ }
        }
        return $null
    }

    $insideText = ""
    if ($inside.Output.Count -gt 0) {
        $insideText = $inside.Output[0].ToString().Trim().ToLowerInvariant()
    }

    if ($insideText -ne "true") {
        Write-Host "[SKIP] not inside Git work tree: $resolvedPath" -ForegroundColor Yellow
        return $null
    }

    $root = Invoke-Git -Repo $resolvedPath -Args @("rev-parse", "--show-toplevel") -Quiet

    if ($root.Code -ne 0 -or $root.Output.Count -eq 0) {
        Write-Host "[SKIP] failed to resolve Git root: $resolvedPath" -ForegroundColor Yellow
        if ($root.Output.Count -gt 0) {
            Write-Host "[GIT OUTPUT]"
            $root.Output | ForEach-Object { Write-Host $_ }
        }
        return $null
    }

    return ($root.Output[0].ToString().Trim())
}

function Get-CurrentBranch {
    param([string]$Repo)

    $branch = Invoke-Git -Repo $Repo -Args @("branch", "--show-current") -Quiet
    if ($branch.Code -eq 0 -and $branch.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($branch.Output[0])) {
        return $branch.Output[0].ToString().Trim()
    }

    return $null
}

function Get-Remotes {
    param([string]$Repo)

    $r = Invoke-Git -Repo $Repo -Args @("remote") -Quiet
    if ($r.Code -ne 0) { return @() }
    return @($r.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ })
}

function Get-RemoteDefaultBranch {
    param(
        [string]$Repo,
        [string]$Remote
    )

    $show = Invoke-Git -Repo $Repo -Args @("remote", "show", $Remote) -Quiet
    if ($show.Code -eq 0) {
        foreach ($line in $show.Output) {
            $s = $line.ToString().Trim()
            if ($s -match "^HEAD branch:\s*(.+)$") {
                return $Matches[1].Trim()
            }
        }
    }

    foreach ($candidate in @("main", "master", "develop")) {
        $check = Invoke-Git -Repo $Repo -Args @("ls-remote", "--heads", $Remote, $candidate) -Quiet
        if ($check.Code -eq 0 -and $check.Output.Count -gt 0) {
            return $candidate
        }
    }

    return "main"
}

function Has-LocalChanges {
    param([string]$Repo)

    $status = Invoke-Git -Repo $Repo -Args @("status", "--porcelain") -Quiet
    return ($status.Code -eq 0 -and $status.Output.Count -gt 0)
}

function Get-UpstreamTracking {
    param([string]$Repo)

    $tracking = Invoke-Git -Repo $Repo -Args @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -Quiet
    if ($tracking.Code -eq 0 -and $tracking.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($tracking.Output[0])) {
        return $tracking.Output[0].ToString().Trim()
    }

    return $null
}


function Test-RemoteBranchExists {
    param(
        [string]$Repo,
        [string]$Remote,
        [string]$Branch
    )

    if ([string]::IsNullOrWhiteSpace($Remote) -or [string]::IsNullOrWhiteSpace($Branch)) {
        return $false
    }

    $check = Invoke-Git -Repo $Repo -Args @("ls-remote", "--exit-code", "--heads", $Remote, $Branch) -Quiet
    return ($check.Code -eq 0 -and $check.Output.Count -gt 0)
}

function Select-UpdateSource {
    param([string]$Repo)

    $branch = Get-CurrentBranch -Repo $Repo
    $remotes = Get-Remotes -Repo $Repo

    if ($remotes.Count -eq 0) {
        return $null
    }

    # 사용자가 명시적으로 -UpdateRemote upstream/origin 등을 준 경우
    if ($UpdateRemote -ne "auto") {
        if (-not ($remotes -contains $UpdateRemote)) {
            Write-Host "[WARN] requested update remote does not exist: $UpdateRemote" -ForegroundColor Yellow
            return $null
        }

        if ($branch -and (Test-RemoteBranchExists -Repo $Repo -Remote $UpdateRemote -Branch $branch)) {
            return [PSCustomObject]@{
                Remote = $UpdateRemote
                Branch = $branch
                Reason = "requested remote has same branch"
            }
        }

        $defaultBranch = Get-RemoteDefaultBranch -Repo $Repo -Remote $UpdateRemote
        return [PSCustomObject]@{
            Remote = $UpdateRemote
            Branch = $defaultBranch
            Reason = "requested remote default branch"
        }
    }

    # fork 구조: upstream이 있으면 우선 upstream 기준으로 업데이트한다.
    if ($remotes -contains "upstream") {
        if ($branch -and (Test-RemoteBranchExists -Repo $Repo -Remote "upstream" -Branch $branch)) {
            return [PSCustomObject]@{
                Remote = "upstream"
                Branch = $branch
                Reason = "upstream has same branch"
            }
        }

        $upstreamDefault = Get-RemoteDefaultBranch -Repo $Repo -Remote "upstream"

        # main/master/develop 같은 기본 브랜치일 때만 upstream default로 동기화.
        # feature 브랜치에 실수로 upstream/main을 섞는 것을 방지한다.
        if ($branch -and ($branch -eq $upstreamDefault -or $branch -in @("main", "master", "develop"))) {
            return [PSCustomObject]@{
                Remote = "upstream"
                Branch = $upstreamDefault
                Reason = "fork default branch sync"
            }
        }
    }

    # 일반 구조: 현재 브랜치의 tracking branch 사용
    $tracking = Get-UpstreamTracking -Repo $Repo
    if ($tracking -and $tracking -match "^([^/]+)/(.+)$") {
        return [PSCustomObject]@{
            Remote = $Matches[1]
            Branch = $Matches[2]
            Reason = "tracking branch"
        }
    }

    # tracking이 없으면 origin/현재브랜치
    if ($branch -and ($remotes -contains "origin") -and (Test-RemoteBranchExists -Repo $Repo -Remote "origin" -Branch $branch)) {
        return [PSCustomObject]@{
            Remote = "origin"
            Branch = $branch
            Reason = "origin has same branch"
        }
    }

    # 마지막 fallback
    $remote = if ($remotes -contains "origin") { "origin" } else { $remotes[0] }
    $default = Get-RemoteDefaultBranch -Repo $Repo -Remote $remote

    return [PSCustomObject]@{
        Remote = $remote
        Branch = $default
        Reason = "fallback default branch"
    }
}

function Show-LocalChanges {
    param([string]$Repo)

    Write-Host ""
    Write-Host "[LOCAL CHANGES]"
    Invoke-Git -Repo $Repo -Args @("status", "--short")
}

function Make-Stash {
    param([string]$Repo)

    $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $msg = "auto-update_keep_$stamp"

    Write-Host ""
    Write-Host "[STASH] saving local changes. Message: $msg" -ForegroundColor Yellow
    $stash = Invoke-Git -Repo $Repo -Args @("stash", "push", "-u", "-m", $msg)

    if ($stash.Code -eq 0) {
        Write-Host "[OK] stash completed. It will not be popped/dropped automatically." -ForegroundColor Green
        Write-Host ""
        Write-Host "[RECENT STASHES]"
        Invoke-Git -Repo $Repo -Args @("stash", "list", "--max-count=5")
        return $true
    }

    Write-Host "[ERROR] stash failed. Skipping this repo." -ForegroundColor Red
    return $false
}

function Fetch-All {
    param([string]$Repo)

    Write-Host ""
    Write-Host "[FETCH] git fetch --all --prune"
    $fetch = Invoke-Git -Repo $Repo -Args @("fetch", "--all", "--prune")
    return ($fetch.Code -eq 0)
}

function Get-GitInternalPath {
    param(
        [string]$Repo,
        [string]$Name
    )

    $pathResult = Invoke-Git -Repo $Repo -Args @("rev-parse", "--git-path", $Name) -Quiet
    if ($pathResult.Code -ne 0 -or $pathResult.Output.Count -eq 0) {
        return $null
    }

    $p = $pathResult.Output[0].ToString().Trim()
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $Repo $p)
}

function Test-GitConflictState {
    param([string]$Repo)

    $paths = @(
        (Get-GitInternalPath -Repo $Repo -Name "rebase-merge"),
        (Get-GitInternalPath -Repo $Repo -Name "rebase-apply"),
        (Get-GitInternalPath -Repo $Repo -Name "MERGE_HEAD")
    ) | Where-Object { $_ }

    foreach ($p in $paths) {
        if (Test-Path -LiteralPath $p) { return $true }
    }

    $unmerged = Invoke-Git -Repo $Repo -Args @("diff", "--name-only", "--diff-filter=U") -Quiet
    return ($unmerged.Code -eq 0 -and $unmerged.Output.Count -gt 0)
}

function Show-ConflictFiles {
    param([string]$Repo)

    Write-Host ""
    Write-Host "[CONFLICT FILES]" -ForegroundColor Red
    $unmerged = Invoke-Git -Repo $Repo -Args @("diff", "--name-only", "--diff-filter=U") -Quiet
    if ($unmerged.Code -eq 0 -and $unmerged.Output.Count -gt 0) {
        $unmerged.Output | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    }
    else {
        Write-Host " - Git conflict state detected, but no unmerged file list was returned." -ForegroundColor Yellow
    }
}

function Resolve-ConflictPrompt {
    param(
        [string]$Repo,
        [string]$OperationName
    )

    Show-ConflictFiles -Repo $Repo

    if ($ContinueOnConflict) {
        Write-Host "[CONFLICT] $OperationName conflict detected. Leaving this repo as-is and continuing because -ContinueOnConflict is set." -ForegroundColor Red
        return $false
    }

    while ($true) {
        Write-Host ""
        Write-Host "[CONFLICT] $OperationName stopped because of conflicts." -ForegroundColor Red
        Write-Host "  R : I resolved conflicts manually. Continue operation."
        Write-Host "  A : Abort current operation and skip this repo."
        Write-Host "  S : Stop the whole script here."
        $ans = Read-Host "Choose [R/A/S]"

        if ($ans -match "^[Rr]") {
            if ($OperationName -match "rebase") {
                $continueResult = Invoke-Git -Repo $Repo -Args @("rebase", "--continue")
                if ($continueResult.Code -eq 0) { return $true }

                if (Test-GitConflictState -Repo $Repo) {
                    Show-ConflictFiles -Repo $Repo
                    continue
                }

                Write-Host "[ERROR] rebase --continue failed. Manual check needed." -ForegroundColor Red
                return $false
            }

            $continueMerge = Invoke-Git -Repo $Repo -Args @("merge", "--continue")
            if ($continueMerge.Code -eq 0) { return $true }

            if (Test-GitConflictState -Repo $Repo) {
                Show-ConflictFiles -Repo $Repo
                continue
            }

            Write-Host "[ERROR] merge --continue failed. Manual check needed." -ForegroundColor Red
            return $false
        }

        if ($ans -match "^[Aa]") {
            if ($OperationName -match "rebase") {
                Invoke-Git -Repo $Repo -Args @("rebase", "--abort")
            }
            else {
                Invoke-Git -Repo $Repo -Args @("merge", "--abort")
            }
            Write-Host "[SKIP] operation aborted. Skipping this repo." -ForegroundColor Yellow
            return $false
        }

        if ($ans -match "^[Ss]") {
            Write-Host "[STOP] user stopped the script because of conflict." -ForegroundColor Red
            exit 2
        }
    }
}

function Sync-FetchedRemoteBranch {
    param(
        [string]$Repo,
        [string]$Remote,
        [string]$Branch,
        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Remote) -or [string]::IsNullOrWhiteSpace($Branch)) {
        Write-Host "[SKIP] invalid sync source."
        return $true
    }

    $target = "$Remote/$Branch"

    $verify = Invoke-Git -Repo $Repo -Args @("rev-parse", "--verify", "--quiet", $target) -Quiet
    if ($verify.Code -ne 0) {
        Write-Host "[SKIP] remote branch not found after fetch: $target" -ForegroundColor Yellow
        return $true
    }

    Write-Host ""
    Write-Host "[SYNC] $target ($Reason)"

    # fetch는 이미 Fetch-All에서 끝났으므로 git pull 대신 fetch된 remote branch를 직접 반영한다.
    # ff-only가 되면 그대로 fast-forward, diverge면 자동 rebase를 시도한다.
    $merge = Invoke-Git -Repo $Repo -Args @("merge", "--ff-only", $target)

    if ($merge.Code -eq 0) {
        return $true
    }

    Write-Host "[INFO] ff-only sync was not possible. Trying automatic rebase onto $target." -ForegroundColor Yellow

    $doRebase = $true
    if ($AskBeforeRebase) {
        $ans = Read-Host "Run git rebase $target? [y/N]"
        $doRebase = ($ans -match "^[Yy]")
    }

    if (-not $doRebase) {
        Write-Host "[SKIP] user skipped rebase."
        return $false
    }

    $rebase = Invoke-Git -Repo $Repo -Args @("rebase", $target)
    if ($rebase.Code -eq 0) {
        Write-Host "[REBASE OK] rebased onto $target." -ForegroundColor Green
        return $true
    }

    if (Test-GitConflictState -Repo $Repo) {
        return (Resolve-ConflictPrompt -Repo $Repo -OperationName "rebase")
    }

    Write-Host "[ERROR] rebase failed, but no conflict state was detected. Manual check needed." -ForegroundColor Red
    return $false
}

function Sync-OriginBranch {
    param(
        [string]$Repo,
        [string]$Reason = "origin branch sync"
    )

    if ($SkipOriginPull) {
        Write-Host "[ORIGIN SYNC SKIP] -SkipOriginPull is set."
        return $true
    }

    $branch = Get-CurrentBranch -Repo $Repo
    if (-not $branch) {
        Write-Host "[ORIGIN SYNC SKIP] detached HEAD."
        return $true
    }

    $remotes = Get-Remotes -Repo $Repo
    if (-not ($remotes -contains "origin")) {
        Write-Host "[ORIGIN SYNC SKIP] no origin remote."
        return $true
    }

    if (-not (Test-RemoteBranchExists -Repo $Repo -Remote "origin" -Branch $branch)) {
        Write-Host "[ORIGIN SYNC SKIP] origin/$branch does not exist yet. Push step can create it."
        return $true
    }

    return (Sync-FetchedRemoteBranch -Repo $Repo -Remote "origin" -Branch $branch -Reason $Reason)
}

function Pull-Repo {
    param([string]$Repo)

    $source = Select-UpdateSource -Repo $Repo
    if ($null -eq $source) {
        Write-Host "[SKIP] no update source."
        return $false
    }

    Write-Host ""
    Write-Host "[UPDATE SOURCE] $($source.Remote)/$($source.Branch) ($($source.Reason))"

    return (Sync-FetchedRemoteBranch -Repo $Repo -Remote $source.Remote -Branch $source.Branch -Reason $source.Reason)
}

function Push-IfAhead {
    param([string]$Repo)

    $branch = Get-CurrentBranch -Repo $Repo
    if (-not $branch) {
        Write-Host "[SKIP] detached HEAD. Push check skipped."
        return
    }

    $remotes = Get-Remotes -Repo $Repo
    if (-not ($remotes -contains "origin")) {
        Write-Host "[SKIP] no origin remote. Push check skipped."
        return
    }

    $remoteRef = "origin/$branch"

    $remoteBranchCheck = Invoke-Git -Repo $Repo -Args @("rev-parse", "--verify", "--quiet", $remoteRef) -Quiet
    if ($remoteBranchCheck.Code -ne 0) {
        Write-Host "[PUSH NEW] $remoteRef does not exist yet."

        $doPushNew = $true
        if ($AskBeforePushOrigin) {
            $ansNew = Read-Host "Push current branch to origin and set upstream? [y/N]"
            $doPushNew = ($ansNew -match "^[Yy]")
        }

        if ($doPushNew) {
            $pushNew = Invoke-Git -Repo $Repo -Args @("push", "-u", "origin", $branch)
            if ($pushNew.Code -eq 0) {
                Write-Host "[PUSH OK] origin/$branch created." -ForegroundColor Green
            }
            else {
                Write-Host "[PUSH FAIL] failed to create origin/$branch." -ForegroundColor Red
            }
        }
        else {
            Write-Host "[PUSH SKIP] user skipped new branch push."
        }

        return
    }

    $count = Invoke-Git -Repo $Repo -Args @("rev-list", "--left-right", "--count", "$remoteRef...HEAD") -Quiet
    if ($count.Code -ne 0 -or $count.Output.Count -eq 0) {
        Write-Host "[WARN] failed to check push difference."
        return
    }

    $parts = $count.Output[0].ToString().Trim() -split "\s+"
    if ($parts.Count -lt 2) { return }

    $behind = [int]$parts[0]
    $ahead = [int]$parts[1]

    if ($ahead -le 0) {
        Write-Host "[PUSH SKIP] no commits to push to $remoteRef."
        return
    }

    # origin 쪽에도 로컬에 없는 커밋이 있으면 non-fast-forward 위험이 있으므로 자동 push하지 않는다.
    if ($behind -gt 0) {
        Write-Host "[PUSH BLOCKED] local is ahead=$ahead but also behind=$behind from $remoteRef." -ForegroundColor Yellow
        Write-Host "               Manual check needed to avoid overwriting/divergent push."
        return
    }

    Write-Host "[PUSH CHECK] ahead=$ahead, behind=$behind for $remoteRef"

    $doPush = $true
    if ($AskBeforePushOrigin) {
        $ans = Read-Host "Push to $remoteRef? [y/N]"
        $doPush = ($ans -match "^[Yy]")
    }

    if ($doPush) {
        $push = Invoke-Git -Repo $Repo -Args @("push", "origin", $branch)
        if ($push.Code -eq 0) {
            Write-Host "[PUSH OK] pushed to $remoteRef." -ForegroundColor Green
        }
        else {
            Write-Host "[PUSH FAIL] push to $remoteRef failed." -ForegroundColor Red
        }
    }
    else {
        Write-Host "[PUSH SKIP] user skipped push."
    }
}

if (-not (Test-GitInstalled)) {
    Read-Host "Press Enter to exit"
    exit 1
}

$candidates = Get-RepoCandidates -Root $RootPath -MaxDepth $MaxDepth
$seen = @{}

foreach ($candidate in $candidates) {
    Write-Section "AUTO UPDATE: $candidate"

    $root = Resolve-GitRoot -Path $candidate

    if (-not $root) {
        continue
    }

    $key = $root.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
        Write-Host "[SKIP] already processed repo: $root"
        continue
    }
    $seen[$key] = $true

    Write-Host "[REPO] $root"
    $branch = Get-CurrentBranch -Repo $root
    if ($branch) { Write-Host "[BRANCH] $branch" } else { Write-Host "[BRANCH] detached HEAD" -ForegroundColor Yellow }

    if (Has-LocalChanges -Repo $root) {
        Show-LocalChanges -Repo $root
        Write-Host ""
        Write-Host "[LOCAL] local changes found. Auto-stashing before update." -ForegroundColor Yellow
        Write-Host "[LOCAL] stash will be kept and not popped/dropped automatically."

        $doStash = $true
        if ($AskBeforeStash) {
            $ans = Read-Host "Save as stash and continue update? [y/N]"
            $doStash = ($ans -match "^[Yy]")
        }

        if (-not $doStash) {
            Write-Host "[SKIP] user skipped stash."
            continue
        }

        $ok = Make-Stash -Repo $root
        if (-not $ok) { continue }
    }
    else {
        Write-Host "[CLEAN] no local changes."
    }

    $fetched = Fetch-All -Repo $root
    if (-not $fetched) {
        Write-Host "[WARN] fetch failed. Skipping pull." -ForegroundColor Yellow
        continue
    }

    $originBefore = Sync-OriginBranch -Repo $root -Reason "origin sync before upstream/update source"
    if (-not $originBefore) {
        Write-Host "[WARN] origin sync failed or stopped. Manual check needed." -ForegroundColor Yellow
        continue
    }

    $pulled = Pull-Repo -Repo $root
    if (-not $pulled) {
        Write-Host "[WARN] update source sync failed or cancelled. Manual check needed." -ForegroundColor Yellow
        continue
    }

    $originAfter = Sync-OriginBranch -Repo $root -Reason "origin sync before push"
    if (-not $originAfter) {
        Write-Host "[WARN] final origin sync failed or stopped. Manual check needed." -ForegroundColor Yellow
        continue
    }

    Push-IfAhead -Repo $root

    Write-Host ""
    Write-Host "[DONE] $root" -ForegroundColor Green
}

Write-Host ""
Write-Host "All update jobs completed."
