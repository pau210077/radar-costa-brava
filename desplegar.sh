#!/usr/bin/env bash
# Despliega el Radar Costa Brava entero.
# Ejecutar en Azure Cloud Shell (Bash):    bash desplegar.sh
# Con aviso de presupuesto por email:      EMAIL=tu@correo.com bash desplegar.sh

set -euo pipefail
cd "$(dirname "$0")"

echo "==> 1/4 Preparando la suscripción (la primera vez tarda un par de minutos)"
for proveedor in Microsoft.Web Microsoft.Storage Microsoft.Insights Microsoft.OperationalInsights Microsoft.Consumption; do
  az provider register --namespace "$proveedor" --wait
done

echo "==> 2/4 Creando la infraestructura con Terraform"
terraform -chdir=infra init -input=false
# Azure a veces da errores pasajeros (404) justo después de crear un recurso: se reintenta
for intento in 1 2 3; do
  if terraform -chdir=infra apply -auto-approve -input=false -var "email_alertas=${EMAIL:-}"; then
    break
  fi
  if [[ $intento -eq 3 ]]; then
    echo "Terraform ha fallado 3 veces. Revisa el error de arriba." >&2
    exit 1
  fi
  echo "Error de Azure, reintento en 30 segundos..."
  sleep 30
done

GRUPO="$(terraform -chdir=infra output -raw grupo)"
FUNCION="$(terraform -chdir=infra output -raw funcion)"
STORAGE="$(terraform -chdir=infra output -raw storage)"
WEB="$(terraform -chdir=infra output -raw web)"

echo "==> 3/4 Subiendo la web"
CLAVE="$(az storage account keys list --resource-group "$GRUPO" --account-name "$STORAGE" --query "[0].value" -o tsv)"
# '$web' es el nombre real del contenedor de la web estática, no una variable
# shellcheck disable=SC2016
az storage blob upload-batch --account-name "$STORAGE" --account-key "$CLAVE" \
  --destination '$web' --source web --overwrite --output none

echo "==> 4/4 Subiendo la Azure Function"
rm -f funcion.zip
(cd function && zip -qr ../funcion.zip . -x "__pycache__/*" ".venv/*")
for intento in 1 2 3; do
  if az functionapp deployment source config-zip --resource-group "$GRUPO" --name "$FUNCION" \
      --src funcion.zip --build-remote true --output none; then
    break
  fi
  if [[ $intento -eq 3 ]]; then
    echo "No se ha podido subir la función. Vuelve a ejecutar: bash desplegar.sh" >&2
    exit 1
  fi
  echo "La Function App aún se está iniciando, reintento en 30 segundos..."
  sleep 30
done
rm -f funcion.zip

cat <<EOF

=====================================================
 Radar desplegado

 Web: $WEB
 Alertas: ${EMAIL:-sin email, no se han creado alertas}

 Los primeros aviones aparecen en menos de 5 minutos.
 Si has puesto email, Azure te avisa por correo de que te ha añadido al Action Group.
=====================================================
EOF
