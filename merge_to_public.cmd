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
gitm master
git rm -f merge_to_public.cmd

REM add more git rm -f lines here to remove other private files
