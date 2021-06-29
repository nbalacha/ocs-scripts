#!/bin/bash

# Prerequisites:
# An OCP cluster with OCS 4.9 installed
# The Red Hat AMQ Streams Operator must be installed


DEFAULT_SC=gp2
OCS_STORAGECLASS=my-storageclass



function ocs_label_nodes {

    for i in $(oc get nodes |grep worker|awk '{print $1}') ;
    do  
        oc label nodes "$i" cluster.ocs.openshift.io/openshift-storage=''
    done
}


# Create a StorageCluster with additional OSDs for the replica 1 pools

function ocs_create_storagecluster () {

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

function ocs_check_storagecluster_ready () { 
	i=0
    printf "Waiting for the StorageCluster to be ready\n"

	while [[ $i -lt 10 ]]
	do
 	  status=$(oc get storagecluster ocs-storagecluster -o jsonpath='{ .status.phase }') 
  		if [[ "$status" = "Ready" ]]; then
    	  break
  		fi
	  printf "."
      sleep 30
      ((i++))
    done

	if [[ "$status" != "Ready" ]]; then
    	printf "The Storage Cluster is not ready. Exiting\n"
		exit 1
	fi
}



function ocs_create_replica1_pools () {

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


function ocs_create_replica1_storageclass () {

# The regions here are for AWS. Please change for your cluster

cat <<EOF | oc apply -f -
allowVolumeExpansion: false
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: "$OCS_STORAGECLASS"
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
  pool: ocs-storagecluster-cephblockpool
  topologyConstrainedPools: |
     [{"poolName":"rpool-0",
       "domainSegments":[
         {"domainLabel":"region","value":"us-east-2"},
         {"domainLabel":"zone","value":"us-east-2a"}]},
     {"poolName":"rpool-1",
       "domainSegments":[
         {"domainLabel":"region","value":"us-east-2"},
         {"domainLabel":"zone","value":"us-east-2b"}]},
     {"poolName":"rpool-2",
       "domainSegments":[
         {"domainLabel":"region","value":"us-east-2"},
         {"domainLabel":"zone","value":"us-east-2c"}]}
     ]   
provisioner: openshift-storage.rbd.csi.ceph.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
}


function ocs_enable_csi_topology_feature() {

	#Patch rbacs
	CLUSTER_ROLE1=$(kubectl get clusterrolebinding  -o custom-columns='NAME:roleRef.name,SERVICE_ACCOUNTS:subjects[?(@.kind=="ServiceAccount")].name' | grep "rook-csi-rbd-provisioner-sa" |awk '{print $1}')
	oc patch clusterrole "$CLUSTER_ROLE1" --type=json -p='[{"op": "add", "path": "/rules/-","value": {"apiGroups":[""],"resources":["nodes"],"verbs": ["get", "list", "watch"]}}]'
	oc patch clusterrole "$CLUSTER_ROLE1" --type=json -p='[{"op": "add", "path": "/rules/-","value": {"apiGroups":["storage.k8s.io"],"resources":["csinodes"],"verbs": ["get", "list", "watch"]}}]'


	CLUSTER_ROLE2=$(kubectl get clusterrolebinding  -o custom-columns='NAME:roleRef.name,SERVICE_ACCOUNTS:subjects[?(@.kind=="ServiceAccount")].name' | grep "rook-csi-rbd-plugin-sa" |awk '{print $1}')
	oc patch clusterrole "$CLUSTER_ROLE2" --type=json -p='[{"op": "add", "path": "/rules/-","value": {"apiGroups":[""],"resources":["nodes"],"verbs": ["get"]}}]'


	#Patch csi-rbdplugin-provisioner deployment
	INDEX1=$(oc get deployment csi-rbdplugin-provisioner -o json  | jq ' .spec.template.spec.containers | map(.name == "csi-provisioner") | index(true)')
	oc patch deployment csi-rbdplugin-provisioner --type=json -p='[{"op": "add", "path": '/spec/template/spec/containers/"$INDEX1"/args/-', "value": "--feature-gates=Topology=true" }]'

	#Patch csi-rbdplugin daemonset
	INDEX2=$(oc get daemonset csi-rbdplugin -o json  | jq ' .spec.template.spec.containers | map(.name == "csi-rbdplugin") | index(true)')
	oc patch daemonset csi-rbdplugin --type=json -p='[{"op": "add", "path": '/spec/template/spec/containers/"$INDEX2"/args/-', "value": "--domainlabels=topology.kubernetes.io/region,topology.kubernetes.io/zone" }]'
#	oc patch deployment csi-rbdplugin-provisioner --type=json -p='[{"op": "add", "path": "/spec/template/spec/containers/"$(INDEX2)"/args/-", "value": "--domainlabels=topology.kubernetes.io/region,topology.kubernetes.io/zone" }]'
}


function setup_ocs () {
  oc project openshift-storage
  ocs_label_nodes
  ocs_create_storagecluster
  ocs_check_storagecluster_ready

  # Enable the topology feature after creating the StorageCluster as the ceph-csi pods are
  # not started until a StorageCluster is created
  ocs_enable_csi_topology_feature

  ocs_create_replica1_pools
  ocs_create_replica1_storageclass
}



function setup_kafka () {
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
        size: 10Gi
        class: $OCS_STORAGECLASS
        deleteClaim: false
  zookeeper:
    replicas: 3
    storage:
      type: persistent-claim
      size: 10Gi
      deleteClaim: false
      class: $OCS_STORAGECLASS
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
}


function teardown_ocs {
	oc delete storageclass $OCS_STORAGECLASS
	oc delete cephblockpool rpool-0 -n openshift-storage
	oc delete cephblockpool rpool-1 -n openshift-storage
	oc delete cephblockpool rpool-2 -n openshift-storage
	oc delete storagecluster ocs-storagecluster -n openshift-storage
}

function cleanup () {
	teardown_kafka
	teardown_ocs
}

setup_ocs
setup_kafka

#cleanup

echo 'All Done!'

