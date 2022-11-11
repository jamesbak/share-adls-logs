#!/bin/bash

# Script to create in-place data share for the $logs container of a specified storage account.
# This is to overcome a UX bug that does not list the $logs (its a hidden container) in the data share portal.

# Parameters
SUBSCRIPTION_ID=
PURVIEW_ACCOUNT=
STORAGE_ACCOUNT=
STORAGE_RESOURCE_GROUP=
STORAGE_LOCATION=
SPN_CLIENT_ID=
SPN_SECRET=
CREATE_SOURCE=1
SHARE_WITH_SPN=b16b8b49-5161-4710-bf50-f2bf561462b3
SHARE_WITH_TENANT=72f988bf-86f1-41af-91ab-2d7cd011db47
SHARE_WITH=

help_message() {
    echo "Usage: $0 -t TENANT_ID -p PURVIEW_ACCOUNT -s STORAGE_ACCOUNT -c SPN_CLIENT_ID -w SPN_SECRET [-r SHARE_WITH] [-n] [-?]"
    echo ""
    echo "Where:"
    echo "  -t TENANT_ID        The id or DNS name of your AAD tenant."
    echo "  -p PURVIEW_ACCOUNT  The name of the Purview account to issue the data share."
    echo '  -s STORAGE_ACCOUNT  The name of the ADLS account containing Log Analytics data.'
    echo "  -c SPN_CLIENT_ID    The client/application id of the AAD Service Principal that has access to both the Purview and ADLS accounts."
    echo "  -w SPN_SECRET       A valid secret for the AAD Service Principal."
    echo "  -r SHARE_WITH       (Optional) The recipient email to share the log data with."
    echo "  -n                  (Optional) Flag to indicate to NOT create a new Purview Source for the ADLS account. Default is to create a new source."
}

which jq > /dev/null
if [ $? -ne 0 ]; then

    echo "This script requires jq to run. Please install using preferred package manager"
    exit 1
fi

while getopts ":?ht:p:s:c:w:r:n" options ; do
    case "${options}" in
        t) TENANT_ID=${OPTARG} ;;
        p) PURVIEW_ACCOUNT=${OPTARG} ;;
        s) STORAGE_ACCOUNT=${OPTARG} ;;
        c) SPN_CLIENT_ID=${OPTARG} ;;
        w) SPN_SECRET=${OPTARG} ;;
        r) SHARE_WITH=${OPTARG} ;;
        n) CREATE_SOURCE=0 ;;
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

# Start building the share in Purivew
# Append account name information to source & share names to improve disambiguation
SOURCE_NAME=adls-logs-source-$STORAGE_ACCOUNT
SHARE_NAME=adls-logs-to-microsoft-$STORAGE_ACCOUNT

# Data source (optional) first
if [ $CREATE_SOURCE -eq 1 ]; then
    # Get the root collection for the account (assume it is already created as the first collection)
    echo "Fetching root collection..."
    ROOT_COLLECTION=$(curl -s -H "Authorization: Bearer $ACCESS_TOKEN" https://$PURVIEW_ACCOUNT.purview.azure.com/account/collections?api-version=2019-11-01-preview | jq -r -e .value[0].name)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to retrieve root collection from Azure Purview account: $PURVIEW_ACCOUNT"
        echo "Please ensure this collection is already created prior to running this script."
        exit 2
    fi

    echo "Creating data source to ADLS account..."
    curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/scan/datasources/$SOURCE_NAME?api-version=2022-02-01-preview -d '{"kind":"AdlsGen2", "properties":{"endpoint":"https://'$STORAGE_ACCOUNT'.dfs.core.windows.net/", "resourceGroup":"'$STORAGE_RESOURCE_GROUP'", "subscriptionId":"'$SUBSCRIPTION_ID'", "resourceName":"'$STORAGE_ACCOUNT'", "location": "'$STORAGE_LOCATION'", "resourceId":"'$STORAGE_RESOURCE_ID'", "collection":{"referenceName": "'$ROOT_COLLECTION'","type": "CollectionReference"}}}' | jq .
fi

# Create the in-place share
echo "Creating in-place data share..."
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/sentShares/$SHARE_NAME?api-version=2021-09-01-preview -d '{"shareKind":"InPlace", "properties":{"description":"Share ADLS diagnostic logs with Microsoft for traffic analysis.", "collection":{"referenceName": "'$ROOT_COLLECTION'","type": "CollectionReference"}}}' | jq .

# Add the logs assets (insights-logs-storageread, insights-logs-storagewrite, insights-logs-storagedelete)
echo 'Adding the logs containers to the data share...'
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/sentShares/$SHARE_NAME/assets/logs?api-version=2021-09-01-preview -d '{"kind":"AdlsGen2Account", "properties":{"storageAccountResourceId": "'$STORAGE_RESOURCE_ID'", "receiverAssetName": "logs", "paths":[{"containerName":"insights-logs-storageread", "senderPath":"resourceId=", "receiverPath":"read"}, {"containerName":"insights-logs-storagewrite", "senderPath":"resourceId=", "receiverPath":"write"}, {"containerName":"insights-logs-storagedelete", "senderPath":"resourceId=", "receiverPath":"delete"}]}}' | jq .

# Finally, create the share invitation
echo "Sending data share invitation to Microsoft..."
INVITE_NAME=$(uuidgen)
if [ ! -z "$SHARE_WITH" ]; then
    echo "Sharing invitation with email: $SHARE_WITH"
    curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/sentShares/$SHARE_NAME/sentShareInvitations/$INVITE_NAME?api-version=2021-09-01-preview -d '{"name":"'$INVITE_NAME'","invitationKind":"User","properties":{"targetEmail":"'$SHARE_WITH'"}}' | jq .
else
    echo "Sharing invitation with SPN: $SHARE_WITH_SPN"
    curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/sentShares/$SHARE_NAME/sentShareInvitations/$INVITE_NAME?api-version=2021-09-01-preview -d '{"name":"'$INVITE_NAME'","invitationKind":"Application","properties":{"targetActiveDirectoryId":"'$SHARE_WITH_TENANT'", "targetObjectId":"'$SHARE_WITH_SPN'"}}' | jq .
fi

echo "Finished"