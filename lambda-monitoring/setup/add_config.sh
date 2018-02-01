#!/bin/sh

# Configuration

. ./env.sh

BUILD_DIR=../target

# Create build temp folder
if [[ ! -d "$BUILD_DIR" ]]; then
    echo "Creating build directory"
    mkdir -p "$BUILD_DIR"
fi

# add the `logging` IAM policy to the application service role

LOGGING_POLICY_ARN=`aws iam list-policies \
			          --output text \
			          --query "Policies[?PolicyName=='$LOGGING_POLICY_NAME'].[Arn]"`
if [[ -z "$LOGGING_POLICY_ARN" ]]; then
	echo "Can't find base logging policy $LOGGING_POLICY_NAME"
	exit -1
fi

APP_ROLE_ARN=`aws iam list-roles --output text --query "Roles[?RoleName=='$APP_ROLE_NAME'].[Arn]"`
if [[ -z "$APP_ROLE_ARN" ]]; then
	echo "Can't find lambda security role $APP_ROLE_NAME"
	exit -1
fi

CAN_LOG=`aws iam list-attached-role-policies \
               --no-paginate --role-name "$APP_ROLE_NAME" \
               --output text \
               --query "AttachedPolicies[?PolicyName=='$LOGGING_POLICY_NAME'].[PolicyName]"`
if [[ -z "$CAN_LOG" ]]; then
	echo "Attaching $LOGGING_POLICY_NAME policy to $APP_ROLE_ARN"
	aws iam attach-role-policy \
	    --role-name "$APP_ROLE_NAME" \
	    --policy-arn "$LOGGING_POLICY_ARN"
fi


### Create application log group

#If the application has already run (and had `CreateLogGroup` permissions), the CloudWatch logs group may already exist.
# Otherwise create it directly

LOG_GROUP_NAME=/aws/lambda/$APP_FUNCTION_NAME
LOG_GROUP_ARN=`aws logs describe-log-groups --output text --query "logGroups[?logGroupName=='/aws/lambda/$APP_FUNCTION_NAME'].[arn]"`
if [[ -z "$LOG_GROUP_ARN" ]]; then
	echo "Creating log group $LOG_GROUP_NAME"
	aws logs create-log-group --log-group-name $LOG_GROUP_NAME
	LOG_GROUP_ARN=`aws logs describe-log-groups --output text --query "logGroups[?logGroupName=='/aws/lambda/$APP_FUNCTION_NAME'].[arn]"`
	# set retention policy (optional, defaults to None)
	aws logs put-retention-policy \
	   --log-group-name $LOG_GROUP_NAME --retention-in-days 30
fi

### Update monitoring security policies

# Add the application log streams to the resources identified in the `monitoring-lambda` policy created during initial setup, e.g.:
#
#    {
#        "Version": "2012-10-17",
#        "Statement": [
#        {
#              "Sid": "ReadLogs",
#              "Effect": "Allow",
#              "Action": [
#                  "logs:GetLogEvents",
#                  "logs:FilterLogEvents"
#              ],
#              "Resource": [
#                  "arn:aws:logs:us-east-1::log-group:$LOG_GROUP_NAME:log-stream:"
#              ]
#          }
#      ]
#    }

# Add log group to monitor role's access list

MONITOR_POLICY_ARN=`aws iam list-policies --output text --query "Policies[?PolicyName=='$MONITOR_POLICY_NAME'].[Arn]"`
if [[ -z "$MONITOR_POLICY_ARN" ]]; then
	echo "Can't find monitor lambda policy $MONITOR_POLICY_ARN"
	exit -1
fi

MONITOR_POLICY_VERSION=`aws iam get-policy --policy-arn "$MONITOR_POLICY_ARN" --output text --query "Policy.[DefaultVersionId]"`
MONITOR_POLICY_FILE=$BUILD_DIR/monitor-lambda-policy.json
aws iam get-policy-version \
     --policy-arn "$MONITOR_POLICY_ARN" \
     --version-id "$MONITOR_POLICY_VERSION" \
	    > "$MONITOR_POLICY_FILE"

# update version as needed
if [[ ! `grep "$LOG_GROUP_ARN" "$MONITOR_POLICY_FILE"` ]]; then
	echo "Updating monitor security policy"
	# drop oldest version
	POLICY_VERSIONS_FILE=$BUILD_DIR/monitor-policy-versions.txt
	aws iam list-policy-versions \
	           --policy-arn "$MONITOR_POLICY_ARN"\
	           --query "Versions[*].[VersionId,IsDefaultVersion,CreateDate]" \
	           --output text --no-paginate \
	           > "$POLICY_VERSIONS_FILE"
	if [[ `wc -l $POLICY_VERSIONS_FILE | awk '{ print $1 }'` = 5 ]]; then
	    # find oldest non-default version
		OLD_VERSION=`grep -v 'True' $POLICY_VERSIONS_FILE | sort -k3 | head -1 | awk '{ print $1 }'`
		echo "Deleting oldest version $OLD_VERSION from $MONITOR_POLICY_NAME"
		aws iam delete-policy-version --policy-arn "$MONITOR_POLICY_ARN" --version-id $OLD_VERSION
	fi

	# ugh. we can't actually change the policy without JSON support
	echo "**** please add the following log resource to $MONITOR_POLICY_NAME ***"
	echo "$LOG_GROUP_ARN"
	echo "***"

#   ...but if we could...

#	echo "Creating new version for $MONITOR_POLICY_NAME"
#	aws iam create-policy-version \
#	    --policy-arn "$MONITOR_POLICY_ARN" \
#	    --policy-document `cat $NEW_MONITOR_POLICY_FILE` \
#		--set-as-default
#
#    TODO: update monitor security policy directly

fi

# Create the monitoring subscription

if [[ ! `aws logs describe-subscription-filters --log-group-name "$LOG_GROUP_NAME" --output text` ]]; then
	echo "Creating lambda monitoring subscription for $APP_FUNCTION_NAME"
	MONITOR_FUNCTION_ARN=`aws lambda list-functions --output text --query "Functions[?FunctionName=='$MONITOR_FUNCTION_NAME'].[FunctionArn]"`
	aws logs put-subscription-filter \
	  --log-group-name "$LOG_GROUP_NAME" \
	  --filter-name "Lambda ($MONITOR_FUNCTION_NAME)" \
	  --filter-pattern "[type=END,dummy,requestId,...]" \
	  --destination-arn "$MONITOR_FUNCTION_ARN"
fi

# Create the topic subscription

TOPIC_ARN=`aws sns list-topics --output text --query "Topics[*].[TopicArn]" | grep ":${TOPIC_NAME}$"`
SUBSCRIPTION_ARN=`aws sns list-subscriptions-by-topic \
    --topic-arn "$TOPIC_ARN" \
    --output text \
    --query "Subscriptions[?Protocol=='email'&&Endpoint=='$SUBSCRIPTION_EMAIL'].[SubscriptionArn]"`

if [[ -z "$SUBSCRIPTION_ARN" ]]; then
	aws sns subscribe --topic-arn $TOPIC_ARN --protocol email --notification-endpoint "$SUBSCRIPTION_EMAIL"
    echo "Please check $SUBSCRIPTION_EMAIL for an AWS subscription request and confirm"
    echo "then run finish_config.sh"
fi