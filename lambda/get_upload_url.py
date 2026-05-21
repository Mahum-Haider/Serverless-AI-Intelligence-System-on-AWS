import json
import boto3
import uuid
import os

s3 = boto3.client('s3')
# This variable is pulled from your Terraform configuration
BUCKET_NAME = os.environ['UPLOAD_BUCKET']

def lambda_handler(event, context):
    # Create a unique ID for the file to prevent overwriting
    file_id = str(uuid.uuid4())
    
    # Parse the information sent from your website
    body = json.loads(event.get('body', '{}'))
    original_name = body.get('fileName', 'artwork.jpg')
    file_type = body.get('fileType', 'image/jpeg') 
    
    object_name = f"{file_id}-{original_name}"

    try:
        # Generate the 'VIP Pass' (Pre-signed URL) matching the exact file type
        url = s3.generate_presigned_url('put_object',
                                        Params={'Bucket': BUCKET_NAME,
                                                'Key': object_name,
                                                'ContentType': file_type},
                                        ExpiresIn=300)
        
        return {
            'statusCode': 200,
            'headers': {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Headers': 'Content-Type',
                'Access-Control-Allow-Methods': 'OPTIONS,POST'
            },
            'body': json.dumps({'uploadURL': url, 'fileName': object_name})
        }
    except Exception as e:
        return {'statusCode': 500, 'body': json.dumps(str(e))}