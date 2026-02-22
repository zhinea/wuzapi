#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is required"
  exit 1
fi

: "${R2_ACCESS_KEY_ID:?R2_ACCESS_KEY_ID is required}"
: "${R2_SECRET_ACCESS_KEY:?R2_SECRET_ACCESS_KEY is required}"
: "${R2_BUCKET:?R2_BUCKET is required}"

R2_ENDPOINT="${R2_ENDPOINT:-${R2_ENDPOINT_URL:-}}"
if [[ -z "${R2_ENDPOINT}" ]]; then
  : "${R2_ACCOUNT_ID:?R2_ACCOUNT_ID is required when R2_ENDPOINT is not set}"
  R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi
R2_BACKUP_PREFIX="${R2_BACKUP_PREFIX:-wuzapi}"
BACKUP_SOURCE_DIR="${BACKUP_SOURCE_DIR:-${ROOT_DIR}/dbdata}"
BACKUP_OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-${ROOT_DIR}/backups/archives}"
BACKUP_FILE_PREFIX="${BACKUP_FILE_PREFIX:-wuzapi-sqlite}"
AWS_CLI_DOCKER_IMAGE="${AWS_CLI_DOCKER_IMAGE:-amazon/aws-cli}"

mkdir -p "${BACKUP_OUTPUT_DIR}"

mapfile -t backup_lines < <(
  docker run --rm \
  -e AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
  -e AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
  -e AWS_DEFAULT_REGION="auto" \
  -e AWS_EC2_METADATA_DISABLED="true" \
  "${AWS_CLI_DOCKER_IMAGE}" \
  s3 ls "s3://${R2_BUCKET}/${R2_BACKUP_PREFIX%/}/" --recursive \
  --endpoint-url "${R2_ENDPOINT}" \
  | awk '{print $1" "$2"|"$3"|"$4}' \
  | grep "${BACKUP_FILE_PREFIX}-.*\\.tar\\.gz$" \
  | sort
)

if [[ ${#backup_lines[@]} -eq 0 ]]; then
  echo "error: no backup file found in s3://${R2_BUCKET}/${R2_BACKUP_PREFIX%/}/"
  exit 1
fi

echo "Available backups in s3://${R2_BUCKET}/${R2_BACKUP_PREFIX%/}/"
for i in "${!backup_lines[@]}"; do
  IFS='|' read -r date_time size key <<<"${backup_lines[$i]}"
  printf "%3d) %s  %10s bytes  %s\n" "$((i + 1))" "${date_time}" "${size}" "${key}"
done

echo
read -r -p "Select backup number to restore: " selected_index

if [[ ! "${selected_index}" =~ ^[0-9]+$ ]] || (( selected_index < 1 || selected_index > ${#backup_lines[@]} )); then
  echo "error: invalid selection"
  exit 1
fi

IFS='|' read -r _ _ RESTORE_KEY <<<"${backup_lines[$((selected_index - 1))]}"

download_path="${BACKUP_OUTPUT_DIR}/restore-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"

docker run --rm \
  -v "${BACKUP_OUTPUT_DIR}:/data" \
  -e AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
  -e AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
  -e AWS_DEFAULT_REGION="auto" \
  -e AWS_EC2_METADATA_DISABLED="true" \
  "${AWS_CLI_DOCKER_IMAGE}" \
  s3 cp "s3://${R2_BUCKET}/${RESTORE_KEY}" "/data/$(basename "${download_path}")" \
  --endpoint-url "${R2_ENDPOINT}" \
  --only-show-errors

mkdir -p "${BACKUP_SOURCE_DIR}"
find "${BACKUP_SOURCE_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -xzf "${download_path}" -C "${BACKUP_SOURCE_DIR}"

echo "restore completed from: s3://${R2_BUCKET}/${RESTORE_KEY}"
echo "restored into: ${BACKUP_SOURCE_DIR}"
