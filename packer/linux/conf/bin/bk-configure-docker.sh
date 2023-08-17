#!/usr/bin/env bash

set -Eeuo pipefail

on_error() {
  echo "Exited $? because of error on line $1" >&2
}

trap 'on_error $LINENO' ERR

## Configures docker before system starts

# Write to system console and to our log file
# See https://alestic.com/2010/12/ec2-user-data-output/
exec > >(tee -a /var/log/elastic-stack.log | logger -t user-data -s 2>/dev/console) 2>&1

echo Reading configuration from lib/bk-configure-docker.sh >&2
# shellcheck disable=SC1091
source /usr/local/lib/bk-configure-docker.sh

if [[ "${DOCKER_USERNS_REMAP:-false}" == "true" ]]; then
  echo User namespace remapping enabled in stack parameters >&2

  echo Enabling user namespace remapping in docker daemon.json >&2
  new_daemon_json="$(jq '."userns-remap"="buildkite-agent"' /etc/docker/daemon.json)"
  cat <<<"$new_daemon_json" > /etc/docker/daemon.json

  buildkite_user_id="$(id -u buildkite-agent)"
  docker_group_id="$(getent group docker | awk -F: '{print $3}')"

  echo "Writing buildkite user id: $buildkite_user_id to /etc/subuid" >&2
  cat <<EOF > /etc/subuid
buildkite-agent:$(id -u buildkite-agent):1
buildkite-agent:100000:65536
EOF

  echo "Writing docker group id: $docker_group_id to /etc/subgid" >&2
  cat <<EOF > /etc/subgid
buildkite-agent:${docker_group_id}:1
buildkite-agent:100000:65536
EOF
else
  echo User namespace remapping not enabled in stack parameters >&2
fi

if [[ "${DOCKER_EXPERIMENTAL:-false}" == "true" ]]; then
  echo Experimental features enabled in stack parameters >&2
  new_daemon_json="$(jq '.experimental=true' /etc/docker/daemon.json)"
  cat <<<"$new_daemon_json" > /etc/docker/daemon.json
else
  echo Experimental features not enabled in stack parameters >&2
fi

if [[ "${BUILDKITE_ENABLE_INSTANCE_STORAGE:-false}" == "true" ]]; then
  echo Instance storage enabled in stack parameters. Moving docker root to the ephemeral device. >&2
  mkdir -p /mnt/ephemeral/docker
  new_daemon_json="$(jq '."data-root"="/mnt/ephemeral/docker"' /etc/docker/daemon.json)"
  cat <<<"$new_daemon_json" > /etc/docker/daemon.json
else
  echo Instance storage not enabled in stack parameters >&2
fi

echo Customising address pools >&2
new_daemon_json="$(jq '."default-address-pools"=[{"base":"172.17.0.0/12","size":20},{"base":"192.168.0.0/16","size":24}]' /etc/docker/daemon.json)"
cat <<<"$new_daemon_json" > /etc/docker/daemon.json

# See https://docs.docker.com/build/building/multi-platform/
echo Installing qemu binfmt for multiarch...
docker run \
  --privileged \
  --userns=host \
  --rm \
  "tonistiigi/binfmt:${QEMU_BINFMT_TAG}" \
    --install all

echo Cleaning up old docker images... >&2
systemctl start docker-low-disk-gc.service

echo Restarting docker... >&2
systemctl restart docker
