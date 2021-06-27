Scripts to deploy Cassandra using replica 1 pools on OCS.
Prerequisites:
1. OCS is installed on the OCP cluster
2. The user has cluster-admin permissions


The script will do the following:
1. Create a StorageCluster with additional storageDeviceSets for replica 1 pools
2. Create replica 1 pools
3. Create a storageClass using the topologyConstrainedPool parameter that maps to
   the pools
4. Deploy Cassandra using the storageClass in the statefulSet.volumeClaimTemplate


