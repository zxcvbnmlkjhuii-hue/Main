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

function Get-RemoteUrl {
    param(
        [string]$Repo,
        [string]$Remote
    )

    $url = Invoke-Git -Repo $Repo -Args @("remote", "get-url", $Remote) -Quiet
    if ($url.Code -eq 0 -and $url.Output.Count -gt 0) {
        return $url.Output[0].ToString().Trim()
    }
    return $null
}

function ConvertTo-GitHubWebUrl {
    param([string]$Url)

    if (-not $Url) { return $null }

    $u = $Url.Trim()

    if ($u -match "^git@github\.com:(.+?)/(.+?)(\.git)?$") {
        return "https://github.com/$($Matches[1])/$($Matches[2] -replace '\.git$','')"
    }

    if ($u -match "^https://github\.com/(.+?)/(.+?)(\.git)?$") {
        return "https://github.com/$($Matches[1])/$($Matches[2] -replace '\.git$','')"
    }

    return $null
}

function Get-GitHubOwner {
    param([string]$Url)

    $web = ConvertTo-GitHubWebUrl -Url $Url
    if (-not $web) { return $null }

    if ($web -match "^https://github\.com/([^/]+)/([^/]+)$") {
        return $Matches[1]
    }

    return $null
}

function Open-ComparePage {
    param(
        [string]$Repo,
        [string]$Branch,
        [string]$BaseBranch
    )

    $remotes = Get-Remotes -Repo $Repo
    $baseRemote = if ($remotes -contains "upstream") { "upstream" } elseif ($remotes -contains "origin") { "origin" } else { $null }
    if (-not $baseRemote) {
        Write-Host "[SKIP] no remote. Browser PR page cannot be opened."
        return
    }

    $baseUrl = ConvertTo-GitHubWebUrl -Url (Get-RemoteUrl -Repo $Repo -Remote $baseRemote)
    if (-not $baseUrl) {
        Write-Host "[SKIP] failed to parse GitHub URL."
        return
    }

    $originUrl = Get-RemoteUrl -Repo $Repo -Remote "origin"
    $originOwner = Get-GitHubOwner -Url $originUrl

    if ($baseRemote -eq "upstream" -and $originOwner) {
        $compare = "{0}/compare/{1}...{2}:{3}?expand=1" -f $baseUrl, $BaseBranch, $originOwner, $Branch
    }
    else {
        $compare = "{0}/compare/{1}...{2}?expand=1" -f $baseUrl, $BaseBranch, $Branch
    }

    Write-Host "[BROWSER] $compare"
    Start-Process $compare
}

function Push-CurrentBranch {
    param(
        [string]$Repo,
        [string]$Branch
    )

    $remotes = Get-Remotes -Repo $Repo
    if (-not ($remotes -contains "origin")) {
        Write-Host "[ERROR] no origin remote. Fork workflow requires origin." -ForegroundColor Red
        return $false
    }

    $tracking = Invoke-Git -Repo $Repo -Args @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -Quiet
    if ($tracking.Code -eq 0) {
        $push = Invoke-Git -Repo $Repo -Args @("push")
        return ($push.Code -eq 0)
    }

    $push2 = Invoke-Git -Repo $Repo -Args @("push", "-u", "origin", $Branch)
    return ($push2.Code -eq 0)
}

function Get-AheadCount {
    param(
        [string]$Repo,
        [string]$Branch
    )

    $check = Invoke-Git -Repo $Repo -Args @("rev-parse", "--verify", "--quiet", "origin/$Branch") -Quiet
    if ($check.Code -ne 0) {
        return 1
    }

    $count = Invoke-Git -Repo $Repo -Args @("rev-list", "--left-right", "--count", "origin/$Branch...HEAD") -Quiet
    if ($count.Code -ne 0 -or $count.Output.Count -eq 0) {
        return 0
    }

    $parts = $count.Output[0].ToString().Trim() -split "\s+"
    if ($parts.Count -lt 2) { return 0 }
    return [int]$parts[1]
}

if (-not (Test-GitInstalled)) {
    Read-Host "Press Enter to exit"
    exit 1
}

$hasGh = Test-GhInstalled
if ($hasGh) {
    Write-Host "[INFO] GitHub CLI found. gh pr create will be used first."
}
else {
    Write-Host "[INFO] GitHub CLI not found. Browser compare page will be opened for PR creation."
}

$candidates = Get-RepoCandidates -Root $RootPath -MaxDepth $MaxDepth
$seen = @{}

foreach ($candidate in $candidates) {
    Write-Section "AUTO PR: $candidate"

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
    if (-not $branch) {
        Write-Host "[SKIP] detached HEAD. Checkout a branch first." -ForegroundColor Yellow
        continue
    }

    Write-Host "[BRANCH] $branch"

    $remotes = Get-Remotes -Repo $root
    $baseRemote = if ($remotes -contains "upstream") { "upstream" } elseif ($remotes -contains "origin") { "origin" } else { $null }
    $baseBranch = if ($baseRemote) { Get-RemoteDefaultBranch -Repo $root -Remote $baseRemote } else { "main" }

    Write-Host "[BASE] $baseRemote/$baseBranch"

    if ($branch -in @("main", "master", "develop")) {
        Write-Host "[WARN] current branch is $branch. A PR branch is recommended." -ForegroundColor Yellow
        $newBranch = Read-Host "Create a new branch? Type branch name or press Enter to continue"
        if (-not [string]::IsNullOrWhiteSpace($newBranch)) {
            $create = Invoke-Git -Repo $root -Args @("switch", "-c", $newBranch)
            if ($create.Code -ne 0) {
                Write-Host "[SKIP] branch creation failed."
                continue
            }
            $branch = $newBranch
            Write-Host "[BRANCH] $branch"
        }
    }

    if (Has-LocalChanges -Repo $root) {
        Write-Host ""
        Write-Host "[CHANGES]"
        Invoke-Git -Repo $root -Args @("status", "--short")

        Write-Host ""
        Write-Host "[DIFF SUMMARY]"
        Invoke-Git -Repo $root -Args @("diff", "--stat")

        $ansCommit = Read-Host "Commit these changes? [y/N]"
        if ($ansCommit -notmatch "^[Yy]") {
            Write-Host "[SKIP] user did not choose commit."
            continue
        }

        $msg = Read-Host "Commit message"
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
            $msg = "Auto PR update $stamp"
        }

        $add = Invoke-Git -Repo $root -Args @("add", "-A")
        if ($add.Code -ne 0) {
            Write-Host "[SKIP] git add failed."
            continue
        }

        $commit = Invoke-Git -Repo $root -Args @("commit", "-m", $msg)
        if ($commit.Code -ne 0) {
            Write-Host "[WARN] commit failed or no changes to commit."
        }
    }
    else {
        Write-Host "[CLEAN] no local changes."
    }

    $ahead = Get-AheadCount -Repo $root -Branch $branch
    if ($ahead -le 0) {
        Write-Host "[SKIP] no commits to push to origin/$branch."
        continue
    }

    $ansPush = Read-Host "Push to origin/$branch? [y/N]"
    if ($ansPush -notmatch "^[Yy]") {
        Write-Host "[SKIP] push skipped."
        continue
    }

    $pushed = Push-CurrentBranch -Repo $root -Branch $branch
    if (-not $pushed) {
        Write-Host "[SKIP] push failed. PR creation skipped."
        continue
    }

    $title = Read-Host "PR title"
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "Auto PR: $branch"
    }

    $body = Read-Host "PR body. Press Enter for default"
    if ([string]::IsNullOrWhiteSpace($body)) {
        $body = "Auto-created PR from $branch."
    }

    $ansPr = Read-Host "Create PR? [y/N]"
    if ($ansPr -notmatch "^[Yy]") {
        Write-Host "[SKIP] PR creation skipped."
        continue
    }

    if ($hasGh) {
        Write-Host "[GH] trying gh pr create..."
        $gh = Invoke-Gh -Repo $root -Args @("pr", "create", "--base", $baseBranch, "--head", $branch, "--title", $title, "--body", $body)
        if ($gh.Code -eq 0) {
            Write-Host "[OK] PR created." -ForegroundColor Green
            continue
        }

        Write-Host "[WARN] gh pr create failed. Opening browser compare page." -ForegroundColor Yellow
    }

    Open-ComparePage -Repo $root -Branch $branch -BaseBranch $baseBranch
}

Write-Host ""
Write-Host "All PR jobs completed."
