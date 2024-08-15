#!/bin/bash

# Variables, pls change with your values
api_key="<API_KEY>"
v1_account_id="<V1_ACCOUNT_ID"

trend_micro_api_url="https://api.xdr.trendmicro.com/beta/cam/gcpProjects/generateTerraformTemplate"
log_file="execution_log.txt"

echo "Execution Logs - $(date)" > "$log_file"

# process each project
process_project() {
    project_info="$1"
    project_id=$(echo "$project_info" | cut -d',' -f1)
    project_name=$(echo "$project_info" | cut -d',' -f2)

    gcloud config set project $project_id 2>/dev/null

    echo "Processing project: $project_id ($project_name)" | tee -a "$log_file"
    gcloud services enable cloudresourcemanager.googleapis.com --project="$project_id" 2>/dev/null 
    gcloud services enable cloudbuild.googleapis.com --project="$project_id" 2>/dev/null
    gcloud services enable artifactregistry.googleapis.com --project="$project_id" 2>/dev/null
    gcloud services enable containerregistry.googleapis.com --project="$project_id" 2>/dev/null
    gcloud services enable secretmanager.googleapis.com --project="$project_id" 2>/dev/null

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
        "$trend_micro_api_url" 2>/dev/null)

    status_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')

    if [[ "$status_code" == "200" ]]; then
        echo "API call successful for $project_name" | tee -a "$log_file"
        mkdir -p "$project_id"
        output_file="$project_id/v1-cloud-project-gcp.tf"
        echo "$response_body" > "$output_file" 2>/dev/null

        cd "$project_id" || { echo "Error: Can't move to the directory $project_id" | tee -a "$log_file"; return 1; }
        export GOOGLE_CLOUD_PROJECT=$project_id
        terraform init > /dev/null 2>&1
        terraform apply -auto-approve > /dev/null 2>&1
        #terraform destroy -auto-approve
        cd - > /dev/null
    else
        echo "Fail" | tee -a "$log_file"
        echo "Error: $response_body" >> "$log_file"
    fi
}
export -f process_project
# List project in GCP
gcloud projects list --format="csv(projectId, name)" | tail -n +2 |
xargs -P 10 -d '\n' -I {} bash -c 'process_project "$@"' _ {}

echo "Script execution completed" | tee -a "$log_file"
