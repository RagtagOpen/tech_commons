# Monitoring Deployment and Configuration

## Configuration

Deployment-specific values (names of roles and policies, topics, lambda functions, etc.) are maintained in [`env.sh`](env.sh), and sourced by the various build and configuration scripts.
Edit the contents of this file as needed.

## Initial Setup

The core monitoring code and associated AWS resources are created by the [`deploy.sh`](deploy.sh) script. Run as

    $ cd $PROJECT/setup
    $ ./deploy.sh

Initial setup entails the following tasks:

1. Build zip archive with source code
1. Create a common logging policy for lambda functions, which can be
   used to grant permissions required to write to CloudWatch logs.
1. Create the SNS reporting topic
1. Create the security role and permissions for the monitor lambda.
1. Create the monitoring lambda and attached code archive.

The script can be run multiple times. It will not change existing resources, only create missing ones.

## Code Updates

To update the `lambda-monitoring` code resource, simply re-run the deployment script, as above.

## Application Setup

To set up monitoring for a specific lambda function:

1. Update [`env.sh`](env.sh) with the correct APP_* variable settings.
2. Run the first stage config script

        $ cd $PROJECT/setup
        $ ./add_config.sh

   This script performs the following steps:

   1. Verify/Update application lambda permissions (to enable logging)
   2. Create/Update the application log group
   3. Update security policy for monitoring component
   4. Create new log subscription to watch application logs for request completion
   
   Once the subscription has been created, it must 
   be confirmed before the rest of the application set can be performed.

3. Confirm the subscription. AWS will send a confirmation email to the subscription 
   address, which will include a link to a confirmation page.
   Once the subscription has been confirmed, the rest of the setup can be run.

4. Run the second stage config script

        $ cd $PROJECT/setup
        $ ./finish_config.sh

  which adds a subscription filter policy and completes the configuration.
