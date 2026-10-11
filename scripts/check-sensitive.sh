#!/usr/bin/env bash
# scripts/check-sensitive.sh - block real environment data from being committed.
#
# Everything in this repo uses placeholders (example.com, CHANGE-ME-...). This
# script fails if it finds, in the text it is given:
#   - credentials: private keys, pull secrets, GitHub/GitLab/AWS tokens, JWTs
#     (service-account tokens), password/token/secret keys with a real value
#   - hostnames on a non-allowlisted domain (corporate DNS, git/registry URLs)
#   - IPv4 addresses outside loopback and the RFC 5737 documentation ranges
#
# Usage:
#   scripts/check-sensitive.sh --staged          # lines added in the index (pre-commit)
#   scripts/check-sensitive.sh --range A..B      # lines added in a commit range (pre-push)
#   scripts/check-sensitive.sh --file <path>     # a single file, e.g. a commit message
#   scripts/check-sensitive.sh --all             # every tracked file (CI)
#
# Allowed domains: githooks/allowed-domains (public upstream API groups, docs,
# example.*). A line containing "sensitive-scan: allow" is skipped - use it
# only for values that are public, and say why in the same comment.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
allowed_file="$root/githooks/allowed-domains"
# Files that legitimately contain the patterns themselves.
skip_files='^(scripts/check-sensitive[.]sh|githooks/allowed-domains|LICENSE)$'

mode=${1:---staged}

# Emit "<file>\t<line>" for every line to check.
added_lines() { # reads a unified diff on stdin
  awk '
    /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
    /^\+/      { printf "%s\t%s\n", file, substr($0, 2) }
  '
}

case $mode in
  --staged) input="$(git diff --cached -U0 --no-color --diff-filter=ACMR | added_lines)" ;;
  --range)  input="$(git diff -U0 --no-color --diff-filter=ACMR "${2:?--range needs A..B}" | added_lines)" ;;
  --file)   input="$(awk -v f="${2:?--file needs a path}" '!/^#/ { printf "%s\t%s\n", f, $0 }' "$2")" ;;
  --all)    input="$(cd "$root" && git ls-files -z | xargs -0 grep -IH '' 2>/dev/null | sed 's/:/\t/' || true)" ;;
  *) echo "usage: $0 [--staged | --range A..B | --file PATH | --all]" >&2; exit 2 ;;
esac

[[ -z $input ]] && exit 0

allowed="$(grep -v -E '^[[:space:]]*(#|$)' "$allowed_file" | tr '\n' ' ')"

# Patterns are split ('' joins) so this file never matches itself.
secret_re='-----BEGIN [A-Z ]*PRIVATE'' KEY-----'
secret_re+='|"auths"[[:space:]]*:[[:space:]]*[{][[:space:]]*"'          # pull secret JSON
secret_re+='|eyJhdXRo''cyI6'                                              # base64 of {"auths":
secret_re+='|gh[pousr]_[A-Za-z0-9]{30,}'                                  # GitHub token
secret_re+='|glpat-[A-Za-z0-9_-]{20,}'                                    # GitLab token
secret_re+='|AKIA[0-9A-Z]{16}'                                            # AWS access key id
secret_re+='|eyJ[A-Za-z0-9_-]{10,}[.]eyJ[A-Za-z0-9_-]{10,}'                # JWT / SA token
secret_re+='|(ssh-(rsa|ed25519)|ecdsa-sha2-nistp[0-9]+) AAAA[A-Za-z0-9+/]{40,}'
# key: value pairs whose value is not a placeholder or a template
kv_re='(password|passwd|pwd|token|secret|apikey|api_key|access_key|secret_key|secretkey)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?[^[:space:]"'"'"'{<$]{6,}'

hits="$(printf '%s\n' "$input" | awk -F'\t' -v skip="$skip_files" -v sre="$secret_re" \
    -v kre="$kv_re" -v allowed=" $allowed " '
  function domain_ok(host,   d) {
    d = host
    while (d ~ /\./) {                       # host itself, then each parent domain
      if (index(allowed, " " d " ")) return 1
      sub(/^[^.]*\./, "", d)
    }
    return 0
  }
  function ip_ok(ip) {
    return ip ~ /^(127\.|0\.0\.0\.0$|192\.0\.2\.|198\.51\.100\.|203\.0\.113\.)/
  }
  function report(kind, what) {
    printf "  %s: %s: %s\n", $1, kind, what
  }
  $1 ~ skip { next }
  {
    line = $0; sub(/^[^\t]*\t/, "", line)
    if (line ~ /sensitive-scan: allow/) next
    low = tolower(line)

    if (line ~ sre) report("credential", substr(line, 1, 60) "...")
    else if (low ~ kre && low !~ /change-me/) report("credential-like value", substr(line, 1, 60) "...")

    s = low
    while (match(s, /[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)*\.(com|net|org|corp|local|internal|intra|lan|biz|info|cloud|us|mx)([^a-z0-9-]|$)/)) {
      host = substr(s, RSTART, RLENGTH); sub(/[^a-z0-9]$/, "", host)
      if (!domain_ok(host)) report("hostname not in githooks/allowed-domains", host)
      s = substr(s, RSTART + RLENGTH)
    }

    s = line
    while (match(s, /(^|[^0-9.])[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)/)) {
      ip = substr(s, RSTART, RLENGTH); gsub(/^[^0-9]|[^0-9]$/, "", ip)
      if (!ip_ok(ip)) report("IP address", ip)
      s = substr(s, RSTART + RLENGTH)
    }
  }
')"

if [[ -n $hits ]]; then
  echo "check-sensitive: real environment data found - use placeholders (example.com, CHANGE-ME-...):" >&2
  printf '%s\n' "$hits" | sort -u >&2
  echo "Public values: add the domain to githooks/allowed-domains, or mark the line with" >&2
  echo "'# sensitive-scan: allow (<reason>)'. Unstage with: git restore --staged <file>" >&2
  exit 1
fi
