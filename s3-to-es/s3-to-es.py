#!/usr/bin/python3
# -*- coding: utf-8 -*-
from __future__ import print_function
import boto3
import json
import datetime
import gzip
import urllib
import urllib3
import logging
from pprint import pprint
from requests_aws4auth import AWS4Auth
from botocore.vendored import requests
from io import BytesIO

"""
Can Override the global variables using Lambda Environment Parameters
"""
globalVars  = {}
globalVars['Owner']                 = "sirona"
globalVars['Environment']           = "Prod"
globalVars['awsRegion']             = "us-west-2"
globalVars['tagName']               = "serverless-s3-to-es-log-ingester"
globalVars['service']               = "es"
globalVars['esIndexPrefix']         = "s3-to-es-"
globalVars['esIndexDocType']        = "s3_to_es_docs"
globalVars['esHosts']               = {
                                        'prod': 'https://vpc-hw-dev-elastic-xc7pkoywlue6tj7dpafnezmy5a.us-west-2.es.amazonaws.com'
                                        }

# Initialize Logger
logger = logging.getLogger()
logger.setLevel(logging.INFO)

def indexDocElement(es_Url, awsauth, docData):
    try:
        #headers = { "Content-Type": "application/json" }
        headers = {'Content-type': 'application/json', 'Accept': 'text/plain'}
        resp = requests.post(es_Url, auth=awsauth, headers=headers, json=docData)
        if resp.status_code == 201:
            logger.info('INFO: Successfully inserted element into ES')
        else:
            logger.error('FAILURE: Unable to index element')
    except Exception as e:
        logger.error('ERROR: {0}'.format( str(e) ) )
        logger.error('ERROR: Unable to index line:"{0}"'.format( str( docData['content'] ) ) )
        print (e)


def lambda_handler(event, context):
    s3 = boto3.client('s3')
    credentials = boto3.Session().get_credentials()
    awsauth = AWS4Auth( credentials.access_key,
                        credentials.secret_key,
                        globalVars['awsRegion'],
                        globalVars['service'],
                        session_token=credentials.token
                    )

    logger.info("Received event: " + json.dumps(event, indent=2))

    try:
        bucket = event['Records'][0]['s3']['bucket']['name']
        key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'])

        # Get documet (obj) form S3
        obj = s3.get_object(Bucket=bucket, Key=key)

    except Exception as e:
        logger.error('ERROR: {0}'.format( str(e) ) )
        logger.error('ERROR: Unable able to GET object:{0} from S3 Bucket:{1}. Verify object exists.'.format(key, bucket) )

    if (key.endswith('.gz')) or (key.endswith('.tar.gz')):
        mycontentzip = gzip.GzipFile(fileobj=BytesIO(obj['Body'].read())).read()
        lines = mycontentzip.decode("utf-8").replace("'", '"')
        # print('unziped file')
    else:
        lines = obj['Body'].read().decode("utf-8").replace("'", '"')

    logger.info('SUCCESS: Retreived object from S3')

    # Split (S3 object/Log File) by lines
    lines = lines.splitlines()
    if (isinstance(lines, str)):
        lines = [lines]

    # Index each line to ES Domain
    indexName = globalVars['esIndexPrefix'] + str( datetime.date.today().year ) + '-' + str( datetime.date.today().month )
    es_Url = globalVars['esHosts'].get('prod') + '/' + indexName + '/' + globalVars['esIndexDocType']

    docData = {}
    docData['objectKey']        = str(key)
    docData['createdDate']      = str(obj['LastModified'])
    docData['content_type']     = str(obj['ContentType'])
    docData['content_length']   = str(obj['ContentLength'])

    for line in lines:
        docData['content'] = str(line)
        indexDocElement(es_Url, awsauth, docData )
    logger.info('SUCCESS: Successfully indexed the entire doc into ES')

if __name__ == '__main__':
    lambda_handler(None, None)
