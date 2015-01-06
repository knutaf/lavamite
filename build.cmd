del exe\lavamite.exe
del graphite-knutaf\*.lib
dub build --arch=x86_64 --build=unittest lavamite:graphite-knutaf
if ERRORLEVEL 1 goto :EOF
dub build --arch=x86_64 --build=unittest lavamite:exe
