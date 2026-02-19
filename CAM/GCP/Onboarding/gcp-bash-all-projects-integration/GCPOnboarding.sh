#!/bin/bash

if [[ -z "$API_KEY" || -z "$V1_ACCOUNT_ID" ]]; then
  echo "Error: Las variables de entorno API_KEY y V1_ACCOUNT_ID deben estar definidas."
  exit 1
fi

VISION_ONE_ENDPOINT="https://cloudaccounts-us.xdr.trendmicro.com/beta/cam/gcpProjects"
api_key="${API_KEY}"
v1_account_id="${V1_ACCOUNT_ID}"
workload_instance_id="${WORKLOAD_INSTANCE_ID}"

PROJECTS=($(gcloud projects list --filter="lifecycleState=ACTIVE" --format="value(projectId)"))

process_project() {
  project_info="$1"
  project_id=$(echo "$project_info" | cut -d',' -f1)
  project_name=$(echo "$project_info" | cut -d',' -f2)
  projectNumber=$(gcloud projects describe $project_id --format="value(projectNumber)")
  if [[ $(project_integrated "$project_id" "$2" "$3") == 1 ]]; then
    return
  fi
  gcloud config set project $project_id
  enable_apis $project_id
  check_workload_pool "$project_id" "$2" "$3" "$4"
}

check_workload_pool(){
    PROJECT_ID=$1
    POOL_BASE_NAME="v1-workload-identity-pool"
    v1_account_id="$2"
    api_key="$3"
    VISION_ONE_ENDPOINT="$4"
    LOCATION="global"
    EXISTING_POOL=$(gcloud iam workload-identity-pools list \
        --location=$LOCATION \
        --project=$PROJECT_ID \
        --format="value(name)" | grep "$POOL_BASE_NAME")

    if [[ -n "$EXISTING_POOL" ]]; then
        echo "Existing Workload Identity Pool founded: $EXISTING_POOL"
        EXISTING_SUFFIX=$(echo "$EXISTING_POOL" | grep -oP "${POOL_BASE_NAME}-\K[[:alnum:]]+$")
        sa_binding $PROJECT_ID $EXISTING_SUFFIX $v1_account_id
        integrate_project $PROJECT_ID "v1-workload-identity-pool-$EXISTING_SUFFIX" $v1_account_id $api_key $VISION_ONE_ENDPOINT
        return 1
    else
        SUFFIX=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 4 | head -n 1)
        create_role $PROJECT_ID $SUFFIX
        create_service_account $PROJECT_ID
        create_workload_pool $PROJECT_ID $SUFFIX
        create_oidc $PROJECT_ID $SUFFIX
        sa_binding $PROJECT_ID $SUFFIX $v1_account_id
        integrate_project $PROJECT_ID $workload_pool_id $v1_account_id $api_key $VISION_ONE_ENDPOINT
    fi
}

enable_apis(){
    gcloud config set project $1
    gcloud services enable iamcredentials.googleapis.com --project=$1
    gcloud services enable cloudresourcemanager.googleapis.com --project=$1
    gcloud services enable iam.googleapis.com --project=$1
    gcloud services enable cloudbuild.googleapis.com --project=$1
    gcloud services enable deploymentmanager.googleapis.com --project=$1
    gcloud services enable cloudfunctions.googleapis.com --project=$1
    gcloud services enable pubsub.googleapis.com --project=$1
    gcloud services enable secretmanager.googleapis.com --project=$1
}

create_role(){
    gcloud config set project $1
    gcloud iam roles create "vision_one_cam_role_$2" \
        --project $1 \
        --title "Vision One CAM Features role" \
        --description "The custom role for Vision One" \
        --permissions="iam.serviceAccounts.getAccessToken,iam.roles.get,iam.roles.list,resourcemanager.tagKeys.get,resourcemanager.tagKeys.list,resourcemanager.tagValues.get,resourcemanager.tagValues.list,iam.serviceAccountKeys.create,iam.serviceAccountKeys.delete,accessapproval.settings.get,alloydb.clusters.list,alloydb.instances.list,apigateway.apiconfigs.getIamPolicy,apigateway.apiconfigs.list,apigateway.apis.get,apigateway.apis.getIamPolicy,apigateway.apis.list,apigateway.gateways.getIamPolicy,apigateway.gateways.list,apigateway.locations.get,apigee.apiproducts.list,apigee.deployments.list,apigee.envgroupattachments.list,apigee.envgroups.list,apigee.environments.getStats,apigee.instanceattachments.list,apigee.instances.list,apigee.proxies.list,apigee.proxyrevisions.get,apikeys.keys.list,artifactregistry.repositories.getIamPolicy,artifactregistry.repositories.list,bigquery.datasets.get,bigquery.tables.get,bigquery.tables.getIamPolicy,bigquery.tables.list,bigtable.clusters.list,bigtable.instances.getIamPolicy,bigtable.instances.list,certificatemanager.certs.list,cloudfunctions.functions.getIamPolicy,cloudfunctions.functions.list,cloudkms.cryptoKeys.getIamPolicy,cloudkms.cryptoKeys.list,cloudkms.keyRings.list,cloudkms.locations.list,cloudsql.instances.list,cloudsql.instances.listServerCas,compute.backendServices.getIamPolicy,compute.backendServices.list,compute.disks.getIamPolicy,compute.disks.list,compute.firewalls.list,compute.globalForwardingRules.list,compute.images.getIamPolicy,compute.images.list,compute.instanceGroups.list,compute.instances.getIamPolicy,compute.instances.list,compute.machineImages.getIamPolicy,compute.machineImages.list,compute.networks.list,compute.projects.get,compute.regionBackendServices.getIamPolicy,compute.regionBackendServices.list,compute.routers.list,compute.sslPolicies.list,compute.subnetworks.getIamPolicy,compute.subnetworks.list,compute.targetHttpsProxies.list,compute.targetSslProxies.list,compute.targetVpnGateways.list,compute.urlMaps.list,compute.vpnGateways.list,compute.zones.list,container.clusters.list,dataproc.clusters.getIamPolicy,dataproc.clusters.list,datastore.databases.list,dns.managedZones.list,dns.policies.list,file.instances.list,iam.roles.list,iam.serviceAccountKeys.list,iam.serviceAccounts.get,iam.serviceAccounts.getIamPolicy,iam.serviceAccounts.list,logging.logEntries.list,logging.logMetrics.list,logging.sinks.list,memcache.instances.list,monitoring.alertPolicies.list,networkconnectivity.hubs.list,networkconnectivity.hubs.listSpokes,notebooks.instances.getIamPolicy,notebooks.instances.list,orgpolicy.policy.get,pubsub.topics.get,pubsub.topics.getIamPolicy,pubsub.topics.list,pubsublite.topics.list,pubsublite.topics.listSubscriptions,redis.clusters.list,redis.instances.list,resourcemanager.projects.get,resourcemanager.projects.getIamPolicy,servicemanagement.services.get,serviceusage.services.list,spanner.instances.getIamPolicy,spanner.instances.list,storage.buckets.getIamPolicy,storage.buckets.list" > /dev/null
}

create_service_account(){
    project_id=$1
    serviceAccount="vision-one-service-account@$project_id.iam.gserviceaccount.com"
    if gcloud iam service-accounts list --project=$project_id --format="value(email)" | grep -q "$serviceAccount"; then
        echo "Service Account $serviceAccount already Exists"
    else
        gcloud iam service-accounts create vision-one-service-account \
            --display-name="The Service Account Trend Micro Vision One will impersonate" \
            --project=$project_id
    fi
}

create_workload_pool(){
    project_id="$1"
    workload_pool_id="v1-workload-identity-pool-$2"
    gcloud iam workload-identity-pools create "$workload_pool_id" --display-name "V1 Workload Identity Pool" --description "The Workload Identity Pool containing Trend Micro Vision One OIDC configuration" --project $project_id --location="global"
}

create_oidc(){
    project_id="$1"
    issuer="https://cloudaccounts-us.xdr.trendmicro.com"
    workload_pool_id="v1-workload-identity-pool-$2"
    gcloud config set project $project_id
    projectNumber=$(gcloud projects describe $project_id --format="value(projectNumber)")
    gcloud iam workload-identity-pools providers create-oidc vision-one-oidc-provider \
        --workload-identity-pool="$workload_pool_id" \
        --location="global" \
        --display-name="Vision One OIDC Provider" \
        --description="The Vision One OIDC provider" \
        --issuer-uri=$issuer \
        --allowed-audiences="//iam.googleapis.com/projects/$projectNumber/locations/global/workloadIdentityPools/$workload_pool_id/providers/vision-one-oidc-provider" \
        --attribute-mapping="google.subject=assertion.sub" \
        --project=$project_id
}

sa_binding(){
    project_id="$1"
    suffix="$2"
    subject="urn:visionone:identity:us:$3:account/$3"
    serviceAccount="vision-one-service-account@$project_id.iam.gserviceaccount.com"
    project_number=$(gcloud projects describe $project_id --format="value(projectNumber)")
    
    gcloud config set project $project_id

    # Agregando --condition=None para evitar el error de políticas existentes con condiciones
    gcloud iam service-accounts add-iam-policy-binding "$serviceAccount" \
        --role="roles/iam.workloadIdentityUser" \
        --member="principal://iam.googleapis.com/projects/$project_number/locations/global/workloadIdentityPools/v1-workload-identity-pool-$suffix/subject/$subject" \
        --project "$project_id" \
        --condition=None > /dev/null

    gcloud projects add-iam-policy-binding "$project_id" \
        --member="serviceAccount:$serviceAccount" \
        --role="roles/viewer" \
        --condition=None > /dev/null

    gcloud projects add-iam-policy-binding "$project_id" \
        --member="serviceAccount:$serviceAccount" \
        --role="projects/$project_id/roles/vision_one_cam_role_$suffix" \
        --condition=None > /dev/null
}

integrate_project(){
    http_endpoint="https://api.xdr.trendmicro.com/beta/cam"
    add_account_url="$http_endpoint/gcpProjects"
    project_id=$1
    workload_pool_id="$2"
    service_account_id=$(gcloud iam service-accounts describe vision-one-service-account@$project_id.iam.gserviceaccount.com --format="value(uniqueId)")
    project_number=$(gcloud projects describe $project_id --format="value(projectNumber)")
    v1_account_id=$3
    api_key=$4
    json_body=$(cat <<EOF
{
  "name": "$project_id",
  "projectNumber": "$project_number", 
  "serviceAccountId": "$service_account_id",
  "workloadIdentityPoolId": "$workload_pool_id",
  "oidcProviderId": "vision-one-oidc-provider"
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
        echo "Account registration VisionOne complete: $project_id"
    else
        error_code=$(echo "$response_body" | jq -r '.error.innererror.code')
        if [[ "$error_code" == "account-exist" ]]; then
            echo "The account $project_id already exists for this GCP project in Vision One"
        else
            echo "Unexpected error response: $response_body"
        fi
    fi
}

project_integrated(){
    project_id=$1
    v1_account_id=$2
    api_key=$3
    trend_micro_api_url="https://api.xdr.trendmicro.com/beta/cam"
    project_number=$(gcloud projects describe $project_id --format="value(projectNumber)")
    response=$(curl -s -w "\n%{http_code}" -X GET \
        -H "Authorization: Bearer $api_key" \
        -H "Content-Type: application/json" \
        -H "x-user-role: Master Administrator" \
        -H "x-customer-id: $v1_account_id" \
        "$trend_micro_api_url/gcpProjects/$project_number")

    if [[ $(echo "$response" | tail -n1) != "200" ]]; then
        return 1
    else
        return 0
    fi
}

export -f project_integrated check_workload_pool process_project integrate_project create_oidc create_role create_service_account sa_binding create_workload_pool enable_apis  # Exportar la funciÃƒÂ³n para que xargs pueda usarla

gcloud projects list --format="csv(projectId, name)" | tail -n +2 |
xargs -P 10 -d '\n' -I {} bash -c 'process_project "$@" "$1"'  _ {} $v1_account_id $api_key $VISION_ONE_ENDPOINT
