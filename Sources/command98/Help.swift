extension Shell {
    static let aliases = [
        "REN": "RENAME", "XCOPY32": "XCOPY", "LINUX": "MAC", "ERASE": "DEL", "CHDIR": "CD", "MKDIR": "MD", "RMDIR": "RD", "LH": "LOADHIGH",
    ]

    static func helpText(_ name: String) -> String {
        let key = aliases[name] ?? name
        return (help[key] ?? featureHelp[key] ?? coreUtilHelp[key] ?? "No help for \(name).") + "\n"
    }

    // all wording here is our own; the switch letters match the original
    static let help: [String: String] = [
        "DIR": """
        Lists the files and folders in a directory.

        DIR [drive:][path][filename] [/P] [/W] [/A[[:]attributes]]
            [/O[[:]sortorder]] [/S] [/B] [/L] [/4] [/-C]

          /P   Pause after every screenful.
          /W   Wide listing, five names per row.
          /A   Show files with these attributes (prefix - to exclude):
               D directories   R read-only   H hidden   A archive   S system
          /O   Sort by: N name  E extension  D date  S size  A access date
               G folders first  C compression ratio (a DriveSpace fossil, ignored)
               Prefix a letter with - to reverse it.
          /S   Include every subdirectory.
          /B   Bare names, no header or totals.
          /L   Lowercase short names.
          /4   Four-digit years.
          /-C  No thousands separators.

        Defaults can live in the DIRCMD environment variable; /-X switches undo them.
        """,
        "CALL": """
        Runs one batch file from inside another, then comes back.

        CALL [drive:][path]filename [batch-parameters]
        """,
        "CHCP": """
        Shows or switches the active code page.

        CHCP [nnn]
        """,
        "RENAME": """
        Renames files. Wildcards work in both names.

        RENAME [drive:][path]filename1 filename2
        REN    [drive:][path]filename1 filename2

        The new name can't include a drive or path.
        """,
        "DEL": """
        Deletes files. Sandbox drives delete for good; other drives use \(Platform.trashName).

        DEL [drive:][path]filename [/P]
        ERASE [drive:][path]filename [/P]

          /P   Ask before each file.
        """,
        "TYPE": """
        Prints the contents of a file.

        TYPE [drive:][path]filename
        """,
        "REM": """
        A remark. Does nothing, on purpose.

        REM [comment]
        """,
        "COPY": """
        Copies files, or joins several into one.

        COPY [/A | /B] source [+ source [+ ...]] [destination] [/V] [/Y | /-Y]

          source       File(s) to copy. CON reads from the keyboard until ^Z.
          destination  Folder or filename for the result.
          /Y           Overwrite without asking.
          /-Y          Ask before overwriting.

        /Y can be preset in the COPYCMD environment variable. Inside batch files
        COPY never asks.
        """,
        "PAUSE": """
        Waits for a keypress.

        PAUSE
        """,
        "DATE": """
        Shows the date. The clock itself belongs to \(Platform.name).

        DATE [date]
        """,
        "TIME": """
        Shows the time. The clock itself belongs to \(Platform.name).

        TIME [time]
        """,
        "VER": """
        Shows the version.

        VER
        """,
        "VOL": """
        Shows a drive's label and serial number.

        VOL [drive:]
        """,
        "CD": """
        Shows or changes the current directory.

        CD [drive:][path]
        CD [..]

          ..   Up one level. ... goes up two, .... up three.

        CD drive: shows that drive's current directory without switching to it.
        """,
        "MD": """
        Creates a directory.

        MD [drive:]path
        """,
        "RD": """
        Removes an empty directory.

        RD [drive:]path
        """,
        "BREAK": """
        Shows or sets extended CTRL+C checking.

        BREAK [ON | OFF]
        """,
        "VERIFY": """
        Shows or sets write verification.

        VERIFY [ON | OFF]
        """,
        "SET": """
        Shows, sets or removes environment variables.

        SET [variable=[string]]

        With no parameters, lists every variable.
        """,
        "PROMPT": """
        Changes the prompt.

        PROMPT [text]

          $P path     $G >    $L <    $B |    $Q =    $$ $
          $N drive    $T time $D date $V version
          $_ newline  $E escape       $H backspace
        """,
        "PATH": """
        Shows or sets where programs are searched for.

        PATH [[drive:]path[;...]]
        PATH ;

        PATH ; clears it. \(Platform.name)'s own PATH is still searched as a last resort.
        """,
        "EXIT": """
        Leaves the command interpreter.

        EXIT
        """,
        "CTTY": """
        Changes the console device. Only CON is supported, for everyone's sake.

        CTTY device
        """,
        "ECHO": """
        Shows messages, or turns command echoing on or off.

        ECHO [ON | OFF]
        ECHO [message]
        ECHO.          prints an empty line
        """,
        "LOCK": """
        Locks a drive for direct disk access. Purely ceremonial on \(Platform.name).

        LOCK [drive:]
        """,
        "UNLOCK": """
        Unlocks a drive.

        UNLOCK [drive:]
        """,
        "GOTO": """
        Jumps to a :label in a batch file. Only the first 8 characters count.

        GOTO label
        """,
        "SHIFT": """
        Shifts batch parameters down by one (%1 becomes %0, and so on).

        SHIFT
        """,
        "IF": """
        Runs a command conditionally in batch files.

        IF [NOT] ERRORLEVEL number command
        IF [NOT] string1==string2 command
        IF [NOT] EXIST filename command

        EXIST is false for directories. Use dirname\\NUL to test for one.
        """,
        "FOR": """
        Runs a command for each item in a set.

        FOR %variable IN (set) DO command [parameters]

        Use %%variable inside batch files. Wildcards in the set expand to files,
        as 8.3 names unless LFNFOR is ON.
        """,
        "CLS": """
        Clears the screen.

        CLS
        """,
        "TRUENAME": """
        Shows the canonical form of a path, with links resolved.

        TRUENAME [drive:][path][filename]
        """,
        "LOADHIGH": """
        Loads a program into upper memory. Everything is upper memory now.

        LOADHIGH [/L:region] [/S] [drive:][path]filename [parameters]
        LH       [/L:region] [/S] [drive:][path]filename [parameters]
        """,
        "LFNFOR": """
        Turns long filenames in FOR on or off.

        LFNFOR [ON | OFF]
        """,
    ]

    // the \\WINDOWS\\COMMAND utilities. wording is ours, switches match the 1999 originals
    static let coreUtilHelp: [String: String] = [
        "ATTRIB": """
        Shows or changes file attributes.

        ATTRIB [+R | -R] [+A | -A] [+S | -S] [+H | -H] [[drive:][path]filename] [/S]

          +  Set.   -  Clear.
          R  Read-only (write permission)    H  Hidden (dotfiles always are)
          A  Archive                         S  System
          /S Include every subdirectory.

        Hidden and system files are left alone unless you mention H or S.
        """,
        "CHKDSK": """
        Reports on a drive: space, files, directories. It never fixes anything.

        CHKDSK [drive:]
        """,
        "CHOICE": """
        Waits for one keypress out of a set, for batch files.

        CHOICE [/C[:]keys] [/N] [/S] [/T[:]c,nn] [text]

          /C[:]keys  Allowed keys (default YN).
          /N         Don't show the [Y,N]? part.
          /S         Keys are case sensitive.
          /T[:]c,nn  Pick c after nn seconds.

        ERRORLEVEL becomes the position of the key pressed, starting at 1.
        """,
        "DELTREE": """
        Deletes a directory and everything inside it.

        DELTREE [/Y] [drive:]path [[drive:]path ...]

          /Y  Don't ask first.

        Sandbox drives delete for good; other drives use \(Platform.trashName).
        """,
        "DISKCOPY": "Copied floppy disks. There are no floppy disks.",
        "DOSKEY": """
        Adds command history, line editing and macros to the prompt.

        DOSKEY [/REINSTALL] [/M] [/H] [/INSERT | /OVERSTRIKE] [macro=[text]]

          /M  List macros.      /H  List history.
          Up/Down  recall       PgUp/PgDn  oldest/newest     F7  numbered list
          F8  search history for what's left of the cursor     Esc  clear line
          Insert  toggle overstrike                           Home/End/Del
          In macros: $1-$9 arguments, $* everything, $T next command,
                     $G > $L < $B | $$ $
        """,
        "EDIT": """
        Opens a file in a text editor ($VISUAL, $EDITOR, nano or vi, whichever turns up first).

        EDIT [[drive:][path]filename]
        """,
        "EMM386": "Turned conventional memory into more memory. Not needed with 16 GB of it.",
        "FC": """
        Compares two files and shows the differences.

        FC [/A] [/C] [/L] [/LBn] [/N] [/W] [/nnnn] file1 file2
        FC /B file1 file2

          /A     Only the first and last line of each difference.
          /B     Byte-by-byte comparison (the default for .EXE .COM .SYS .OBJ .LIB .BIN).
          /C     Ignore case.            /L    Compare as text.
          /LBn   Give up after n differing lines in a row (default 100).
          /N     Show line numbers.      /W    Squeeze runs of spaces and tabs.
          /nnnn  Lines that must match again before a difference ends (default 2).
        """,
        "FDISK": "Partitioned hard disks. Not from in here.",
        "FIND": """
        Looks for a string in files, or in whatever is piped in.

        FIND [/V] [/C] [/N] [/I] "string" [[drive:][path]filename ...]

          /V  Lines that DON'T contain the string.
          /C  Just count the lines.
          /N  Show line numbers.
          /I  Ignore case.

        The string has to be in double quotes. ERRORLEVEL is 0 if something was
        found, 1 if not.
        """,
        "FORMAT": "Formatted disks. Now it just asks if you're sure, then says no.",
        "KEYB": """
        Shows or sets the keyboard code. \(Platform.name) does the real work.

        KEYB [xx]
        """,
        "LABEL": """
        Creates, changes or removes a drive's volume label.

        LABEL [drive:][label]
        """,
        "MAC": """
        Runs a \(Platform.name) program from the host PATH, skipping the DOS search.

        \(Platform.hostUtility) command [arguments]

        Handy when a DOS utility has the same name: \(Platform.hostUtility) find . -name "*.txt"
        """,
        "MEM": """
        Shows memory use, in the classic layout.

        MEM [/C | /D]

          /C  Also list the modules loaded below 1 MB.
        """,
        "MODE": """
        Shows or changes the console size.

        MODE [CON]
        MODE CON [COLS=c] [LINES=n]
        MODE 40 | 80 | CO80 | BW80 | MONO
        """,
        "MORE": """
        Shows text one screen at a time.

        MORE [drive:][path]filename
        MORE < [drive:][path]filename
        command | MORE
        """,
        "MOVE": """
        Moves files, or renames a directory.

        MOVE [/Y | /-Y] [drive:][path]filename1[,...] destination
        MOVE [/Y | /-Y] [drive:][path]dirname1 dirname2

          /Y   Overwrite without asking.      /-Y  Ask first.
        """,
        "NLSFUNC": "Loads national language support, which is what CHCP was waiting for.",
        "SCANDISK": "Checked FAT disks. On Linux, use fsck to fix a disk.",
        "SETVER": "Told old programs a different DOS version. Nobody asks anymore.",
        "SMARTDRV": "Was a disk cache. \(Platform.name) is one now.",
        "SORT": """
        Sorts lines of text, ignoring case.

        SORT [/R] [/+n] [[drive:][path]filename]
        command | SORT [/R] [/+n]

          /R   Reverse order.
          /+n  Sort starting at column n.
        """,
        "START": """
        Opens a file, folder, program or URL the way the desktop would.

        START [/W] [/M] [/MAX] [/R] target [arguments]

          /W  Wait until it closes.     /M  Open in the background.
        """,
        "SUBST": """
        Makes a drive letter that points at a folder.

        SUBST [drive1: [drive2:]path]
        SUBST drive1: /D

        SUBST with no parameters lists the current ones.
        """,
        "SYS": "Copied DOS onto a disk to make it bootable. \(Platform.name) boots itself.",
        "XCOPY": """
        Copies files and whole directory trees.

        XCOPY source [destination] [/A | /M] [/D[:date]] [/P] [/S [/E]] [/W] [/C] [/I]
              [/Q] [/F] [/L] [/H] [/R] [/T] [/U] [/K] [/N] [/Y | /-Y]

          /A  Only files with the archive bit; leave it.   /M  Same, but clear it.
          /D  Only files changed on/after date (or newer than the destination).
          /P  Ask about each file.       /S  Subdirectories too.  /E  Even empty ones.
          /W  Wait for a key first.      /C  Keep going after errors.
          /I  Assume the destination is a directory.
          /Q  Quiet.   /F  Show source and destination.   /L  Only list.
          /H  Include hidden and system files.   /R  Overwrite read-only files.
          /T  Copy the folder structure only.    /U  Only files that exist at the destination.
          /K  Keep attributes.           /N  Use short names.
        """,
        "COMMAND": """
        Starts a fresh copy of the command interpreter. EXIT comes back here.

        COMMAND [/P] [/Y] [/C command | /K command]
        """,
        "WIN": "Starts Windows. Here, that means the file manager.",
    ]
}
