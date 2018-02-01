# Design

The Ragtag lambda monitoring solution involves the following AWS objects:

* **application** - the lambda resource to monitor.
* **application service role** - the service role assigned to the application resource
* **application log** - the CloudWatch Logs group associated with the application resource.
* **monitor** - the monitoring resource. in the current design, every application requires a dedicated monitor instance. We're looking into ways to
   parameterize the monitor to allow the same monitor to support multiple applications.
* **monitor service role** - the security role assigned to the monitor resource.
* **monitor log** - the CloudWatch Logs group associated with the monitoring resource
* **monitoring subscription** - a CloudWatch Log subscription that invokes the monitor when it detects an application request has completed.
* **reporting topic** - an SNS topic used to deliver monitor reports to interested subscribers
* **reporting subscription** - a subscription on the reporting topic that delivers monitoring-related messages to end users or other channels.