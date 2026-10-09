#!/bin/bash
set -e

REGION="${AWS_DEFAULT_REGION:-us-east-1}"

create_table_if_not_exists() {
  local table_name="$1"
  shift

  if awslocal dynamodb describe-table --table-name "$table_name" --region "$REGION" > /dev/null 2>&1; then
    echo "Table '$table_name' already exists, skipping."
    return
  fi

  echo "Creating table '$table_name'..."
  awslocal dynamodb create-table --table-name "$table_name" --region "$REGION" "$@"
  echo "Table '$table_name' created."
}

# Adds a GSI (string hash key, all attributes) to a table created before it existed
add_index_if_not_exists() {
  local table_name="$1"
  local index_name="$2"
  local attribute="$3"

  local existing
  existing=$(awslocal dynamodb describe-table --table-name "$table_name" --region "$REGION" \
    --query "Table.GlobalSecondaryIndexes[?IndexName=='$index_name'].IndexName" --output text)
  if [ -n "$existing" ] && [ "$existing" != "None" ]; then
    echo "Index '$index_name' on '$table_name' already exists, skipping."
    return
  fi

  echo "Adding index '$index_name' to '$table_name'..."
  awslocal dynamodb update-table --table-name "$table_name" --region "$REGION" \
    --attribute-definitions "AttributeName=$attribute,AttributeType=S" \
    --global-secondary-index-updates \
    "[{\"Create\":{\"IndexName\":\"$index_name\",\"KeySchema\":[{\"AttributeName\":\"$attribute\",\"KeyType\":\"HASH\"}],\"Projection\":{\"ProjectionType\":\"ALL\"}}}]" \
    > /dev/null
  echo "Index '$index_name' added."
}

# Faclab Invoicing Certificates
create_table_if_not_exists certificates \
  --attribute-definitions \
    AttributeName=id,AttributeType=S \
    AttributeName=serial_number,AttributeType=S \
  --key-schema \
    AttributeName=id,KeyType=HASH \
  --global-secondary-indexes \
    "IndexName=SerialNumberIndex,KeySchema=[{AttributeName=serial_number,KeyType=HASH}],Projection={ProjectionType=ALL}" \
  --billing-mode PAY_PER_REQUEST

# Faclab Invoicing Company Config
create_table_if_not_exists company_config \
  --attribute-definitions \
    AttributeName=id,AttributeType=S \
  --key-schema \
    AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# Faclab Invoicing Invoices
# StatusIndex: the recovery job and the status endpoint read unfinished invoices
create_table_if_not_exists invoices \
  --attribute-definitions \
    AttributeName=id,AttributeType=S \
    AttributeName=saleId,AttributeType=S \
    AttributeName=status,AttributeType=S \
  --key-schema \
    AttributeName=id,KeyType=HASH \
  --global-secondary-indexes \
    "IndexName=SaleIdIndex,KeySchema=[{AttributeName=saleId,KeyType=HASH}],Projection={ProjectionType=ALL}" \
    "IndexName=StatusIndex,KeySchema=[{AttributeName=status,KeyType=HASH}],Projection={ProjectionType=ALL}" \
  --billing-mode PAY_PER_REQUEST
add_index_if_not_exists invoices StatusIndex status
