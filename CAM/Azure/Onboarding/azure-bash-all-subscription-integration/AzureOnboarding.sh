#!/bin/bash

# Variables globales para almacenar el Application ID y Principal ID
global_app_id=""
global_principal_id=""

if [[ -z "$API_KEY" || -z "$V1_ACCOUNT_ID" ]]; then
  echo "Error: Las variables de entorno API_KEY y V1_ACCOUNT_ID deben estar definidas."
  exit 1
fi

api_key="${API_KEY}"
v1_account_id="${V1_ACCOUNT_ID}"
vision_one_api_url="https://api.xdr.trendmicro.com/beta/cam/azureSubscriptions"
workload_instance_id="${WORKLOAD_INSTANCE_ID}"
issuer="https://cloudaccounts-us.xdr.trendmicro.com"
subject="urn:visionone:identity:us:$v1_account_id:account/$v1_account_id"

all_results=()

if [[ -n "$workload_instance_id" ]]; then
  connected_security_services=$(cat <<EOF
  "connectedSecurityServices": [
    {
      "name": "workload",
      "instanceIds": ["$workload_instance_id"]
    }
  ]
EOF
)
else
  connected_security_services=$(cat <<EOF
  "connectedSecurityServices": [{}]
EOF
)
fi

required_resource_accesses='[
    {
        "resourceAppId": "00000002-0000-0000-c000-000000000000",
        "resourceAccess": [
            {"id": "311a71cc-e848-46a1-bdf8-97ff7156d8e6", "type": "Scope"},
            {"id": "5778995a-e1bf-45b8-affa-663a9f3f4d04", "type": "Scope"},
            {"id": "c582532d-9d9e-43bd-a97c-2667a28ce295", "type": "Scope"},
            {"id": "5778995a-e1bf-45b8-affa-663a9f3f4d04", "type": "Role"}
        ]
    },
    {
        "resourceAppId": "00000003-0000-0000-c000-000000000000",
        "resourceAccess": [
            {"id": "e1fe6dd8-ba31-4d61-89e7-88639da4683d", "type": "Scope"},
            {"id": "a154be20-db9c-4678-8ab7-66f6cc099a59", "type": "Scope"},
            {"id": "7ab1d382-f21e-4acd-a863-ba3e13f7da61", "type": "Role"},
            {"id": "df021288-bdef-4463-88db-98f22de89214", "type": "Role"}
        ]
    }
]'

log_file="execution_log.txt"
echo "Log de ejecución - $(date)" > $log_file

process_subscription() {
    subscription_id=$1
    subscription_name=$2

    app_registration_name="v1-app-registration-${subscription_id}"
    federated_cred_name="v1-fed-cred"
    role_name="v1-custom-role-${subscription_id}"
    role_definition_file="custom_role_definition.json"

    az account set --subscription "$subscription_id" > /dev/null 2>&1

    # Reutilizar Application ID y Principal ID si ya existen
    if [[ -z "$global_app_id" ]]; then
        app_id=$(az ad app list --filter "displayName eq '$app_registration_name'" --query "[0].appId" -o tsv 2>/dev/null)
        if [ -z "$app_id" ]; then
            app_id=$(az ad app create --display-name "$app_registration_name" --required-resource-accesses "$required_resource_accesses" --query "appId" -o tsv 2>/dev/null)
            echo "App Registration Created: $subscription_name" | tee -a $log_file
            global_app_id="$app_id"  # Almacenar el App ID para las siguientes suscripciones
        else
            echo "App Registration Already Exist: $subscription_name" | tee -a $log_file
            global_app_id="$app_id"  # Usar el App ID existente
        fi
        federated_cred_exists=$(az ad app federated-credential list --id "$app_id" --query "[?name=='$federated_cred_name'].name" -o tsv 2>/dev/null)
        if [ -z "$federated_cred_exists" ]; then
            az ad app federated-credential create --id "$app_id" --parameters "{\"name\": \"$federated_cred_name\", \"issuer\": \"$issuer\", \"subject\": \"$subject\", \"description\": \"Federated Credentials created by Trend Micro Vision One, used for Accessing Azure Resources\", \"audiences\": [\"api://AzureADTokenExchange\"]}" > /dev/null 2>&1
            echo "Federated Credentials Created: $subscription_name" | tee -a $log_file
        else
            echo "Federated Credentials Already Exist: $subscription_name" | tee -a $log_file
        fi
    else
        app_id="$global_app_id"
        echo "Reutilizando App ID para $subscription_name - $app_id" | tee -a $log_file
    fi

    # Reutilizar Principal ID si ya existe
    if [[ -z "$global_principal_id" ]]; then
        principal_id=$(az ad sp list --filter "appId eq '$app_id'" --query "[0].id" -o tsv 2>/dev/null)
        if [ -z "$principal_id" ]; then
            az ad sp create --id "$app_id" > /dev/null 2>&1
            principal_id=$(az ad sp show --id "$app_id" --query id --out tsv 2>/dev/null)
            echo "Principal ID Created: $subscription_name" | tee -a $log_file
            global_principal_id="$principal_id"  # Almacenar el Principal ID para las siguientes suscripciones
        else
            echo "Principal ID Already Exist: $subscription_name" | tee -a $log_file
            global_principal_id="$principal_id"  # Usar el Principal ID existente
        fi
    else
        principal_id="$global_principal_id"
        echo "Reutilizando Principal ID para $subscription_name $principal_id" | tee -a $log_file
    fi

    role_definition=$(cat <<EOF
{
    "Name": "$role_name",
    "Description": "Vision One Integration",
    "Actions": [
        "Microsoft.ContainerService/managedClusters/listClusterUserCredential/action",
        "Microsoft.ContainerService/managedClusters/read",
        "Microsoft.Resources/subscriptions/resourceGroups/read",
        "Microsoft.Authorization/roleAssignments/read",
        "Microsoft.Authorization/roleDefinitions/read",
        "*/read",
        "Microsoft.AppConfiguration/configurationStores/ListKeyValue/action",
        "Microsoft.Network/networkWatchers/queryFlowLogStatus/action",
        "Microsoft.Web/sites/config/list/Action"
    ],
    "DataActions": [],
    "NotDataActions": [],
    "AssignableScopes": ["/subscriptions/$subscription_id"]
}
EOF
)

    echo "$role_definition" > "$role_definition_file"
    role_exists=$(az role definition list --name "$role_name" --query "[?roleName=='$role_name'].[roleName]" -o tsv 2>/dev/null)
    if [ -z "$role_exists" ]; then
        az role definition create --role-definition "$role_definition_file" > /dev/null 2>&1
        echo "Role Definition Created: $subscription_name" | tee -a $log_file
    else
        echo "Role Definition Already Exist: $subscription_name" | tee -a $log_file
    fi
    rm -f "$role_definition_file"

    role_assignment_exists=$(az role assignment list --assignee "$principal_id" --role "$role_name" --query "[?principalId=='$principal_id' && roleDefinitionName=='$role_name']" -o tsv 2>/dev/null)
    if [ -z "$role_assignment_exists" ]; then
        az role assignment create --assignee "$principal_id" --role "$role_name" --scope "/subscriptions/$subscription_id" > /dev/null 2>&1
        echo "Role Assignment Created: $subscription_name" | tee -a $log_file
    else
        echo "Role Assignment Already Exist: $subscription_name" | tee -a $log_file
    fi

    tenant_id=$(az account show --query tenantId -o tsv 2>/dev/null)
    http_endpoint="https://api.xdr.trendmicro.com/beta/cam"
    add_account_url="$http_endpoint/azureSubscriptions"

    echo "$subscription_id, $app_id, $tenant_id, $subscription_name, $v1_account_id, $connected_security_services"
    json_body=$(cat <<EOF
{
    "subscriptionId": "$subscription_id",
    "applicationId": "$app_id",
    "tenantId": "$tenant_id",
    "name": "$subscription_name",
    "description": "Vision One Integration with Cloud Posture",
    $connected_security_services
}
EOF
)

    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -H "x-user-role: Master Administrator" \
        -H "x-customer-id: $v1_account_id" \
        -d "$json_body" \
        "$add_account_url")

    status_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [[ "$status_code" == "201" ]]; then
        echo "Account registration VisionOne complete: $subscription_name" | tee -a $log_file
    else
        error_code=$(echo "$response_body" | jq -r '.error.innererror.code')
        if [[ "$error_code" == "account-exist" ]]; then
            echo "The account $subscription_name already exists for this Azure subscription in Vision One" | tee -a $log_file
        else
            echo "Unexpected error response: $response_body" | tee -a $log_file
        fi
    fi
}

subscriptions=$(az account list --query "[].{id:id, name:name}" -o tsv | awk '{print $1 "," $2}')

while IFS=',' read -r subscription_id subscription_name; do
    {
        process_subscription "$subscription_id" "$subscription_name"
    } 
done <<< "$subscriptions"
wait
