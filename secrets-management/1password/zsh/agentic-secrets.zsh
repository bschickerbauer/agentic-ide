# agentic-secrets.zsh — 1Password-backed secrets for agentic CLIs (zsh).
#
# Source this file from ~/.zshrc (install.sh does that). Requires the 1Password CLI (`op`)
# with desktop-app integration (macOS: 1Password > Settings > Developer > Integrate with
# 1Password CLI). The desktop app must be RUNNING, not just installed: with the app integration,
# op resolves every reference through the app and has no session of its own. If the app is not
# running, op cannot connect, secrets-load fails, and the wrapped command starts without secrets.
# Works in zsh on macOS and WSL2 (on WSL2 the Windows app is the one that must be running).
#
# Files (override by exporting before this file is sourced):
#   AGENTIC_CONFIG_FILE   non-secret config, sourced at every shell start  (~/.config/agentic/config.env)
#   AGENTIC_SECRETS_FILE  KEY=op://vault/item/field references, no secrets (~/.config/agentic/secrets.env)
#
# Modes:
#   lazy (default)  the first call of a wrapped command (AGENTIC_WRAP_COMMANDS, default "claude")
#                   resolves all secrets into this shell, then runs the real binary.
#   eager           AGENTIC_SECRETS_AUTOLOAD=1 resolves them at interactive shell start.
#   isolated        secrets-run <cmd> injects secrets into that process only.
#
# Functions: secrets-load [-f]  secrets-unload  secrets-status  secrets-run <cmd...>  secrets-edit  secrets-names

: ${AGENTIC_HOME:=$HOME/.config/agentic}
: ${AGENTIC_CONFIG_FILE:=$AGENTIC_HOME/config.env}
: ${AGENTIC_SECRETS_FILE:=$AGENTIC_HOME/secrets.env}
: ${AGENTIC_WRAP_COMMANDS:=claude}

# 1. Non-secret configuration: cheap, no op call, safe for non-interactive shells.
[[ -r $AGENTIC_CONFIG_FILE ]] && source "$AGENTIC_CONFIG_FILE"

# Variable names managed by the secrets file (used by unload/status).
# No leading underscore anywhere in this file: Claude Code's shell snapshot omits functions whose
# name starts with "_", and the wrappers below must keep working inside its Bash tool.
secrets-names() {
  [[ -r $AGENTIC_SECRETS_FILE ]] || return 1
  sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*$/\2/p' "$AGENTIC_SECRETS_FILE"
}

# Resolve every op:// reference with ONE op call and export the results into this shell.
secrets-load() {
  [[ -n $AGENTIC_SECRETS_LOADED && $1 != -f ]] && return 0
  if ! command -v op >/dev/null 2>&1; then
    print -u2 "secrets-load: 1Password CLI (op) not found"; return 1
  fi
  if [[ ! -r $AGENTIC_SECRETS_FILE ]]; then
    print -u2 "secrets-load: $AGENTIC_SECRETS_FILE not found"; return 1
  fi
  local resolved err hint
  if ! resolved="$(op inject -i "$AGENTIC_SECRETS_FILE" 2>"${TMPDIR:-/tmp}/agentic-op-err.$$")"; then
    err=$(head -n1 "${TMPDIR:-/tmp}/agentic-op-err.$$" 2>/dev/null); rm -f "${TMPDIR:-/tmp}/agentic-op-err.$$"
    # When the desktop app is not running, op reports "couldn't connect to the 1Password desktop
    # app" and suggests updating the app, which is misleading. Name the real cause and the way out.
    if [[ $err == *connect*"desktop app"* ]]; then
      hint="the 1Password desktop app is not running. Start it"
      [[ $OSTYPE == darwin* ]] && hint+=" (open -a 1Password)"
      hint+=", approve the CLI prompt it shows, then rerun the command or secrets-load"
    else
      hint="1Password locked, desktop app not running, CLI integration off, or bad reference"
    fi
    print -u2 "secrets-load: op inject failed: $hint${err:+ [$err]}"
    return 1
  fi
  rm -f "${TMPDIR:-/tmp}/agentic-op-err.$$"
  local line key val rc=0
  while IFS= read -r line; do
    [[ -z ${line//[[:space:]]/} || ${line//[[:space:]]/} == \#* ]] && continue
    line=${line#export }
    key=${line%%=*}; val=${line#*=}
    [[ $key == [A-Za-z_]* ]] || continue
    # strip one pair of surrounding quotes (references with spaces must be quoted in the file)
    [[ $val == \"*\" || $val == \'*\' ]] && val=${val:1:-1}
    if [[ $val == op://* ]]; then
      print -u2 "secrets-load: unresolved reference for $key"; rc=1; continue
    fi
    export "$key=$val"
  done <<< "$resolved"
  export AGENTIC_SECRETS_LOADED=1
  return $rc
}

# Remove every managed variable from this shell.
secrets-unload() {
  local k
  for k in ${(f)"$(secrets-names)"}; do unset "$k"; done
  unset AGENTIC_SECRETS_LOADED
}

# Show which managed variables are set. Prints lengths, never values.
secrets-status() {
  local k v
  print "config : $AGENTIC_CONFIG_FILE  ($([[ -r $AGENTIC_CONFIG_FILE ]] && print ok || print missing))"
  print "secrets: $AGENTIC_SECRETS_FILE  ($([[ -n $AGENTIC_SECRETS_LOADED ]] && print loaded || print 'not loaded'))"
  print "op     : $(command -v op >/dev/null 2>&1 && op --version || print 'not installed')"
  for k in ${(f)"$(secrets-names)"}; do
    v=${(P)k}
    if [[ -n $v ]]; then printf '  %-32s set (%d chars)\n' "$k" ${#v}
    else printf '  %-32s unset\n' "$k"; fi
  done
}

# Run a command with secrets injected into that process only. Nothing is exported here.
# --no-masking keeps the child's stdout/stderr on the TTY (needed for interactive TUIs).
secrets-run() {
  op run --env-file "$AGENTIC_SECRETS_FILE" --no-masking -- "$@"
}

secrets-edit() { "${EDITOR:-vi}" "$AGENTIC_SECRETS_FILE"; }

# 2. Lazy wrappers: load on first use, then run the real binary. Skipped inside Claude Code's
#    own Bash tool (CLAUDECODE is set there and the environment is already inherited). Each
#    wrapper is self-contained so it still works when only the wrapper itself was snapshotted.
for agentic_cmd in ${=AGENTIC_WRAP_COMMANDS}; do
  eval "${agentic_cmd}() {
    if [[ -z \$AGENTIC_SECRETS_LOADED && -z \$CLAUDECODE ]]; then
      secrets-load || print -u2 \"${agentic_cmd}: starting without 1Password secrets\"
    fi
    command ${agentic_cmd} \"\$@\"
  }"
done
unset agentic_cmd

# 3. Eager mode: opt in, interactive shells only, never inside Claude Code, never blocking on error.
if [[ -n $AGENTIC_SECRETS_AUTOLOAD && -o interactive && -z $CLAUDECODE ]]; then
  secrets-load 2>/dev/null || true
fi
