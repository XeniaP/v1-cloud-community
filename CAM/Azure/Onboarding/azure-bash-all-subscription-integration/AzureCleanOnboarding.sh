#!/bin/bash

if [[ -z "$API_KEY" || -z "$V1_ACCOUNT_ID" ]]; then
  echo "Error: The Env Variables API_KEY and V1_ACCOUNT_ID isn't exists."
  exit 1
fi

api_key="${API_KEY}"
v1_account_id="${V1_ACCOUNT_ID}"

all_results=()
process_subscription() {
    subscription_line=$1
    subscription_name=$(echo $subscription_line | cut -d ',' -f2)
    subscription_id=$(echo $subscription_line | cut -d ',' -f1)

    app_registration_name="v1-app-registration-${subscription_id}"
    federated_cred_name="v1-fed-cred"
    role_name="v1-custom-role-${subscription_id}"
    rg_name="trendmicro-v1-${subscription_id}" 
    progress=()

    az account set --subscription "$subscription_id" > /dev/null 2>&1

    # Step 1: Delete Account in Vision One
    tenant_id=$(az account show --query tenantId -o tsv 2>/dev/null)
    http_endpoint="https://api.xdr.trendmicro.com/beta/cam"
    delete_account_url="$http_endpoint/azureSubscriptions/$subscription_id"

    status_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
        -H "Authorization: Bearer $api_key" \
        -H "x-user-role: Master Administrator" \
        -H "x-customer-id: $v1_account_id" \
        "$delete_account_url")

    if [[ "$status_code" == "204" ]]; then
        progress+=("Completed")
    else
        progress+=("Failed")
    fi

    # Step 2: Eliminar la asignación de rol
    principal_id=$(az ad sp list --filter "displayName eq '$app_registration_name'" --query "[0].id" -o tsv 2>/dev/null)
    if [ ! -z "$principal_id" ]; then
        az role assignment delete --assignee $principal_id --role "$role_name" --scope "/subscriptions/$subscription_id" > /dev/null 2>&1
        progress+=("Completed")
    else
        progress+=("NotExist")
    fi

    # Step 3: Eliminar el rol personalizado
    role_exists=$(az role definition list --name "$role_name" --query "[?roleName=='$role_name'].[roleName]" -o tsv 2>/dev/null)
    if [ ! -z "$role_exists" ]; then
        az role definition delete --name "$role_name" > /dev/null 2>&1
        progress+=("Completed")
    else
        progress+=("NotExist")
    fi

    rg_exists=$(az group exists -n "$rg_name" 2>/dev/null)

    if [[ "$rg_exists" == "true" ]]; then
    # elimina locks que podrían bloquear la eliminación
    mapfile -t lock_ids < <(az lock list -g "$rg_name" --query "[].id" -o tsv 2>/dev/null)
    if (( ${#lock_ids[@]} > 0 )); then
        for id in "${lock_ids[@]}"; do
        az lock delete --ids "$id" >/dev/null 2>&1 || true
        done
    fi

    # opcional: forzar tipos “difíciles” (VMs, VMSS, etc.)
    # export FORCE_TYPES="Microsoft.Compute/virtualMachines,Microsoft.Compute/virtualMachineScaleSets"
    if [[ -n "${FORCE_TYPES:-}" ]]; then
        az group delete -n "$rg_name" --yes --no-wait \
        --force-deletion-types "$FORCE_TYPES" >/dev/null 2>&1 || del_rc=$?
    else
        az group delete -n "$rg_name" --yes --no-wait >/dev/null 2>&1 || del_rc=$?
    fi

    if [[ ${del_rc:-0} -ne 0 ]]; then
        progress+=("Failed")
    else
        # espera a que quede realmente eliminado
        az group wait -n "$rg_name" --deleted >/dev/null 2>&1 || true
        progress+=("Completed")
    fi
    else
    progress+=("NotExist")
    fi

    # Step 4: Eliminar las credenciales federadas
    app_id=$(az ad app list --filter "displayName eq '$app_registration_name'" --query "[0].appId" -o tsv 2>/dev/null)
    echo "$app_id"
    if [ ! -z "$app_id" ]; then
        federated_cred_exists=$(az ad app federated-credential list --id "$app_id" --query "[?name=='$federated_cred_name'].name" -o tsv 2>/dev/null)
        if [ ! -z "$federated_cred_exists" ]; then
            az ad app federated-credential delete --id "$app_id" --name "$federated_cred_name" > /dev/null 2>&1
            progress+=("Completed")
        else
            progress+=("NotExist")
        fi
        
        # Step 5: Eliminar la aplicación registrada
        if [ -z "$app_id" ]; then
            progress+=("NotExist")
        else
            az ad app delete --id "$app_id" > /dev/null 2>&1
            progress+=("Completed")
        fi
    else
        progress+=("NotExist")
    fi

    # Guardar resultados de la suscripción
    all_results+=("$(printf "%s\t%s\t%s\t%s\t%s\t%s" "$subscription_name" "${progress[0]}" "${progress[1]}" "${progress[2]}" "${progress[3]}" "${progress[4]}")")
}

# Leer el archivo de suscripciones y procesar secuencialmente
start_time=$(date +%s)

subscriptions=$(az account list --query "[].{id:id, name:name}" -o tsv | awk '{print $1 "," $2}')

while IFS= read -r subscription_line; do
    sub_start_time=$(date +%s)
    process_subscription "$subscription_line"
    sub_end_time=$(date +%s)
    sub_time=$((sub_end_time - sub_start_time))
    echo "Processed subscription: $(echo $subscription_line | cut -d ',' -f2) in $sub_time seconds"
done <<< "$subscriptions"
end_time=$(date +%s)

# Calcular el tiempo total
total_time=$((end_time - start_time))

# Imprimir reporte final
echo -e "Subscription\tAPI Unregistration\tRole Assignment Deletion\tCustom Role Deletion\tFederated Credential Deletion\tApp Registration Deletion"
for result in "${all_results[@]}"; do
    echo -e "$result"
done

# Imprimir el tiempo total
echo "Total time: $total_time seconds"
