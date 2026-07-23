---
description: Control Claude Maxx (off | ask | auto | now | setup | scroll on | scroll off | stats | status)
allowed-tools: Bash(curl:*)
---

!curl -s --max-time 1 "http://127.0.0.1:8765/cmd?arg=$ARGUMENTS" || echo "daemon not running"

Reply with only the command output shown above, verbatim, and nothing else.
