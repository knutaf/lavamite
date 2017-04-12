@echo off
for /D %%i in (round_*) do rmdir /s /q %%i
del /f lavamite_status_dry.json
