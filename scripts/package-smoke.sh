#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <postgresql-package.tar.gz>" >&2
    exit 2
fi

archive_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
container_name="${CONTAINER_NAME:-postgres-augurs-extension-package-smoke}"

cleanup() {
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

docker run --detach \
    --name "${container_name}" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    postgres:17-bookworm >/dev/null

until docker exec "${container_name}" pg_isready -U postgres >/dev/null 2>&1; do
    sleep 1
done

docker cp "${archive_path}" "${container_name}:/tmp/postgres-augurs-extension.tar.gz"
docker exec "${container_name}" \
    tar -xzf /tmp/postgres-augurs-extension.tar.gz -C /

result="$(docker exec "${container_name}" psql \
    --username postgres \
    --dbname postgres \
    --quiet \
    --no-align \
    --tuples-only \
    --command "CREATE EXTENSION postgres_augurs_extension; SELECT count(*) FROM augurs_detect_changepoints(ARRAY[0.5, 1.0, 0.4, 0.8, 1.5, 0.9, 0.6, 25.3, 20.4, 27.3, 30.0]::float8[]);")"

if [[ "${result}" != "2" ]]; then
    echo "unexpected package smoke-test result: ${result}" >&2
    exit 1
fi

echo "package smoke test passed"
