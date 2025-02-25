# Vision One Integration Script

This repository contains a Bash script to integrate All GCP projects with Trend Micro Vision One. The script performs the request of terraform template and execute for each project.

## Requirements

- [GCloud CLI](https://cloud.google.com/sdk/docs/install)
- [jq](https://stedolan.github.io/jq/download/)
- Access and Permission in GCP & Vision One.

## Configuration

1. Create Vision One Custom Role:
    Minimum permissions required for the Vision One integration are:
    [Vision One Role Creation](https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-configuring-custom-user-roles#GUID-BED80320-70E5-47C4-9530-CC26073D469D-7dm92w)
    [![Role Permissions](../../../../CAM/Azure/Onboarding/azure-bash-all-subscription-integration/img/V1_RoleDefinition.png)]

2. Create ApiKey with Custom Role:
    [Vision One ApiKey Creation](https://docs.trendmicro.com/en-us/documentation/article/trend-vision-one-configuring-api-keys#GUID-3D3A3A3D-3D3A-4D3A-3D3A-3D3A3D3A3D3A-7dm92w)

3. Get Vision One Account ID:
    [![Vision One Account ID](../../../../CAM/Azure/Onboarding/azure-bash-all-subscription-integration/img/VisionOneAccountID.png)]

4. Azure CLI Login:
    ```sh
    gcloud auth login
    ```

6. Configure the API_KEY and V1_ACCOUNT_ID values like Environment Variables:

    ```
    export API_KEY="<API_KEY>"
    export V1_ACCOUNT_ID="<V1_ACCOUNT_ID>"
    ```
7. Run the script:
    ```sh
    curl https://raw.githubusercontent.com/XeniaP/v1-cloud-community/refs/heads/main/CAM/GCP/Onboarding/gcp-bash-all-projects-integration/GCPOnboarding.sh | bash
    ```
8. wait for the script to complete the execution.
9. Verify the accounts in Vision One
10. Clean the Environment Variables
    ```
    export API_KEY=""
    export V1_ACCOUNT_ID=""
    ```

## Created By XeniaP - Trend Micro
