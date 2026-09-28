#!/usr/bin/env bash
set -euo pipefail

image_name="${IMAGE_NAME:-postgres-augurs-extension:package}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${OUTPUT_DIR:-${repo_root}/dist}"
commit_sha="${GITHUB_SHA:-local}"
extension_version="$(awk -F'"' '$1 ~ /^version[[:space:]]*=/ { print $2; exit }' "${repo_root}/Cargo.toml")"

if [[ -z "${extension_version}" ]]; then
    echo "could not derive the extension version from Cargo.toml" >&2
    exit 1
fi

mkdir -p "${output_dir}"
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/postgres-augurs-package.XXXXXX")"
container_id=""

cleanup() {
    if [[ -n "${container_id}" ]]; then
        docker rm "${container_id}" >/dev/null 2>&1 || true
    fi
    rm -rf "${staging_dir}"
}

trap cleanup EXIT

docker build \
    --file "${repo_root}/.docker/Dockerfile" \
    --target package \
    --tag "${image_name}" \
    "${repo_root}"

container_id="$(docker create "${image_name}")"
mkdir -p "${staging_dir}/package-root"
docker cp "${container_id}:/workspace/package/." "${staging_dir}/package-root/"

archive_name="postgres_augurs_extension-pg17-${extension_version}-${commit_sha}.tar.gz"
archive_path="${staging_dir}/${archive_name}"

tar -C "${staging_dir}/package-root" -czf "${archive_path}" .

mapfile -t package_entries < <(
    tar -tzf "${archive_path}" \
        | sed 's#^\./##' \
        | sed '/\/$/d; /^$/d'
)

expected_library="usr/lib/postgresql/17/lib/postgres_augurs_extension.so"
expected_control="usr/share/postgresql/17/extension/postgres_augurs_extension.control"

has_entry() {
    local expected="$1"
    local entry
    for entry in "${package_entries[@]}"; do
        if [[ "${entry}" == "${expected}" ]]; then
            return 0
        fi
    done
    return 1
}

if ! has_entry "${expected_library}"; then
    echo "package is missing ${expected_library}" >&2
    exit 1
fi

if ! has_entry "${expected_control}"; then
    echo "package is missing ${expected_control}" >&2
    exit 1
fi

sql_entries=()
for entry in "${package_entries[@]}"; do
    if [[ "${entry}" =~ ^usr/share/postgresql/17/extension/postgres_augurs_extension--[^/]+\.sql$ ]]; then
        sql_entries+=("${entry}")
    fi
done

if [[ "${#sql_entries[@]}" -ne 1 || "${#package_entries[@]}" -ne 3 ]]; then
    printf 'unexpected package contents:\n%s\n' "${package_entries[@]}" >&2
    exit 1
fi

final_path="${output_dir}/${archive_name}"
if [[ -e "${final_path}" ]]; then
    echo "refusing to overwrite existing package ${final_path}" >&2
    exit 1
fi

mv "${archive_path}" "${final_path}"
printf '%s\n' "${final_path}"
