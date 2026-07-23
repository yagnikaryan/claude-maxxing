---
description: Control Claude Maxx (off | ask | auto | now | setup | hide | scroll on | scroll off | stats | status)
allowed-tools: Bash(curl:*)
---

!curl -sG --max-time 1 --data-urlencode "arg=$ARGUMENTS" "http://127.0.0.1:8765/cmd" || echo "daemon not running"

Reply with only the command output shown above, verbatim, and nothing else.
