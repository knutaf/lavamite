TARGET=takephoto

$(TARGET).exe: main.cpp
	cl /Fe$(TARGET).exe /EHsc /Zi /W4 main.cpp /link shlwapi.lib advapi32.lib mfplat.lib mf.lib mfuuid.lib

clean:
	del *.exe *.obj *.pdb *.ilk

cleanup:
	del *.obj *.pdb *.ilk
