param(
    [string]$RootPath = $PSScriptRoot,
    [int]$MaxDepth = 8,
    [switch]$NoAutoTrustSafeDirectory
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

function Pull-Repo {
    param([string]$Repo)

    $tracking = Get-UpstreamTracking -Repo $Repo

    if ($tracking) {
        Write-Host ""
        Write-Host "[PULL] tracking branch: $tracking"
        $pull = Invoke-Git -Repo $Repo -Args @("pull", "--ff-only")
        if ($pull.Code -eq 0) { return $true }

        Write-Host "[WARN] ff-only pull failed. Rebase may require manual conflict resolution." -ForegroundColor Yellow
        $ans = Read-Host "Run git pull --rebase? [y/N]"
        if ($ans -match "^[Yy]") {
            $rebase = Invoke-Git -Repo $Repo -Args @("pull", "--rebase")
            return ($rebase.Code -eq 0)
        }

        return $false
    }

    $remotes = Get-Remotes -Repo $Repo
    if ($remotes.Count -eq 0) {
        Write-Host "[SKIP] no remotes."
        return $false
    }

    $remote = if ($remotes -contains "upstream") { "upstream" } elseif ($remotes -contains "origin") { "origin" } else { $remotes[0] }
    $branch = Get-RemoteDefaultBranch -Repo $Repo -Remote $remote

    if (-not $branch) {
        Write-Host "[SKIP] failed to find default branch for $remote."
        return $false
    }

    Write-Host ""
    Write-Host "[PULL] no tracking branch. Trying $remote/$branch with --ff-only"
    $pull2 = Invoke-Git -Repo $Repo -Args @("pull", "--ff-only", $remote, $branch)
    if ($pull2.Code -eq 0) { return $true }

    Write-Host "[WARN] ff-only pull failed. Rebase may require manual conflict resolution." -ForegroundColor Yellow
    $ans2 = Read-Host "Run git pull --rebase $remote $branch? [y/N]"
    if ($ans2 -match "^[Yy]") {
        $rebase2 = Invoke-Git -Repo $Repo -Args @("pull", "--rebase", $remote, $branch)
        return ($rebase2.Code -eq 0)
    }

    return $false
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

    $remoteBranchCheck = Invoke-Git -Repo $Repo -Args @("rev-parse", "--verify", "--quiet", "origin/$branch") -Quiet
    if ($remoteBranchCheck.Code -ne 0) {
        Write-Host "[INFO] origin/$branch does not exist yet."
        $ansNew = Read-Host "Push current branch to origin? [y/N]"
        if ($ansNew -match "^[Yy]") {
            Invoke-Git -Repo $Repo -Args @("push", "-u", "origin", $branch)
        }
        return
    }

    $count = Invoke-Git -Repo $Repo -Args @("rev-list", "--left-right", "--count", "origin/$branch...HEAD") -Quiet
    if ($count.Code -ne 0 -or $count.Output.Count -eq 0) {
        Write-Host "[WARN] failed to check push difference."
        return
    }

    $parts = $count.Output[0].ToString().Trim() -split "\s+"
    if ($parts.Count -lt 2) { return }

    $behind = [int]$parts[0]
    $ahead = [int]$parts[1]

    if ($ahead -le 0) {
        Write-Host "[PUSH SKIP] no commits to push to origin/$branch."
        return
    }

    Write-Host "[PUSH CHECK] ahead=$ahead, behind=$behind for origin/$branch"
    $ans = Read-Host "Push to origin/$branch? [y/N]"
    if ($ans -match "^[Yy]") {
        Invoke-Git -Repo $Repo -Args @("push", "origin", $branch)
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
        Write-Host "Local changes found before update." -ForegroundColor Yellow
        Write-Host "Stash will be kept and not popped/dropped automatically."
        $ans = Read-Host "Save as stash and continue update? [y/N]"
        if ($ans -notmatch "^[Yy]") {
            Write-Host "[SKIP] user did not choose stash."
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

    $pulled = Pull-Repo -Repo $root
    if (-not $pulled) {
        Write-Host "[WARN] pull failed or cancelled. Manual check needed." -ForegroundColor Yellow
        continue
    }

    Push-IfAhead -Repo $root

    Write-Host ""
    Write-Host "[DONE] $root" -ForegroundColor Green
}

Write-Host ""
Write-Host "All update jobs completed."
