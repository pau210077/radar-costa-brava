# Infraestructura del Radar Costa Brava en Azure

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none" # se registran en desplegar.sh
}

variable "region" {
  default = "francecentral"
}

variable "email_alertas" {
  description = "Email para las alertas y el aviso de presupuesto (vacío = sin avisos)"
  default     = ""
}

# Sufijo aleatorio: los nombres de Storage y Function App deben ser únicos en todo Azure
resource "random_string" "sufijo" {
  length  = 5
  upper   = false
  special = false
}

locals {
  sufijo = random_string.sufijo.result
  tags   = { proyecto = "radar-costa-brava" }
}

resource "azurerm_resource_group" "radar" {
  name     = "rg-radar-costabrava"
  location = var.region
  tags     = local.tags
}

# Storage Account: aloja la web (static website) y los datos que escribe la función
resource "azurerm_storage_account" "radar" {
  name                     = "stradar${local.sufijo}"
  resource_group_name      = azurerm_resource_group.radar.name
  location                 = azurerm_resource_group.radar.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags
}

resource "azurerm_storage_account_static_website" "web" {
  storage_account_id = azurerm_storage_account.radar.id
  index_document     = "index.html"
}

# Monitorización de la función (con límite diario para no pagar nada)
resource "azurerm_log_analytics_workspace" "radar" {
  name                = "log-radar-${local.sufijo}"
  resource_group_name = azurerm_resource_group.radar.name
  location            = azurerm_resource_group.radar.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.1
  tags                = local.tags
}

resource "azurerm_application_insights" "radar" {
  name                = "appi-radar-${local.sufijo}"
  resource_group_name = azurerm_resource_group.radar.name
  location            = azurerm_resource_group.radar.location
  workspace_id        = azurerm_log_analytics_workspace.radar.id
  application_type    = "web"
  tags                = local.tags
}

# Azure Functions en plan de consumo: solo se paga por uso (1 millón de ejecuciones/mes gratis)
resource "azurerm_service_plan" "radar" {
  name                = "asp-radar-${local.sufijo}"
  resource_group_name = azurerm_resource_group.radar.name
  location            = azurerm_resource_group.radar.location
  os_type             = "Linux"
  sku_name            = "Y1"
  tags                = local.tags
}

resource "azurerm_linux_function_app" "radar" {
  name                       = "func-radar-${local.sufijo}"
  resource_group_name        = azurerm_resource_group.radar.name
  location                   = azurerm_resource_group.radar.location
  service_plan_id            = azurerm_service_plan.radar.id
  storage_account_name       = azurerm_storage_account.radar.name
  storage_account_access_key = azurerm_storage_account.radar.primary_access_key
  https_only                 = true
  tags                       = local.tags

  site_config {
    application_insights_connection_string = azurerm_application_insights.radar.connection_string
    application_stack {
      python_version = "3.11"
    }
  }

  app_settings = {
    SCM_DO_BUILD_DURING_DEPLOYMENT = "true"
    ENABLE_ORYX_BUILD              = "true"
    # true = la función falla a propósito, para probar las alertas (ver README)
    SIMULAR_FALLO = "false"
  }

  lifecycle {
    # Al subir el código, Azure añade este ajuste: que Terraform no lo borre
    ignore_changes = [
      app_settings["WEBSITE_RUN_FROM_PACKAGE"],
      tags["hidden-link: /app-insights-resource-id"],
    ]
  }
}

# Presupuesto: avisa por email si el gasto pasa de 5 € al mes
resource "azurerm_consumption_budget_resource_group" "radar" {
  count             = var.email_alertas == "" ? 0 : 1
  name              = "presupuesto-radar"
  resource_group_id = azurerm_resource_group.radar.id
  amount            = 5
  time_grain        = "Monthly"

  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", timestamp())
  }

  notification {
    enabled        = true
    threshold      = 50
    operator       = "GreaterThan"
    contact_emails = [var.email_alertas]
  }

  lifecycle {
    ignore_changes = [time_period]
  }
}

output "grupo" {
  value = azurerm_resource_group.radar.name
}

output "funcion" {
  value = azurerm_linux_function_app.radar.name
}

output "storage" {
  value = azurerm_storage_account.radar.name
}

output "web" {
  value = azurerm_storage_account.radar.primary_web_endpoint
}
