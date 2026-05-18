AUTO GIT TOOLS v2
=================

구성
----
- AutoUpdateAll.ps1
- AutoPRAll.ps1
- Run_AutoUpdate.bat
- Run_AutoPR.bat
- repo_list.txt

이번 수정 내용
--------------
1. Run_*.bat 파일을 BOM 없이 저장했습니다.
   기존의 '癤?echo off' 문제는 UTF-8 BOM이 cmd에서 글자로 읽혀서 발생한 것입니다.

2. Git repo 판정을 다음 방식으로 변경했습니다.

   git -C "경로" rev-parse --show-toplevel

   그래서 단순히 .git 폴더가 있는지만 보지 않습니다.
   .git 파일 방식, worktree, submodule 형태도 처리합니다.

3. AutoUpdateAll.ps1은 로컬 변경사항이 있으면 stash 여부를 묻습니다.
   stash는 아래처럼 남겨둡니다.

   git stash push -u -m auto-update_keep_yyyyMMdd_HHmmss

   자동 pop/drop 하지 않습니다.
   즉, 업데이트 후에도 stash가 그대로 남아 있습니다.

4. 업데이트 후 origin으로 보낼 commit이 없으면 push를 생략합니다.

5. AutoPRAll.ps1은 repo마다 다음 순서로 묻습니다.

   변경사항 확인
   commit 여부
   push 여부
   PR 생성 여부

6. gh CLI가 있으면 gh pr create를 시도합니다.
   gh CLI가 없거나 실패하면 GitHub compare 페이지를 브라우저로 엽니다.

사용법
------
1. 이 zip을 프로젝트 폴더에 풉니다.
2. repo_list.txt에 실제 repo 경로를 한 줄씩 넣습니다.
3. 업데이트:
   Run_AutoUpdate.bat
4. PR:
   Run_AutoPR.bat

주의
----
- repo_list.txt의 경로가 실제 Git 작업트리 안이어야 합니다.
- 만약 여전히 Git 작업트리가 아니라고 나오면, 해당 폴더에서 직접 아래 명령을 확인하세요.

  git status

- Assets 내부 폴더가 실제 별도 repo라면 각 폴더 안에서 git status가 정상 작동해야 합니다.
