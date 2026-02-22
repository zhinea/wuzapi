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
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
BACKUP_FILE_PREFIX="${BACKUP_FILE_PREFIX:-wuzapi-sqlite}"
AWS_CLI_DOCKER_IMAGE="${AWS_CLI_DOCKER_IMAGE:-amazon/aws-cli}"

if [[ ! -d "${BACKUP_SOURCE_DIR}" ]]; then
  echo "error: backup source dir does not exist: ${BACKUP_SOURCE_DIR}"
  exit 1
fi

mkdir -p "${BACKUP_OUTPUT_DIR}"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
file_name="${BACKUP_FILE_PREFIX}-${timestamp}.tar.gz"
archive_path="${BACKUP_OUTPUT_DIR}/${file_name}"
object_key="${R2_BACKUP_PREFIX%/}/${file_name}"

tar -czf "${archive_path}" -C "${BACKUP_SOURCE_DIR}" .

docker run --rm \
  -v "${BACKUP_OUTPUT_DIR}:/data" \
  -e AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" \
  -e AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" \
  -e AWS_DEFAULT_REGION="auto" \
  -e AWS_EC2_METADATA_DISABLED="true" \
  "${AWS_CLI_DOCKER_IMAGE}" \
  s3 cp "/data/${file_name}" "s3://${R2_BUCKET}/${object_key}" \
  --endpoint-url "${R2_ENDPOINT}" \
  --only-show-errors

if [[ "${BACKUP_RETENTION_DAYS}" =~ ^[0-9]+$ ]] && [[ "${BACKUP_RETENTION_DAYS}" -gt 0 ]]; then
  find "${BACKUP_OUTPUT_DIR}" -type f -name "${BACKUP_FILE_PREFIX}-*.tar.gz" -mtime +"${BACKUP_RETENTION_DAYS}" -delete
fi

echo "backup uploaded: s3://${R2_BUCKET}/${object_key}"
