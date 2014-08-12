module windows_serial;

import core.sys.windows.windows;

pragma(lib, "kernel32.lib");

immutable DWORD NOPARITY      = 0;
immutable DWORD ODDPARITY     = 1;
immutable DWORD EVENPARITY    = 2;
immutable DWORD MARKPARITY    = 3;
immutable DWORD SPACEPARITY   = 4;

immutable DWORD ONESTOPBIT    = 0;
immutable DWORD ONE5STOPBITS  = 1;
immutable DWORD TWOSTOPBITS   = 2;

//
// Baud rates at which the communication device operates
//
immutable DWORD CBR_110       = 110;
immutable DWORD CBR_300       = 300;
immutable DWORD CBR_600       = 600;
immutable DWORD CBR_1200      = 1200;
immutable DWORD CBR_2400      = 2400;
immutable DWORD CBR_4800      = 4800;
immutable DWORD CBR_9600      = 9600;
immutable DWORD CBR_14400     = 14400;
immutable DWORD CBR_19200     = 19200;
immutable DWORD CBR_38400     = 38400;
immutable DWORD CBR_56000     = 56000;
immutable DWORD CBR_57600     = 57600;
immutable DWORD CBR_115200    = 115200;
immutable DWORD CBR_128000    = 128000;
immutable DWORD CBR_256000    = 256000;

struct DCB {
  DWORD DCBlength;
  DWORD BaudRate;
  /*
  DWORD fBinary  :1;
  DWORD fParity  :1;
  DWORD fOutxCtsFlow  :1;
  DWORD fOutxDsrFlow  :1;
  DWORD fDtrControl  :2;
  DWORD fDsrSensitivity  :1;
  DWORD fTXContinueOnXoff  :1;
  DWORD fOutX  :1;
  DWORD fInX  :1;
  DWORD fErrorChar  :1;
  DWORD fNull  :1;
  DWORD fRtsControl  :2;
  DWORD fAbortOnError  :1;
  DWORD fDummy2  :17;
  */
  DWORD fStuff;
  WORD  wReserved;
  WORD  XonLim;
  WORD  XoffLim;
  BYTE  ByteSize;
  BYTE  Parity;
  BYTE  StopBits;
  char  XonChar;
  char  XoffChar;
  char  ErrorChar;
  char  EofChar;
  char  EvtChar;
  WORD  wReserved1;
};

struct COMSTAT {
  /*
  DWORD fCtsHold  :1;
  DWORD fDsrHold  :1;
  DWORD fRlsdHold  :1;
  DWORD fXoffHold  :1;
  DWORD fXoffSent  :1;
  DWORD fEof  :1;
  DWORD fTxim  :1;
  DWORD fReserved  :25;
  */
  DWORD fStuff;
  DWORD cbInQue;
  DWORD cbOutQue;
};

extern (C)
BOOL GetCommState(
  HANDLE hFile,
  DCB* lpDCB
);

extern(C)
BOOL SetCommState(
  HANDLE hFile,
  DCB* lpDCB
);

extern(C)
BOOL ClearCommError(
  HANDLE hFile,
  DWORD* lpErrors,
  COMSTAT* lpStat
);

extern(C)
BOOL SetCommMask(
  HANDLE hFile,
  DWORD dwEvtMask
);

extern(C)
BOOL FlushFileBuffers(
  HANDLE hFile
);
