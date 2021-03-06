#!/bin/bash

# Prerequisites:
# An OCP cluster with OCS 4.8  or later installed
# cluster-admin permissions


DEFAULT_SC=gp2
OCS_STORAGECLASS=my-storageclass
REGION=us-east-2

function usage {
    programname=$0

    echo "usage: $programname deploy|clean|help"
    echo "  deploy      deploy OCS and Cassandra"
    echo "  cleanup     remove OCS and Cassandra"
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
}


# Create a StorageCluster with additional OSDs for the replica 1 pools

function ocs_label_nodes {

	for i in $(oc get nodes |grep worker|awk '{print $1}') ;
	do
		oc label nodes "$i" cluster.ocs.openshift.io/openshift-storage=''
	done
}

function ocs_create_storagecluster {

printf "Creating StorageCluster with extra OSDs\n"

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
            storage: 50Gi
    portable: true
    replica: 1
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
            storage: 50Gi
    portable: true
    replica: 1
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
            storage: 50Gi
    portable: true
    replica: 1
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

printf "Creating replica 1 pools\n"

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


function ocs_create_replica1_storageclass {

# The regions here are for AWS. Please change to the correct values for your cluster
printf "Creating a topology constrained StorageClass mapping to the replica 1 pools\n"

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
  mapOptions: osd_request_timeout=60
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


function enable_csi_topology_feature {

	printf "Enabling the ceph-csi topology feature\n"
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
}


function setup_ocs {
  ocs_label_nodes
  oc project openshift-storage
  ocs_create_storagecluster
  ocs_wait_storagecluster_ready

  # Enable the topology feature after creating the StorageCluster as the ceph-csi pods are
  # not started until a StorageCluster is created
  enable_csi_topology_feature

  ocs_create_replica1_pools
  ocs_create_replica1_storageclass
}


# Deploy Cassandra with 3 replicas
# The other option is to install the DataStax operator which is available
# in the OperatorHub specifying the storageClass created earlier.

function setup_cassandra {

	printf "Setting up Cassandra to use the replica 1 pools\n"
	oc new-project cassandra

	oc project cassandra
	oc create serviceaccount useroot
	oc adm policy add-scc-to-user anyuid -z useroot

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  labels:
    app: cassandra
  name: cassandra
  namespace: cassandra
spec:
  clusterIP: None
  ports:
  - port: 9042
  selector:
    app: cassandra
EOF

cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: cassandra
  labels:
    app: cassandra
  namespace: cassandra
spec:
  serviceName: cassandra
  replicas: 3
  selector:
    matchLabels:
      app: cassandra
  template:
    metadata:
      labels:
        app: cassandra
    spec:
      terminationGracePeriodSeconds: 1800
      serviceAccountName: useroot
      containers:
      - name: cassandra
        image: cassandra:3.11
        imagePullPolicy: Always
        ports:
        - containerPort: 7000
          name: intra-node
        - containerPort: 7001
          name: tls-intra-node
        - containerPort: 7199
          name: jmx
        - containerPort: 9042
          name: cql
        resources:
          limits:
            cpu: "500m"
            memory: 2Gi
          requests:
            cpu: "500m"
            memory: 2Gi
        lifecycle:
          preStop:
            exec:
              command:
              - /bin/sh
              - -c
              - nodetool drain
        env:
          - name: MAX_HEAP_SIZE
            value: 512M
          - name: HEAP_NEWSIZE
            value: 100M
          - name: CASSANDRA_SEEDS
            value: "cassandra-0.cassandra.cassandra.svc.cluster.local"
          - name: CASSANDRA_CLUSTER_NAME
            value: "K8Demo"
          - name: CASSANDRA_DC
            value: "DC1-K8Demo"
          - name: CASSANDRA_RACK
            value: "Rack1-K8Demo"
          - name: POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
#        readinessProbe:
#          exec:
#            command:
#            - /bin/bash
#            - -c
#            - /ready-probe.sh
#         initialDelaySeconds: 15
#          timeoutSeconds: 5
        # These volume mounts are persistent. They are like inline claims,
        # but not exactly because the names need to match exactly one of
        # the stateful pod volumes.
        volumeMounts:
        - name: cassandra-data
          mountPath: /var/lib/cassandra
  updateStrategy:
    rollingUpdate:
      partition: 0
    type: RollingUpdate
  # These are converted to volume claims by the controller
  # and mounted at the paths mentioned above.
  volumeClaimTemplates:
  - metadata:
      name: cassandra-data
    spec:
      accessModes: [ "ReadWriteOnce" ]
      storageClassName: "$OCS_STORAGECLASS"
      resources:
        requests:
          storage: 5Gi
EOF

}

function cleanup_cassandra {

	oc delete statefulset cassandra -n cassandra
	oc delete service cassandra -n cassandra
	oc delete pvc cassandra-data-cassandra-0 -n cassandra
	oc delete pvc cassandra-data-cassandra-1 -n cassandra
	oc delete pvc cassandra-data-cassandra-2 -n cassandra

	for i in $(oc get pv |grep my-storageclass| awk '{print $1}'); do oc delete pv "$i"; done
}

function cleanup_ocs {

	oc delete storageclass "$OCS_STORAGECLASS"
	oc delete cephblockpool rpool-0 -n openshift-storage
	oc delete cephblockpool rpool-1 -n openshift-storage
	oc delete cephblockpool rpool-2 -n openshift-storage
	oc delete storagecluster ocs-storagecluster -n openshift-storage

}

function cleanup {

	printf "Cleaning up\n"
	cleanup_cassandra
	cleanup_ocs
}


prereq_check

case $1 in
    deploy) deploy=true ;;
    cleanup) cleanup=true ;;
    help) usage;;
    *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
esac


if [ "$deploy" = true ]; then
    printf "Deploying OCS and Storage Cluster and Cassandra Cluster!\n"
    setup_ocs
    setup_cassandra
    exit
fi

if [ "$cleanup" = true ]; then
    printf "Cleanup!\n"
    cleanup
fi


echo 'All Done!'

