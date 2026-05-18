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

function Get-RepoCandidates {
    param([string]$ListPath)

    if (Test-Path $ListPath) {
        $lines = [System.IO.File]::ReadAllLines($ListPath, [System.Text.Encoding]::UTF8)
        $result = New-Object System.Collections.Generic.List[string]

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
            if ($trimmed.StartsWith("#")) { continue }

            # 앞뒤 따옴표 제거
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

    return $null
}

function Get-UpstreamTracking {
    param([string]$Repo)

    $tracking = Invoke-Git -Repo $Repo -Args @("rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") -Quiet
    if ($tracking.Code -eq 0 -and $tracking.Output.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($tracking.Output[0])) {
        return $tracking.Output[0].ToString().Trim()
    }

    return $null
}

function Has-LocalChanges {
    param([string]$Repo)

    $status = Invoke-Git -Repo $Repo -Args @("status", "--porcelain") -Quiet
    return ($status.Code -eq 0 -and $status.Output.Count -gt 0)
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
    Write-Host "[STASH] 로컬 변경사항을 stash로 보존합니다. 메시지: $msg" -ForegroundColor Yellow
    $stash = Invoke-Git -Repo $Repo -Args @("stash", "push", "-u", "-m", $msg)

    if ($stash.Code -eq 0) {
        Write-Host "[OK] stash 완료. 자동 pop/drop 하지 않습니다." -ForegroundColor Green
        Write-Host ""
        Write-Host "[최근 stash 목록]"
        Invoke-Git -Repo $Repo -Args @("stash", "list", "--max-count=5")
        return $true
    }

    Write-Host "[ERROR] stash 실패. 이 repo 업데이트를 건너뜁니다." -ForegroundColor Red
    return $false
}

function Fetch-All {
    param([string]$Repo)

    Write-Host ""
    Write-Host "[FETCH] remotes fetch 중..."
    $fetch = Invoke-Git -Repo $Repo -Args @("fetch", "--all", "--prune")
    return ($fetch.Code -eq 0)
}

function Pull-Repo {
    param([string]$Repo)

    $tracking = Get-UpstreamTracking -Repo $Repo

    if ($tracking) {
        Write-Host ""
        Write-Host "[PULL] 현재 브랜치 tracking 기준으로 pull --ff-only: $tracking"
        $pull = Invoke-Git -Repo $Repo -Args @("pull", "--ff-only")
        if ($pull.Code -eq 0) { return $true }

        Write-Host "[WARN] ff-only pull 실패. rebase로 시도할까요? 충돌이 나면 수동 해결 필요." -ForegroundColor Yellow
        $ans = Read-Host "git pull --rebase 실행? [y/N]"
        if ($ans -match "^[Yy]") {
            $rebase = Invoke-Git -Repo $Repo -Args @("pull", "--rebase")
            return ($rebase.Code -eq 0)
        }

        return $false
    }

    $remotes = Get-Remotes -Repo $Repo
    if ($remotes.Count -eq 0) {
        Write-Host "[SKIP] remote가 없습니다."
        return $false
    }

    $remote = if ($remotes -contains "upstream") { "upstream" } elseif ($remotes -contains "origin") { "origin" } else { $remotes[0] }
    $branch = Get-RemoteDefaultBranch -Repo $Repo -Remote $remote

    if (-not $branch) {
        Write-Host "[SKIP] $remote 의 기본 브랜치를 찾지 못했습니다."
        return $false
    }

    Write-Host ""
    Write-Host "[PULL] tracking이 없어 $remote/$branch 기준으로 pull --ff-only"
    $pull2 = Invoke-Git -Repo $Repo -Args @("pull", "--ff-only", $remote, $branch)
    if ($pull2.Code -eq 0) { return $true }

    Write-Host "[WARN] ff-only pull 실패. rebase로 시도할까요? 충돌이 나면 수동 해결 필요." -ForegroundColor Yellow
    $ans2 = Read-Host "git pull --rebase $remote $branch 실행? [y/N]"
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
        Write-Host "[SKIP] detached HEAD 상태라 push 확인을 생략합니다."
        return
    }

    $remotes = Get-Remotes -Repo $Repo
    if (-not ($remotes -contains "origin")) {
        Write-Host "[SKIP] origin remote가 없어 push 확인을 생략합니다."
        return
    }

    $remoteBranchCheck = Invoke-Git -Repo $Repo -Args @("rev-parse", "--verify", "--quiet", "origin/$branch") -Quiet
    if ($remoteBranchCheck.Code -ne 0) {
        Write-Host "[INFO] origin/$branch 가 아직 없습니다."
        $ansNew = Read-Host "현재 브랜치를 origin에 새로 push할까요? [y/N]"
        if ($ansNew -match "^[Yy]") {
            Invoke-Git -Repo $Repo -Args @("push", "-u", "origin", $branch)
        }
        return
    }

    $count = Invoke-Git -Repo $Repo -Args @("rev-list", "--left-right", "--count", "origin/$branch...HEAD") -Quiet
    if ($count.Code -ne 0 -or $count.Output.Count -eq 0) {
        Write-Host "[WARN] push 대상 차이를 확인하지 못했습니다."
        return
    }

    $parts = $count.Output[0].ToString().Trim() -split "\s+"
    if ($parts.Count -lt 2) { return }

    $behind = [int]$parts[0]
    $ahead = [int]$parts[1]

    if ($ahead -le 0) {
        Write-Host "[PUSH SKIP] origin/$branch 로 보낼 새 커밋이 없습니다."
        return
    }

    Write-Host "[PUSH CHECK] origin/$branch 보다 $ahead commit 앞서 있습니다. behind=$behind"
    $ans = Read-Host "origin/$branch 로 push할까요? [y/N]"
    if ($ans -match "^[Yy]") {
        Invoke-Git -Repo $Repo -Args @("push", "origin", $branch)
    }
}

if (-not (Test-GitInstalled)) {
    Read-Host "종료하려면 Enter"
    exit 1
}

$candidates = Get-RepoCandidates -ListPath $RepoListPath
$seen = @{}

foreach ($candidate in $candidates) {
    Write-Section "AUTO UPDATE: $candidate"

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
    if ($branch) { Write-Host "[BRANCH] $branch" } else { Write-Host "[BRANCH] detached HEAD" -ForegroundColor Yellow }

    if (Has-LocalChanges -Repo $root) {
        Show-LocalChanges -Repo $root
        Write-Host ""
        Write-Host "업데이트 전 로컬 변경사항이 있습니다." -ForegroundColor Yellow
        Write-Host "stash는 남겨두고 자동으로 pop/drop 하지 않습니다."
        $ans = Read-Host "stash로 보존하고 업데이트를 계속할까요? [y/N]"
        if ($ans -notmatch "^[Yy]") {
            Write-Host "[SKIP] 사용자가 stash를 선택하지 않아 이 repo는 건너뜁니다."
            continue
        }

        $ok = Make-Stash -Repo $root
        if (-not $ok) { continue }
    }
    else {
        Write-Host "[CLEAN] 로컬 변경사항 없음."
    }

    $fetched = Fetch-All -Repo $root
    if (-not $fetched) {
        Write-Host "[WARN] fetch 실패. 이 repo는 pull을 건너뜁니다." -ForegroundColor Yellow
        continue
    }

    $pulled = Pull-Repo -Repo $root
    if (-not $pulled) {
        Write-Host "[WARN] pull 완료 실패 또는 취소. 수동 확인 필요." -ForegroundColor Yellow
        continue
    }

    Push-IfAhead -Repo $root

    Write-Host ""
    Write-Host "[DONE] $root" -ForegroundColor Green
}

Write-Host ""
Write-Host "전체 업데이트 완료."
