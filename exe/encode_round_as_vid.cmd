@echo off
setlocal
set path=%path%;F:\programs\ffmpeg\bin
set indir=%1
if not defined indir echo Need input directory && goto :EOF

set tmpdir=%temp%\lavamite_encode

cmd /c rmdir /s /q %tmpdir%
cmd /c mkdir %tmpdir%

set num=0
for %%f in (%indir%\*.jpg) do call :renam %%f

REM ffmpeg -framerate 13 -i %tmpdir%\%%d.jpg -c:v libx264 -preset veryslow -b:v 200000 %indir%\round.mp4
REM ffmpeg -y -s 160x120 -framerate 12 -i %tmpdir%\%%d.jpg -b:v 100000 %indir%\round.gif
f:\programs\gifsicle.exe -m -V -o %indir%\round.gif --delay 1 --optimize=3 --no-extensions --resize 213x160 %tmpdir%\*.gif
goto :EOF

:renam
set fil=%1
if not defined fil goto :EOF
REM copy %fil% %tmpdir%\%num%.jpg
ffmpeg -y -i %fil% %tmpdir%\%~n1.gif
set /a num=%num%+1
goto :EOF

