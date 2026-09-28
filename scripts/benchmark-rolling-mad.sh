#!/usr/bin/env bash
set -euo pipefail

image_name="postgres-augurs-extension:poc"
container_name="postgres-augurs-extension-rolling-mad-benchmark"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
batch_sizes_string="${BATCH_SIZES:-2880 8640 43200}"
iterations="${ITERATIONS:-3}"

cleanup() {
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
}

trap cleanup EXIT

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
    docker build --tag "${image_name}" "${repo_root}"
fi

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
    --quiet \
    --file /workspace/sql/benchmark-rolling-mad-setup.sql

printf 'batch_size\titerations\telapsed_s\trequest_avg_ms\trolling_mad_avg_ms\tcpu_avg_pct\tcpu_peak_pct\n'

for batch_size in ${batch_sizes_string}; do
    timing_file="$(mktemp)"
    cpu_file="$(mktemp)"
    workload_log="$(mktemp)"

    /usr/bin/time -p -o "${timing_file}" \
        docker exec "${container_name}" psql \
            --username postgres \
            --dbname postgres \
            --quiet \
            --tuples-only \
            --no-align \
            --file /workspace/sql/benchmark-rolling-mad-workload.sql \
            --variable "batch_size=${batch_size}" \
            --variable "iterations=${iterations}" \
            >"${workload_log}" 2>&1 &
    workload_pid=$!

    while kill -0 "${workload_pid}" 2>/dev/null; do
        cpu_percent="$(docker stats --no-stream --format '{{.CPUPerc}}' "${container_name}" 2>/dev/null | tr -d '%')"
        case "${cpu_percent}" in
            ''|*[!0-9.]*) ;;
            *) printf '%s\n' "${cpu_percent}" >>"${cpu_file}" ;;
        esac
        sleep 0.25
    done

    if ! wait "${workload_pid}"; then
        cat "${workload_log}" >&2
        echo "rolling MAD benchmark workload failed for batch size ${batch_size}" >&2
        exit 1
    fi

    elapsed_seconds="$(awk '$1 == "real" { print $2 }' "${timing_file}")"
    request_average_ms="$(awk -v elapsed="${elapsed_seconds}" -v count="${iterations}" \
        'BEGIN { printf "%.2f", elapsed * 1000 / count }')"
    workload_values="$(tail -n 1 "${workload_log}" | tr -d '\r')"
    IFS='|' read -r rolling_mad_average_ms complete_runs measured_iterations <<<"${workload_values}"
    if [[ -z "${rolling_mad_average_ms:-}" || "${complete_runs:-}" != "${iterations}" || "${measured_iterations:-}" != "${iterations}" ]]; then
        cat "${workload_log}" >&2
        echo "rolling MAD benchmark timings were incomplete for batch size ${batch_size}" >&2
        exit 1
    fi
    cpu_average="$(awk '{ sum += $1 } END { if (NR) printf "%.2f", sum / NR; else print "n/a" }' "${cpu_file}")"
    cpu_peak="$(awk 'BEGIN { max = 0 } $1 > max { max = $1 } END { if (NR) printf "%.2f", max; else print "n/a" }' "${cpu_file}")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${batch_size}" "${iterations}" "${elapsed_seconds}" "${request_average_ms}" \
        "${rolling_mad_average_ms}" "${cpu_average}" "${cpu_peak}"

    rm -f "${timing_file}" "${cpu_file}" "${workload_log}"
done
