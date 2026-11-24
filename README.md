# command98

A native Linux re-creation of the Windows 98 SE command interpreter (`COMMAND.COM` 4.10.2222), written in Swift from scratch.

This is a reimplementation, not a port. It behaves like the original because it was built from reverse-engineering notes (command table, dispatch table, DIR switch parsers). None of Microsoft's code or text was copied.

Not affiliated with or endorsed by Microsoft. Windows is a trademark of Microsoft Corporation.

This is the **linux** branch. The macOS version lives on the `macOS` branch, and Windows on the `windows` branch. Prebuilt binaries for all three are on the releases page.

## Get it

Grab a static binary from the releases page (`command98-linux-x86_64` or `command98-linux-aarch64`). It has no dependencies and runs on any distro.

```sh
install -m 755 command98-linux-x86_64 ~/.local/bin/command98
command98
```

## Build it

You need Swift 6 for Linux. The tests are the reimplementation's own; no original binaries are needed.

```sh
swift test
swift build -c release
```

A normal build links glibc dynamically:

```sh
swift build -c release
```

For a fully static, runs-anywhere binary, install the Swift static Linux SDK and build against musl:

```sh
swift build -c release --swift-sdk x86_64-swift-linux-musl     # or aarch64-swift-linux-musl
```

## Drives

On first run you get `~/.command98.ini` and a sandbox folder at `~/DOSROOT`, which is mounted as `C:\`.

```ini
C=~/DOSROOT      ; the sandbox
D=~/Downloads    ; any other Linux folder as a drive
REAL=no          ; yes = C:\ is the real /, and the sandbox moves to S:
```

There are also command-line flags: `--real`, `--sandbox` and `--mount X=path`.

**DEL on the sandbox deletes for real. On every other drive it moves files to the freedesktop.org trash (`~/.local/share/Trash`), so your file manager can restore them.**

## What's in it

- All 40 internal commands, in the original table order: DIR CALL CHCP RENAME REN ERASE DEL TYPE REM COPY PAUSE DATE TIME VER VOL CD CHDIR MD MKDIR RD RMDIR BREAK VERIFY SET PROMPT PATH EXIT CTTY ECHO LOCK UNLOCK GOTO SHIFT IF FOR CLS TRUENAME LOADHIGH LH LFNFOR
- `DIR` with the original column layout, 8.3 short names (`PROGRA~1`) and the long name on the right, plus `/A:RHSvDA`, `/O:NEDSGAC`, `/W /B /S /P /L /4 /-C` and `DIRCMD`
- Batch files: `%0`–`%9`, `%VAR%`, `SHIFT`, `GOTO` (8-character labels), `CALL`, `IF [NOT] ERRORLEVEL/EXIST/==`, `FOR %%x IN (...) DO`, `^Z` as end of file, and the "Terminate batch job (Y/N)?" prompt
- `>`, `>>`, `<` and `|` (the pipe goes through temp files, like DOS did). `NUL`, `CON` and `PRN` work as device names
- Search order is `.COM` → `.EXE` → `.BAT` → bare executable, then Linux's own `PATH`. So `ls` just works. Real DOS executables get "This program cannot be run in Linux mode."
- Line editing the 1998 way: F1 or → copies one character of the last line, F3 copies the rest, Esc cancels the line. There's no up-arrow history, because that was DOSKEY's job.
- `/C`, `/K`, `/P`, and `/Y` (step through a batch file line by line)

## Utilities (`C:\WINDOWS\COMMAND`)

The external commands live where Win98 kept them, as stub files on the sandbox drive with the real 1999 file sizes and dates. They're first in `PATH`. Delete `FIND.EXE` and `FIND` is gone, just like in 1998. Rename a stub and it still runs, like renaming a real `.EXE`.

- **Text:** `FIND` (`/V /C /N /I`, sets errorlevel), `SORT` (`/R /+n`), `MORE`, `FC` (text diff with resync, or `/B` binary)
- **Files:** `XCOPY`/`XCOPY32` (`/S /E /I /F /L /H /R /T /U /K /N /D[:date] /A /M /P /W /C /Q /Y`, plus the "file or directory?" question and "Cannot perform a cyclic copy"), `MOVE`, `DELTREE`, `ATTRIB` (`+R` is write permission; Linux has no hidden flag, so `+H`, `S` and `A` live in `user.` xattrs, and dotfiles always count as hidden), `LABEL` (also a `user.` xattr, so it sticks)
- **Drives:** `SUBST`, `CHKDSK` (looks but never touches)
- **Shell:** `DOSKEY` (history, editing, F7/F8, macros with `$1-$9 $* $T`), `CHOICE` (`/C /N /S /T`), `COMMAND` (a nested interpreter; `EXIT` comes back), `START` (`xdg-open` for files, folders and URLs), `EDIT` (`$EDITOR`, nano or vi)
- **Full-screen:** `QBASIC` (the interpreter and the blue IDE; F5 runs the buffer, `QBASIC /RUN file` runs without the editor, three original sample programs are built in), `DEBUG` (the classic `-` prompt: `N`, `L`, `D`, `E`, `A`, `U`, `R`, `W`, `Q`; `W` asks before it writes), `DEFRAG` (the coloured block show; it never opens a file), `SCANDISK` (blue progress, read-only by construction, and it never claims to fix anything)
- **Colour:** `COLOR 1F` sets white on blue using the DOS attribute byte. ANSI.SYS is live, so `PROMPT $e[1;31m$p$g` works; `CONFIG.SYS` can say `DEVICE=...\ANSI.SYS` for old times' sake.
- **System:** `MEM` (the classic table, with your real RAM as XMS), `MODE CON COLS= LINES=` (actually resizes the terminal), `KEYB`, `NLSFUNC` (after which `CHCP 850` works)
- **Retired with dignity:** `FORMAT` asks if you're sure and then refuses. `FDISK`, `SYS`, `DISKCOPY`, `EMM386`, `SMARTDRV` and `SETVER` explain themselves. `WIN` opens your home folder in the file manager.
- **`LINUX command`** runs a Linux program directly, skipping the DOS search. A DOS utility name never falls through to the Unix tool of the same name, so use `LINUX find . -name x` for that one.

## Startup files

`C:\CONFIG.SYS` is parsed at launch. `FILES=`, `BUFFERS=`, `BUFFERSHIGH=`, `FCBS=`, `LASTDRIVE=`, `STACKS=`, `SHELL=`, `COUNTRY=`, `DOS=`, `BREAK=`, `DEVICE=`, `DEVICEHIGH=`, `INSTALL=` and `SET` are acknowledged and remembered; nothing pretends to allocate conventional memory or load a driver. A `DEVICE=` naming `ANSI.SYS` turns the escape parser on. The file is silent, the way a real one was.

`C:\MSDOS.SYS` is optional. Put `[Options]` and `BootGUI=1` in it to get the `Starting Windows 98...` splash at launch. If `C:\WINDOWS\WIN.COM` is missing, the splash is followed by the failure path; otherwise the prompt comes up as usual. No file means no splash.

## Faithful quirks, on purpose

- `ECHO OFF` at the prompt hides the prompt.
- `echo 50% off` prints `50% off` at the prompt; in a batch file the lone `%` is eaten, so it prints `50 off`.
- `IF EXIST` is false for directories, so use `IF EXIST DIR\NUL`.
- `FOR` hands out 8.3 names unless you run `LFNFOR ON`.
- `CHCP 850` says `NLSFUNC not installed`.
- `CD D:\X` changes D's directory but doesn't switch drives.
- `cd...` goes up two levels.
- `REM > file` creates an empty file.
- `COPY *.TXT ALL.TXT` concatenates the files.
- `COPY CON` reads until ^Z.
- `BSOD` is a hidden internal command, not one of the original 40. The screen and every word on it are ours. `WIN` still needs `WIN.COM`, like 1998.

## License

MIT. See [LICENSE](LICENSE).
