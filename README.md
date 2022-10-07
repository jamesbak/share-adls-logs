# Create a Azure Purview In-Place data share for classic diagnostic logs in Azure Data Lake Storage

The 'classic' diagnostic logs for an ADLS storage account are saved to the `$logs` container of that account. When the Azure Purview portal enumerates containers to make available for creating an [in-place data share](https://learn.microsoft.com/azure/purview/how-to-share-data?tabs=azure-portal) the `$logs` container is ommitted as the `$` prefix indicates that the container should be hidden.

However, this script directly invokes the [Purview REST API](https://learn.microsoft.com/rest/api/purview/) that permits the creation of a share for this data.

The data in this share can be shared with Microsoft ADLS engineers to analyze traffic patterns on the specified ADLS account, which can in turn lead to guidance for optimization and cost savings.