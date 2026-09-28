#!/usr/bin/env bash
set -euo pipefail

image_name="postgres-augurs-extension:poc"
container_name="postgres-augurs-extension-poc"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cleanup() {
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

docker build \
    --file "${repo_root}/.docker/Dockerfile" \
    --tag "${image_name}" \
    "${repo_root}"
docker run --detach \
    --name "${container_name}" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    --volume "${repo_root}/sql:/workspace/sql:ro" \
    "${image_name}" >/dev/null

until docker exec "${container_name}" pg_isready -U postgres >/dev/null 2>&1; do
    sleep 1
done

docker exec "${container_name}" psql \
    --username postgres \
    --dbname postgres \
    --file /workspace/sql/poc.sql
