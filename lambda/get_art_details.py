import json
import boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('ArtworkMetadata')

def lambda_handler(event, context):
    try:
        response = table.scan()
        items = response.get('Items', [])
        
        return {
            'statusCode': 200,
            'headers': {
                # This is the "permission slip" for your browser
                'Access-Control-Allow-Origin': '*', 
                'Access-Control-Allow-Methods': 'GET, OPTIONS',
                'Access-Control-Allow-Headers': 'Content-Type',
            },
            'body': json.dumps(items)
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': {
                'Access-Control-Allow-Origin': '*',
            },
            'body': json.dumps({'error': str(e)})
        }