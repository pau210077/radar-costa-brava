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
