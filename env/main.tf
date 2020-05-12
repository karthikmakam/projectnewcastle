provider "azurerm" {
  version = "~>2.0"
  features {}
}

provider "external" {
  version = "~> 1.2"
}

terraform {
  backend "azurerm" {}
}

data "azurerm_client_config" "current" {}

# Resource Group
# resource "azurerm_resource_group" "rg" {
#   name     = "${var.project_name}-rg-${var.environment}"
#   location = var.location
# }

# Cosmos DB Account
resource "azurerm_cosmosdb_account" "cosmos" {
  name                = "${var.project_name}-cosmos-${var.environment}"
  resource_group_name = var.project_name
  location            = var.location
  offer_type          = "Standard"
  kind                = "MongoDB"

  enable_automatic_failover = false

  consistency_policy {
    consistency_level = "Strong"
  }

  geo_location {
    location          = var.location
    failover_priority = 0
  }

  # Default is MongoDB 3.2, use capabilities to enable MongoDB 3.6
  # https://github.com/terraform-providers/terraform-provider-azurerm/issues/4757
  capabilities {
    name = "EnableMongo"
  }
}

# Cosmos DB Mongo Database
resource "azurerm_cosmosdb_mongo_database" "mongodb" {
  name                = var.project_name
  resource_group_name = azurerm_cosmosdb_account.cosmos.resource_group_name
  account_name        = azurerm_cosmosdb_account.cosmos.name
}

# Cosmos DB Mongo Collection
resource "azurerm_cosmosdb_mongo_collection" "coll_patient" {
  name                = "patient"
  resource_group_name = azurerm_cosmosdb_mongo_database.mongodb.resource_group_name
  account_name        = azurerm_cosmosdb_mongo_database.mongodb.account_name
  database_name       = azurerm_cosmosdb_mongo_database.mongodb.name
  shard_key           = "_shardKey"
  throughput          = 400
}

resource "azurerm_cosmosdb_mongo_collection" "coll_audit" {
  name                = "audit"
  resource_group_name = azurerm_cosmosdb_mongo_database.mongodb.resource_group_name
  account_name        = azurerm_cosmosdb_mongo_database.mongodb.account_name
  database_name       = azurerm_cosmosdb_mongo_database.mongodb.name
  shard_key           = "_shardKey"
  throughput          = 400
}

# Storage Account
resource "azurerm_storage_account" "sa" {
  name                      = "${var.project_name}sa${var.environment}"
  resource_group_name       = var.project_name
  location                  = var.location
  account_kind              = "StorageV2"
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  access_tier               = "Hot"
  enable_https_traffic_only = true
}

# Elastic Premium Plan
resource "azurerm_app_service_plan" "asp_patient_api" {
  name                = "${var.project_name}-asp-patient-api-${var.environment}"
  resource_group_name = var.project_name
  location            = var.location
  kind                = "elastic"

  # https://docs.microsoft.com/en-us/azure/azure-functions/functions-networking-options#regional-virtual-network-integration
  # A /26 with 64 addresses accommodates a Premium plan with 30 instances.
  maximum_elastic_worker_count = 30

  sku {
    tier = "ElasticPremium"
    size = "EP1"
  }
}

# Consumption Plan
resource "azurerm_app_service_plan" "asp_audit_api" {
  name                = "${var.project_name}-asp-audit-api-${var.environment}"
  resource_group_name = var.project_name
  location            = var.location
  kind                = "FunctionApp"

  sku {
    tier = "Dynamic"
    size = "Y1"
  }
}

# Application Insights
resource "azurerm_application_insights" "ai" {
  name                = "${var.project_name}-ai-${var.environment}"
  resource_group_name = var.project_name
  location            = var.location
  application_type    = "Node.JS"
  retention_in_days   = 90
}

# Virtual Network
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.project_name}-vnet-${var.environment}"
  resource_group_name = var.project_name
  location            = var.location
  address_space       = ["10.0.0.0/16"]
}

# Subnet
resource "azurerm_subnet" "snet" {
  name                 = "${var.project_name}-snet-${var.environment}"
  resource_group_name  = var.project_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/26"]

  delegation {
    name = "fadelegation"

    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }

  service_endpoints = ["Microsoft.Web"]
}

# Function App Module
# Patient API
module "fa_patient_api" {
  source                           = "./modules/function_app"
  name                             = "${var.project_name}-fa-patient-api-${var.environment}"
  resource_group_name              = var.project_name
  location                         = var.location
  app_service_plan_id              = azurerm_app_service_plan.asp_patient_api.id
  storage_account_name             = azurerm_storage_account.sa.name
  storage_account_access_key       = azurerm_storage_account.sa.primary_access_key
  app_insights_instrumentation_key = azurerm_application_insights.ai.instrumentation_key
  ip_restriction_ip_address        = "${azurerm_api_management.apim.public_ip_addresses[0]}/32"

  extra_app_settings = {
    mongo_connection_string = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.cosmos_conn.id})"
  }

  key_vault_id = azurerm_key_vault.kv.id
}

# Audit API
module "fa_audit_api" {
  source                           = "./modules/function_app"
  name                             = "${var.project_name}-fa-audit-api-${var.environment}"
  resource_group_name              = var.project_name
  location                         = var.location
  app_service_plan_id              = azurerm_app_service_plan.asp_audit_api.id
  storage_account_name             = azurerm_storage_account.sa.name
  storage_account_access_key       = azurerm_storage_account.sa.primary_access_key
  app_insights_instrumentation_key = azurerm_application_insights.ai.instrumentation_key
  ip_restriction_subnet_id         = azurerm_subnet.snet.id

  extra_app_settings = {
    mongo_connection_string = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.cosmos_conn.id})"
  }

  key_vault_id = azurerm_key_vault.kv.id
}

# Function App Host Key
# 2020-05-12 Currently azurerm provider does not export function app host keys
# https://github.com/terraform-providers/terraform-provider-azurerm/issues/699
# Patient API Host Key
data "external" "fa_patient_api_host_key" {
  program = ["bash", "-c", "az rest --method post --uri /subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.project_name}/providers/Microsoft.Web/sites/${module.fa_patient_api.name}/host/default/listKeys?api-version=2018-11-01 --query functionKeys"]

  depends_on = [
    module.fa_patient_api
  ]
}

# Audit API Host Key
data "external" "fa_audit_api_host_key" {
  program = ["bash", "-c", "az rest --method post --uri /subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.project_name}/providers/Microsoft.Web/sites/${module.fa_audit_api.name}/host/default/listKeys?api-version=2018-11-01 --query functionKeys"]

  depends_on = [
    module.fa_audit_api
  ]
}

# Regional VNet Integration
resource "azurerm_app_service_virtual_network_swift_connection" "vnet_int" {
  app_service_id = module.fa_patient_api.id
  subnet_id      = azurerm_subnet.snet.id
}

# API Management
resource "azurerm_api_management" "apim" {
  name                = "${var.project_name}-apim-${var.environment}"
  resource_group_name = var.project_name
  location            = var.location
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email

  sku_name = "Developer_1"

  identity {
    type = "SystemAssigned"
  }
}

# API Management Backend
# 2020-05-12 Currently azurerm provider cannot add function app as backend to API Management
# https://github.com/terraform-providers/terraform-provider-azurerm/issues/5032
resource "azurerm_api_management_backend" "fa_patient_api" {
  name                = "fa-patient-api"
  resource_group_name = azurerm_api_management.apim.resource_group_name
  api_management_name = azurerm_api_management.apim.name
  protocol            = "http"
  url                 = "https://${module.fa_patient_api.default_hostname}"
  resource_id         = "https://management.azure.com/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${var.project_name}/providers/Microsoft.Web/sites/${module.fa_patient_api.name}"
}

# API
resource "azurerm_api_management_api" "helloworld" {
  name                = "helloworld-api"
  resource_group_name = azurerm_api_management.apim.resource_group_name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "HelloWorld API"
  path                = "helloworld"
  protocols           = ["https"]
  service_url         = "https://${module.fa_patient_api.default_hostname}/api/HelloWorld"
}

# API Policy
resource "azurerm_api_management_api_policy" "helloworld_policy" {
  api_name            = azurerm_api_management_api.helloworld.name
  api_management_name = azurerm_api_management_api.helloworld.api_management_name
  resource_group_name = azurerm_api_management_api.helloworld.resource_group_name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <send-request ignore-error="false" timeout="20" response-variable-name="codeResponse" mode="new">
      <set-url>${azurerm_key_vault_secret.fa_patient_api_host_key.id}?api-version=7.0</set-url>
      <set-method>GET</set-method>
      <authentication-managed-identity resource="https://vault.azure.net" />
    </send-request>
    <set-header name="x-functions-key" exists-action="override">
      <value>@((string)((IResponse)context.Variables["codeResponse"]).Body.As<JObject>()["value"])</value>
    </set-header>
  </inbound>
</policies>
XML
}

# API Operation
resource "azurerm_api_management_api_operation" "helloworld_get" {
  operation_id        = "helloworld-get"
  api_name            = azurerm_api_management_api.helloworld.name
  api_management_name = azurerm_api_management_api.helloworld.api_management_name
  resource_group_name = azurerm_api_management_api.helloworld.resource_group_name
  display_name        = "HelloWorld GET"
  method              = "GET"
  url_template        = "/"
}

# Key Vault
resource "azurerm_key_vault" "kv" {
  name                        = "${var.project_name}-kv-${var.environment}"
  resource_group_name         = var.project_name
  location                    = var.location
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  soft_delete_enabled         = false
  purge_protection_enabled    = false

  sku_name = "standard"
}

# Key Vault Access Policy
resource "azurerm_key_vault_access_policy" "sp" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "delete",
    "get",
    "set"
  ]
}

resource "azurerm_key_vault_access_policy" "apim" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = azurerm_api_management.apim.identity[0].tenant_id
  object_id    = azurerm_api_management.apim.identity[0].principal_id

  secret_permissions = [
    "get"
  ]
}

# Key Vault Secret
resource "azurerm_key_vault_secret" "cosmos_conn" {
  name         = "cosmos-conn"
  value        = azurerm_cosmosdb_account.cosmos.connection_strings[0]
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [
    azurerm_key_vault_access_policy.sp
  ]
}

resource "azurerm_key_vault_secret" "fa_patient_api_host_key" {
  name         = "fa-patient-api-host-key"
  value        = data.external.fa_patient_api_host_key.result.default
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [
    azurerm_key_vault_access_policy.sp
  ]
}

resource "azurerm_key_vault_secret" "fa_audit_api_host_key" {
  name         = "fa-audit-api-host-key"
  value        = data.external.fa_audit_api_host_key.result.default
  key_vault_id = azurerm_key_vault.kv.id

  depends_on = [
    azurerm_key_vault_access_policy.sp
  ]
}
