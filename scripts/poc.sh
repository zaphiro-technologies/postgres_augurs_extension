#!/usr/bin/env bash
set -euo pipefail

image_name="postgres-augurs-extension:poc"
container_name="postgres-augurs-extension-poc"

cleanup() {
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

docker build --tag "${image_name}" .
docker run --detach \
    --name "${container_name}" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    "${image_name}" >/dev/null

until docker exec "${container_name}" pg_isready -U postgres >/dev/null 2>&1; do
    sleep 1
done

docker exec "${container_name}" psql \
    --username postgres \
    --dbname postgres \
    --file /workspace/sql/poc.sql
