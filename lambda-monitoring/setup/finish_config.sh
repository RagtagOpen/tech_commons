#!/bin/sh

# Configuration

. ./env.sh

TOPIC_ARN=`aws sns list-topics --output text --query "Topics[*].[TopicArn]" | grep ":${TOPIC_NAME}$"`
APP_SUBSCRIPTION_ARN=`aws sns list-subscriptions-by-topic \
    --topic-arn "$TOPIC_ARN" \
    --output text \
    --query "Subscriptions[?Protocol=='email'&&Endpoint=='$APP_SUBSCRIPTION_EMAIL'].[SubscriptionArn]"`

if [[ -z "$APP_SUBSCRIPTION_ARN" ]]; then
    echo "The topic subscription for $APP_SUBSCRIPTION_EMAIL has not been created or confirmed"
	echo "Please check $APP_SUBSCRIPTION_EMAIL for an AWS subscription request and confirm"
    echo "then run finish_config.sh"
fi

aws sns set-subscription-attributes \
            --subscription-arn "$APP_SUBSCRIPTION_ARN" \
            --attribute-name FilterPolicy \
            --attribute-value "{ \"function\": [\"$APP_FUNCTION_NAME\"], \"status\": [\"success\",\"error\",\"warning\"]}"
