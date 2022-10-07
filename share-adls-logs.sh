#!/bin/bash

# Script to create in-place data share for the $logs container of a specified storage account.
# This is to overcome a UX bug that does not list the $logs (its a hidden container) in the data share portal.

# Parameters
SUBSCRIPTION_ID=
PURVIEW_ACCOUNT=
STORAGE_ACCOUNT=
STORAGE_ACCOUNT_RESOURCE_GROUP=
SPN_CLIENT_ID=
SPN_SECRET=
CREATE_SOURCE=1
SHARE_WITH=dakaban@microsoft.com

# Constants
SOURCE_NAME=adls-logs-source
SHARE_NAME=adls-logs-to-microsoft

checkstatus() {
    
     if [ $? -ne 0 ]; then
        echo "DEBUG... $1 failed"
    else
        echo "DEBUG... $1 success"
    fi
}

help_message() {
    echo "Usage: $0 -s SUBSCRIPTION_ID -p PURVIEW_ACCOUNT -a STORAGE_ACCOUNT -g STORAGE_ACCOUNT_RESOURCE_GROUP -c SPN_CLIENT_ID -w SPN_SECRET [-r SHARE_WITH] [-n] [-?]"
    echo ""
    echo "Where:"
    echo "  -s SUBSCRIPTION_ID  The Azure subscription id containing both Purview and ADLS account."
    echo "  -p PURVIEW_ACCOUNT  The name of the Purview account to issue the data share."
    echo '  -a STORAGE_ACCOUNT  The name of the ADLS account with $logs container.'
    echo "  -g STORAGE_ACCOUNT_RESOURCE_GROUP "
    echo "                      The resource group name containing the above storage account."
    echo "  -c SPN_CLIENT_ID    The client id of the AAD Service Principal that has access to both the Purview and ADLS accounts."
    echo "  -w SPN_SECRET       A valid secret for the AAD Service Principal."
    echo "  -r SHARE_WITH       (Optional) The recipient email to share the log data with."
    echo "  -n                  (Optional) Flag to indicate to NOT create a new Purview Source for the ADLS account. Default is to create a new source."
}

which jq > /dev/null
if [ $? -ne 0 ]; then

    echo "This script requires jq to run. Please install using preferred package manager"
    exit 1
fi

while getopts ":?hs:p:a:g:c:w:r:n" options ; do
    case "${options}" in
        s) SUBSCRIPTION_ID=${OPTARG} ;;
        p) PURVIEW_ACCOUNT=${OPTARG} ;;
        a) STORAGE_ACCOUNT=${OPTARG} ;;
        g) STORAGE_ACCOUNT_RESOURCE_GROUP=${OPTARG} ;;
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
if [ ! "$SUBSCRIPTION_ID" ] || [ ! "$PURVIEW_ACCOUNT" ] || [ ! "$STORAGE_ACCOUNT" ] || [ ! "$STORAGE_ACCOUNT_RESOURCE_GROUP" ] || [ ! "$SPN_CLIENT_ID" ] || [ ! "$SPN_SECRET" ] || [ ! "$SHARE_WITH" ]; then
    help_message
    exit 1
fi

# Acquire token for Purview data plan
ACCESS_TOKEN=$(curl -s -X POST -H "Content-Type: application/x-www-form-urlencoded" --data-urlencode "client_id=$SPN_CLIENT_ID" --data-urlencode  "client_secret=$SPN_SECRET" --data-urlencode  "scope=https://purview.azure.net/.default" --data-urlencode  "grant_type=client_credentials" "https://login.microsoftonline.com/microsoft.com/oauth2/v2.0/token" | jq -r -e '.access_token')
if [ $? -ne 0 ]; then
    echo "Error: Failed to acquire access token. Verify that the specified AAD service principal credentials are correct."
    exit 2
fi

# Start building the share in Purivew
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
    curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/scan/datasources/$SOURCE_NAME?api-version=2022-02-01-preview -d '{"kind":"AdlsGen2", "properties":{"endpoint":"https://'$STORAGE_ACCOUNT'.dfs.core.windows.net/", "resourceGroup":"'$STORAGE_ACCOUNT_RESOURCE_GROUP'", "subscriptionId":"'$SUBSCRIPTION_ID'", "resourceName":"'$STORAGE_ACCOUNT'", "location": "canadacentral", "resourceId":"/subscriptions/'$SUBSCRIPTION_ID'/resourceGroups/'$STORAGE_ACCOUNT_RESOURCE_GROUP'/providers/Microsoft.Storage/storageAccounts/'$STORAGE_ACCOUNT'", "collection":{"referenceName": "'$ROOT_COLLECTION'","type": "CollectionReference"}}}' | jq .
fi

# Create the in-place share
echo "Creating in-place data share..."
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/sentShares/$SHARE_NAME?api-version=2021-09-01-preview -d '{"shareKind":"InPlace", "properties":{"description":"Share ADLS diagnostic logs with Microsoft for traffic analysis.", "collection":{"referenceName": "'$ROOT_COLLECTION'","type": "CollectionReference"}}}' | jq .

# Add the $logs assets
echo 'Adding the $logs container to the data share...'
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/sentShares/$SHARE_NAME/assets/logs?api-version=2021-09-01-preview -d '{"kind":"AdlsGen2Account", "properties":{"storageAccountResourceId": "/subscriptions/'$SUBSCRIPTION_ID'/resourceGroups/'$STORAGE_ACCOUNT_RESOURCE_GROUP'/providers/Microsoft.Storage/storageAccounts/'$STORAGE_ACCOUNT'", "receiverAssetName": "logs", "paths":[{"containerName":"$logs", "senderPath":"blob", "receiverPath":""}]}}' | jq .

# Finally, create the share invitation
echo "Sending data share invitation to Microsoft..."
INVITE_NAME=$(uuidgen)
curl -s -X PUT -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" https://$PURVIEW_ACCOUNT.purview.azure.com/share/sentShares/$SHARE_NAME/sentShareInvitations/$INVITE_NAME?api-version=2021-09-01-preview -d '{"name":"'$INVITE_NAME'","invitationKind":"User","properties":{"targetEmail":"'$SHARE_WITH'"}}' | jq .

echo "Finished"