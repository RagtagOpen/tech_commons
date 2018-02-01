"""
Collect log events for completed AWS lambda runs and publish status report
"""
from __future__ import print_function

import base64
import json
import logging
import os
import zlib

import boto3

# message formatting in separate module, perhaps one day we can support customizing
# format through some kind of context-specific formatting hook.
from format_request_events import create_message_subject, create_message_body

def get_env_var(name, default_value = None):
    """Get the value of an environment variable, if defined"""
    if name in os.environ:
        return os.environ[name]
    elif default_value is not None:
        return default_value
    else:
        raise RuntimeError('Required environment variable %s not found' % name)

# Get configuration from environment variables
topic_arn = get_env_var('REPORTING_TOPIC_ARN')

# Configure local logging
log_level = get_env_var('LOG_LEVEL', 'INFO')
log = logging.getLogger()
log.setLevel(log_level)

def decompress_string(value):
    """
    Convert base64-encoded, compressed data to a string
    """
    data = base64.b64decode(value)
    return zlib.decompress(data,47,4096).decode()

def unpack_subscription_event(event):
    """
    Convert and parse cloudwatch log subscription event
    """
    payload = decompress_string(event['awslogs']['data'])
    event = json.loads(payload)
    return event

def get_run_events(requestId, context):
    """
    Get cloudwatch log events for the specified lambda request

    Assumes log events are formatted with the default Lambda log format, i.e. '<level> <timestamp> <requestid> ...".
    """
    logs = boto3.client('logs')
    log_group_name = context['log_group_name']
    log_stream_name = context['log_stream_name']
    log_filter = '[level,ts,id=%s,...]' % requestId
    results = logs.filter_log_events(
                logGroupName=log_group_name,
                logStreamNames=[log_stream_name],
                filterPattern=log_filter,
                interleaved=True)
    events = results['events']
    # get additional batches
    while 'nextToken' in results:
        results = logs.filter_log_events(
                    logGroupName=log_group_name,
                    logStreamNames=[log_stream_name],
                    filterPattern=log_filter,
                    interleaved=True,
                    nextToken=results['nextToken'])
        events.extend(results['events'])
    return events

def analyze_run_events(requestId, events, context):
    """
    Collect information about request execution from log events.
    """
    assert len(events) > 0, "No events found for request %s" % requestId
    errors = 0
    warnings = 0
    startts = 0
    endts = 0
    for event in events:
        if 'message' in event:
            message = event['message']
            if message.startswith('START'):
                startts = event['timestamp']
            elif message.startswith('END'):
                endts = event['timestamp']
            elif message.startswith('[ERROR]'):
                errors = errors + 1
            elif message.startswith('[WARNING]'):
                warnings = warnings + 1
    assert startts > 0, "No START event found in request log trace %s" % requestId
    assert endts > 0, "No END event found in request log trace %s" % requestId
    duration = endts - startts
    return { 'start': startts, 'end': endts, 'duration': duration, 'errors': errors, 'warnings': warnings }

def create_topic_message(info, context):
    """
    Create a report message for a request execution
    """
    subject = create_message_subject(info, context)
    defaultMessage = create_message_body(info, context)
    # TODO define alternate messages for other protocols, e.g. SMS
    return (subject, defaultMessage)

def publish_run_info(info, context):
    """
    Publish job execution report to SNS topic.

    If context.dry_run is True, dumps subject and message to stdout instead of
    publishing to the topic.
    """
    (subject,message) = create_topic_message(info, context)
    if info['errors'] > 0:
        status = 'error'
    elif info['warnings'] > 0:
        status = 'warning'
    else:
        status = 'success'
    attributes = {
         'function': {
             'DataType': 'String',
             'StringValue': context['function_name']
         },
         'status': {
             'DataType': 'String',
             'StringValue': status
         },
         'errors': {
             'DataType': 'String',
             'StringValue': str(info['errors'])
         },
         'warnings': {
             'DataType': 'String',
             'StringValue': str(info['warnings'])
         },
    }

    print_level = logging.INFO if context['dry_run'] else logging.DEBUG
    log.log(print_level, "SUBJECT: %s", subject)
    log.log(print_level, "ATTRIBUTES:\n%s", json.dumps(attributes))
    log.log(print_level, "BODY\n%s", message)
    if context['dry_run']:
        # return dummy publish response
        response = { 'MessageId': '12345' }
    else:
        # publish to topic
        sns = boto3.client('sns')
        response = sns.publish(
                     TopicArn=topic_arn,
                     Subject=subject,
                     Message=message,
                     MessageAttributes=attributes)
    log.info('Published message %s to target topic %s', response['MessageId'], topic_arn)
    return response

def process_lambda_run(requestId, context):
    """
    Process CloudWatch log events for a lambda function run
    """
    log.debug('Processing log events for %s request %s', context['function_name'], requestId)
    events = get_run_events(requestId, context)
    log.debug('Found %d events', len(events))
    info = analyze_run_events(requestId, events, context)
    publish_run_info(dict(info,
                          requestId=requestId,
                          events=events),
                     context)

def get_request_ids(events, context):
    """
    Get request IDs from a set of lambda log events
    """
    ids = []
    for event in events:
        if ('extractedFields' in event):
            fields = event['extractedFields']
            if 'type' in fields and fields['type'] == 'END' and 'requestId' in fields:
                ids.append(fields['requestId'])
    # should always be at least one END event
    assert len(ids) > 0, "No END events found in message stream."
    # shouldn't be any dupes
    assert len(ids) == len(set(ids)), "Found duplicate request ids"
    return ids

def process_lambda_events(events, context):
    """
    Process a set of Lambda log events, running `process_lambda_run` for each END event.

    It's possible that the log subscription could be configured to send all events
    for a particular run to the handler, but I haven't seen anything that guarantees this. So
    for now we only look at END requests, then explicitly collect all the others through a
    filter_log_events query. It's highly recommended to add a filter to the log subscription
    that only looks at 'END' events, to avoid including other request events that will only be
    discarded here.
    """
    ids = get_request_ids(events, context)
    log.debug("Processing events for %d runs", len(ids))
    for request_id in ids:
        process_lambda_run(request_id, context)

def get_lambda_tags(function_name):
    """
    Get all tags and values associated with the specified function name.
    """
    return {  }

#
# lambda entry point
#
def lambda_handler(handler_event, handler_context):
    """
    Process a CloudWatch Log trigger.
    """
    dry_run = os.getenv('DRY_RUN', 'false').lower() == 'true'
    subscription_event = unpack_subscription_event(handler_event)
    log.debug('Event data: %s', json.dumps(subscription_event))
    log_group_name = subscription_event['logGroup']
    log_stream_name = subscription_event['logStream']
    if log_group_name.startswith('/aws/lambda/'):
        function_name = log_group_name[12:]
    else:
        raise RuntimeError('Log group %s is not a lambda' % log_group_name)
    display_name = get_lambda_tags(function_name).get('DISPLAY_NAME', function_name)
    # set up handler context
    context = {
        'log_group_name': log_group_name,
        'log_stream_name': log_stream_name,
        'function_name': function_name,
        'display_name': display_name,
        'dry_run': dry_run
    }
    process_lambda_events(subscription_event['logEvents'], context)
    return 'Mischief managed.'
