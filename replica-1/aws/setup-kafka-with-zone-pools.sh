#!/bin/bash

# Prerequisites:
# An OCP cluster with OCS 4.9 installed
# The Red Hat AMQ Streams Operator must be installed


DEFAULT_SC=gp2
OCS_STORAGECLASS=my-storageclass
REGION=us-east-2




function usage {
    programname=$0

    echo "usage: $programname deploy|clean|help"
    echo "  deploy      deploy OCS and Kafka"
    echo "  cleanup     remove OCS and Kafka"
    echo "  help        display help"
    exit 1
}


function prereq_check {

  _=$(command -v oc);
  if [ "$?" != "0" ]; then
	  printf "You don\'t seem to have oc installed.\n"
      printf "Exiting with code 127...\n"
      exit 127;
  fi;

  sub=$(oc get subs -n openshift-storage --ignore-not-found --no-headers -o custom-columns=":metadata.name")
  if [[ -z "$sub" ]]; then
		printf "The OCS Operator is not installed on the OCP cluster\n"
		exit 127
  fi

  sub=$(oc get subs -n openshift-operators --ignore-not-found --no-headers -o custom-columns=":metadata.name" | grep amq-streams)
  if [[ -z "$sub" ]]; then
		printf -- "The AMQ Streams Operator is not installed on the OCP cluster\n"
		exit 127
  fi
  echo "All done!"
}


function ocs_label_nodes {
printf "Labeling nodes for Openshift Storage\n"

    for i in $(oc get nodes |grep worker|awk '{print $1}') ;
    do  
        oc label nodes "$i" cluster.ocs.openshift.io/openshift-storage=''
    done
}


# Create a StorageCluster with additional OSDs for the replica 1 pools

function ocs_create_storagecluster {

printf "Creating StorageCluster\n"

cat <<EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  namespace: openshift-storage
  name: ocs-storagecluster
spec:
  manageNodes: false
  multiCloudGateway:
    reconcileStrategy: ignore
  monPVCTemplate:
    spec:
      storageClassName: "$DEFAULT_SC"
      accessModes:
      - ReadWriteOnce
      resources:
        requests:
          storage: 30Gi
  storageDeviceSets:
  - name: r0-deviceset
    count: 1
    deviceClass: rep0
    dataPVCTemplate:
      spec:
        storageClassName: "$DEFAULT_SC"
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
        resources:
          requests:
            storage: 100Gi
    portable: true
    placement: 
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: Exists
            - key: topology.kubernetes.io/zone 
              operator: In
              values:
               - "${REGION}a"
    preparePlacement:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: Exists
            - key: topology.kubernetes.io/zone 
              operator: In
              values:
               - "${REGION}a"
    replica: 1 
  - name: r1-deviceset
    count: 1
    deviceClass: rep1
    dataPVCTemplate:
      spec:
        storageClassName: "$DEFAULT_SC"
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
        resources:
          requests:
            storage: 100Gi
    portable: true
    placement: 
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: Exists
            - key: topology.kubernetes.io/zone 
              operator: In
              values:
               - "${REGION}b"
    preparePlacement:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: Exists
            - key: topology.kubernetes.io/zone 
              operator: In
              values:
               - "${REGION}b"
    replica: 1 
  - name: r2-deviceset
    count: 1
    deviceClass: rep2
    dataPVCTemplate:
      spec:
        storageClassName: "$DEFAULT_SC"
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
        resources:
          requests:
            storage: 100Gi
    portable: true
    placement: 
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: Exists
            - key: topology.kubernetes.io/zone 
              operator: In
              values:
               - "${REGION}c"
    preparePlacement:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
          - matchExpressions:
            - key: cluster.ocs.openshift.io/openshift-storage
              operator: Exists
            - key: topology.kubernetes.io/zone 
              operator: In
              values:
               - "${REGION}c"
    replica: 1 
  - name: ocs-deviceset
    count: 1
    deviceClass: std
    dataPVCTemplate:
      spec:
        storageClassName: "$DEFAULT_SC"
        accessModes:
        - ReadWriteOnce
        volumeMode: Block
        resources:
          requests:
            storage: 512Gi
    portable: true
    replica: 3
EOF

}

function ocs_wait_storagecluster_ready { 

	oc wait storagecluster/ocs-storagecluster --for=condition=Available --timeout=300s -n openshift-storage

    status=$(oc get storagecluster ocs-storagecluster -o jsonpath='{ .status.phase }') 
	if [[ "$status" != "Ready" ]]; then
    	printf "The Storage Cluster is not ready. Exiting\n"
		exit 1
	fi
}



function ocs_create_replica1_pools {

printf "Creating OCS replica 1 pools\n"

cat <<EOF | oc apply -f -
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: rpool-0
  namespace: openshift-storage
spec:
  compressionMode: ""
  crushRoot: ""
  deviceClass: "rep0"
  enableRBDStats: false
  erasureCoded:
    codingChunks: 0
    dataChunks: 0
  failureDomain: host 
  mirroring: {}
  parameters:
    compression_mode: ""
  replicated:
    requireSafeReplicaSize: false
    size: 1
    targetSizeRatio: 0
  statusCheck:
    mirror: {}
EOF

cat <<EOF | oc apply -f -
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: rpool-1
  namespace: openshift-storage
spec:
  compressionMode: ""
  crushRoot: ""
  deviceClass: "rep1"
  enableRBDStats: false
  erasureCoded:
    codingChunks: 0
    dataChunks: 0
  failureDomain: host 
  mirroring: {}
  parameters:
    compression_mode: ""
  replicated:
    requireSafeReplicaSize: false
    size: 1
    targetSizeRatio: 0
  statusCheck:
    mirror: {}
EOF

cat <<EOF | oc apply -f -
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: rpool-2
  namespace: openshift-storage
spec:
  compressionMode: ""
  crushRoot: ""
  deviceClass: "rep2"
  enableRBDStats: false
  erasureCoded:
    codingChunks: 0
    dataChunks: 0
  failureDomain: host 
  mirroring: {}
  parameters:
    compression_mode: ""
  replicated:
    requireSafeReplicaSize: false
    size: 1
    targetSizeRatio: 0
  statusCheck:
    mirror: {}
EOF

}


function ocs_create_replica1_storageclasses {

# The regions used here are for my AWS cluster.
# Please change to the values your cluster

printf "Creating storageclasses\n"

cat <<EOF | oc apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: "$OCS_STORAGECLASS-zone-a"
parameters:
  clusterID: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/fstype: ext4
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  imageFeatures: layering
  imageFormat: "2" 
  pool: rpool-0
provisioner: openshift-storage.rbd.csi.ceph.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values:
    - "${REGION}a"
EOF

cat <<EOF | oc apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: "$OCS_STORAGECLASS-zone-b"
parameters:
  clusterID: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/fstype: ext4
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  imageFeatures: layering
  imageFormat: "2" 
  pool: rpool-1
provisioner: openshift-storage.rbd.csi.ceph.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values:
    - "${REGION}b"
EOF

cat <<EOF | oc apply -f -
allowVolumeExpansion: true
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: "$OCS_STORAGECLASS-zone-c"
parameters:
  clusterID: openshift-storage
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: openshift-storage
  csi.storage.k8s.io/fstype: ext4
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: openshift-storage
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: openshift-storage
  imageFeatures: layering
  imageFormat: "2" 
  pool: rpool-2
provisioner: openshift-storage.rbd.csi.ceph.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowedTopologies:
- matchLabelExpressions:
  - key: topology.kubernetes.io/zone
    values:
    - "${REGION}c"
EOF
}


function setup_ocs {
  oc project openshift-storage
  ocs_label_nodes
  ocs_create_storagecluster
  ocs_wait_storagecluster_ready
  ocs_create_replica1_pools
  ocs_create_replica1_storageclasses
}



function setup_kafka {
	oc new-project kafka
 
cat <<EOF | oc apply -f -
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-kafka-cluster
  namespace: kafka
spec:
  kafka:
    version: 2.7.0
    replicas: 3
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
      - name: external
        port: 9094
        type: nodeport
        tls: false
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      log.message.format.version: "2.7"
      inter.broker.protocol.version: "2.7"
    storage:
      type: jbod
      volumes:
      - id: 0
        type: persistent-claim
        size: 50Gi
        deleteClaim: false
        overrides:
          - broker: 0
            class: "$OCS_STORAGECLASS-zone-a"
          - broker: 1
            class: "$OCS_STORAGECLASS-zone-b"
          - broker: 2
            class: "$OCS_STORAGECLASS-zone-c"
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 10Gi
      deleteClaim: false
      class: "$DEFAULT_SC"
  entityOperator:
    topicOperator: {}
    userOperator: {}
EOF

}


function teardown_kafka {

	oc delete kafka my-kafka-cluster -n kafka
	for i in {0..2}; 
	do
		oc -n kafka delete pvc data-0-my-kafka-cluster-kafka-$i
		oc -n kafka delete pvc data-my-kafka-cluster-zookeeper-$i
	done
	oc delete ns kafka
}


function teardown_ocs {
	oc delete storageclass "$OCS_STORAGECLASS-zone-a"
	oc delete storageclass "$OCS_STORAGECLASS-zone-b"
	oc delete storageclass "$OCS_STORAGECLASS-zone-c"
	oc delete cephblockpool rpool-0 -n openshift-storage
	oc delete cephblockpool rpool-1 -n openshift-storage
	oc delete cephblockpool rpool-2 -n openshift-storage
	oc delete storagecluster ocs-storagecluster -n openshift-storage
}

function cleanup {
	teardown_kafka
	teardown_ocs
}

prereq_check

case $1 in
    deploy) deploy=true ;;
    cleanup) cleanup=true ;;
    help) usage;;
    *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
esac


if [ "$deploy" = true ]; then
	printf "Deploying OCS and Storage CLuster and Kafka Cluster!\n"
	setup_ocs
	setup_kafka
	exit
fi

if [ "$cleanup" = true ]; then
	printf "Cleanup!\n"
	cleanup
fi

printf "Done!\n"
exit
