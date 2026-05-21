import json
import boto3
import urllib.parse
import uuid

# -----------------------------
# AWS CLIENTS
# -----------------------------
session = boto3.Session(region_name='us-east-1')

s3 = session.client('s3')
rekognition = session.client('rekognition')
dynamodb = session.resource('dynamodb', region_name='ca-central-1')


def lambda_handler(event, context):
    try:
        # -----------------------------
        # 1. Get S3 event data
        # -----------------------------
        bucket = event['Records'][0]['s3']['bucket']['name']
        key = urllib.parse.unquote_plus(
            event['Records'][0]['s3']['object']['key'],
            encoding='utf-8'
        )

        print(f"Processing image: {key} from bucket: {bucket}")

        # -----------------------------
        # 2. Read image from S3
        # -----------------------------
        image_obj = s3.get_object(Bucket=bucket, Key=key)
        image_bytes = image_obj['Body'].read()

        # -----------------------------
        # 3. Rekognition - detect labels
        # -----------------------------
        rek_response = rekognition.detect_labels(
            Image={'Bytes': image_bytes},
            MaxLabels=10,
            MinConfidence=70
        )

        labels = [label['Name'] for label in rek_response['Labels']]
        print(f"Detected Labels: {labels}")

        # -----------------------------
        # 4. SIMPLE AI DESCRIPTION (NO BEDROCK)
        # -----------------------------
        title = f"Abstract Vision of {', '.join(labels[:3])}"

        description = (
            f"This artwork beautifully represents elements of {', '.join(labels)}. "
            "It blends imagination and reality into a modern artistic expression."
        )

        price_min = 100 + len(labels) * 20
        price_max = 250 + len(labels) * 35

        final_text = (
            f"{title}\n\n"
            f"{description}\n\n"
            f"Estimated Price: ${price_min} - ${price_max}"
        )

        print(f"Generated Output: {final_text}")

        # -----------------------------
        # 5. Save to DynamoDB
        # -----------------------------
        table = dynamodb.Table('ArtworkMetadata')
        artwork_id = str(uuid.uuid4())

        table.put_item(
            Item={
                'ArtworkID': artwork_id,
                'FileName': key,
                'Labels': labels,
                'AIDescription': final_text
            }
        )

        print("Saved to DynamoDB successfully!")

        return {
            'statusCode': 200,
            'body': json.dumps('Processing Complete')
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        raise e