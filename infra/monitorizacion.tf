# Monitorización y alertas del Radar Costa Brava
#
# Reutiliza el Application Insights y el Log Analytics de main.tf.
# Las alertas solo se crean si se pasa un email (variable email_alertas):
# sin email no hay a quién avisar y así tampoco cuestan nada.

locals {
  con_alertas = var.email_alertas != ""
}

# Action Group: a quién se avisa cuando salta una alerta (aquí, un email)
resource "azurerm_monitor_action_group" "radar" {
  count               = local.con_alertas ? 1 : 0
  name                = "ag-radar-${local.sufijo}"
  resource_group_name = azurerm_resource_group.radar.name
  short_name          = "radar" # máximo 12 caracteres, sale en el asunto del email
  tags                = local.tags

  email_receiver {
    name                    = "email-pau"
    email_address           = var.email_alertas
    use_common_alert_schema = true
  }
}

# Alerta 1: "El radar se ha parado"
# Cada ejecución que guarda datos bien escribe en los logs "Radar: N aviones ahora...".
# Si en 15 minutos no aparece ninguno (deberían salir 3), el radar no está recogiendo.
# Es una alerta de logs: ejecuta una consulta KQL cada 15 minutos.
# (Azure no acepta ventanas de 20 minutos: o 15 o 30.)
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "radar_parado" {
  count                = local.con_alertas ? 1 : 0
  name                 = "El radar se ha parado"
  display_name         = "El radar se ha parado"
  description          = "No ha habido ninguna recogida de aviones correcta en los últimos 15 minutos."
  resource_group_name  = azurerm_resource_group.radar.name
  location             = azurerm_resource_group.radar.location
  scopes               = [azurerm_application_insights.radar.id]
  severity             = 1
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  tags                 = local.tags

  criteria {
    query                   = <<-KQL
      traces
      | where message startswith "Radar:"
    KQL
    time_aggregation_method = "Count"
    operator                = "LessThan"
    threshold               = 1

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  # Cuando vuelve a funcionar, la alerta se cierra sola y llega otro email
  auto_mitigation_enabled = true

  action {
    action_groups = [azurerm_monitor_action_group.radar[0].id]
  }
}

# Alerta 2: "Fallos en la recogida"
# Salta si alguna ejecución de la función termina con error en los últimos 15 minutos.
# Es una alerta de métricas: usa el contador de peticiones fallidas que
# Application Insights ya calcula solo, sin escribir ninguna consulta.
resource "azurerm_monitor_metric_alert" "funcion_falla" {
  count               = local.con_alertas ? 1 : 0
  name                = "Fallos en la recogida"
  description         = "Alguna ejecución de la Azure Function ha terminado con error en los últimos 15 minutos."
  resource_group_name = azurerm_resource_group.radar.name
  scopes              = [azurerm_application_insights.radar.id]
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  criteria {
    metric_namespace = "microsoft.insights/components"
    metric_name      = "requests/failed"
    aggregation      = "Count"
    operator         = "GreaterThan"
    threshold        = 0
  }

  action {
    action_group_id = azurerm_monitor_action_group.radar[0].id
  }
}

# Prueba de disponibilidad: Azure abre la web desde 5 sitios de Europa cada 15 minutos.
# Es la prueba "ping" clásica, que es gratis. Microsoft la retira el 30/09/2028;
# la sustituta (prueba "estándar") se cobra por ejecución. Más detalle en el README.
resource "azurerm_application_insights_web_test" "web" {
  name                    = "web-radar-${local.sufijo}"
  resource_group_name     = azurerm_resource_group.radar.name
  location                = azurerm_resource_group.radar.location
  application_insights_id = azurerm_application_insights.radar.id
  kind                    = "ping"
  frequency               = 900
  timeout                 = 30
  enabled                 = true
  description             = "Comprueba que la web del radar responde"
  geo_locations = [
    "emea-nl-ams-azr",  # West Europe
    "emea-gb-db3-azr",  # North Europe
    "emea-fr-pra-edge", # France Central
    "emea-ch-zrh-edge", # France South
    "emea-ru-msa-edge", # UK South
  ]

  configuration = <<-XML
    <WebTest Name="web-radar" Id="5b0bd4a6-1f0e-4f4e-9d6c-2f8a8a0c7e11" Enabled="True" Timeout="30" xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010" PreAuthenticate="True" Proxy="default" StopOnError="False">
      <Items>
        <Request Method="GET" Guid="0c3f3c1e-7a51-4b8e-a1b8-6d4c3c2b9f20" Version="1.1" Url="${azurerm_storage_account.radar.primary_web_endpoint}" ThinkTime="0" Timeout="30" ParseDependentRequests="False" FollowRedirects="True" RecordResult="True" Cache="False" ResponseTimeGoal="0" Encoding="utf-8" ExpectedHttpStatusCode="200" IgnoreHttpStatusCode="False" />
      </Items>
    </WebTest>
  XML

  lifecycle {
    # Azure añade una etiqueta "hidden-link" que enlaza la prueba con App Insights
    ignore_changes = [tags]
  }
}

# Alerta 3: "La web no responde"
# Salta si la web falla desde 3 de los 5 sitios a la vez (si falla solo uno,
# seguramente es un problema de red de ese sitio y no de la web).
resource "azurerm_monitor_metric_alert" "web_caida" {
  count               = local.con_alertas ? 1 : 0
  name                = "La web no responde"
  description         = "La web del radar no responde desde al menos 3 de las 5 ubicaciones de prueba."
  resource_group_name = azurerm_resource_group.radar.name
  scopes              = [azurerm_application_insights_web_test.web.id, azurerm_application_insights.radar.id]
  severity            = 1
  frequency           = "PT5M"
  window_size         = "PT15M"
  tags                = local.tags

  application_insights_web_test_location_availability_criteria {
    web_test_id           = azurerm_application_insights_web_test.web.id
    component_id          = azurerm_application_insights.radar.id
    failed_location_count = 3
  }

  action {
    action_group_id = azurerm_monitor_action_group.radar[0].id
  }
}

# Workbook "Radar Costa Brava – Salud": un panel con 4 gráficos para ver de un vistazo
# cómo va la función. Está en Monitor > Workbooks (o en el App Insights > Workbooks).
resource "random_uuid" "workbook" {} # Azure exige que el nombre de un Workbook sea un GUID

locals {
  # Cada gráfico es una consulta KQL sobre Application Insights
  graficos_salud = [
    {
      titulo = "Ejecuciones por hora"
      tipo   = "barchart"
      query  = <<-KQL
        requests
        | summarize Correctas = countif(success == true), Fallidas = countif(success == false) by bin(timestamp, 1h)
        | order by timestamp asc
      KQL
    },
    {
      titulo = "Errores y avisos por hora"
      tipo   = "barchart"
      query  = <<-KQL
        traces
        | summarize Errores = countif(severityLevel >= 3), Avisos = countif(severityLevel == 2) by bin(timestamp, 1h)
        | order by timestamp asc
      KQL
    },
    {
      titulo = "Duración de la función (segundos)"
      tipo   = "timechart"
      query  = <<-KQL
        requests
        | summarize Media = round(avg(duration) / 1000, 2), ['Más lenta'] = round(max(duration) / 1000, 2) by bin(timestamp, 1h)
        | order by timestamp asc
      KQL
    },
    {
      titulo = "Aviones detectados por hora"
      tipo   = "timechart"
      query  = <<-KQL
        traces
        | where message startswith "Radar:"
        | parse message with "Radar: " aviones:int " aviones ahora" *
        | summarize Media = round(avg(aviones), 1), ['Máximo'] = max(aviones) by bin(timestamp, 1h)
        | order by timestamp asc
      KQL
    },
  ]
}

resource "azurerm_application_insights_workbook" "salud" {
  name                = random_uuid.workbook.result
  resource_group_name = azurerm_resource_group.radar.name
  location            = azurerm_resource_group.radar.location
  display_name        = "Radar Costa Brava – Salud"
  source_id           = lower(azurerm_application_insights.radar.id) # tiene que ir en minúsculas
  category            = "workbook"
  tags                = local.tags

  data_json = jsonencode({
    version             = "Notebook/1.0"
    fallbackResourceIds = [azurerm_application_insights.radar.id]
    isLocked            = false
    items = concat(
      [
        {
          type = 1
          name = "titulo"
          content = {
            json = "## Radar Costa Brava – Salud\nCómo va la Azure Function que recoge los aviones cada 5 minutos. Si algo se tuerce, aquí se ve antes que en la web."
          }
        },
        {
          type = 9
          name = "periodo"
          content = {
            version = "KqlParameterItem/1.0"
            style   = "pills"
            parameters = [{
              id         = "6c1a4c8e-2b0f-4f7a-9d55-0e6f1f2a3b4c"
              version    = "KqlParameterItem/1.0"
              name       = "Periodo"
              type       = 4
              isRequired = true
              value      = { durationMs = 86400000 }
              typeSettings = {
                allowCustom = true
                selectableValues = [
                  { durationMs = 3600000 },
                  { durationMs = 21600000 },
                  { durationMs = 86400000 },
                  { durationMs = 259200000 },
                  { durationMs = 604800000 },
                ]
              }
            }]
          }
        },
      ],
      [
        for i, g in local.graficos_salud : {
          type        = 3
          name        = "grafico-${i + 1}"
          customWidth = "50"
          content = {
            version                  = "KqlItem/1.0"
            title                    = g.titulo
            query                    = g.query
            size                     = 0
            queryType                = 0
            resourceType             = "microsoft.insights/components"
            timeContextFromParameter = "Periodo"
            visualization            = g.tipo
          }
        }
      ]
    )
  })
}
