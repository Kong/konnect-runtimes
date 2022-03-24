

Instructions for Setting up your Kong instance on GCP:

1. After clicking the "Open in Cloud Shell" link, on the GCP Cloud Shell page, be sure to select "Trust Repo" before clicking "Confirm".
2. Ensure that gcloud is using the correct project:

    gcloud config get-value project

3. To update your gcp project, use the following commands:

    gcloud projects list
    gcloud config set project `PROJECT ID`

4. Ensure that Billing is enabled on your project. (GCP Documentation: https://cloud.google.com/billing/docs/how-to/modify-project)
5. Ensure that GCP Secret Manger is enabled with the following command:

    gcloud services enable secretmanager.googleapis.com

6. Copy, Paste, and Run the shell script from the Kong Konnect console.

