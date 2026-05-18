param(
    [string]$RepoListPath = "$PSScriptRoot\repo_list.txt"
)

$ErrorActionPreference = "Continue"

function Write-Section($text) {
    Write-Host ""
    Write-Host "============================================================"
    Write-Host $text
    Write-Host "============================================================"
}

function Test-GitInstalled {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Host "[ERROR] git 명령을 찾을 수 없습니다. Git for Windows 설치 또는 PATH 등록이 필요합니다." -ForegroundColor Red
        return $false
    }
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

    $output = & git -C $Repo @Args 2>&1
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

function Get-RepoCandidates {
    param([string]$ListPath)

    if (Test-Path $ListPath) {
        $lines = [System.IO.File]::ReadAllLines($ListPath, [System.Text.Encoding]::UTF8)
        $result = New-Object System.Collections.Generic.List[string]

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if ($trimmed.StartsWith("#")) { continue }
            $trimmed = $trimmed.Trim('"')
            $result.Add($trimmed)
        }

        return @($result)
    }

    return @((Get-Location).Path)
}

function Resolve-GitRoot {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return $null
    }

    $resolvedPath = (Resolve-Path $Path).Path
    $inside = Invoke-Git -Repo $resolvedPath -Args @("rev-parse", "--is-inside-work-tree") -Quiet

    if ($inside.Code -ne 0) {
        return $null
    }

    $root = Invoke-Git -Repo $resolvedPath -Args @("rev-parse", "--show-toplevel") -Quiet
    if ($root.Code -ne 0 -or $root.Output.Count -eq 0) {
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
        Write-Host "[SKIP] remote가 없어 브라우저 PR 페이지를 열 수 없습니다."
        return
    }

    $baseUrl = ConvertTo-GitHubWebUrl -Url (Get-RemoteUrl -Repo $Repo -Remote $baseRemote)
    if (-not $baseUrl) {
        Write-Host "[SKIP] GitHub URL을 해석하지 못했습니다."
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
        Write-Host "[ERROR] origin remote가 없습니다. fork workflow에서는 origin이 필요합니다." -ForegroundColor Red
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
    Read-Host "종료하려면 Enter"
    exit 1
}

$hasGh = Test-GhInstalled
if ($hasGh) {
    Write-Host "[INFO] GitHub CLI(gh)를 찾았습니다. PR 생성에 gh를 우선 사용합니다."
}
else {
    Write-Host "[INFO] GitHub CLI(gh)가 없습니다. PR 생성 시 브라우저 compare 페이지를 엽니다."
}

$candidates = Get-RepoCandidates -ListPath $RepoListPath
$seen = @{}

foreach ($candidate in $candidates) {
    Write-Section "AUTO PR: $candidate"

    $root = Resolve-GitRoot -Path $candidate

    if (-not $root) {
        Write-Host "[SKIP] Git 작업트리가 아닙니다. 경로를 확인하세요."
        continue
    }

    $key = $root.ToLowerInvariant()
    if ($seen.ContainsKey($key)) {
        Write-Host "[SKIP] 이미 처리한 repo입니다: $root"
        continue
    }
    $seen[$key] = $true

    Write-Host "[REPO] $root"

    $branch = Get-CurrentBranch -Repo $root
    if (-not $branch) {
        Write-Host "[SKIP] detached HEAD 상태입니다. 브랜치를 체크아웃한 뒤 다시 실행하세요." -ForegroundColor Yellow
        continue
    }

    Write-Host "[BRANCH] $branch"

    $remotes = Get-Remotes -Repo $root
    $baseRemote = if ($remotes -contains "upstream") { "upstream" } elseif ($remotes -contains "origin") { "origin" } else { $null }
    $baseBranch = if ($baseRemote) { Get-RemoteDefaultBranch -Repo $root -Remote $baseRemote } else { "main" }

    Write-Host "[BASE] $baseRemote/$baseBranch"

    if ($branch -in @("main", "master", "develop")) {
        Write-Host "[WARN] 현재 브랜치가 $branch 입니다. PR용 작업 브랜치를 만드는 것을 추천합니다." -ForegroundColor Yellow
        $newBranch = Read-Host "새 브랜치를 만들까요? 브랜치명을 입력하거나 Enter로 그대로 진행"
        if (-not [string]::IsNullOrWhiteSpace($newBranch)) {
            $create = Invoke-Git -Repo $root -Args @("switch", "-c", $newBranch)
            if ($create.Code -ne 0) {
                Write-Host "[SKIP] 브랜치 생성 실패."
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

        $ansCommit = Read-Host "이 변경사항을 commit할까요? [y/N]"
        if ($ansCommit -notmatch "^[Yy]") {
            Write-Host "[SKIP] 사용자가 commit을 선택하지 않았습니다."
            continue
        }

        $msg = Read-Host "커밋 메시지 입력"
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $stamp = Get-Date -Format "yyyy-MM-dd HH:mm"
            $msg = "Auto PR update $stamp"
        }

        $add = Invoke-Git -Repo $root -Args @("add", "-A")
        if ($add.Code -ne 0) {
            Write-Host "[SKIP] git add 실패."
            continue
        }

        $commit = Invoke-Git -Repo $root -Args @("commit", "-m", $msg)
        if ($commit.Code -ne 0) {
            Write-Host "[WARN] commit 실패 또는 커밋할 변경사항 없음."
        }
    }
    else {
        Write-Host "[CLEAN] 로컬 변경사항 없음."
    }

    $ahead = Get-AheadCount -Repo $root -Branch $branch
    if ($ahead -le 0) {
        Write-Host "[SKIP] origin/$branch 로 보낼 커밋이 없습니다."
        continue
    }

    $ansPush = Read-Host "origin/$branch 로 push할까요? [y/N]"
    if ($ansPush -notmatch "^[Yy]") {
        Write-Host "[SKIP] push를 건너뜁니다."
        continue
    }

    $pushed = Push-CurrentBranch -Repo $root -Branch $branch
    if (-not $pushed) {
        Write-Host "[SKIP] push 실패. PR 생성을 건너뜁니다."
        continue
    }

    $title = Read-Host "PR 제목 입력"
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = "Auto PR: $branch"
    }

    $body = Read-Host "PR 설명 입력. Enter면 기본 설명 사용"
    if ([string]::IsNullOrWhiteSpace($body)) {
        $body = "Auto-created PR from $branch."
    }

    $ansPr = Read-Host "PR을 만들까요? [y/N]"
    if ($ansPr -notmatch "^[Yy]") {
        Write-Host "[SKIP] PR 생성을 건너뜁니다."
        continue
    }

    if ($hasGh) {
        Write-Host "[GH] gh pr create 시도 중..."
        $gh = Invoke-Gh -Repo $root -Args @("pr", "create", "--base", $baseBranch, "--head", $branch, "--title", $title, "--body", $body)
        if ($gh.Code -eq 0) {
            Write-Host "[OK] PR 생성 완료." -ForegroundColor Green
            continue
        }

        Write-Host "[WARN] gh pr create 실패. 브라우저 compare 페이지를 엽니다." -ForegroundColor Yellow
    }

    Open-ComparePage -Repo $root -Branch $branch -BaseBranch $baseBranch
}

Write-Host ""
Write-Host "전체 PR 처리 완료."
