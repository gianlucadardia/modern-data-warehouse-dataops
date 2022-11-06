#!/bin/bash

# Access granted under MIT Open Source License: https://en.wikipedia.org/wiki/MIT_License
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated 
# documentation files (the "Software"), to deal in the Software without restriction, including without limitation 
# the rights to use, copy, modify, merge, publish, distribute, sublicense, # and/or sell copies of the Software, 
# and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions 
# of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED 
# TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL 
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER 
# DEALINGS IN THE SOFTWARE.

#######################################################
# Deploys all necessary azure resources and stores
# configuration information in an .ENV file
#
# Prerequisites:
# - User is logged in to the azure cli
# - Correct Azure subscription is selected
#######################################################

set -o errexit
set -o pipefail
set -o nounset
# set -o xtrace # For debugging

. ./scripts/common.sh

###################
# REQUIRED ENV VARIABLES:
#
# PROJECT
# DEPLOYMENT_ID
# ENV_NAME
# AZURE_LOCATION
# AZURE_SUBSCRIPTION_ID
# SYNAPSE_SQL_PASSWORD
LOGFILE="/home/gdardia/deploy.log"

#####################
# DEPLOY ARM TEMPLATE

# Set account to where ARM template will be deployed to
echo "$0 - Deploying to Subscription: $AZURE_SUBSCRIPTION_ID" >> $LOGFILE	
az account set --subscription "$AZURE_SUBSCRIPTION_ID"

# Create resource group
resource_group_name="$PROJECT-$DEPLOYMENT_ID-$ENV_NAME-rg"
echo "$0 - Creating resource group: $resource_group_name" >> $LOGFILE
az group create --name "$resource_group_name" --location "$AZURE_LOCATION" --tags Environment="$ENV_NAME"

# By default, set all KeyVault permission to deployer
# Retrieve KeyVault User Id
kv_owner_object_id=$(az ad signed-in-user show --output json | jq -r '.id')


# Validate arm template

echo "$0 - Validating deployment" >> $LOGFILE
arm_output=$(az deployment group validate \
    --resource-group "$resource_group_name" \
    --template-file "./infrastructure/main.bicep" \
    --parameters @"./infrastructure/main.parameters.${ENV_NAME}.json" \
    --parameters project="${PROJECT}" keyvault_owner_object_id="${kv_owner_object_id}" deployment_id="${DEPLOYMENT_ID}" synapse_sqlpool_admin_password="${SYNAPSE_SQL_PASSWORD}" \
    --output json)

echo "$0 - Validating deployment..... DONE" >> $LOGFILE


# Deploy arm template
echo "$0 - Deploying resources into $resource_group_name" >> $LOGFILE
arm_output=$(az deployment group create \
    --resource-group "$resource_group_name" \
    --template-file "./infrastructure/main.bicep" \
    --parameters @"./infrastructure/main.parameters.${ENV_NAME}.json" \
    --parameters project="${PROJECT}" deployment_id="${DEPLOYMENT_ID}" keyvault_owner_object_id="${kv_owner_object_id}" synapse_sqlpool_admin_password="${SYNAPSE_SQL_PASSWORD}" \
    --output json)

echo "$0 - Deploying resources into $resource_group_name....... DONE" >> $LOGFILE

if [[ -z $arm_output ]]; then
    echo >&2 "ARM deployment failed."
    exit 1
fi


########################
# RETRIEVE KEYVAULT INFORMATION
echo "$0 - # RETRIEVE KEYVAULT INFORMATION" >> $LOGFILE

echo "$0 - Retrieving KeyVault information from the deployment." >> $LOGFILE

kv_name=$(echo "$arm_output" | jq -r '.properties.outputs.keyvault_name.value')
kv_dns_name=https://${kv_name}.vault.azure.net/


# Store in KeyVault
az keyvault secret set --vault-name "$kv_name" --name "kvUrl" --value "$kv_dns_name"
az keyvault secret set --vault-name "$kv_name" --name "subscriptionId" --value "$AZURE_SUBSCRIPTION_ID"


#########################
# CREATE AND CONFIGURE SERVICE PRINCIPAL FOR ADLA GEN2
echo "$0 - # CREATE AND CONFIGURE SERVICE PRINCIPAL FOR ADLA GEN2" >> $LOGFILE

# Retrive account and key
azure_storage_account=$(echo "$arm_output" | jq -r '.properties.outputs.storage_account_name.value')
azure_storage_key=$(az storage account keys list \
    --account-name "$azure_storage_account" \
    --resource-group "$resource_group_name" \
    --output json |
    jq -r '.[0].value')

# Add file system storage account
storage_file_system=datalake
echo "$0 - Creating ADLS Gen2 File system: $storage_file_system" >> $LOGFILE
az storage container create --name $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key"

echo "$0 - Creating folders within the file system." >> $LOGFILE
# Create folders for databricks libs
az storage fs directory create -n '/sys/databricks/libs' -f $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key"
# Create folders for SQL external tables
az storage fs directory create -n '/data/dw/fact_parking' -f $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key"
az storage fs directory create -n '/data/dw/dim_st_marker' -f $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key"
az storage fs directory create -n '/data/dw/dim_parking_bay' -f $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key"
az storage fs directory create -n '/data/dw/dim_location' -f $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key"

echo "$0 - Uploading seed data to data/seed" >> $LOGFILE
az storage blob upload --container-name $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key" \
    --file data/seed/dim_date.csv --name "data/seed/dim_date/dim_date.csv" --overwrite
az storage blob upload --container-name $storage_file_system --account-name "$azure_storage_account" --account-key "$azure_storage_key" \
    --file data/seed/dim_time.csv --name "data/seed/dim_time/dim_time.csv" --overwrite

# Set Keyvault secrets
az keyvault secret set --vault-name "$kv_name" --name "datalakeAccountName" --value "$azure_storage_account"
az keyvault secret set --vault-name "$kv_name" --name "datalakeKey" --value "$azure_storage_key"
az keyvault secret set --vault-name "$kv_name" --name "datalakeurl" --value "https://$azure_storage_account.dfs.core.windows.net"


####################
# APPLICATION INSIGHTS
echo "$0 - # APPLICATION INSIGHTS" >> $LOGFILE

echo "$0 - Retrieving ApplicationInsights information from the deployment." >> $LOGFILE
appinsights_name=$(echo "$arm_output" | jq -r '.properties.outputs.appinsights_name.value')
appinsights_key=$(az monitor app-insights component show \
    --app "$appinsights_name" \
    --resource-group "$resource_group_name" \
    --output json |
    jq -r '.instrumentationKey')

# Store in Keyvault
az keyvault secret set --vault-name "$kv_name" --name "applicationInsightsKey" --value "$appinsights_key"


####################
# LOG ANALYTICS 
echo "$0 - # LOG ANALYTICS " >> $LOGFILE

echo "$0 - Retrieving Log Analytics information from the deployment." >> $LOGFILE
loganalytics_name=$(echo "$arm_output" | jq -r '.properties.outputs.loganalytics_name.value')
loganalytics_id=$(az monitor log-analytics workspace show \
    --workspace-name "$loganalytics_name" \
    --resource-group "$resource_group_name" \
    --output json |
    jq -r '.customerId')
loganalytics_key=$(az monitor log-analytics workspace get-shared-keys \
    --workspace-name "$loganalytics_name" \
    --resource-group "$resource_group_name" \
    --output json |
    jq -r '.primarySharedKey')

# Store in Keyvault
az keyvault secret set --vault-name "$kv_name" --name "logAnalyticsId" --value "$loganalytics_id"
az keyvault secret set --vault-name "$kv_name" --name "logAnalyticsKey" --value "$loganalytics_key"


####################
# SYNAPSE ANALYTICS
echo "$0 - # SYNAPSE ANALYTICS" >> $LOGFILE

echo "$0 - Retrieving Synapse Analytics information from the deployment." >> $LOGFILE
synapseworkspace_name=$(echo "$arm_output" | jq -r '.properties.outputs.synapseworskspace_name.value')
synapse_dev_endpoint=$(az synapse workspace show \
    --name "$synapseworkspace_name" \
    --resource-group "$resource_group_name" \
    --output json |
    jq -r '.connectivityEndpoints | .dev')

synapse_sparkpool_name=$(echo "$arm_output" | jq -r '.properties.outputs.synapse_output_spark_pool_name.value')
synapse_sqlpool_name=$(echo "$arm_output" | jq -r '.properties.outputs.synapse_sql_pool_output.value.synapse_pool_name')

# The server name of connection string will be the same as Synapse worspace name
synapse_sqlpool_server=$(echo "$arm_output" | jq -r '.properties.outputs.synapseworskspace_name.value')
synapse_sqlpool_admin_username=$(echo "$arm_output" | jq -r '.properties.outputs.synapse_sql_pool_output.value.username')
# the database name of dedicated sql pool will be the same with dedicated sql pool by default
synapse_dedicated_sqlpool_db_name=$(echo "$arm_output" | jq -r '.properties.outputs.synapse_sql_pool_output.value.synapse_pool_name')

# Store in Keyvault
echo "$0 - # Store in Keyvault" >> $LOGFILE
az keyvault secret set --vault-name "$kv_name" --name "synapseWorkspaceName" --value "$synapseworkspace_name"
az keyvault secret set --vault-name "$kv_name" --name "synapseDevEndpoint" --value "$synapse_dev_endpoint"
az keyvault secret set --vault-name "$kv_name" --name "synapseSparkPoolName" --value "$synapse_sparkpool_name"
az keyvault secret set --vault-name "$kv_name" --name "synapseSqlPoolServer" --value "$synapse_sqlpool_server"
az keyvault secret set --vault-name "$kv_name" --name "synapseSQLPoolAdminUsername" --value "$synapse_sqlpool_admin_username"
az keyvault secret set --vault-name "$kv_name" --name "synapseSQLPoolAdminPassword" --value "$SYNAPSE_SQL_PASSWORD"
az keyvault secret set --vault-name "$kv_name" --name "synapseDedicatedSQLPoolDBName" --value "$synapse_dedicated_sqlpool_db_name"

# Deploy Synapse artifacts
echo "$0 - # Deploy Synapse artifacts" >> $LOGFILE
export AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID
export RESOURCE_GROUP_NAME=$resource_group_name
export SYNAPSE_WORKSPACE_NAME=$synapseworkspace_name
export SYNAPSE_DEV_ENDPOINT=$synapse_dev_endpoint
export BIG_DATAPOOL_NAME=$synapse_sparkpool_name
export SQL_POOL_NAME=$synapse_sqlpool_name
export LOG_ANALYTICS_WS_ID=$loganalytics_id
export LOG_ANALYTICS_WS_KEY=$loganalytics_key
export KEYVAULT_NAME=$kv_name
export AZURE_STORAGE_ACCOUNT=$azure_storage_account
echo "$0 - STARTING SCRIPT scripts/deploy_synapse_artifacts.sh " >> $LOGFILE

    bash -c "./scripts/deploy_synapse_artifacts.sh"

echo "$0 - STARTING SCRIPT scripts/deploy_synapse_artifacts.sh ....... DONE" >> $LOGFILE

# SERVICE PRINCIPAL IN SYNAPSE INTEGRATION TESTS
# Synapse SP for integration tests
 sp_synapse_name="${PROJECT}-syn-${ENV_NAME}-${DEPLOYMENT_ID}-sp"
 sp_synapse_out=$(az ad sp create-for-rbac \
     --role Contributor \
     --scopes "/subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$resource_group_name/providers/Microsoft.Synapse/workspaces/$synapseworkspace_name" \
     --name "$sp_synapse_name" \
     --output json)
 sp_synapse_id=$(echo "$sp_synapse_out" | jq -r '.appId')
 sp_synapse_pass=$(echo "$sp_synapse_out" | jq -r '.password')
 sp_synapse_tenant=$(echo "$sp_synapse_out" | jq -r '.tenant')

# Save Synapse SP credentials in Keyvault
 az keyvault secret set --vault-name "$kv_name" --name "spSynapseName" --value "$sp_synapse_name"
 az keyvault secret set --vault-name "$kv_name" --name "spSynapseId" --value "$sp_synapse_id"
 az keyvault secret set --vault-name "$kv_name" --name "spSynapsePass" --value "$sp_synapse_pass"
 az keyvault secret set --vault-name "$kv_name" --name "spSynapseTenantId" --value "$sp_synapse_tenant"

# Grant Synapse Administrator to this SP so that it can trigger Synapse pipelines
wait_service_principal_creation "$sp_synapse_id"
sp_synapse_object_id=$(az ad sp show --id "$sp_synapse_id" --query "id" -o tsv)
assign_synapse_role_if_not_exists "$synapseworkspace_name" "Synapse Administrator" "$sp_synapse_object_id"
assign_synapse_role_if_not_exists "$synapseworkspace_name" "Synapse SQL Administrator" "$sp_synapse_object_id"


####################
# AZDO Azure Service Connection and Variables Groups
echo "$0 - # AZDO Azure Service Connection and Variables Groups" >> $LOGFILE

# AzDO Azure Service Connections
PROJECT=$PROJECT \
ENV_NAME=$ENV_NAME \
RESOURCE_GROUP_NAME=$resource_group_name \
DEPLOYMENT_ID=$DEPLOYMENT_ID \
SYNAPSE_WORKSPACE_NAME=$synapseworkspace_name \
echo "$0 - STARTING scripts/deploy_azdo_service_connection_azure.sh" >> $LOGFILE

    bash -c "./scripts/deploy_azdo_service_connections_azure.sh"

echo "$0 - STARTING scripts/deploy_azdo_service_connection_azure.sh..... DONE" >> $LOGFILE
# AzDO Variable Groups

export SP_SYNAPSE_ID=$sp_synapse_id 
export SP_SYNAPSE_PASS=$sp_synapse_pass 
export SP_SYNAPSE_TENANT=$sp_synapse_tenant
export PROJECT=$PROJECT
export ENV_NAME=$ENV_NAME
export AZURE_SUBSCRIPTION_ID=$AZURE_SUBSCRIPTION_ID 
export RESOURCE_GROUP_NAME=$resource_group_name 
export AZURE_LOCATION=$AZURE_LOCATION 
export KV_URL=$kv_dns_name 
export AZURE_STORAGE_KEY=$azure_storage_key 
export AZURE_STORAGE_ACCOUNT=$azure_storage_account 
export SYNAPSE_WORKSPACE_NAME=$synapseworkspace_name 
export BIG_DATAPOOL_NAME=$synapse_sparkpool_name 
export SYNAPSE_SQLPOOL_SERVER=$synapse_sqlpool_server 
export SYNAPSE_SQLPOOL_ADMIN_USERNAME=$synapse_sqlpool_admin_username 
export SYNAPSE_SQLPOOL_ADMIN_PASSWORD=$SYNAPSE_SQL_PASSWORD 
export SYNAPSE_DEDICATED_SQLPOOL_DATABASE_NAME=$synapse_dedicated_sqlpool_db_name 
export LOG_ANALYTICS_WS_ID=$loganalytics_id 
export LOG_ANALYTICS_WS_KEY=$loganalytics_key 

echo "$0 - STARTING scripts deploy_azdo_variables.sh" >> $LOGFILE

    bash -c "./scripts/deploy_azdo_variables.sh"

echo "$0 - STARTING scripts deploy_azdo_variables.sh.......DONE" >> $LOGFILE

####################
# BUILD ENV FILE FROM CONFIG INFORMATION
echo "$0 - BUILD ENV FILE FROM CONFIG INFORMATION" >> $LOGFILE

env_file=".env.${ENV_NAME}"
echo "$0 - Appending configuration to .env file."
cat << EOF >> "$env_file"

# ------ Configuration from deployment on ${TIMESTAMP} -----------
RESOURCE_GROUP_NAME=${resource_group_name}
AZURE_LOCATION=${AZURE_LOCATION}
AZURE_STORAGE_ACCOUNT=${azure_storage_account}
AZURE_STORAGE_KEY=${azure_storage_key}
APPINSIGHTS_KEY=${appinsights_key}
KV_URL=${kv_dns_name}
LOG_ANALYTICS_WS_ID=${loganalytics_id}
SYNAPSE_WORKSPACE_NAME=${synapseworkspace_name}
SYNAPSE_SQLPOOL_SERVER=${synapse_sqlpool_name}
SYNAPSE_SQLPOOL_ADMIN_USERNAME=${synapse_sqlpool_admin_username}
SYNAPSE_DEDICATED_SQLPOOL_DATABASE_NAME=${synapse_dedicated_sqlpool_db_name}
SP_SYNAPSE_ID=${sp_synapse_id}
SP_SYNAPSE_NAME=${sp_synapse_name}

EOF
echo "Completed deploying Azure resources $resource_group_name ($ENV_NAME)"
