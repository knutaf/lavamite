set magic=%1
if not defined magic (
    copy /y %~dpnx0 %temp%\
    call %temp%\%~nx0 magic
    goto :EOF
)

git checkout public
if %errorlevel% NEQ 0 (
    goto :EOF
)
cmd /c gitm master
git rm -f %~dp0\merge_to_public.cmd
git rm -f %~dp0\exe\tuning_data.xlsx
git rm -f %~dp0\exe\todo.txt
git rm -f %~dp0\exe\encode_round_as_vid.cmd

REM add more git rm -f lines here to remove other private files
