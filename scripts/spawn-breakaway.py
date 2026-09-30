"""Spawn a command so it ESCAPES this process's Windows job object.

STATUS -- CONFIRMED REFUSED ON THIS HOST (kept as documentation)
=================================================================
This was the first attempt at making the daemon survive its supervisor, and it
does not work here. `CreateProcess` with `CREATE_BREAKAWAY_FROM_JOB` fails with

    BREAKAWAY-FAILED [WinError 5] 拒绝访问 (winerror=5)

because the harness's background job does not set
`JOB_OBJECT_LIMIT_BREAKAWAY_OK`, and a flag the job forbids is not a flag you
can pass. A plain child -- however "detached" -- is still a job member and is
killed the instant the job is torn down.

The path that DOES work is spawning from a process outside the job: the WMI
provider runs in a service host (WmiPrvSE.exe), so `Win32_Process.Create`
produces a process that is not a job member. See `Spawn-OutsideJob` in
`keep-stack3.ps1`. Let this file stand as a record of the dead end.

Original rationale
------------------
A background job is torn down by killing every process in its job object, and
Windows has no other way out for an ordinary child: `detached`/`DETACHED_PROCESS`
only detaches the console, not the job. The one flag that does escape is
CREATE_BREAKAWAY_FROM_JOB -- and it only works if the job allows breakaway
(JOB_OBJECT_LIMIT_BREAKAWAY_OK). If the job forbids it, CreateProcess fails with
ERROR_ACCESS_DENIED (5) and this script reports that instead of pretending.

Usage:  python spawn-breakaway.py <logfile> <command> [args...]
"""
import subprocess
import sys

DETACHED_PROCESS = 0x00000008
CREATE_NEW_PROCESS_GROUP = 0x00000200
CREATE_BREAKAWAY_FROM_JOB = 0x01000000

logpath = sys.argv[1]
cmd = sys.argv[2:]
flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_BREAKAWAY_FROM_JOB

log = open(logpath, "ab", buffering=0)
try:
    p = subprocess.Popen(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=log,
        creationflags=flags,
        close_fds=True,
    )
    print("BREAKAWAY-OK pid=%d cmd=%s" % (p.pid, " ".join(cmd)))
except OSError as e:
    print("BREAKAWAY-FAILED %s (winerror=%s) cmd=%s"
          % (e, getattr(e, "winerror", "?"), " ".join(cmd)))
    sys.exit(2)
