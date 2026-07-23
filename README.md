# Claude Maxx

A macOS menu bar daemon that surfaces short-form content (or reading material) only while a
Claude Code prompt is running, offers the user a per-prompt choice, and removes the content the
instant the agent finishes or needs input.

The agent's lifecycle bounds the scroll.

## Status

Early scaffold. See `SPEC.md` for the full technical architecture and build plan.

## Development

```bash
swift build
swift run
```
