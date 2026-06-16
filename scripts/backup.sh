#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_ID="${BACKUP_HOST:-$(hostname -s)}"
CONFIG_FILE="${BACKUP_CONFIG:-${REPO_DIR}/hosts/${HOST_ID}/backup.conf}"
PUSH="${BACKUP_PUSH:-0}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

safe_relpath() {
  case "$1" in
    backups/${HOST_ID}/*|manifests/${HOST_ID}/*|scripts/*|hosts/*/backup.conf|.github/workflows/*|README.md|.gitignore) return 0 ;;
    *) return 1 ;;
  esac
}

reject_plaintext_in_repo() {
  local bad=0
  while IFS= read -r -d '' f; do
    rel="${f#${REPO_DIR}/}"
    case "$rel" in
      .git/*|*.tar.zst.age|*.sha256|*.json|*.md|*.sh|*.conf|*.txt|.gitignore|*.yml|*.yaml) ;;
      *) printf 'Unexpected file in repo: %s\n' "$rel" >&2; bad=1 ;;
    esac
    case "$rel" in
      *.tar|*.tar.zst|*.zip|*.sql|*.dump|*.bak|*.key|*.pem|*.env|*.sqlite|*.db|age-identity*|id_*|*_rsa|*_ed25519)
        printf 'Forbidden plaintext/secret-like file in repo: %s\n' "$rel" >&2; bad=1 ;;
    esac
  done < <(find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -type f -print0)
  [[ "$bad" -eq 0 ]] || fail "repo contains forbidden files"
}

validate_staged_files() {
  local bad=0 path
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    path="${path#\"}"
    path="${path%\"}"
    if ! safe_relpath "$path"; then
      printf 'Refusing to stage unsafe path: %s\n' "$path" >&2
      bad=1
      continue
    fi
    case "$path" in
      *.tar|*.tar.zst|*.zip|*.sql|*.dump|*.bak|*.key|*.pem|*.env|*.sqlite|*.db|age-identity*|id_*|*_rsa|*_ed25519)
        printf 'Refusing to stage plaintext/secret-like path: %s\n' "$path" >&2
        bad=1 ;;
    esac
  done < <(GIT_MASTER=1 git -C "$REPO_DIR" diff --cached --name-only)
  [[ "$bad" -eq 0 ]] || fail "unsafe staged files detected"
}

git_with_token() {
  [[ -n "${GITHUB_TOKEN:-}" ]] || fail "GITHUB_TOKEN required for authenticated git operation"
  GIT_ASKPASS="$REPO_DIR/scripts/git-askpass.sh" GITHUB_TOKEN="$GITHUB_TOKEN" GIT_MASTER=1 git -C "$REPO_DIR" "$@"
}

sync_remote_before_backup() {
  [[ "$PUSH" == "1" ]] || return 0
  [[ -n "${GITHUB_TOKEN:-}" ]] || fail "GITHUB_TOKEN required when BACKUP_PUSH=1"
  log "syncing latest origin/main before creating backup"
  git_with_token pull --rebase --autostash origin main
}

push_with_retry() {
  local attempt max_attempts
  max_attempts=3
  for attempt in $(seq 1 "$max_attempts"); do
    log "pushing to origin/main, attempt ${attempt}/${max_attempts}"
    if git_with_token push origin HEAD:main; then
      return 0
    fi
    log "push failed; rebasing on latest origin/main before retry"
    git_with_token pull --rebase --autostash origin main
    sleep $((attempt * 10))
  done
  fail "push failed after ${max_attempts} attempts"
}

main() {
  need_cmd tar
  need_cmd zstd
  need_cmd age
  need_cmd sha256sum
  need_cmd git
  need_cmd find

  [[ -f "$CONFIG_FILE" ]] || fail "missing config: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"

  [[ "${HOST_ID}" == "${CONFIG_HOST_ID:-}" ]] || fail "host mismatch: BACKUP_HOST=$HOST_ID config=${CONFIG_HOST_ID:-unset}"
  [[ -n "${AGE_RECIPIENT:-}" ]] || fail "AGE_RECIPIENT is required"
  [[ ${#BACKUP_PATHS[@]} -gt 0 ]] || fail "BACKUP_PATHS must not be empty"

  sync_remote_before_backup

  mkdir -p "$REPO_DIR/backups/$HOST_ID" "$REPO_DIR/manifests/$HOST_ID"
  reject_plaintext_in_repo

  for p in "${BACKUP_PATHS[@]}"; do
    if [[ "$p" == "$REPO_DIR" || "$p" == "$REPO_DIR"/* ]]; then
      fail "backup path points inside backup repo: $p"
    fi
  done

  local ts tmpdir plain_archive encrypted rel_encrypted checksum_file manifest latest_file
  ts="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
  tmpdir="$(mktemp -d)"
  plain_archive="$tmpdir/${HOST_ID}-${ts}.tar.zst"
  encrypted="$REPO_DIR/backups/$HOST_ID/${ts}.tar.zst.age"
  rel_encrypted="backups/$HOST_ID/${ts}.tar.zst.age"
  checksum_file="$REPO_DIR/backups/$HOST_ID/${ts}.sha256"
  manifest="$REPO_DIR/manifests/$HOST_ID/${ts}.json"
  latest_file="$REPO_DIR/backups/$HOST_ID/latest.txt"

  cleanup() {
    if [[ -n "${tmpdir:-}" ]]; then
      rm -rf "$tmpdir"
    fi
  }
  trap cleanup EXIT INT TERM

  log "creating plaintext archive outside repo"
  local existing_paths=()
  for p in "${BACKUP_PATHS[@]}"; do
    if [[ -e "$p" ]]; then
      existing_paths+=("$p")
    else
      log "skip missing path: $p"
    fi
  done
  [[ ${#existing_paths[@]} -gt 0 ]] || fail "no configured backup paths exist"

  tar --zstd -cpf "$plain_archive" \
    --warning=no-file-changed \
    --ignore-failed-read \
    "${TAR_EXCLUDES[@]:-}" \
    "${existing_paths[@]}"

  [[ -s "$plain_archive" ]] || fail "plaintext archive missing or empty"
  log "encrypting archive"
  age -r "$AGE_RECIPIENT" -o "$encrypted" "$plain_archive"
  [[ -s "$encrypted" ]] || fail "encrypted archive missing or empty"
  rm -f "$plain_archive"

  (cd "$REPO_DIR" && sha256sum "$rel_encrypted" > "$checksum_file")
  printf '%s\n' "$rel_encrypted" > "$latest_file"

  python3 - "$manifest" "$HOST_ID" "$ts" "$rel_encrypted" "$checksum_file" "${existing_paths[@]}" <<'PY'
import hashlib, json, os, sys
manifest, host, ts, rel, checksum_file, *paths = sys.argv[1:]
with open(os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(manifest))), rel), 'rb') as fh:
    digest = hashlib.sha256(fh.read()).hexdigest()
data = {
    "host_id": host,
    "timestamp_utc": ts,
    "encrypted_archive": rel,
    "encrypted_archive_sha256": digest,
    "included_paths": paths,
}
with open(manifest, 'w', encoding='utf-8') as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
PY

  reject_plaintext_in_repo

  GIT_MASTER=1 git -C "$REPO_DIR" add README.md .gitignore scripts hosts .github backups/$HOST_ID manifests/$HOST_ID
  validate_staged_files

  log "backup prepared: $rel_encrypted"

  if [[ "$PUSH" == "1" ]]; then
    [[ -n "${GITHUB_TOKEN:-}" ]] || fail "GITHUB_TOKEN required when BACKUP_PUSH=1"
    GIT_AUTHOR_NAME="${BACKUP_GIT_AUTHOR_NAME:-zqbxdev}" \
      GIT_AUTHOR_EMAIL="${BACKUP_GIT_AUTHOR_EMAIL:-zqbxdev@users.noreply.github.com}" \
      GIT_COMMITTER_NAME="${BACKUP_GIT_COMMITTER_NAME:-zqbxdev}" \
      GIT_COMMITTER_EMAIL="${BACKUP_GIT_COMMITTER_EMAIL:-zqbxdev@users.noreply.github.com}" \
      GIT_MASTER=1 git -C "$REPO_DIR" commit -m "Add ${HOST_ID} encrypted backup ${ts}"
    push_with_retry
  fi
}

main "$@"
