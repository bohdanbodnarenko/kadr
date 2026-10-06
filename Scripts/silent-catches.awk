# Finds `catch` blocks that log an error and do nothing a user could see (docs/18 X-2).
#
# Prints `path:line: <the logger.error line>` for each. A heuristic, deliberately: a
# block counts as reporting if it mentions any of the presenter vocabulary below, or
# rethrows, or hands the error to a completion. Anything else that only logs is either a
# real silent failure or belongs in Scripts/silent-catches.allow with its reason.
#
# Usage: awk -f Scripts/silent-catches.awk Kadr/**/*.swift

function reports(text) {
    # Shown here, or handed to a caller that shows it: a nil, false or failed result, an
    # error property a view reads, or a callback that takes the error.
    return text ~ /FailurePresenter|RecordingFailureNotice|NSAlert|\.present\(|presentError|failExport|failure = |Failure\(|status = |feedback|Feedback|setStatus|notice = |Notice\(|showError|throw |completion\?\(|completion\(|reply\(|respond\(|onFailure|handle\(error|deliver\(|report\(|return nil|return false|return \.failed|[A-Za-z]Error = |finish\(error|[Ff]ailed\(\)|AfterFailed|markUnrecoverable/
}

FNR == 1 {
    depth = 0
    inCatch = 0
}

{
    line = $0
    if (!inCatch && line ~ /(^|[^A-Za-z])catch([^A-Za-z]|$)/ && line ~ /\{[[:space:]]*$/) {
        inCatch = 1
        catchDepth = 0
        body = ""
        logLine = ""
        logAt = 0
    }
    if (inCatch) {
        body = body "\n" line
        if (logAt == 0 && line ~ /logger\.error/) {
            logLine = line
            logAt = FNR
        }
        # On the catch line itself only what follows `catch` counts: the `}` before it
        # closes the `do`, not this block.
        if (catchDepth == 0 && body !~ /\n.*\n/) {
            sub(/^.*catch/, "", line)
        }
        opens = gsub(/\{/, "{", line)
        closes = gsub(/\}/, "}", line)
        catchDepth += opens - closes
        if (catchDepth <= 0) {
            if (logAt > 0 && !reports(body)) {
                sub(/^[[:space:]]+/, "", logLine)
                printf "%s:%d: %s\n", FILENAME, logAt, logLine
            }
            inCatch = 0
        }
    }
}
