#!/bin/bash
#
# Kadr — reset a Mac to "Kadr was never here", for reproducing first-run bugs
# (docs/17 T-DIAG-4, smoke script step 1 in docs/12 §0).
#
# Removes Kadr's settings, its Application Support folder (History, studio sessions,
# diagnostics), caches and saved window state for both the agent and the editor; resets
# every privacy grant Kadr can hold; removes the `kadr` command-line link; and puts
# Finder's desktop icons back if a crash left them hidden.
#
# The app itself stays unless --remove-app is passed, because the usual next step is to
# launch it again and walk through onboarding.
#
# Nothing here needs sudo. `tccutil reset` for a single bundle ID works as the user.
#
# Usage:
#   Scripts/uninstall.sh [--yes] [--remove-app]
set -euo pipefail

AGENT_ID="com.bohdanbodnarenko.kadr"
EDITOR_ID="com.bohdanbodnarenko.kadr.Editor"
APP_PATH="/Applications/Kadr.app"

assume_yes=0
remove_app=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y) assume_yes=1 ;;
        --remove-app) remove_app=1 ;;
        --keep-app) remove_app=0 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

say() { printf '• %s\n' "$1"; }

if [ "$assume_yes" -eq 0 ]; then
    printf 'This deletes all Kadr settings, History and studio sessions, and resets its\n'
    printf 'privacy permissions. Captures saved to your own folders are not touched.\n'
    read -r -p 'Continue? [y/N] ' answer
    case "$answer" in [yY]*) ;; *) printf 'Nothing changed.\n'; exit 1 ;; esac
fi

# ---------------------------------------------------------------- quit
# Quitting first matters: a running agent writes its preferences back on quit, which would
# undo the `defaults delete` below.
for app in KadrEditor Kadr; do
    if pgrep -x "$app" >/dev/null; then
        osascript -e "quit app \"$app\"" >/dev/null 2>&1 || true
        sleep 1
        pkill -x "$app" 2>/dev/null || true
        say "quit $app"
    fi
done

# ---------------------------------------------------------------- login item
# SMAppService registrations belong to the app; asking the app's own login item record to
# go is the only supported route from a script, so this uses System Events and tolerates
# there being nothing to remove.
osascript -e 'tell application "System Events" to delete (every login item whose name is "Kadr")' \
    >/dev/null 2>&1 && say "removed the Kadr login item" || true

# ---------------------------------------------------------------- preferences and files
for domain in "$AGENT_ID" "$EDITOR_ID"; do
    defaults delete "$domain" >/dev/null 2>&1 && say "deleted preferences for $domain" || true
done
# cfprefsd caches domains; without this a relaunch can read the deleted values back.
killall cfprefsd 2>/dev/null || true

paths=(
    "$HOME/Library/Application Support/Kadr"
    "$HOME/Library/Caches/$AGENT_ID"
    "$HOME/Library/Caches/$EDITOR_ID"
    "$HOME/Library/HTTPStorages/$AGENT_ID"
    "$HOME/Library/HTTPStorages/$AGENT_ID.binarycookies"
    "$HOME/Library/Saved Application State/$AGENT_ID.savedState"
    "$HOME/Library/Saved Application State/$EDITOR_ID.savedState"
)
for path in "${paths[@]}"; do
    if [ -e "$path" ]; then
        rm -rf "$path"
        say "removed ${path/#$HOME/\~}"
    fi
done

# ---------------------------------------------------------------- privacy grants
for service in ScreenCapture Accessibility ListenEvent Microphone Camera SpeechRecognition; do
    for bundle in "$AGENT_ID" "$EDITOR_ID"; do
        tccutil reset "$service" "$bundle" >/dev/null 2>&1 || true
    done
done
say "reset Screen Recording, Accessibility, Input Monitoring, Microphone, Camera and Speech Recognition"

# ---------------------------------------------------------------- command-line tool
# The same two places Kadr/Automation/CLIInstaller.swift links into. Only a link that
# points into a Kadr bundle is removed; anything else called `kadr` is somebody else's.
for link in /usr/local/bin/kadr "$HOME/.local/bin/kadr"; do
    if [ -L "$link" ]; then
        target=$(readlink "$link")
        if [[ "$target" == *Kadr.app/* ]]; then
            rm -f "$link"
            say "removed the CLI link $link"
        fi
    fi
done

# ---------------------------------------------------------------- desktop icons
# Kadr hides desktop icons while capturing and restores them afterwards; a crash in between
# leaves them hidden. Only touch Finder when that is what happened.
if [ "$(defaults read com.apple.finder CreateDesktop 2>/dev/null || echo 1)" = "0" ]; then
    defaults write com.apple.finder CreateDesktop -bool true
    killall Finder 2>/dev/null || true
    say "restored desktop icons"
fi

# ---------------------------------------------------------------- the app
if [ "$remove_app" -eq 1 ] && [ -d "$APP_PATH" ]; then
    rm -rf "$APP_PATH"
    say "removed $APP_PATH"
fi

printf 'Done. Kadr will start as a first launch.\n'
