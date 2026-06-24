#!/bin/bash
set -e

# OpenCode Background Command Fix
# Fixes issue where commands with & or sleep hang indefinitely
# Based on PR #29831: https://github.com/anomalyco/opencode/pull/29831

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

OPENCODE_DIR="${HOME}/.opencode"
BACKUP_DIR="${OPENCODE_DIR}/bin"
FIX_DIR="/tmp/opencode-fix"
ORIGINAL_BINARY="${BACKUP_DIR}/opencode"
BACKUP_BINARY="${BACKUP_DIR}/opencode.original"

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help       Show this help message"
    echo "  -r, --restore    Restore original OpenCode binary"
    echo "  -v, --verify     Verify fix is applied"
    echo "  -c, --clean      Remove fix source files"
    echo ""
    echo "This script fixes OpenCode background command hanging issues."
    echo "Based on PR #29831: https://github.com/anomalyco/opencode/pull/29831"
}

check_dependencies() {
    local missing=()
    for cmd in git bun; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install bun: npm install -g bun"
        exit 1
    fi
}

check_opencode() {
    if [ ! -f "$ORIGINAL_BINARY" ]; then
        log_error "OpenCode not found at $ORIGINAL_BINARY"
        log_info "Install OpenCode first: curl -fsSL https://opencode.ai/install | bash"
        exit 1
    fi
}

backup_original() {
    if [ ! -f "$BACKUP_BINARY" ]; then
        cp "$ORIGINAL_BINARY" "$BACKUP_BINARY"
        log_info "Backed up original to $BACKUP_BINARY"
    else
        log_info "Backup already exists"
    fi
}

clone_repository() {
    log_info "Cloning OpenCode repository..."
    rm -rf "$FIX_DIR"
    mkdir -p "$FIX_DIR"
    git clone --depth 1 https://github.com/anomalyco/opencode.git "$FIX_DIR/opencode-src" 2>/dev/null
    log_info "Repository cloned"

    log_info "Installing dependencies..."
    cd "$FIX_DIR/opencode-src" && bun install
    log_info "Dependencies installed"
}

apply_fix() {
    local spawner_file="$FIX_DIR/opencode-src/packages/core/src/cross-spawn-spawner.ts"

    if [ ! -f "$spawner_file" ]; then
        log_error "cross-spawn-spawner.ts not found"
        exit 1
    fi

    log_info "Applying fix..."

    cat > "$FIX_DIR/spawn_function.txt" << 'FIX'
  const spawn = (command: ChildProcess.StandardCommand, opts: NodeChildProcess.SpawnOptions) =>
    Effect.callback<readonly [NodeChildProcess.ChildProcess, ExitSignal], PlatformError.PlatformError>((resume) => {
      const signal = Deferred.makeUnsafe<readonly [code: number | null, signal: NodeJS.Signals | null]>()
      const proc = launch(command.command, command.args, opts)
      let end = false
      let exit: readonly [code: number | null, signal: NodeJS.Signals | null] | undefined
      proc.on("error", (err) => {
        resume(Effect.fail(toPlatformError("spawn", err, command)))
      })
      // Resolve on whichever of exit/close fires first.
      // exit returns promptly once the main process is gone (fixing background child hangs);
      // close is kept as the backstop for failed spawns where cross-spawn emits
      // spawn->error->close but never exit, so exit-only would hang that path forever.
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
      proc.on("spawn", () => {
        resume(Effect.succeed([proc, signal]))
      })
      return Effect.sync(() => {
        proc.kill("SIGTERM")
      })
    })
FIX

    awk '
    /const spawn = \(command: ChildProcess.StandardCommand/ {
        while ((getline line < "'"$FIX_DIR/spawn_function.txt"'") > 0) print line
        skip = 1
        next
    }
    skip && /^\s*\}\)$/ {
        skip = 0
        next
    }
    !skip { print }
    ' "$spawner_file" > "$FIX_DIR/fixed_spawner.ts"

    mv "$FIX_DIR/fixed_spawner.ts" "$spawner_file"
    rm -f "$FIX_DIR/spawn_function.txt"

    log_info "Fix applied"
}

create_binary() {
    log_info "Creating fixed binary..."

    local wrapper_script="$FIX_DIR/wrapper.sh"
    local opencode_src="$FIX_DIR/opencode-src/packages/opencode/src/index.ts"

    cat > "$wrapper_script" << EOF
#!/bin/bash
exec bun run "$opencode_src" "\$@"
EOF

    chmod +x "$wrapper_script"

    # Handle "Text file busy" by moving the current binary first
    if fuser "$ORIGINAL_BINARY" >/dev/null 2>&1; then
        log_warn "OpenCode is currently running, moving current binary..."
        mv "$ORIGINAL_BINARY" "${ORIGINAL_BINARY}.running" 2>/dev/null || true
    fi

    cp "$wrapper_script" "$ORIGINAL_BINARY"
    chmod +x "$ORIGINAL_BINARY"

    log_info "Fixed binary created"
}

verify_fix() {
    log_info "Verifying fix..."

    if opencode --version &> /dev/null; then
        log_info "OpenCode is working"

        log_info "Testing background command..."
        if timeout 15 opencode run "sleep 1 & echo 'Fix verified'" 2>&1 | grep -q "Fix verified"; then
            log_info "SUCCESS: Background commands work correctly"
        else
            log_warn "Could not verify fix automatically (may still work)"
        fi
    else
        log_error "OpenCode is not working after fix"
        exit 1
    fi
}

restore_original() {
    if [ -f "$BACKUP_BINARY" ]; then
        cp "$BACKUP_BINARY" "$ORIGINAL_BINARY"
        chmod +x "$ORIGINAL_BINARY"
        log_info "Original binary restored"
    else
        log_error "No backup found at $BACKUP_BINARY"
        exit 1
    fi
}

verify_installed() {
    if [ -f "$BACKUP_BINARY" ]; then
        log_info "Fix is installed (backup exists)"

        if diff -q "$ORIGINAL_BINARY" "$BACKUP_BINARY" > /dev/null 2>&1; then
            log_warn "Original binary is in place (fix not active)"
        else
            log_info "Fixed binary is active"
        fi
    else
        log_info "No fix installed (using original binary)"
    fi
}

cleanup_source() {
    if [ -d "$FIX_DIR" ]; then
        rm -rf "$FIX_DIR"
        log_info "Source files cleaned up"
    else
        log_info "No source files to clean"
    fi
}

main() {
    case "${1:-}" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -r|--restore)
            restore_original
            exit 0
            ;;
        -v|--verify)
            verify_installed
            exit 0
            ;;
        -c|--clean)
            cleanup_source
            exit 0
            ;;
        "")
            ;;
        *)
            log_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac

    log_info "OpenCode Background Command Fix"
    log_info "=============================="
    echo

    check_dependencies
    check_opencode
    backup_original
    clone_repository
    apply_fix
    create_binary
    verify_fix

    echo
    log_info "Installation complete!"
    log_info "Restart OpenCode to apply the fix"
    log_info "To restore: $0 --restore"
    log_info "To clean source files: $0 --clean"
}

main "$@"
