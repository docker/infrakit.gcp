#!/bin/sh

set -e

export CLOUDSDK_CORE_PROJECT=code-story-blog
export CLOUDSDK_COMPUTE_ZONE=europe-west1-d

INFRAKIT_IMAGE=infrakit/devbundle:master-1041
GCLOUD="docker run -e CLOUDSDK_CORE_PROJECT --rm -v gcloud-config:/.config google/cloud-sdk gcloud"
TAG="ci-infrakit-${CIRCLE_BUILD_NUM:-local}"

cleanup() {
  echo Clean up

  docker rm -f flavor group instance-gcp 2>/dev/null || true
  docker volume rm infrakit 2>/dev/null || true
  docker volume rm gcloud-config 2>/dev/null || true
}

auth_gcloud() {
  echo Authenticate GCloud

  docker volume create --name gcloud-config
  docker run --rm -e GCLOUD_SERVICE_KEY -v gcloud-config:/.config google/cloud-sdk bash -c 'echo ${GCLOUD_SERVICE_KEY} | base64 --decode > /.config/key.json'
  docker run --rm -v gcloud-config:/.config google/cloud-sdk gcloud auth activate-service-account --key-file=/.config/key.json
}

remove_previous_instances() {
  echo Remove previous instances

  OLD=$(${GCLOUD} compute instances list --filter='tags.items ~ ci-infrakit' --uri)
  if [ -n "${OLD}" ]; then
    ${GCLOUD} compute instances delete -q --delete-disks=boot ${OLD}
  fi
}

run_infrakit() {
  echo Run Infrakit

  docker volume create --name infrakit

  run_plugin='docker run -d -v infrakit:/root/.infrakit/'

  $run_plugin --name=flavor ${INFRAKIT_IMAGE} infrakit-flavor-vanilla --log=5
  $run_plugin --name=group ${INFRAKIT_IMAGE} infrakit-group-default --name=group --log=5
}

build_infrakit_gcp() {
  echo Build Infrakit GCP Instance Plugin

  pushd ..
  DOCKER_PUSH=false DOCKER_TAG_LATEST=false DOCKER_BUILD_FLAGS="" make build-docker
  popd
}

run_infrakit_gcp() {
  echo Run Infrakit GCP Instance Plugin

  docker run -d --name=instance-gcp \
    -v infrakit:/root/.infrakit/ \
    -e CLOUDSDK_CORE_PROJECT \
    -e CLOUDSDK_COMPUTE_ZONE \
    -e GOOGLE_APPLICATION_CREDENTIALS=/key.json \
    -v $(pwd)/key.json:/key.json \
    infrakit/gcp:dev \
    infrakit-instance-gcp --log=5
}

create_group() {
  echo Create Instance Group

  docker_run="docker run --rm -v infrakit:/root/.infrakit/"
  docker cp nodes.json group:/root/.infrakit/
  $docker_run busybox sed -i.bak s/{{TAG}}/${TAG}/g /root/.infrakit/nodes.json
  $docker_run busybox cat /root/.infrakit/nodes.json
  $docker_run ${INFRAKIT_IMAGE} infrakit group commit /root/.infrakit/nodes.json
}

check_instances_created() {
  echo Check that the instances are there

  for i in $(seq 1 120); do
    COUNT=$(${GCLOUD} compute instances list --filter="tags.items ~ ${TAG}" --uri | wc -w | tr -d '[:space:]')

    if [ ${COUNT} -gt 2 ]; then
      echo "- ERROR: ${COUNT} instances where created"
      exit 1
    fi

    if [ ${COUNT} -eq 2 ]; then
      echo "- 2 instances where created"
      return
    fi

    echo "- ${COUNT} instances where created for now"
    docker logs --tail 1 group
    sleep 1
  done
}

destroy_group() {
  echo Destroy Instance Group

  docker run --rm -v infrakit:/root/.infrakit/ ${INFRAKIT_IMAGE} infrakit group destroy nodes
}

check_instances_gone() {
  echo Check that the instances are gone

  for i in $(seq 1 120); do
    COUNT=$(${GCLOUD} compute instances list --filter="tags.items ~ ${TAG}" --uri | wc -w | tr -d '[:space:]')

    if [ ${COUNT} -eq 0 ]; then
      echo "- All instances are gone"
      return
    fi

    echo "- ${COUNT} instances are still around"
  done
}

[ "${CI}" ] || cleanup
auth_gcloud
remove_previous_instances
run_infrakit
build_infrakit_gcp
run_infrakit_gcp
create_group
check_instances_created
destroy_group
check_instances_gone

exit 0
