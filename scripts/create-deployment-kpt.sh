#!/usr/bin/env bash
# Copyright 2024 The Nephio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Stricter error handling
set -e # Exit on error
set -u # Must predefine variables
set -o pipefail # Check errors in piped commands

STARLARK_IMG="ghcr.io/kptdev/krm-functions-catalog/starlark:v0.5"
SEARCH_REPLACE_IMG="ghcr.io/kptdev/krm-functions-catalog/search-replace:v0.2"
PORCH_CACHE_TYPE="CR"

function error() {
  cat <<EOF
Error: ${1}
Usage: ${0} [flags]
Supported Flags:
  --destination DIRECTORY             ... directory in which the Porch kpt pkg will be downloaded to
  --server-image IMAGE                ... address of the Porch server image
  --controllers-image IMAGE           ... address of the Porch controllers image
  --function-image IMAGE              ... address of the Porch function runtime image
  --wrapper-server-image IMAGE        ... address of the Porch function wrapper server image
  --test-git-server-image             ... address of the test git server image
  --enabled-reconcilers RECONCILERS   ... comma-separated list of reconcilers that should be enabled in porch controller
EOF
  exit 1
}

# Flag variables
DESTINATION=""
IMAGE_REPO=""
IMAGE_TAG=""
ENABLED_RECONCILERS="packagevariants,packagevariantsets"
SERVER_IMAGE="ghcr.io/nxmatic/porch-server:v1.5.5"
CONTROLLERS_IMAGE="ghcr.io/nxmatic/porch-controllers:v1.5.5"
FUNCTION_IMAGE="ghcr.io/nxmatic/porch-function-runner:v1.5.5"
WRAPPER_SERVER_IMAGE="ghcr.io/nxmatic/porch-wrapper-server:v1.5.5"
TEST_GIT_SERVER_IMAGE="ghcr.io/nxmatic/test-git-server:v1.5.5"
KIND_CONTEXT_NAME="kind"
SKIP_KIND_LOAD="true"

while [[ $# -gt 0 ]]; do
  key="${1}"
  case "${key}" in
    --destination)
      DESTINATION="${2}"
      shift 2
    ;;

   --server-image)
      SERVER_IMAGE="${2}"
      shift 2
    ;;

    --controllers-image)
      CONTROLLERS_IMAGE="${2}"
      shift 2
    ;;

    --function-image)
      FUNCTION_IMAGE="${2}"
      shift 2
    ;;

    --wrapper-server-image)
      WRAPPER_SERVER_IMAGE="${2}"
      shift 2
    ;;

    --test-git-server-image)
      TEST_GIT_SERVER_IMAGE="${2}"
      shift 2
    ;;

    --enabled-reconcilers)
      ENABLED_RECONCILERS="${2}"
      shift 2
    ;;
    
    --kind-context)
      KIND_CONTEXT_NAME="${2}"
      shift 2
    ;;

    --skip-kind-load)
      SKIP_KIND_LOAD="${2}"
      shift 2
    ;;

    *)
      error "Invalid argument: ${key}"
    ;;
  esac
done


function validate() {
  yq -v &> /dev/null            || error "'yq' command must be installed"
  [ -n "${DESTINATION}"       ] || error "--destination is required"
  [ -n "${SERVER_IMAGE}"      ] || error "--server-image is required"
  [ -n "${CONTROLLERS_IMAGE}" ] || error "--controllers-image is required"
  [ -n "${FUNCTION_IMAGE}"    ] || error "--function-image is required"
  [ -n "${WRAPPER_SERVER_IMAGE}"    ] || error "--wrapper-server-image is required"
}


function customize-pkg-images {
  kpt fn eval "${DESTINATION}" --image ${SEARCH_REPLACE_IMG} -- by-value-regex="${1}" put-value="${2}"
}

function deploy-gitea-dev-pkg {
	cp -R ./test/pkgs/gitea-dev "${DESTINATION}"
  kpt fn render ${DESTINATION}/gitea-dev
  kpt live init ${DESTINATION}/gitea-dev
  kpt live apply ${DESTINATION}/gitea-dev
}

function deploy-porch-dev-pkg {
  # Render the package locally (no live apply)
  kpt fn render ${DESTINATION}/porch
  echo "Rendered porch package to ${DESTINATION}/porch (live apply skipped)."
}

function configure-porch-cache-cr {
  local pkg="${DESTINATION}/porch"

  # Set ConfigMap cache type
  kpt fn eval ${pkg} \
    --image ${SEARCH_REPLACE_IMG} \
    --match-kind ConfigMap \
    --match-name porch-config \
    --match-namespace porch-system \
    -- by-path=data.cache-type put-value="${PORCH_CACHE_TYPE}"

  # Remove postgres wiring and force CR cache args
  kpt fn eval ${pkg} \
    --image ${STARLARK_IMG} \
    --match-kind Deployment \
    --match-name porch-server \
    --match-namespace porch-system \
    -- "source=
for resource in ctx.resource_list['items']:
    podspec = resource['spec']['template']['spec']

    # Remove wait-for-postgres initContainer
    if 'initContainers' in podspec:
        new_init = [c for c in podspec['initContainers'] if c.get('name') != 'wait-for-postgres']
        if new_init:
            podspec['initContainers'] = new_init
        else:
            podspec.pop('initContainers')

    # Update containers
    for container in podspec.get('containers', []):
        if 'envFrom' in container:
            container['envFrom'] = []

        args = container.get('args', [])
        for i, arg in enumerate(args):
            if arg.startswith('--cache-type='):
                args[i] = '--cache-type=cr'
"

  # Drop bundled postgres bits if present
  rm -f ${pkg}/*porch-postgres*.yaml 2>/dev/null || true
}

function load-custom-images {
  kind load docker-image ${SERVER_IMAGE} -n ${KIND_CONTEXT_NAME}
	kind load docker-image ${CONTROLLERS_IMAGE} -n ${KIND_CONTEXT_NAME}
	kind load docker-image ${FUNCTION_IMAGE} -n ${KIND_CONTEXT_NAME}
	kind load docker-image ${WRAPPER_SERVER_IMAGE} -n ${KIND_CONTEXT_NAME}
  kind load docker-image ${TEST_GIT_SERVER_IMAGE} -n ${KIND_CONTEXT_NAME}
}

function main() {
  if [[ "${SKIP_KIND_LOAD}" != "true" ]]; then
    echo "Loading images into kind cluster ${KIND_CONTEXT_NAME}..."
    load-custom-images
  else
    echo "Skipping kind image load (generation-only mode)."
  fi

  echo "Preparing porch kpt package in ${DESTINATION}..."
  rm -rf ${DESTINATION}/porch || true
  kpt pkg get https://github.com/nephio-project/catalog/tree/main/nephio/core/porch ${DESTINATION}
  kpt fn eval ${DESTINATION}/porch \
    --image ${STARLARK_IMG} \
    --match-kind Deployment \
    --match-name porch-controllers \
    --match-namespace porch-system \
    -- "reconcilers=$ENABLED_RECONCILERS" 'source=
reconcilers = ctx.resource_list["functionConfig"]["data"]["reconcilers"].split(",")
for resource in ctx.resource_list["items"]:
  c = resource["spec"]["template"]["spec"]["containers"][0]
  c["env"] = []
  for r in reconcilers:
    c["env"].append({"name": "ENABLE_" + r.upper(), "value": "true"})
'

  configure-porch-cache-cr

  customize-pkg-images \
  "docker.io/nephio/porch-server:(latest|v2\.0\.0)" \
  "${SERVER_IMAGE}"

  customize-pkg-images \
  "docker.io/nephio/porch-controllers:(latest|v2\.0\.0)" \
  "${CONTROLLERS_IMAGE}"

  customize-pkg-images \
  "docker.io/nephio/porch-function-runner:(latest|v2\.0\.0)" \
  "${FUNCTION_IMAGE}"

  customize-pkg-images \
  "docker.io/nephio/porch-wrapper-server:(latest|v2\.0\.0)" \
  "${WRAPPER_SERVER_IMAGE}"

  echo "Rendering porch package with newly built images (no live apply)..."
  deploy-porch-dev-pkg

  echo
  echo Done.
  echo
}

validate
main
