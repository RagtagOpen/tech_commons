#!/bin/sh

# Configuration

. env.sh

BUILD_DIR=../target
SRC_DIR=../lambda-monitoring

# Create build temp folder
if [[ ! -d "$BUILD_DIR" ]]; then
	echo "Creating build directory"
	mkdir -p "$BUILD_DIR"
fi

# zip up code for deployment
echo "Building code archive"
ARCHIVE_PATH=$BUILD_DIR/monitoring.zip
rm -rf "$ARCHIVE_PATH"
zip -jr "$ARCHIVE_PATH" "$SRC_DIR"

echo "Creating AWS resources"

# Create the base lambda logging policy

LOGGING_POLICY_ARN=`aws iam list-policies --output text --query "Policies[?PolicyName=='$LOGGING_POLICY_NAME'].[Arn]"`
if [[ -z "$LOGGING_POLICY_ARN" ]]; then
	echo "Creating base logging policy... "
	aws iam create-policy \
	  --policy-name "$LOGGING_POLICY_NAME" \
	  --description "Minimum permissions for creating log streams and writing log events." \
	  --policy-document file://logging-policy.json
	LOGGING_POLICY_ARN=`aws iam list-policies --output text --query "Policies[?PolicyName=='$LOGGING_POLICY_NAME'].[Arn]"`
	echo "Created $LOGGING_POLICY_ARN"
fi

# Create the reporting topic

TOPIC_ARN=`aws sns list-topics --output text --query "Topics[*].[TopicArn]" | grep ":${TOPIC_NAME}$"`
if [[ -z "$TOPIC_ARN" ]]; then
	echo "Creating reporting topic"
    TOPIC_ARN=`aws sns create-topic --name "$TOPIC_NAME" --output text`
	aws sns set-topic-attributes \
	          --topic-arn "$TOPIC_ARN" \
	          --attribute-name DisplayName \
	          --attribute-value "AWS Lambda Monitoring"
	echo "Created $TOPIC_ARN"
fi

# Create the base monitor access policy

MONITOR_POLICY_ARN=`aws iam list-policies --output text --query "Policies[?PolicyName=='$MONITOR_POLICY_NAME'].[Arn]"`
if [[ -z "$MONITOR_POLICY_ARN" ]]; then
	echo "Creating monitor access policy"
	sed -E -e 's/\$TOPIC_ARN/'$TOPIC_ARN'/' monitor-lambda-policy-template.json > $BUILD_DIR/monitor-lambda-policy.json
	aws iam create-policy \
	  --policy-name "$MONITOR_POLICY_NAME" \
	  --description "Security policy for monitoring lambdas. Provides permissions to read CloudWatch logs and publish to SNS topics." \
	  --policy-document file://$BUILD_DIR/monitor-lambda-policy.json
	rm -f $BUILD_DIR/monitor-lambda-policy.json
    MONITOR_POLICY_ARN=`aws iam list-policies --output text --query "Policies[?PolicyName=='$MONITOR_POLICY_NAME'].[Arn]"`
    echo "Created $MONITOR_POLICY_ARN"
fi

# Create the monitoring security role

MONITOR_ROLE_ARN=`aws iam list-roles --output text --query "Roles[?RoleName=='$MONITOR_ROLE_NAME'].[Arn]"`
if [[ -z "$MONITOR_ROLE_ARN" ]]; then
	echo "Creating monitor access role"
	aws iam create-role \
	   --role-name "$MONITOR_ROLE_NAME" \
	   --description "Security role for monitoring lambda function executions. Provides permissions to access logs and publish to a topic." \
	   --assume-role-policy-document file://lambda-assume-role-policy.json
	MONITOR_ROLE_ARN=`aws iam list-roles --output text --query "Roles[?RoleName=='$MONITOR_ROLE_NAME'].[Arn]"`
	echo "Created $MONITOR_ROLE_ARN"
fi

# Add base and monitoring policies to security role

MONITOR_ROLE_POLICIES=`aws iam list-attached-role-policies --role-name "$MONITOR_ROLE_NAME" --output text --query "AttachedPolicies[*].[PolicyName]"`
CHANGED=
if ! echo $MONITOR_ROLE_POLICIES | egrep "\\b$LOGGING_POLICY_NAME\\b" > /dev/null; then
    echo "Attaching $LOGGING_POLICY_NAME policy to $MONITOR_ROLE_ARN"
	aws iam attach-role-policy \
	    --role-name "$MONITOR_ROLE_NAME" \
	    --policy-arn "$LOGGING_POLICY_ARN"
	CHANGED=true
fi
if ! echo $MONITOR_ROLE_POLICIES | egrep "\\b$MONITOR_POLICY_NAME\\b" > /dev/null; then
    echo "Attaching $MONITOR_POLICY_NAME policy to $MONITOR_ROLE_ARN"
	aws iam attach-role-policy \
	    --role-name "$MONITOR_ROLE_NAME" \
	    --policy-arn "$MONITOR_POLICY_ARN"
	CHANGED=true
fi
if [[ "$CHANGED" ]]; then
	echo "Waiting 10s for IAM changes to propagate"
	sleep 10
fi

# Create or update monitoring lambda function

FUNCTION_ARN=`aws lambda list-functions --output text --query "Functions[?FunctionName=='$MONITOR_FUNCTION_NAME'].[FunctionArn]"`
if [[ -z "$FUNCTION_ARN" ]]; then
	echo "Creating $MONITOR_FUNCTION_NAME"
	aws lambda create-function \
	    --function-name "$MONITOR_FUNCTION_NAME" \
	    --runtime python3.6 \
	    --role "$MONITOR_ROLE_ARN" \
	    --handler monitor_lambda_runs.lambda_handler \
	    --zip-file "fileb://$ARCHIVE_PATH" \
	    --description 'Monitor log output from lambda execution requests' \
	    --timeout 30 \
	    --environment "Variables={REPORTING_TOPIC_ARN=$TOPIC_ARN}"
	FUNCTION_ARN=`aws lambda list-functions --output text --query "Functions[?FunctionName=='$MONITOR_FUNCTION_NAME'].[FunctionArn]"`
    # TODO move to add_config and use per-subscription invocation permissions
	aws lambda add-permission \
	    --function-name "$MONITOR_FUNCTION_NAME" \
	    --statement-id "AllowLogSubscription" \
	    --action "lambda:InvokeFunction" \
	    --principal "logs.amazonaws.com" > /dev/null
	echo "Created $FUNCTION_ARN"
else
	echo "Updating $MONITOR_FUNCTION_NAME"
	aws lambda update-function-code \
		--function-name "$MONITOR_FUNCTION_NAME" \
		--zip-file "fileb://$ARCHIVE_PATH"
    echo "complete"
fi

