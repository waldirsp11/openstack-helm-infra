#!/bin/bash

# Copyright 2017 The Openstack-Helm Authors.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

set -xe

#NOTE: Deploy command
[ -s /tmp/ceph-fs-uuid.txt ] || uuidgen > /tmp/ceph-fs-uuid.txt
CEPH_PUBLIC_NETWORK="$(./tools/deployment/multinode/kube-node-subnet.sh)"
CEPH_CLUSTER_NETWORK="$(./tools/deployment/multinode/kube-node-subnet.sh)"
CEPH_FS_ID="$(cat /tmp/ceph-fs-uuid.txt)"
#NOTE(portdirect): to use RBD devices with Ubuntu kernels < 4.5 this
# should be set to 'hammer'
. /etc/os-release
if [ "x${ID}" == "xubuntu" ] && \
   [ "$(uname -r | awk -F "." '{ print $2 }')" -lt "5" ]; then
  CRUSH_TUNABLES=hammer
else
  CRUSH_TUNABLES=null
fi
if [ "x${ID}" == "xcentos" ]; then
  CRUSH_TUNABLES=hammer
fi
tee /tmp/ceph.yaml << EOF
endpoints:
  ceph_mon:
    namespace: ceph
    port:
      mon:
        default: 6789
  ceph_mgr:
    namespace: ceph
    port:
      mgr:
        default: 7000
      metrics:
        default: 9283
network:
  public: ${CEPH_PUBLIC_NETWORK}
  cluster: ${CEPH_CLUSTER_NETWORK}
deployment:
  storage_secrets: true
  ceph: true
  rbd_provisioner: true
  cephfs_provisioner: true
  client_secrets: false
  rgw_keystone_user_and_endpoints: false
jobs:
  ceph_defragosds:
    # Execute every 15 minutes for gates
    cron: "*/15 * * * *"
    history:
      # Number of successful job to keep
      successJob: 1
      # Number of failed job to keep
      failJob: 1
    concurrency:
      # Skip new job if previous job still active
      execPolicy: Forbid
    startingDeadlineSecs: 60
manifests:
  deployment_mds: false
  cronjob_defragosds: true
bootstrap:
  enabled: true
conf:
  ceph:
    global:
      fsid: ${CEPH_FS_ID}
    mon:
      mon_clock_drift_allowed: 2.0
  rgw_ks:
    enabled: true
  pool:
    crush:
      tunables: ${CRUSH_TUNABLES}
    target:
      # NOTE(portdirect): 5 nodes, with one osd per node
      osd: 3
      pg_per_osd: 100
  storage:
    osd:
      - data:
          type: directory
          location: /var/lib/openstack-helm/ceph/osd/osd-one
        journal:
          type: directory
          location: /var/lib/openstack-helm/ceph/osd/journal-one
storageclass:
  rbd:
    ceph_configmap_name: ceph-etc
ceph_mgr_modules_config:
  prometheus:
    server_port: 9283
monitoring:
  prometheus:
    enabled: true
    ceph_mgr:
      port: 9283
EOF

for CHART in ceph-mon ceph-osd ceph-client ceph-provisioners; do
  helm upgrade --install ${CHART} ./${CHART} \
    --namespace=ceph \
    --values=/tmp/ceph.yaml \
    ${OSH_INFRA_EXTRA_HELM_ARGS} \
    ${OSH_INFRA_EXTRA_HELM_ARGS_CEPH_DEPLOY}

  #NOTE: Wait for deploy
  ./tools/deployment/common/wait-for-pods.sh ceph 1200

  #NOTE: Validate deploy
  MON_POD=$(kubectl get pods \
    --namespace=ceph \
    --selector="application=ceph" \
    --selector="component=mon" \
    --no-headers | awk '{ print $1; exit }')
  kubectl exec -n ceph ${MON_POD} -- ceph -s
done
helm test ceph-osd --timeout 900
helm test ceph-client --timeout 900
