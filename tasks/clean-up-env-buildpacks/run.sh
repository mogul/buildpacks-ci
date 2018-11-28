#!/usr/bin/env bash
# shellcheck disable=SC2086

set -euo pipefail
if [ "$ALLOW_FAILURE" = true ] ; then #This script runs before and after deployment so if the env is not deployed yet this script can fail
  set +e
fi

set +x
eval "$(bbl --state-dir bbl-state/${ENV_NAME} print-env)"
cf_password=$(credhub get -n /bosh-${ENV_NAME}/cf/cf_admin_password -j | jq -r .value)

target="api.$ENV_NAME.buildpacks-gcp.ci.cf-app.com"

cf api "$target" --skip-ssl-validation || (sleep 4 && cf api "$target" --skip-ssl-validation)

cf auth admin "$cf_password" || (sleep 4 && cf auth admin "$cf_password")
set -x

# We don't have the hwc-buildpack in this list because cf-deployment installs it as nil-stack and we want to
# delete it here and replace it later.
custom_buildpacks=$(cf buildpacks | tail -n +4 | awk '{ print $1,$6 }' | grep -v 'apt_buildpack\|binary_buildpack\|credhub_buildpack\|dotnet_core_buildpack\|go_buildpack\|nginx_buildpack\|nodejs_buildpack\|php_buildpack\|python_buildpack\|r_buildpack\|ruby_buildpack\|staticfile_buildpack\|java_buildpack' | grep 'cflinuxfs2\|cflinuxfs3\|windows' || true)

echo "$custom_buildpacks" | while read -r bp_and_stack; do
  bp=$(echo $bp_and_stack | cut -d ' ' -f1)
  stack=$(echo $bp_and_stack | cut -d ' ' -f2)
  cf delete-buildpack "$bp" -s "$stack" -f
done

null_buildpacks=$(cf buildpacks | tail -n +4 | grep -v 'cflinuxfs2\|cflinuxfs3\|windows' | cut -d ' ' -f1 || true)

for bp in $null_buildpacks; do
  cf delete-buildpack "$bp" -f -s ""
done

if [ "$INSTALL_STACK_ASSOC_HWC_BPS" = true ] ; then
  for windows_stack in windows2012R2 windows2016 windows; do
    pushd hwc-buildpack
        export GOBIN=$PWD/.bin
        export PATH=$GOBIN:$PATH
       (go install github.com/cloudfoundry/libbuildpack/packager/buildpack-packager)

        buildpack-packager build -stack "$windows_stack"
        cf create-buildpack hwc_buildpack hwc_buildpack-*.zip 999
        rm hwc_buildpack-*.zip
    popd

    pushd binary-buildpack
        export GOPATH="$PWD"
        export GOBIN=$PWD/.bin
        export PATH=$GOBIN:$PATH
       (cd src/*/vendor/github.com/cloudfoundry/libbuildpack/packager/buildpack-packager && go install)

        buildpack-packager build -stack "$windows_stack"
        cf create-buildpack binary_buildpack binary_buildpack-*.zip 999 || cf update-buildpack binary_buildpack -p binary_buildpack-*.zip -s "$windows_stack" || true
        rm binary_buildpack-*.zip
    popd
  done
fi

