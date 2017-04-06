@echo off
setlocal
set path=%path%;F:\programs\ffmpeg\bin
set indir=%1
if not defined indir echo Need input directory && goto :EOF

set tmpdir=%temp%\lavamite_encode

cmd /c rmdir /s /q %tmpdir%
cmd /c mkdir %tmpdir%
cmd /c mkdir %tmpdir%\discarded

set num=0
set last_copy=
for %%f in (%indir%\*.jpg) do call :renam %%f

ffmpeg -y -framerate 13 -i %tmpdir%\%%d.jpg -c:v libx264 -preset veryslow -b:v 1000000 %indir%\round.mp4
REM ffmpeg -y -s 160x120 -framerate 12 -i %tmpdir%\%%d.jpg -b:v 100000 %indir%\round.gif
REM f:\programs\gifsicle.exe -m -V -o %indir%\round.gif --delay 1 --optimize=3 --no-extensions --resize 213x160 %tmpdir%\*.gif
goto :EOF

:renam
set fil=%1
if not defined fil goto :EOF
copy %fil% %tmpdir%\%num%.jpg
REM ffmpeg -y -i %fil% %tmpdir%\%~n1.gif
set /a num=%num%+1
goto :EOF

:renam_replace_black_frames
set fil=%1
if not defined fil goto :EOF
F:\knut\prog\learn\dlang\image_reading\image_reading.exe %fil%
if %errorlevel% == 0 (
    set last_copy=%fil%
    copy %fil% %tmpdir%\%num%.jpg
    REM ffmpeg -y -i %fil% %tmpdir%\%~n1.gif
) else (
    copy %fil% %tmpdir%\discarded\
    copy %last_copy% %tmpdir%\%num%.jpg
)
set /a num=%num%+1
goto :EOF

:renam_omit_black
set fil=%1
if not defined fil goto :EOF
F:\knut\prog\learn\dlang\image_reading\image_reading.exe %fil%
if %errorlevel% == 0 (
    set last_copy=%fil%
    copy %fil% %tmpdir%\%num%.jpg
    REM ffmpeg -y -i %fil% %tmpdir%\%~n1.gif
) else (
    copy %fil% %tmpdir%\discarded\
    copy %last_copy% %tmpdir%\%num%.jpg
)
set /a num=%num%+1
goto :EOF

