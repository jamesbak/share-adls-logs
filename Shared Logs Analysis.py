# Databricks notebook source
# MAGIC %md
# MAGIC 
# MAGIC ## Import Log Analytics data for ADLS that is shared by customers
# MAGIC 
# MAGIC Ingest Storage Log data from [Log Analytics](https://learn.microsoft.com/azure/storage/blobs/monitor-blob-storage-reference#resource-logs) into consolidated Delta table. This process reads the raw JSON files, performs some minor extraction/processing and then writes the data to a dedicated Delta table.
# MAGIC 
# MAGIC This process is intended to be run for each customer/project that shares logs. ie. We run an extract per share and then create a separate table per share. The schema for each table created for each share will be the same.
# MAGIC 
# MAGIC Unfortunately, there is not currently any incremental processing - ALL log data is read and overwritten to a new table. This is due to the fact that the [source directory structure](https://learn.microsoft.com/azure/azure-monitor/essentials/resource-logs#send-to-azure-storage) for Log Analytics is incompatible with Spark/Hive partition schemes and so the raw data cannot be partitioned. Therefore, it must read and process all data.
# MAGIC 
# MAGIC **Note:** It is assumed that access to both the raw & processed storage accounts have already been established for the cluster.
# MAGIC 
# MAGIC ### Instructions
# MAGIC Enter details in the notebook widgets:
# MAGIC 1. 'Raw Account' is the name of the storage account containing the shared raw log data from the customer's Log Analytics.
# MAGIC 2. 'Raw Container' is the name of the container in the 'Raw Account' storage account containing the log data in JSON form.
# MAGIC 3. 'Processed Account' is the name of the storage account containing the processed Delta table. This can be the same as the 'Raw Account'.
# MAGIC 4. 'Processed Table Name' is the name of the Delta table that this data will be read into.

# COMMAND ----------

# Create parameterization widgets
dbutils.widgets.text(name="raw_account", defaultValue="adlslogsrecipient", label="Raw Account:")
dbutils.widgets.text(name="raw_container", defaultValue="", label="Raw Container:")
dbutils.widgets.text(name="processed_account", defaultValue="adlslogsprocessed", label="Processed Account:")
dbutils.widgets.text(name="processed_table", defaultValue="", label="Processed Table Name:")

# COMMAND ----------

raw_account = dbutils.widgets.get("raw_account")
raw_container = dbutils.widgets.get("raw_container")
processed_account = dbutils.widgets.get("processed_account")
processed_table = dbutils.widgets.get("processed_table")

# COMMAND ----------

from pyspark.sql.functions import *

# Read the raw JSON data
dfRead = spark.read.json(f"abfss://{raw_container}@{raw_account}.dfs.core.windows.net/logs/read/subscriptions/*/resourceGroups/*/providers/Microsoft.Storage/storageAccounts/*/blobServices/default/y=*/m=*/d=*/h=*/m=*/*") \
  .select("time", "callerIpAddress", "correlationId", "durationMs", "operationName", "operationVersion", "properties.clientRequestId", "properties.conditionsUsed", "properties.downloadRange", "properties.etag", "properties.responseBodySize", "properties.serverLatencyMs", "properties.userAgentHeader", "protocol", "statusCode", "statusText", "uri")
dfWrite = spark.read.json(f"abfss://{raw_container}@{raw_account}.dfs.core.windows.net/logs/write/subscriptions/*/resourceGroups/*/providers/Microsoft.Storage/storageAccounts/*/blobServices/default/y=*/m=*/d=*/h=*/m=*/*") \
  .select("time", "callerIpAddress", "correlationId", "durationMs", "operationName", "operationVersion", "properties.clientRequestId", "properties.conditionsUsed", "properties.etag", "properties.serverLatencyMs", "properties.userAgentHeader", "protocol", "statusCode", "statusText", "uri") \
  .withColumn("downloadRange", lit(None)) \
  .withColumn("responseBodySize", lit(None))
dfDelete = spark.read.json(f"abfss://{raw_container}@{raw_account}.dfs.core.windows.net/logs/delete/subscriptions/*/resourceGroups/*/providers/Microsoft.Storage/storageAccounts/*/blobServices/default/y=*/m=*/d=*/h=*/m=*/*") \
  .select("time", "callerIpAddress", "correlationId", "durationMs", "operationName", "operationVersion", "properties.clientRequestId", "properties.etag", "properties.serverLatencyMs", "properties.userAgentHeader", "protocol", "statusCode", "statusText", "uri") \
  .withColumn("downloadRange", lit(None)) \
  .withColumn("responseBodySize", lit(None)) \
  .withColumn("conditionsUsed", lit(None))
df = dfRead.unionByName(dfWrite).unionByName(dfDelete)

# COMMAND ----------

df.printSchema()

# COMMAND ----------

df1 = df.withColumn("timestamp", to_timestamp(col("time"))) \
  .withColumn("rangeStart", regexp_extract(col("downloadRange"), "bytes=(\d+)-(\d+)", 1)) \
  .withColumn("rangeEnd", regexp_extract(col("downloadRange"), "bytes=(\d+)-(\d+)", 2)) \
  .withColumn("year", year(col("timestamp"))) \
  .withColumn("month", month(col("timestamp"))) \
  .withColumn("day", dayofmonth(col("timestamp"))) \
  .withColumn("hour", hour(col("timestamp"))) \
  .orderBy("timestamp")

# COMMAND ----------

display(df1)

# COMMAND ----------

# MAGIC %md
# MAGIC 
# MAGIC Write the data to a Delta table in the **processed** storage account.
# MAGIC 
# MAGIC Data is partitioned by year, month, day, hour

# COMMAND ----------

df1.write \
  .option("path", f"abfss://processed@{processed_account}.dfs.core.windows.net/{processed_table}") \
  .partitionBy("year", "month", "day", "hour") \
  .saveAsTable(processed_table, mode="overwrite")

# COMMAND ----------

# MAGIC %md
# MAGIC 
# MAGIC Query away...

# COMMAND ----------

# MAGIC %sql
# MAGIC select operationName, count(*) from ${processed_table}
# MAGIC group by operationName

# COMMAND ----------

# MAGIC %sql
# MAGIC select * from ${processed_table}
# MAGIC where operationName = "AppendFile"
