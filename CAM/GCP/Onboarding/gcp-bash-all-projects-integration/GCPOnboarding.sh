#!/bin/bash

export VI_API_KEY="<v1-api-key>"
export V1_ACCOUNT_ID="<v1-account-id>"
export TREND_MICRO_API_URL="https://api.xdr.trendmicro.com/beta/cam/gcpProjects/generateTerraformTemplate"

verify_and_add_to_vision_one() {
    project_id="$1"
    api_key="$2"
    v1_account_id="$3"
    trend_micro_api_url="$4"
    log_file="$5"
    error_log_file="$6"

    # Check if project is registered in Vision One
    response=$(curl -s -w "\n%{http_code}" -X GET \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -H "x-user-role: Master Administrator" \
        -H "x-customer-id: $v1_account_id" \
        "$trend_micro_api_url/gcpProjects/$project_id")

    if [[ $(echo "$response" | tail -n1) != "200" ]]; then
        echo "Project $project_id not found in Vision One. Integrating..." | tee -a "$log_file"
        # Call integration endpoint if needed
        workloadIdentityPoolId=$(gcloud iam workload-identity-pools list --location="global" --filter="name:projects/$project_id" --format="value(name)")
        oidcProviderId=$(gcloud iam workload-identity-pools providers list --location="global" --workload-identity-pool="$workloadIdentityPoolId" --format="value(name)")
        serviceAccountId=$(gcloud iam service-accounts list --filter="email:vision-one-service-account@$project_id.iam.gserviceaccount.com" --format="value(uniqueId)")
        projectNumber=$(gcloud projects describe "$project_id" --format="value(projectNumber)")

        integration_response=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Authorization: Bearer $api_key" \
            -H "Content-Type: application/json" \
            -H "x-user-role: Master Administrator" \
            -H "x-customer-id: $v1_account_id" \
            -d '{
                "workloadIdentityPoolId": "'$workloadIdentityPoolId'",
                "oidcProviderId": "'$oidcProviderId'",
                "serviceAccountId": "'$serviceAccountId'",
                "projectNumber": "'$projectNumber'",
                "name": "'$project_name'",
                "description": ""
            }' \
            "$trend_micro_api_url")

        integration_status_code=$(echo "$integration_response" | tail -n1)
        integration_response_body=$(echo "$integration_response" | sed '$d')

        if [[ "$integration_status_code" == "200" ]]; then
            echo "Integration successful for project $project_name ($project_id)." | tee -a "$log_file"
        else
            echo "Integration failed for project $project_name ($project_id): $integration_response_body" | tee -a "$error_log_file"
        fi
    else
        echo "Project $project_id already exists in Vision One." | tee -a "$log_file"
    fi
}

export -f verify_and_add_to_vision_one

process_project() {
    project_info="$1"
    action="$2"
    script_dir="$3"
    log_file="$script_dir/execution_log.txt"
    error_log_file="$script_dir/error_log.txt"

    if [ -z "$log_file" ]; then
        echo "Error: log_file variable is not set." >&2
        exit 1
    fi
    if [ -z "$error_log_file" ]; then
        echo "Error: error_log_file variable is not set." >&2
        exit 1
    fi
    # Crear los archivos de log si no existen
    touch "$log_file"
    touch "$error_log_file"

    api_key="${VI_API_KEY}"
    v1_account_id="${V1_ACCOUNT_ID}"

    trend_micro_api_url="${TREND_MICRO_API_URL}"
    project_id=$(echo "$project_info" | cut -d',' -f1)
    project_name=$(echo "$project_info" | cut -d',' -f2)

    echo "Log de ejecución - $(date)" >> "$log_file"

    if [ -z "$log_file" ]; then
        echo "Error: log_file variable is not set." >&2
        exit 1
    fi

    gcloud config set project $project_id 2>>"$error_log_file"

    echo "Processing project: $project_id ($project_name)" | tee -a "$log_file"

    json_body=$(cat <<EOF
{
    "gcpProjectName": "$project_name"
}
EOF
)

    response=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -H "x-user-role: Master Administrator" \
        -H "x-customer-id: $v1_account_id" \
        -d "$json_body" \
        "$trend_micro_api_url" 2>>"$error_log_file")

    status_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')
    gcloud iam service-accounts list --filter="email:vision-one-service-account@"$project_id".iam.gserviceaccount.com" --format="value(uniqueId)"

    if [[ "$status_code" == "200" ]]; then
        echo "Download template complete for $project_name" | tee -a "$log_file"
        mkdir -p "$project_id"
        output_file="$project_id/v1-cloud-project-gcp.tf"
        echo "$response_body" > "$output_file" 2>>"$error_log_file"

        cd "$project_id" || { echo "Error: can't move to directory $project_id" | tee -a "$log_file"; return 1; }
        export GOOGLE_CLOUD_PROJECT=$project_id
        terraform init >>"$log_file" 2>>"$error_log_file"
        terraform $action -auto-approve >>"$log_file" 2>>"$error_log_file"

        if [[ "$action" == "apply" ]]; then
            verify_and_add_to_vision_one "$project_id" "$api_key" "$v1_account_id" "$trend_micro_api_url" "$log_file" "$error_log_file"
        fi

        cd - > /dev/null
    else
        echo "Fail" | tee -a "$log_file"
        echo "Error: $response_body" >> "$error_log_file"
    fi
}

export -f process_project # Exportar la función para que esté disponible para xargs
script_dir=$(dirname "$(readlink -f "$0")")

action=${1:-apply} #define action to execute the terraform, default action apply

if [ "$action" != "apply" ] && [ "$action" != "destroy" ]; then
    echo "Error: Invalide action. Use 'apply' or 'destroy'." >&2
    exit 1
fi
log_file="$script_dir/execution_log.txt"

gcloud projects list --format="csv(projectId, name)" >> "$log_file"

# Listar todos los proyectos en GCP
gcloud projects list --format="csv(projectId, name)" | tail -n +2 |
xargs -P 10 -d '\n' -I {} bash -c 'process_project "$@" "$1" "$2"'  _ {} "$action" "$script_dir"

echo "Script execution completed" | tee -a "$log_file"
