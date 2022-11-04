#!/bin/bash

help_message() {
    echo "Usage: $0 -t TENANT_ID -p PURVIEW_ACCOUNT -s STORAGE_ACCOUNT -c SPN_CLIENT_ID -w SPN_SECRET [-r SENDER_TENANT_ID] [-?]"
    echo ""
    echo "Where:"
    echo "  -t TENANT_ID        The id or DNS name of your AAD tenant."
    echo "  -p PURVIEW_ACCOUNT  The name of the Purview account to receive the data share."
    echo '  -s STORAGE_ACCOUNT  The name of the ADLS account to map the share into.'
    echo "  -c SPN_CLIENT_ID    The client/application id of the AAD Service Principal that has access to both the Purview and ADLS accounts."
    echo "  -w SPN_SECRET       A valid secret for the AAD Service Principal."
    echo '  -r SENDER_TENANT_ID (Optional) The name of the AAD tenant that shared the data. This will also be used as the container name for mapping the shared data.'
}

which jq > /dev/null
if [ $? -ne 0 ]; then

    echo "This script requires jq to run. Please install using preferred package manager"
    exit 1
fi

while getopts ":?ht:p:s:c:w:r:" options ; do
    case "${options}" in
        t) TENANT_ID=${OPTARG} ;;
        p) PURVIEW_ACCOUNT=${OPTARG} ;;
        s) STORAGE_ACCOUNT=${OPTARG} ;;
        c) SPN_CLIENT_ID=${OPTARG} ;;
        w) SPN_SECRET=${OPTARG} ;;
        r) SENDER_TENANT_ID=${OPTARG} ;;
        *|?|h)
            help_message
            exit 1
            ;;
    esac
done
if [ ! "$TENANT_ID" ] || [ ! "$PURVIEW_ACCOUNT" ] || [ ! "$STORAGE_ACCOUNT" ] || [ ! "$SPN_CLIENT_ID" ] || [ ! "$SPN_SECRET" ]; then
    help_message
    exit 1
fi

# Acquire token for Purview data plane
echo "Acquiring access token to Azure Purview for service principal: $SPN_CLIENT_ID"
ACCESS_TOKEN=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "client_id=$SPN_CLIENT_ID" --data-urlencode  "client_secret=$SPN_SECRET" --data-urlencode  "scope=https://purview.azure.net/.default" --data-urlencode  "grant_type=client_credentials" "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" | jq -r -e '.access_token')
if [ $? -ne 0 ]; then
    echo "Error: Failed to acquire access token. Verify that the specified AAD service principal credentials are correct."
    exit 2
fi
ARM_ACCESS_TOKEN=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "client_id=$SPN_CLIENT_ID" --data-urlencode  "client_secret=$SPN_SECRET" --data-urlencode  "scope=https://management.azure.com/.default" --data-urlencode  "grant_type=client_credentials" "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" | jq -r -e '.access_token')
if [ $? -ne 0 ]; then
    echo "Error: Failed to acquire access token. Verify that the specified AAD service principal credentials are correct."
    exit 2
fi

# Find the specified storage account in the SPN's subscriptions
echo "Looking up ARM details for storage account: $STORAGE_ACCOUNT"
for SUB_ENUM in $(curl -s -H "Authorization: Bearer $ARM_ACCESS_TOKEN" https://management.azure.com/subscriptions?api-version=2020-01-01 | jq -r .value[].subscriptionId)
do
    ACCOUNTS_ENUM=$(curl -s -H "Authorization: Bearer $ARM_ACCESS_TOKEN" https://management.azure.com/subscriptions/$SUB_ENUM/providers/Microsoft.Storage/storageAccounts?api-version=2022-05-01) 
    echo $ACCOUNTS_ENUM | jq -e '.value | any(.name == "'$STORAGE_ACCOUNT'")'
    if [ $? -eq 0 ]; then
        SUBSCRIPTION_ID=$SUB_ENUM
        break
    fi 
done
if [ ! "$SUBSCRIPTION_ID" ]; then
    echo "Failed to find account: $STORAGE_ACCOUNT in accessible subscriptions."
    exit 1
fi
ACCOUNT_INFO=$(echo $ACCOUNTS_ENUM | jq '.value[] | select(.name == "'$STORAGE_ACCOUNT'")')
# Extract the resource group
EXP=".*/resourceGroups/(.*)/providers.*"
STORAGE_RESOURCE_ID=$(echo $ACCOUNT_INFO | jq -r .id)
[[ $STORAGE_RESOURCE_ID =~ $EXP ]]
STORAGE_RESOURCE_GROUP=${BASH_REMATCH[1]}
# Location
STORAGE_LOCATION=$(echo $ACCOUNT_INFO | jq -r .location)

# Lookup the share invitation - if we've been specified a share tenant, then look for that. Otherwise, just pick the first invite.
if [ ! "$SENDER_TENANT_ID" ]; then
    echo "Looking up first share inviation"
    SHARE_INVITE=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" https://$PURVIEW_ACCOUNT.purview.azure.com/share/receivedInvitations?api-version=2021-09-01-preview | jq .value[0])
    SENDER_TENANT_ID=$(echo $SHARE_INVITE | jq -r .properties.senderTenantName)
else
    echo "Looking up share inviation from: $SENDER_TENANT_ID"
    SHARE_INVITE=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" https://$PURVIEW_ACCOUNT.purview.azure.com/share/receivedInvitations?api-version=2021-09-01-preview | jq '.value[] | select(.properties.senderTenantName == "'"$SENDER_TENANT_ID"'")')  
fi
if [ ! "$SHARE_INVITE" ]; then
    echo "Share invitation not found."
    exit 3
fi
INVITATION_ID=$(echo $SHARE_INVITE | jq -r .name)
SHARE_LOCATION=$(echo $SHARE_INVITE | jq -r .properties.location)
FIXED_SENDER_TENANT=$(echo $SENDER_TENANT_ID | tr [:upper:] [:lower:] | tr ' ' '-')
SHARE_NAME="adls-share-logs-from-$FIXED_SENDER_TENANT"

# Create a ADLS source in the Purview account to receive the shared data
echo "Fetching root collection..."
ROOT_COLLECTION=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" https://$PURVIEW_ACCOUNT.purview.azure.com/account/collections?api-version=2019-11-01-preview | jq -r -e .value[0].name)
if [ $? -ne 0 ]; then
    echo "Error: Failed to retrieve root collection from Azure Purview account: $PURVIEW_ACCOUNT"
    echo "Please ensure this collection is already created prior to running this script."
    exit 2
fi
# Create a source for the account that we are mapping into
echo "Creating data source to ADLS account..."
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/scan/datasources/$STORAGE_ACCOUNT?api-version=2022-02-01-preview -d '{"kind":"AdlsGen2", "properties":{"endpoint":"https://'$STORAGE_ACCOUNT'.dfs.core.windows.net/", "resourceGroup":"'$STORAGE_RESOURCE_GROUP'", "subscriptionId":"'$SUBSCRIPTION_ID'", "resourceName":"'$STORAGE_ACCOUNT'", "location": "'$STORAGE_LOCATION'", "resourceId":"'$STORAGE_RESOURCE_ID'", "collection":{"referenceName": "'$ROOT_COLLECTION'","type": "CollectionReference"}}}' | jq .

# Create the received share from the invitation
echo "Accepting the share invitation"
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/receivedShares/$SHARE_NAME?api-version=2021-09-01-preview -d '{"shareKind":"InPlace","properties":{"sentShareLocation":"'$SHARE_LOCATION'", "invitationId":"'$INVITATION_ID'", "collection":{"referenceName":"'$ROOT_COLLECTION'", "type":"CollectionReference"}}}' | jq .

# Map the shared assets
echo "Retrieving list of shared assets"
ASSETS=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" https://$PURVIEW_ACCOUNT.purview.azure.com/share/receivedShares/$SHARE_NAME/receivedAssets?api-version=2021-09-01-preview | jq .value[0])
ASSET_ID=$(echo $ASSETS | jq -r .name)
ASSET_NAME=$(echo $ASSETS | jq -r .properties.receiverAssetName)
echo "Mapping shared asset to recipient account: $ASSET_NAME"
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/receivedShares/$SHARE_NAME/assetMappings/$ASSET_NAME?api-version=2021-09-01-preview -d '{"kind": "AdlsGen2Account", "properties": { "assetId": "'$ASSET_ID'", "storageAccountResourceId": "'$STORAGE_RESOURCE_ID'", "containerName": "'$FIXED_SENDER_TENANT'", "folder": "'$ASSET_NAME'", "mountPath": ""}}' | jq .

echo "Finished. Logs have been shared to https://$STORAGE_ACCOUNT.dfs.core.windows.net/$FIXED_SENDER_TENANT/"