# command98

A native Windows re-creation of the Windows 98 SE command interpreter (`COMMAND.COM` 4.10.2222), written in Swift from scratch.

This is a reimplementation, not a port. It behaves like the original because it was built from reverse-engineering notes (command table, dispatch table, DIR switch parsers). None of Microsoft's code or text was copied.

Not affiliated with or endorsed by Microsoft. Windows is a trademark of Microsoft Corporation.

This is the **windows** branch: Windows 98's COMMAND.COM, running on the Windows that replaced it. The macOS and Linux versions live on the `macOS` and `linux` branches.

## Get it

Grab `command98-windows-x86_64.exe` from the releases page and run it. It needs the Microsoft Visual C++ Redistributable (x64), which nearly every Windows install already has.

## Build it

Install Visual Studio Build Tools (MSVC and the Windows SDK) and the Swift 6 toolchain for Windows, then:

```bat
swift build -c release --static-swift-stdlib
swift test
```

## Drives

On first run you get `%USERPROFILE%\.command98.ini` and a sandbox folder at `%USERPROFILE%\DOSROOT`, which is mounted as `C:\`.

```ini
C=~/DOSROOT      ; the sandbox
D=~/Downloads    ; any other folder as a drive
REAL=no          ; yes = every real drive letter is itself, and the sandbox moves to S: (or the next free letter)
```

There are also command-line flags: `--real`, `--sandbox` and `--mount X=path`.

**DEL on the sandbox deletes for real. On every other drive it goes to the Recycle Bin.**

In real mode, `VOL C:` shows the drive's actual label and serial number.

## What's in it

- All 40 internal commands, in the original table order: DIR CALL CHCP RENAME REN ERASE DEL TYPE REM COPY PAUSE DATE TIME VER VOL CD CHDIR MD MKDIR RD RMDIR BREAK VERIFY SET PROMPT PATH EXIT CTTY ECHO LOCK UNLOCK GOTO SHIFT IF FOR CLS TRUENAME LOADHIGH LH LFNFOR
- `DIR` with the original column layout, 8.3 short names (`PROGRA~1`) and the long name on the right, plus `/A:RHSvDA`, `/O:NEDSGAC`, `/W /B /S /P /L /4 /-C` and `DIRCMD`
- Batch files: `%0`–`%9`, `%VAR%`, `SHIFT`, `GOTO` (8-character labels), `CALL`, `IF [NOT] ERRORLEVEL/EXIST/==`, `FOR %%x IN (...) DO`, `^Z` as end of file, and the "Terminate batch job (Y/N)?" prompt
- `>`, `>>`, `<` and `|` (the pipe goes through temp files, like DOS did). `NUL`, `CON` and `PRN` work as device names
- Search order is `.COM` → `.EXE` → `.BAT` → bare executable, then Windows' own `PATH`. So `notepad` and `ipconfig` just work. PE executables run natively. Real 16-bit DOS executables get "This program cannot be run in Windows mode.", which is the old message turned around.
- Line editing the 1998 way: F1 or → copies one character of the last line, F3 copies the rest, Esc cancels the line. There's no up-arrow history, because that was DOSKEY's job.
- `/C`, `/K`, `/P`, and `/Y` (step through a batch file line by line)

## Utilities (`C:\WINDOWS\COMMAND`)

The external commands live where Win98 kept them, as stub files on the sandbox drive with the real 1999 file sizes and dates. They're first in `PATH`. Delete `FIND.EXE` and `FIND` is gone, just like in 1998. Rename a stub and it still runs, like renaming a real `.EXE`.

- **Text:** `FIND` (`/V /C /N /I`, sets errorlevel), `SORT` (`/R /+n`), `MORE`, `FC` (text diff with resync, or `/B` binary)
- **Files:** `XCOPY`/`XCOPY32` (`/S /E /I /F /L /H /R /T /U /K /N /D[:date] /A /M /P /W /C /Q /Y`, plus the "file or directory?" question and "Cannot perform a cyclic copy"), `MOVE`, `DELTREE`, `ATTRIB` (the real NTFS read-only, hidden, system and archive bits, the same four it flipped in 1998)
- **Drives:** `SUBST`, `LABEL` (stored in an NTFS alternate data stream, so it sticks), `CHKDSK` (looks but never touches)
- **Shell:** `DOSKEY` (history, editing, F7/F8, macros with `$1-$9 $* $T`), `CHOICE` (`/C /N /S /T`), `COMMAND` (a nested interpreter; `EXIT` comes back), `START` (the real `start`, for files, folders, programs and URLs), `EDIT` (`%EDITOR%`, then the new MS-DOS-style `edit`, then Notepad)
- **Full-screen:** `QBASIC` (the interpreter and the blue IDE; F5 runs the buffer, `QBASIC /RUN file` runs without the editor, three original sample programs are built in), `DEBUG` (the classic `-` prompt: `N`, `L`, `D`, `E`, `A`, `U`, `R`, `W`, `Q`; `W` asks before it writes), `DEFRAG` (the coloured block show; it never opens a file), `SCANDISK` (blue progress, read-only by construction, and it never claims to fix anything)
- **Colour:** `COLOR 1F` sets white on blue using the DOS attribute byte. ANSI.SYS is live, so `PROMPT $e[1;31m$p$g` works; `CONFIG.SYS` can say `DEVICE=...\ANSI.SYS` for old times' sake.
- **System:** `MEM` (the classic table, with your real RAM as XMS), `MODE CON COLS= LINES=` (actually resizes the terminal), `KEYB`, `NLSFUNC` (after which `CHCP 850` works)
- **Retired with dignity:** `FORMAT` asks if you're sure and then refuses. `FDISK`, `SYS`, `DISKCOPY`, `EMM386`, `SMARTDRV` and `SETVER` explain themselves. `WIN` starts Explorer. On Windows. Finally. `BSOD` shows the blue failure page on demand.
- **`NT command`** hands the whole line to the real `cmd.exe`, so `NT dir /s`, `NT ver` and `NT ipconfig /all` get the modern versions. A DOS utility name never falls through to the Windows tool of the same name.

## Startup files

`C:\CONFIG.SYS` is parsed at launch. `FILES=`, `BUFFERS=`, `BUFFERSHIGH=`, `FCBS=`, `LASTDRIVE=`, `STACKS=`, `SHELL=`, `COUNTRY=`, `DOS=`, `BREAK=`, `DEVICE=`, `DEVICEHIGH=`, `INSTALL=` and `SET` are acknowledged and remembered; nothing pretends to allocate conventional memory or load a driver. A `DEVICE=` naming `ANSI.SYS` turns the escape parser on. The file is silent, the way a real one was.

`C:\MSDOS.SYS` is optional. Put `[Options]` and `BootGUI=1` in it to get the `Starting Windows 98...` splash at launch. If `C:\WINDOWS\WIN.COM` is missing, the splash is followed by the failure path; otherwise the prompt comes up as usual. No file means no splash.

## Faithful quirks, on purpose

- `ECHO OFF` at the prompt hides the prompt.
- `echo 50% off` prints `50% off` at the prompt; inside a batch file the lone `%` is eaten, so it prints `50 off`.
- `echo %%` prints `%`, and `echo %NOSUCHVAR%` prints `ECHO is on` because the pair is substituted with nothing.
- `IF EXIST` is false for directories, so use `IF EXIST DIR\NUL`.
- `FOR` hands out 8.3 names unless you run `LFNFOR ON`.
- `CHCP 850` says `NLSFUNC not installed`.
- `CD D:\X` changes D's directory but doesn't switch drives.
- `cd...` goes up two levels.
- `REM > file` creates an empty file.
- `COPY *.TXT ALL.TXT` concatenates the files.
- `COPY CON` reads until ^Z.
- `BSOD` is a hidden internal command, not one of the original 40. The screen and every word on it are ours; `WIN` still needs `WIN.COM`, like 1998.

## License

MIT. See [LICENSE](LICENSE).
