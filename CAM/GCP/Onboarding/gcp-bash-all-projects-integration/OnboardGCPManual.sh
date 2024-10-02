#!/bin/bash

if [[ -z "$API_KEY" || -z "$V1_ACCOUNT_ID" ]]; then
  echo "Error: Las variables de entorno API_KEY y V1_ACCOUNT_ID deben estar definidas."
  exit 1
fi

api_key="${API_KEY}"
v1_account_id="${V1_ACCOUNT_ID}"
vision_one_api_url="https://api.xdr.trendmicro.com/"
workload_instance_id="${WORKLOAD_INSTANCE_ID}"
issuer="https://cloudaccounts-us.xdr.trendmicro.com"
subject="urn:visionone:identity:us:$v1_account_id:account/$v1_account_id"

SUFFIX=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 4 | head -n 1)

all_results=()

PRIMARY_PROJECT_ID=$(gcloud projects list --format="csv(projectId)" | tail -n +2 | head -n 1)

# Verificar que se obtuvo correctamente el proyecto principal
if [[ -z "$PRIMARY_PROJECT_ID" ]]; then
  echo "Error: No se pudo encontrar ningún proyecto."
  exit 1
else
  echo "El proyecto principal es: $PRIMARY_PROJECT_ID"
fi

# Crear el rol personalizado en el proyecto principal si no existe
EXISTING_ROLE=$(gcloud iam roles describe vision_one_cam_role --project=$PRIMARY_PROJECT_ID --format="value(name)")

if [[ -z "$EXISTING_ROLE" ]]; then
  echo "Creando el rol personalizado vision_one_cam_role en el proyecto principal $PRIMARY_PROJECT_ID..."
  gcloud iam roles create vision_one_cam_role \
    --project=$PRIMARY_PROJECT_ID \
    --title="Vision One CAM Features role" \
    --description="The custom role for Vision One" \
    --permissions="iam.serviceAccounts.getAccessToken,iam.roles.get,iam.roles.list,resourcemanager.tagKeys.get,resourcemanager.tagKeys.list,resourcemanager.tagValues.get,resourcemanager.tagValues.list,iam.serviceAccountKeys.create,iam.serviceAccountKeys.delete,accessapproval.settings.get,alloydb.clusters.list,alloydb.instances.list,apigateway.apiconfigs.getIamPolicy,apigateway.apiconfigs.list,apigateway.apis.get,apigateway.apis.getIamPolicy,apigateway.apis.list,apigateway.gateways.getIamPolicy,apigateway.gateways.list,apigateway.locations.get,apigee.apiproducts.list,apigee.deployments.list,apigee.envgroupattachments.list,apigee.envgroups.list,apigee.environments.getStats,apigee.instanceattachments.list,apigee.instances.list,apigee.proxies.list,apigee.proxyrevisions.get,apikeys.keys.list,artifactregistry.repositories.getIamPolicy,artifactregistry.repositories.list,bigquery.datasets.get,bigquery.tables.get,bigquery.tables.getIamPolicy,bigquery.tables.list,bigtable.clusters.list,bigtable.instances.getIamPolicy,bigtable.instances.list,certificatemanager.certs.list,cloudfunctions.functions.getIamPolicy,cloudfunctions.functions.list,cloudkms.cryptoKeys.getIamPolicy,cloudkms.cryptoKeys.list,cloudkms.keyRings.list,cloudkms.locations.list,cloudsql.instances.list,cloudsql.instances.listServerCas,compute.backendServices.getIamPolicy,compute.backendServices.list,compute.disks.getIamPolicy,compute.disks.list,compute.firewalls.list,compute.globalForwardingRules.list,compute.images.getIamPolicy,compute.images.list,compute.instanceGroups.list,compute.instances.getIamPolicy,compute.instances.list,compute.machineImages.getIamPolicy,compute.machineImages.list,compute.networks.list,compute.projects.get,compute.regionBackendServices.getIamPolicy,compute.regionBackendServices.list,compute.routers.list,compute.sslPolicies.list,compute.subnetworks.getIamPolicy,compute.subnetworks.list,compute.targetHttpsProxies.list,compute.targetSslProxies.list,compute.targetVpnGateways.list,compute.urlMaps.list,compute.vpnGateways.list,compute.zones.list,container.clusters.list,dataproc.clusters.getIamPolicy,dataproc.clusters.list,datastore.databases.list,dns.managedZones.list,dns.policies.list,file.instances.list,iam.roles.list,iam.serviceAccountKeys.list,iam.serviceAccounts.get,iam.serviceAccounts.getIamPolicy,iam.serviceAccounts.list,logging.logEntries.list,logging.logMetrics.list,logging.sinks.list,memcache.instances.list,monitoring.alertPolicies.list,networkconnectivity.hubs.list,networkconnectivity.hubs.listSpokes,notebooks.instances.getIamPolicy,notebooks.instances.list,orgpolicy.policy.get,pubsub.topics.get,pubsub.topics.getIamPolicy,pubsub.topics.list,pubsublite.topics.list,pubsublite.topics.listSubscriptions,redis.clusters.list,redis.instances.list,resourcemanager.projects.get,resourcemanager.projects.getIamPolicy,servicemanagement.services.get,serviceusage.services.list,spanner.instances.getIamPolicy,spanner.instances.list,storage.buckets.getIamPolicy,storage.buckets.list"
else
  echo "El rol vision_one_cam_role ya existe en el proyecto principal $PRIMARY_PROJECT_ID."
fi

#if [[ -n "$workload_instance_id" ]]; then
#  connected_security_services=$(cat <<EOF
#  "connectedSecurityServices": [
#    {
#      "name": "workload",
#      "instanceIds": ["$workload_instance_id"]
#    }
#  ]
#EOF
#  )
#else
#  connected_security_services=$(cat <<EOF
#  "connectedSecurityServices": [{}]
#EOF
#  )
#fi

#mutex=$(mktemp -u)
#exec 3>$mutex

log_file="execution_log.txt"
echo "Log de ejecución - $(date)" > $log_file

processed_count=0
total_subscriptions=0

process_project() {
    project_info="$1"
    project_id=$(echo "$project_info" | cut -d',' -f1)
    project_name=$(echo "$project_info" | cut -d',' -f2)

    projectNumber=$(gcloud projects describe $project_id --format="value(projectNumber)")
    echo $projectNumber

    gcloud config set project $project_id

    # Verificar si la cuenta de servicio ya existe
    EXISTING_SERVICE_ACCOUNT=$(gcloud iam service-accounts list \
    --filter="email:vision-one-service-account@$project_id.iam.gserviceaccount.com" \
    --project=$project_id \
    --format="value(email)")

    if [[ -z "$EXISTING_SERVICE_ACCOUNT" ]]; then
        echo "La cuenta de servicio no existe. Creando la cuenta de servicio..."
        # Crear la cuenta de servicio si no existe
        gcloud iam service-accounts create vision-one-service-account \
            --display-name="The Service Account Trend Micro Vision One will impersonate" \
            --project=$project_id
    else
        echo "La cuenta de servicio ya existe: $EXISTING_SERVICE_ACCOUNT"
        # Utilizar la cuenta de servicio existente
    fi

    SUFFIX=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 4 | head -n 1)

    # Define el ID del Workload Identity Pool y el proyecto
    POOL_ID="v1-workload-identity-pool-$SUFFIX"
    LOCATION="global"
    OIDC_PROVIDER_ID="vision-one-oidc-provider"

    echo "gcloud iam workload-identity-pools list --location=global --project$project_id"

    # Verificar si el Workload Identity Pool ya existe
    EXISTING_POOL=$(gcloud iam workload-identity-pools describe $POOL_ID \
    --location=$LOCATION \
    --project=$project_id \
    --format="value(name)")

    if [[ -z "$EXISTING_POOL" ]]; then
        echo "El Workload Identity Pool no existe. Creando el Workload Identity Pool..."
        # Crear el Workload Identity Pool si no existe
        gcloud iam workload-identity-pools create $POOL_ID \
            --display-name="V1 Workload Identity Pool" \
            --description="The Workload Identity Pool containing Trend Micro Vision One OIDC configuration" \
            --project=$project_id \
            --location=$LOCATION
    else
        echo "El Workload Identity Pool ya existe: $EXISTING_POOL"
        # Utilizar el Workload Identity Pool existente
    fi

    # Verificar si el OIDC Provider ya existe buscando por el ID completo
    EXISTING_OIDC_PROVIDER=$(gcloud iam workload-identity-pools providers describe $OIDC_PROVIDER_ID \
    --workload-identity-pool=$POOL_ID \
    --location=$LOCATION \
    --project=$project_id \
    --format="value(name)")

    if [[ -z "$EXISTING_OIDC_PROVIDER" ]]; then
        echo "El OIDC Provider no existe. Creando el OIDC Provider..."
        # Crear el OIDC Provider si no existe
        gcloud iam workload-identity-pools providers create-oidc $OIDC_PROVIDER_ID \
            --workload-identity-pool=$POOL_ID \
            --location=$LOCATION \
            --display-name="Vision One OIDC Provider" \
            --issuer-uri="https://cloudaccounts-us.xdr.trendmicro.com" \
            --allowed-audiences="//iam.googleapis.com/projects/$project_id/locations/global/workloadIdentityPools/$POOL_ID/providers/$OIDC_PROVIDER_ID" \
            --attribute-mapping="google.subject=assertion.sub" \
            --project=$project_id
    else
        echo "El OIDC Provider ya existe: $EXISTING_OIDC_PROVIDER"
        # Utilizar el OIDC Provider existente
    fi
    gcloud config set project $project_id
    # Asignar la política IAM de Workload Identity User
    gcloud iam service-accounts add-iam-policy-binding vision-one-service-account@$project_id.iam.gserviceaccount.com \
    --role="roles/iam.workloadIdentityUser" \
    --member="principal://iam.googleapis.com/projects/$projectNumber/locations/global/workloadIdentityPools/$POOL_ID/subject/urn:visionone:identity:us:f70c57f3-3205-4bf0-97ae-8290be64fa5d:account/f70c57f3-3205-4bf0-97ae-8290be64fa5d"

    # Habilitar las APIs necesarias
    gcloud services enable iamcredentials.googleapis.com --project=$project_id
    gcloud services enable cloudresourcemanager.googleapis.com --project=$project_id
    gcloud services enable iam.googleapis.com --project=$project_id
    gcloud services enable cloudbuild.googleapis.com --project=$project_id
    gcloud services enable deploymentmanager.googleapis.com --project=$project_id
    gcloud services enable cloudfunctions.googleapis.com --project=$project_id
    gcloud services enable pubsub.googleapis.com --project=$project_id
    gcloud services enable secretmanager.googleapis.com --project=$project_id

    # Asignar el rol personalizado al Service Account desde el proyecto principal
    gcloud projects add-iam-policy-binding $project_id \
    --role="projects/$PRIMARY_PROJECT_ID/roles/vision_one_cam_role" \
    --member="serviceAccount:vision-one-service-account@$project_id.iam.gserviceaccount.com"

    http_endpoint="https://api.xdr.trendmicro.com/beta/cam"
    add_account_url="$http_endpoint/gcpProjects"
    # Obtener el nombre completo del Workload Identity Pool
    workloadIdentityPoolId=$(gcloud iam workload-identity-pools describe $POOL_ID --location="global" --format="value(name)")
    # Extraer la última parte del ID después de la última "/"
    workloadIdentityPoolId=$(echo $workloadIdentityPoolId | awk -F'/' '{print $NF}')
    # Imprimir el resultado para verificar
    echo $workloadIdentityPoolId

    oidcProviderId=$(gcloud iam workload-identity-pools providers describe vision-one-oidc-provider --workload-identity-pool="$POOL_ID" --location="global" --format="value(name)")
    echo $oidcProviderId

    serviceAccountId=$(gcloud iam service-accounts describe vision-one-service-account@$project_id.iam.gserviceaccount.com --format="value(uniqueId)")
    echo $serviceAccountId

    json_body=$(cat <<EOF
{
    "name": "$project_name",
    "workloadIdentityPoolId": "$workloadIdentityPoolId",
    "oidcProviderId": "vision-one-oidc-provider",
    "serviceAccountId": "$serviceAccountId",
    "projectNumber": "$projectNumber",
    "description": "Vision One Integration with Cloud Posture"
}
EOF
)

    echo $json_body

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

export -f process_project

gcloud projects list --format="csv(projectId, name)" | tail -n +2 |
xargs -P 10 -d '\n' -I {} bash -c 'process_project "$@"'  _ {}

wait