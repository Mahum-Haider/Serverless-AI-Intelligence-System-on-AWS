import boto3
from botocore.exceptions import ClientError

# Configuration - Ensure these match your main.tf
REGION = "ca-central-1"
# Update these names to match your actual S3 and DynamoDB resource names
BUCKET_NAME = "mahum-artist-uploads-19373b71" 
TABLE_NAME = "ArtworkMetadata"

def run_admin_report():
    print("\n" + "="*40)
    print("🎨 CLOUD-ARTIST-PLATFORM ADMIN TOOL")
    print("="*40)

    # Initialize AWS Clients
    s3 = boto3.client('s3', region_name=REGION)
    dynamodb = boto3.resource('dynamodb', region_name=REGION)
    table = dynamodb.Table(TABLE_NAME)

    # 1. Audit S3 Bucket
    print(f"\n[1/2] Auditing S3 Storage...")
    try:
        response = s3.list_objects_v2(Bucket=BUCKET_NAME)
        image_count = response.get('KeyCount', 0)
        print(f"✅ Found {image_count} raw images in S3.")
    except ClientError as e:
        print(f"❌ S3 Error: {e.response['Error']['Message']}")

    # 2. Audit DynamoDB Metadata
    print(f"\n[2/2] Auditing AI Metadata...")
    try:
        response = table.scan()
        items = response.get('Items', [])
        print(f"✅ Found {len(items)} metadata records in DynamoDB.")
        
        if items:
            all_labels = []
            for item in items:
                # This line checks for 'Labels', 'labels', OR 'tags'
                # It uses whichever one it finds first.
                labels = item.get('Labels') or item.get('labels') or item.get('tags') or []
                
                # If labels are stored as a list of strings
                if isinstance(labels, list):
                    all_labels.extend(labels)
            
            unique_labels = sorted(list(set(all_labels)))
            print(f"🤖 System has identified {len(unique_labels)} unique AI subjects.")
            
            if unique_labels:
                print(f"🏷️  Top AI Categories: {', '.join(unique_labels[:5])}")
            else:
                # DEBUG: If still 0, let's see what a sample record actually looks like
                print("⚠️  Labels found, but format is unexpected. Sample record keys:")
                print(list(items[0].keys()))
    
    except ClientError as e:
        print(f"❌ DynamoDB Error: {e.response['Error']['Message']}")

    print("\n" + "="*40)
    print("REPORT COMPLETE")
    print("="*40 + "\n")

if __name__ == "__main__":
    run_admin_report()