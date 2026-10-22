#!/usr/bin/env bash
# Borra todo lo que ha creado el Radar Costa Brava en Azure.
# Ejecutar en Azure Cloud Shell (Bash):    bash borrar.sh

set -euo pipefail
cd "$(dirname "$0")"

read -r -p "Se borrará el grupo rg-radar-costabrava y todo lo que contiene. Escribe BORRAR para seguir: " respuesta
if [[ "$respuesta" != "BORRAR" ]]; then
  echo "Cancelado, no se ha borrado nada."
  exit 0
fi

az group delete --name rg-radar-costabrava --yes
rm -rf infra/.terraform infra/.terraform.lock.hcl infra/terraform.tfstate infra/terraform.tfstate.backup

echo "Listo: todo borrado."
