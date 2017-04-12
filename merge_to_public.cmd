setlocal
set repo=%1
if not defined repo (
    copy /y %~dpnx0 %temp%\
    call %temp%\%~nx0 %~dp0
    goto :EOF
)

git checkout public
if %errorlevel% NEQ 0 (
    goto :EOF
)
cmd /c gitm master
git rm -f %repo%\merge_to_public.cmd
git rm -f %repo%\exe\tuning_data.xlsx
git rm -f %repo%\exe\todo.txt
git rm -f %repo%\exe\encode_round_as_vid.cmd

REM add more git rm -f lines here to remove other private files
