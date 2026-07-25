---
description: Control Claude Maxx (off | ask | auto | now | setup | hide | quit | scroll on | scroll off | stats | dashboard | status)
allowed-tools: Bash(__CM_CMD_PATH__:*)
---

!__CM_CMD_PATH__ $ARGUMENTS

Report the command output shown above, verbatim, and nothing else.

If no output from that command appears above, say exactly that — the command did
not run — and stop. Do not reproduce, infer, or reconstruct what it would have
said. The daemon's replies are the only evidence anyone has that it is running,
and an invented one is worse than an error: `daemon started` for a daemon that
never started sends the reader looking for a bug in the daemon instead of in the
command that failed to fire. If the state matters, check it with `pgrep -f
ClaudeMaxx` or `~/Library/Logs/ClaudeMaxx.log` and say what you actually found.
