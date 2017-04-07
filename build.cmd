setlocal
pushd %~dp0
del exe\lavamite.exe
if ERRORLEVEL 1 goto :EOF
dub build --arch=x86_64 --build=unittest lavamite:exe
popd
