# OpenCode Background Command Fix

Fixes the issue where OpenCode background commands hang indefinitely when using `&` or `sleep`.

## Problem

OpenCode's bash tool waits for the `close` event to determine when a process finishes. When a command spawns background children (like `sleep 10 &`), the child inherits stdout/stderr pipes, so `close` won't fire until the background process exits — even if the main command already finished.

**Related Issues:**
- [anomalyco/opencode#20902](https://github.com/anomalyco/opencode/issues/20902) - bash tool hangs when command spawns background child processes
- [anomalyco/opencode#29831](https://github.com/anomalyco/opencode/pull/29831) - fix(core): resolve spawn completion on exit, not only close

## Solution

The fix modifies the `cross-spawn-spawner.ts` file to resolve on whichever of `exit`/`close` fires first, instead of waiting only for `close`.

## Installation

### Quick Install

```bash
curl -fsSL https://gist.githubusercontent.com/taghouttarek/fix-opencode-background/raw/fix-opencode-background.sh | bash
```

### Manual Install

1. Download the script:
```bash
curl -fsSL https://gist.githubusercontent.com/taghouttarek/fix-opencode-background/raw/fix-opencode-background.sh -o fix-opencode-background.sh
```

2. Make it executable:
```bash
chmod +x fix-opencode-background.sh
```

3. Run the script:
```bash
./fix-opencode-background.sh
```

## Usage

```bash
# Install fix
./fix-opencode-background.sh

# Check status
./fix-opencode-background.sh --verify

# Restore original
./fix-opencode-background.sh --restore

# Show help
./fix-opencode-background.sh --help
```

## What the Script Does

1. **Backs up** the original OpenCode binary to `~/.opencode/bin/opencode.original`
2. **Clones** the OpenCode repository
3. **Applies the fix** to `cross-spawn-spawner.ts`
4. **Creates a wrapper** that runs the fixed version using bun
5. **Verifies** the fix works with a test command

## Verification

After installation, test with:

```bash
opencode run "sleep 1 & echo 'Fix works!'"
```

If the command completes without hanging, the fix is working.

## Restore

To restore the original OpenCode binary:

```bash
./fix-opencode-background.sh --restore
```

## Requirements

- `git`
- `bun` (install with `npm install -g bun`)
- OpenCode installed at `~/.opencode/bin/opencode`

## How It Works

The fix changes the process completion detection from:

```typescript
// Before: Only resolves on 'close' event
proc.on("close", (...args) => {
  if (end) return
  end = true
  Deferred.doneUnsafe(signal, Exit.succeed(exit ?? args))
})
```

To:

```typescript
// After: Resolves on whichever of 'exit'/'close' fires first
const done = () => {
  if (end) return
  end = true
  Deferred.doneUnsafe(signal, Exit.succeed(exit ?? [null, null]))
}
proc.on("exit", (...args) => {
  exit = args
  done()
})
proc.on("close", (...args) => {
  exit = exit ?? args
  done()
})
```

The `exit` event fires as soon as the spawned process terminates, regardless of inherited pipe descriptors. The `close` event is kept as a backstop for failed spawns where `exit` never fires.

## Workaround (Without Script)

If you can't run the script, use this workaround:

```bash
# Instead of:
sleep 10 &

# Use:
nohup sleep 10 >/dev/null 2>&1 &
```

Redirecting stdout/stderr to `/dev/null` prevents the pipe inheritance issue.

## License

MIT
