# bw-functions.sh — source this from your ~/.zshrc (or ~/.bashrc):
#
#     source ~/bin/bw-functions.sh
#
# Then, in any shell:
#
#     bwset LINEAR_API_KEY                  # sets LINEAR_API_KEY in the current shell
#     bwset LINEAR_API_KEY DB_PASS GH_TOKEN # sets all three, one shared secret-list fetch
#     bwshow LINEAR_API_KEY                 # print the value to the terminal, nothing exported
#     bwlist                                # list secret keys and IDs (no values)
#     bwlistall                             # list every secret as KEY=value (prints values)
#     bwunset LINEAR_API_KEY                # remove it from the current shell
#     bwunset --all                         # remove every var this session's bwset created
#
# These are shell FUNCTIONS, not a subprocess, so they modify your live shell
# directly — no `eval "$(...)"` needed. The BWS access token is read from the
# keychain and used only for a single `bws` call; it is never exported into
# your shell.
#
# Config (override in your environment before sourcing, or any time):
#     BWS_KEYCHAIN_SERVICE   keychain "service" name  (default: bws-access-token)
#     BWS_KEYCHAIN_ACCOUNT   keychain "account" name  (default: unset)

# --- private: print the full `bws secret list` JSON to stdout, or fail -------
__bws_fetch_list() {
  local kc_service="${BWS_KEYCHAIN_SERVICE:-bws-access-token}"
  local kc_account="${BWS_KEYCHAIN_ACCOUNT:-}"
  local token json

  command -v security >/dev/null 2>&1 || { printf 'bwset: security not found (macOS?)\n' >&2; return 1; }
  command -v bws      >/dev/null 2>&1 || { printf 'bwset: bws CLI not on PATH\n'         >&2; return 1; }
  command -v jq       >/dev/null 2>&1 || { printf 'bwset: jq not on PATH\n'              >&2; return 1; }

  if [[ -n "$kc_account" ]]; then
    token="$(security find-generic-password -s "$kc_service" -a "$kc_account" -w 2>/dev/null)" \
      || { printf "bwset: no keychain item for service='%s' account='%s'\n" "$kc_service" "$kc_account" >&2; return 1; }
  else
    token="$(security find-generic-password -s "$kc_service" -w 2>/dev/null)" \
      || { printf "bwset: no keychain item for service='%s'\n" "$kc_service" >&2; return 1; }
  fi
  [[ -n "$token" ]] || { printf "bwset: keychain item '%s' was empty\n" "$kc_service" >&2; return 1; }

  json="$(BWS_ACCESS_TOKEN="$token" bws secret list --output json 2>/dev/null)"
  local ec=$?
  unset token
  [[ $ec -eq 0 ]] || { printf 'bwset: failed to list secrets (bad token or no access?)\n' >&2; return 1; }
  printf '%s' "$json"
}

# --- bwset <SECRET_KEY> [SECRET_KEY ...] --------------------------------------
# Looks up each key or secret ID against one shared `bws secret list` fetch,
# exports whatever it finds, and reports a one-line summary of hits/misses.
bwset() {
  if [[ $# -lt 1 ]]; then
    printf 'usage: bwset <SECRET_KEY> [SECRET_KEY ...]\n' >&2
    return 2
  fi

  local json
  json="$(__bws_fetch_list)" || return 1

  local -a set_vars=() missing_vars=()
  local key count value

  for key in "$@"; do
    count="$(jq --arg k "$key" '[.[] | select(.key == $k or .id == $k)] | length' <<<"$json")"
    if [[ "$count" == "0" ]]; then
      printf "bwset: no secret with key or id '%s'\n" "$key" >&2
      missing_vars+=("$key")
      continue
    fi
    if [[ "$count" != "1" ]]; then
      printf "bwset: %s secrets share key '%s' — pass the secret ID instead\n" "$count" "$key" >&2
      missing_vars+=("$key")
      continue
    fi
    value="$(jq -r --arg k "$key" 'first(.[] | select(.key == $k or .id == $k)) | .value' <<<"$json")"
    if [[ -z "$value" || "$value" == "null" ]]; then
      printf "bwset: secret '%s' has no value\n" "$key" >&2
      missing_vars+=("$key")
      continue
    fi
    export "$key=$value"
    set_vars+=("$key")
    # remember what we set so `bwunset --all` can clean up
    case " ${__BWSET_VARS:-} " in
      *" $key "*) : ;;
      *) __BWSET_VARS="${__BWSET_VARS:-}${__BWSET_VARS:+ }$key" ;;
    esac
  done
  unset value

  local set_msg="" miss_msg=""
  [[ ${#set_vars[@]} -eq 0 ]]     || set_msg="Set $(IFS=', '; echo "${set_vars[*]}")"
  [[ ${#missing_vars[@]} -eq 0 ]] || miss_msg="could not find $(IFS=', '; echo "${missing_vars[*]}") to set"

  if [[ -n "$set_msg" && -n "$miss_msg" ]]; then
    printf '%s; %s\n' "$set_msg" "$miss_msg"
  elif [[ -n "$set_msg" ]]; then
    printf '%s\n' "$set_msg"
  elif [[ -n "$miss_msg" ]]; then
    printf '%s\n' "$miss_msg" >&2
  fi

  [[ ${#missing_vars[@]} -eq 0 ]]
}

# --- bwshow <SECRET_KEY> [SECRET_KEY ...] -------------------------------------
# Prints secret values to stdout without exporting anything. One argument prints
# the bare value; several print KEY=value lines.
bwshow() {
  if [[ $# -lt 1 ]]; then
    printf 'usage: bwshow <SECRET_KEY> [SECRET_KEY ...]\n' >&2
    return 2
  fi

  local json
  json="$(__bws_fetch_list)" || return 1

  local key count value rc=0
  for key in "$@"; do
    count="$(jq --arg k "$key" '[.[] | select(.key == $k or .id == $k)] | length' <<<"$json")"
    if [[ "$count" == "0" ]]; then
      printf "bwshow: no secret with key or id '%s'\n" "$key" >&2
      rc=1
      continue
    fi
    if [[ "$count" != "1" ]]; then
      printf "bwshow: %s secrets share key '%s'; pass the secret ID instead\n" "$count" "$key" >&2
      rc=1
      continue
    fi
    value="$(jq -r --arg k "$key" 'first(.[] | select(.key == $k or .id == $k)) | .value' <<<"$json")"
    if [[ $# -eq 1 ]]; then
      printf '%s\n' "$value"
    else
      printf '%s=%s\n' "$key" "$value"
    fi
  done
  unset value json
  return $rc
}

# --- bwlist -------------------------------------------------------------------
# Prints one "KEY<tab>ID" line per secret, sorted by key. Values are never printed.
bwlist() {
  local json
  json="$(__bws_fetch_list)" || return 1
  jq -r '.[] | "\(.key)\t\(.id)"' <<<"$json" | sort
  unset json
}

# --- bwlistall ----------------------------------------------------------------
# Prints one "KEY=value" line per secret, sorted by key. Prints secret values.
bwlistall() {
  local json
  json="$(__bws_fetch_list)" || return 1
  jq -r '.[] | "\(.key)=\(.value)"' <<<"$json" | sort
  unset json
}

# --- bwunset <VAR_NAME> | --all -----------------------------------------------
bwunset() {
  if [[ "${1:-}" == "--all" ]]; then
    local -a unset_vars=()
    local v
    for v in ${__BWSET_VARS:-}; do
      unset "$v"
      unset_vars+=("$v")
    done
    unset __BWSET_VARS
    if [[ ${#unset_vars[@]} -gt 0 ]]; then
      printf 'Unset %s\n' "$(IFS=', '; echo "${unset_vars[*]}")"
    else
      printf 'Nothing to unset\n'
    fi
    return 0
  fi
  if [[ $# -ne 1 ]]; then
    printf 'usage: bwunset <VAR_NAME> | --all\n' >&2
    return 2
  fi
  unset "$1"
  printf 'Unset %s\n' "$1"
  # drop it from the tracking list
  local kept="" v
  for v in ${__BWSET_VARS:-}; do
    [[ "$v" == "$1" ]] || kept="${kept}${kept:+ }$v"
  done
  __BWSET_VARS="$kept"
}
