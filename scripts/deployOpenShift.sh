#!/bin/bash

echo $(date) " - Starting Script"

set -e

export SUDOUSER=$1
export PASSWORD="$2"
export PRIVATEKEY=$3
export MASTER=$4
export MASTERPUBLICIPHOSTNAME=$5
export MASTERPUBLICIPADDRESS=$6
export INFRA=$7
export NODE=$8
export NODECOUNT=$9
export INFRACOUNT=${10}
export MASTERCOUNT=${11}
export ROUTING=${12}
export REGISTRYSA=${13}
export ACCOUNTKEY="${14}"
export TENANTID=${15}
export SUBSCRIPTIONID=${16}
export AADCLIENTID=${17}
export AADCLIENTSECRET="${18}"
export RESOURCEGROUP=${19}
export LOCATION=${20}
export METRICS=${21}
export LOGGING=${22}
export AZURE=${23}
export STORAGEKIND=${24}
export ENABLECNS=${25}
export CNS=${26}
export CNSCOUNT=${27}
export VNETNAME=${28}
export NODENSG=${29}
export NODEAVAILIBILITYSET=${30}

echo "SUDOUSER=$1"
echo "PASSWORD=$2"
echo "PRIVATEKEY=$3"
echo "MASTER=$4"
echo "MASTERPUBLICIPHOSTNAME=$5"
echo "MASTERPUBLICIPADDRESS=$6"
echo "INFRA=$7"
echo "NODE=$8"
echo "NODECOUNT=$9"
echo "INFRACOUNT=${10}"
echo "MASTERCOUNT=${11}"
echo "ROUTING=${12}"
echo "REGISTRYSA=${13}"
echo "ACCOUNTKEY=${14}"
echo "TENANTID=${15}"
echo "SUBSCRIPTIONID=${16}"
echo "AADCLIENTID=${17}"
echo "AADCLIENTSECRET=${18}"
echo "RESOURCEGROUP=${19}"
echo "LOCATION=${20}"
echo "METRICS=${21}"
echo "LOGGING=${22}"
echo "AZURE=${23}"
echo "STORAGEKIND=${24}"
echo "VNETNAME=${25}"
echo "NODENSG=${26}"
echo "NODEAVAILIBILITYSET=${27}"

# Set CNS to default storage type.  Will be overridden later if Azure is true
export CNS_DEFAULT_STORAGE=true

# Determine if Commercial Azure or Azure Government
CLOUD=$( curl -H Metadata:true "http://169.254.169.254/metadata/instance/compute/location?api-version=2017-04-02&format=text" | cut -c 1-2 )
export CLOUD=${CLOUD^^}

export MASTERLOOP=$((MASTERCOUNT - 1))
export INFRALOOP=$((INFRACOUNT - 1))
export NODELOOP=$((NODECOUNT - 1))

# Generate private keys for use by Ansible
echo $(date) " - Generating Private keys for use by Ansible for OpenShift Installation"

runuser -l $SUDOUSER -c "echo \"$PRIVATEKEY\" > ~/.ssh/id_rsa"
runuser -l $SUDOUSER -c "chmod 600 ~/.ssh/id_rsa*"

echo $(date) "- Configuring SSH ControlPath to use shorter path name"

sed -i -e "s/^# control_path = %(directory)s\/%%h-%%r/control_path = %(directory)s\/%%h-%%r/" /etc/ansible/ansible.cfg
sed -i -e "s/^#host_key_checking = False/host_key_checking = False/" /etc/ansible/ansible.cfg
sed -i -e "s/^#pty=False/pty=False/" /etc/ansible/ansible.cfg
sed -i -e "s/^#stdout_callback = skippy/stdout_callback = skippy/" /etc/ansible/ansible.cfg

# Create docker registry config based on Commercial Azure or Azure Government
if [[ $CLOUD == "US" ]]
then
  DOCKERREGISTRYYAML=dockerregistrygov.yaml
  export CLOUDNAME="AzureUSGovernmentCloud"
else
  DOCKERREGISTRYYAML=dockerregistrypublic.yaml
  export CLOUDNAME="AzurePublicCloud"
fi

# Setting the default openshift_cloudprovider_kind if Azure enabled
if [[ $AZURE == "true" ]]
then
    CLOUDKIND="openshift_cloudprovider_kind=azure
openshift_cloudprovider_azure_client_id=$AADCLIENTID
openshift_cloudprovider_azure_client_secret=$AADCLIENTSECRET
openshift_cloudprovider_azure_tenant_id=$TENANTID
openshift_cloudprovider_azure_subscription_id=$SUBSCRIPTIONID
openshift_cloudprovider_azure_cloud=$CLOUDNAME
openshift_cloudprovider_azure_vnet_name=$VNETNAME
openshift_cloudprovider_azure_security_group_name=$NODENSG
openshift_cloudprovider_azure_availability_set_name=$NODEAVAILIBILITYSET
openshift_cloudprovider_azure_resource_group=$RESOURCEGROUP
openshift_cloudprovider_azure_location=$LOCATION"
	CNS_DEFAULT_STORAGE=false
	if [[ $STORAGEKIND == "managed" ]]
	then
		SCKIND="openshift_storageclass_parameters={'kind': 'managed', 'storageaccounttype': 'Premium_LRS'}"
	else
		SCKIND="openshift_storageclass_parameters={'kind': 'shared', 'storageaccounttype': 'Premium_LRS'}"
	fi
fi

# Cloning Ansible playbook repository
(cd /home/$SUDOUSER && git clone https://github.com/Microsoft/openshift-container-platform-playbooks.git)
if [ -d /home/${SUDOUSER}/openshift-container-platform-playbooks ]
then
  chmod -R 777 /home/$SUDOUSER/openshift-container-platform-playbooks
  echo " - Retrieved playbooks successfully"
else
  echo " - Retrieval of playbooks failed"
  exit 99
fi

# Create playbook to update ansible.cfg file

cat > updateansiblecfg.yaml <<EOF
#!/usr/bin/ansible-playbook

- hosts: localhost
  gather_facts: no
  tasks:
  - lineinfile:
      dest: /etc/ansible/ansible.cfg
      regexp: '^library '
      insertafter: '#library        = /usr/share/my_modules/'
      line: 'library = /home/${SUDOUSER}/openshift-ansible/roles/lib_utils/library/'
EOF

# Run Ansible Playbook to update ansible.cfg file

echo $(date) " - Updating ansible.cfg file"

ansible-playbook ./updateansiblecfg.yaml

# Create Master nodes grouping
echo $(date) " - Creating Master nodes grouping"

for (( c=0; c<$MASTERCOUNT; c++ ))
do
  mastergroup="$mastergroup
$MASTER-$c openshift_node_group_name='node-config-master'"
done

# Create Infra nodes grouping 
echo $(date) " - Creating Infra nodes grouping"

for (( c=0; c<$INFRACOUNT; c++ ))
do
  infragroup="$infragroup
$INFRA-$c openshift_node_group_name='node-config-infra'"
done

# Create Nodes grouping
echo $(date) " - Creating Nodes grouping"

for (( c=0; c<$NODECOUNT; c++ ))
do
  nodegroup="$nodegroup
$NODE-$c openshift_node_group_name='node-config-compute'"
done

# Set HA mode if 3 or 5 masters chosen
if [[ $MASTERCOUNT != 1 ]]
then
	export HAMODE="openshift_master_cluster_method=native"
fi

# Create CNS nodes grouping if CNS is enabled
if [ $ENABLECNS == "true" ]
then
    echo $(date) " - Creating CNS nodes grouping"

    for (( c=0; c<$CNSCOUNT; c++ ))
    do
        cnsgroup="$cnsgroup
$CNS-$c openshift_hostname=$CNS-$c openshift_node_group_name='node-config-compute'"
    done
fi

# Create glusterfs configuration if CNS is enabled
if [ $ENABLECNS == "true" ]
then
    echo $(date) " - Creating glusterfs configuration"

    for (( c=0; c<$CNSCOUNT; c++ ))
    do
        runuser $SUDOUSER -c "ssh-keyscan -H $CNS-$c >> ~/.ssh/known_hosts"
        drive=$(runuser $SUDOUSER -c "ssh $CNS-$c 'sudo /usr/sbin/fdisk -l'" | awk '$1 == "Disk" && $2 ~ /^\// && ! /mapper/ {if (drive) print drive; drive = $2; sub(":", "", drive);} drive && /^\// {drive = ""} END {if (drive) print drive;}')
        drive1=$(echo $drive | cut -d ' ' -f 1)
        drive2=$(echo $drive | cut -d ' ' -f 2)
        drive3=$(echo $drive | cut -d ' ' -f 3)
        cnsglusterinfo="$cnsglusterinfo
$CNS-$c glusterfs_devices='[ \"${drive1}\", \"${drive2}\", \"${drive3}\" ]'"
    done
fi

# Create Ansible Hosts File
echo $(date) " - Create Ansible Hosts file"

cat > /etc/ansible/hosts <<EOF
# Create an OSEv3 group that contains the masters and nodes groups
[OSEv3:children]
masters
nodes
etcd
master0
glusterfs
new_nodes

# Set variables common for all OSEv3 hosts
[OSEv3:vars]
ansible_ssh_user=$SUDOUSER
ansible_become=yes
openshift_install_examples=true
openshift_deployment_type=origin
openshift_release=v3.11
docker_udev_workaround=True
openshift_use_dnsmasq=True
openshift_master_default_subdomain=$ROUTING
openshift_override_hostname_check=true
os_sdn_network_plugin_name='redhat/openshift-ovs-multitenant'
openshift_master_api_port=443
openshift_master_console_port=443
# ist in 3.11 anders: 
#osm_default_node_selector='region=app'
osm_default_node_selector='node-role.kubernetes.io/compute=true'
openshift_disable_check=disk_availability,memory_availability,docker_image_availability

$CLOUDKIND

# default selectors for router and registry services
#openshift_router_selector='region=infra'
#openshift_registry_selector='region=infra'
openshift_router_selector='node-role.kubernetes.io/infra=true'
openshift_registry_selector='node-role.kubernetes.io/infra=true'

$HAMODE
openshift_master_cluster_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_hostname=$MASTERPUBLICIPHOSTNAME
openshift_master_cluster_public_vip=$MASTERPUBLICIPADDRESS

# Enable HTPasswdPasswordIdentityProvider
# 3.11 filename entfernt
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider'}]

# Disable service catalog - Install after cluster is up if Azure Cloud Provider is enabled
openshift_enable_service_catalog=false

# Disable the OpenShift SDN plugin
# openshift_use_openshift_sdn=true

# Setup metrics
openshift_metrics_install_metrics=false
openshift_metrics_start_cluster=true
openshift_metrics_hawkular_nodeselector={"node-role.kubernetes.io/infra":"true"}
openshift_metrics_cassandra_nodeselector={"node-role.kubernetes.io/infra":"true"}
openshift_metrics_heapster_nodeselector={"node-role.kubernetes.io/infra":"true"}

# Setup logging
openshift_logging_install_logging=false
openshift_logging_fluentd_nodeselector={"logging":"true"}
openshift_logging_es_nodeselector={"node-role.kubernetes.io/infra":"true"}
openshift_logging_kibana_nodeselector={"node-role.kubernetes.io/infra":"true"}
openshift_logging_curator_nodeselector={"node-role.kubernetes.io/infra":"true"}
openshift_logging_master_public_url=https://$MASTERPUBLICIPHOSTNAME

# host group for masters
[masters]
$MASTER-[0:${MASTERLOOP}]

# host group for etcd
[etcd]
$MASTER-[0:${MASTERLOOP}]

[master0]
$MASTER-0

# Only populated when CNS is enabled
[glusterfs]
$cnsglusterinfo

# host group for nodes
[nodes]
$mastergroup
$infragroup
$nodegroup
$cnsgroup

# host group for new nodes
[new_nodes]
EOF

echo $(date) " - Cloning openshift-ansible repo for use in installation"

runuser -l $SUDOUSER -c "git clone -b release-3.11 https://github.com/openshift/openshift-ansible /home/$SUDOUSER/openshift-ansible"
chmod -R 777 /home/$SUDOUSER/openshift-ansible

# Run a loop playbook to ensure DNS Hostname resolution is working prior to continuing with script
echo $(date) " - Running DNS Hostname resolution check"
runuser -l $SUDOUSER -c "ansible-playbook ~/openshift-container-platform-playbooks/check-dns-host-name-resolution.yaml"
echo $(date) " - DNS Hostname resolution check complete"

# Setup NetworkManager to manage eth0
echo $(date) " - Setting up NetworkManager on eth0 (0)"
DOMAIN=`domainname -d`
DNSSERVER=`tail -1 /etc/resolv.conf | cut -d ' ' -f 2`

echo $(date) " - Setting up NetworkManager on eth0 (1)"
runuser -l $SUDOUSER -c "ansible-playbook -c paramiko /home/$SUDOUSER/openshift-ansible/playbooks/openshift-node/network_manager.yml"

sleep 10
echo $(date) " - Setting up NetworkManager on eth0 (2)"
runuser -l $SUDOUSER -c "ansible all -c paramiko -b -o -m service -a \"name=NetworkManager state=restarted\""
sleep 10
echo $(date) " - Setting up NetworkManager on eth0 (3)"
runuser -l $SUDOUSER -c "ansible all -c paramiko -b -o -m command -a \"nmcli con modify eth0 ipv4.dns-search $DOMAIN, ipv4.dns $DNSSERVER\""
echo $(date) " - Setting up NetworkManager on eth0 (4)"
runuser -l $SUDOUSER -c "ansible all -c paramiko -b -o -m service -a \"name=NetworkManager state=restarted\""
echo $(date) " - NetworkManager configuration complete"

# Initiating installation of OpenShift Origin prerequisites using Ansible Playbook
echo $(date) " - Running Prerequisites via Ansible Playbook"
runuser -l $SUDOUSER -c "ansible-playbook -f 10 /home/$SUDOUSER/openshift-ansible/playbooks/prerequisites.yml"
echo $(date) " - Prerequisites check complete"

# Initiating installation of OpenShift Origin using Ansible Playbook
echo $(date) " - Installing OpenShift Container Platform via Ansible Playbook"

runuser -l $SUDOUSER -c "ansible-playbook /home/$SUDOUSER/openshift-ansible/playbooks/deploy_cluster.yml"
echo $(date) " - OpenShift Origin Cluster install complete"
echo $(date) " - Running additional playbooks to finish configuring and installing other components"

echo $(date) " - Modifying sudoers"

sed -i -e "s/Defaults    requiretty/# Defaults    requiretty/" /etc/sudoers
sed -i -e '/Defaults    env_keep += "LC_TIME LC_ALL LANGUAGE LINGUAS _XKB_CHARSET XAUTHORITY"/aDefaults    env_keep += "PATH"' /etc/sudoers

echo $(date) "- Re-enabling requiretty"

sed -i -e "s/# Defaults    requiretty/Defaults    requiretty/" /etc/sudoers

# Adding user to OpenShift authentication file
echo $(date) "- Adding OpenShift user"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/addocpuser.yaml"

# Assigning cluster admin rights to OpenShift user
echo $(date) "- Assigning cluster admin rights to user"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/assignclusteradminrights.yaml"

# Configure Docker Registry to use Azure Storage Account
echo $(date) "- Configuring Docker Registry to use Azure Storage Account"

runuser $SUDOUSER -c "ansible-playbook -f 10 ~/openshift-container-platform-playbooks/$DOCKERREGISTRYYAML"

# Reconfigure glusterfs storage class
if [ $CNS_DEFAULT_STORAGE == "true" ]
then
    echo $(date) "- Create default glusterfs storage class"
    cat > /home/$SUDOUSER/default-glusterfs-storage.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "$CNS_DEFAULT_STORAGE"
  name: default-glusterfs-storage
parameters:
  resturl: http://heketi-storage-glusterfs.${ROUTING}
  restuser: admin
  secretName: heketi-storage-admin-secret
  secretNamespace: glusterfs
provisioner: kubernetes.io/glusterfs
reclaimPolicy: Delete
EOF
    runuser -l $SUDOUSER -c "oc create -f /home/$SUDOUSER/default-glusterfs-storage.yaml"

    echo $(date) " - Sleep for 10"
    sleep 10
fi

# Ensuring selinux is configured properly
if [ $ENABLECNS == "true" ]
then
    # Setting selinux to allow gluster-fusefs access
    echo $(date) " - Setting selinux to allow gluster-fuse access"
    runuser -l $SUDOUSER -c "ansible all -o -f 30 -b -a 'sudo setsebool -P virt_sandbox_use_fusefs on'" || true
# End of CNS specific section
fi

# Installing Service Catalog, Ansible Service Broker and Template Service Broker
if [[ $AZURE == "true" || $ENABLECNS == "true" ]]
then
    runuser -l $SUDOUSER -c "ansible-playbook -e openshift_cloudprovider_azure_client_id=$AADCLIENTID -e openshift_cloudprovider_azure_client_secret=\"$AADCLIENTSECRET\" -e openshift_cloudprovider_azure_tenant_id=$TENANTID -e openshift_cloudprovider_azure_subscription_id=$SUBSCRIPTIONID -e openshift_enable_service_catalog=true -f 30 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-service-catalog/config.yml"
fi

# Adding Open Sevice Broker for Azaure (requires service catalog)
if [[ $AZURE == "true" ]]
then
    oc new-project osba
    oc process -f https://raw.githubusercontent.com/Azure/open-service-broker-azure/master/contrib/openshift/osba-os-template.yaml  \
        -p ENVIRONMENT=AzurePublicCloud \
        -p AZURE_SUBSCRIPTION_ID=$SUBSCRIPTIONID \
        -p AZURE_TENANT_ID=$TENANTID \
        -p AZURE_CLIENT_ID=$AADCLIENTID \
        -p AZURE_CLIENT_SECRET=$AADCLIENTSECRET \
        | oc create -f -
fi

# Configure Metrics

if [ $METRICS == "true" ]
then
    sleep 30
    echo $(date) "- Deploying Metrics"
    if [[ $AZURE == "true" || $ENABLECNS == "true" ]]
    then
        runuser -l $SUDOUSER -c "ansible-playbook -e openshift_cloudprovider_azure_client_id=$AADCLIENTID -e openshift_cloudprovider_azure_client_secret=\"$AADCLIENTSECRET\" -e openshift_cloudprovider_azure_tenant_id=$TENANTID -e openshift_cloudprovider_azure_subscription_id=$SUBSCRIPTIONID -e openshift_metrics_install_metrics=True -e openshift_metrics_cassandra_storage_type=dynamic -f 30 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-metrics/config.yml"
    else
        runuser -l $SUDOUSER -c "ansible-playbook -e openshift_metrics_install_metrics=True /home/$SUDOUSER/openshift-ansible/playbooks/openshift-metrics/config.yml"
    fi
    if [ $? -eq 0 ]
    then
        echo $(date) " - Metrics configuration completed successfully"
    else
        echo $(date) " - Metrics configuration failed"
        exit 11
    fi
fi

# Configure Logging

if [ $LOGGING == "true" ]
then
    sleep 60
    echo $(date) "- Deploying Logging"
    if [[ $AZURE == "true" || $ENABLECNS == "true" ]]
    then
        runuser -l $SUDOUSER -c "ansible-playbook -e openshift_cloudprovider_azure_client_id=$AADCLIENTID -e openshift_cloudprovider_azure_client_secret=\"$AADCLIENTSECRET\" -e openshift_cloudprovider_azure_tenant_id=$TENANTID -e openshift_cloudprovider_azure_subscription_id=$SUBSCRIPTIONID -e openshift_logging_install_logging=True -e openshift_logging_es_pvc_dynamic=true -f 30 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-logging/config.yml"
    else
        runuser -l $SUDOUSER -c "ansible-playbook -e openshift_logging_install_logging=True -f 30 /home/$SUDOUSER/openshift-ansible/playbooks/openshift-logging/config.yml"
    fi
    if [ $? -eq 0 ]
    then
        echo $(date) " - Logging configuration completed successfully"
    else
        echo $(date) " - Logging configuration failed"
        exit 12
    fi
fi

# Delete yaml files
echo $(date) "- Deleting unecessary files"

rm -rf /home/${SUDOUSER}/openshift-container-platform-playbooks

echo $(date) "- Sleep for 30"

sleep 30

echo $(date) " - Script complete"
