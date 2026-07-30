import json
import os
import requests
import base64
import boto3
import re
from openai import AzureOpenAI
from datetime import datetime
import urllib.parse
from botocore.exceptions import ClientError

# Initialize AWS clients outside the handler for performance
s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
failure_table = dynamodb.Table("DeviceFailureLogs")  # type: ignore[attr-defined]
secrets_client = boto3.client("secretsmanager")


def get_secret(secret_name, region_name="us-east-1"):
    """
    Retrieve a secret from AWS Secrets Manager.
    Returns the secret value as a string or raises an exception if the secret cannot be retrieved.
    """
    try:
        get_secret_value_response = secrets_client.get_secret_value(
            SecretId=secret_name
        )
        secret = get_secret_value_response["SecretString"]
        print(f"Successfully retrieved secret: {secret_name}")
        return secret
    except ClientError as e:
        print(f"ERROR: Could not retrieve secret '{secret_name}': {e}")
        raise e
    except Exception as e:
        print(f"ERROR: Unexpected error retrieving secret '{secret_name}': {e}")
        raise e


def get_secrets_from_json(secret_name, region_name="us-east-1"):
    """
    Retrieve multiple secrets stored as JSON in a single AWS Secrets Manager secret.
    Returns a dictionary with the parsed JSON content.
    """
    try:
        secret_string = get_secret(secret_name, region_name)
        secrets_dict = json.loads(secret_string)
        print(f"Successfully parsed JSON secret: {secret_name}")
        return secrets_dict
    except json.JSONDecodeError as e:
        print(f"ERROR: Could not parse JSON from secret '{secret_name}': {e}")
        raise e
    except Exception as e:
        print(f"ERROR: Could not retrieve JSON secret '{secret_name}': {e}")
        raise e


def read_local_file(path):
    """Reads a template file from the local Lambda deployment package."""
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def read_s3_file(bucket_name, object_key):
    """Reads a log file from an S3 bucket."""
    try:
        response = s3_client.get_object(Bucket=bucket_name, Key=object_key)
        return response["Body"].read().decode("utf-8")
    except Exception as e:
        print(f"Error reading S3 object s3://{bucket_name}/{object_key}: {e}")
        raise


def parse_log_details(log_content):
    """Parses the entire log file to extract key details in one pass."""
    log_details = {
        "hostname": "Unknown",
        "model": "Unknown",
        "device_owner": "Unknown",
        "domain": "Unknown",
        "os_version": "Unknown",
        "build_date": "Unknown",
        "last_boot_time": "Unknown",
        "passed": 0,
        "failed": 0,
        "cloud_pc_location": None,
    }
    patterns = {
        "hostname": re.compile(r"Hostname:\s*(.*)", re.IGNORECASE),
        "model": re.compile(r"Model:\s*(.*)", re.IGNORECASE),
        "device_owner": re.compile(r"Device owner:\s*(.*)", re.IGNORECASE),
        "domain": re.compile(r"Domain:\s*(.*)", re.IGNORECASE),
        "os_version": re.compile(r"OS Version:\s*(.*)", re.IGNORECASE),
        "build_date": re.compile(
            r"OS Install Date:\s*(\d{4}-\d{2}-\d{2})", re.IGNORECASE
        ),
        "last_boot_time": re.compile(r"Last Boot Time:\s*(.*)", re.IGNORECASE),
        "passed": re.compile(r"Passed:\s*(\d+)", re.IGNORECASE),
        "failed": re.compile(r"Failed:\s*(\d+)", re.IGNORECASE),
        "cloud_pc_location": re.compile(r"Cloud PC Location:\s*(.*)", re.IGNORECASE),
    }
    for line in log_content.splitlines():
        for key, pattern in patterns.items():
            match = pattern.search(line)
            if match:
                value = match.group(1).strip()
                if key in ["passed", "failed"]:
                    log_details[key] = int(value)
                else:
                    log_details[key] = value
                print(
                    f"Found '{key}': '{log_details[key]}' from line: '{line.strip()}'"
                )

    print(f"Final log_details: {log_details}")
    return log_details


def create_presigned_url(bucket_name, object_key, expiration=86400):
    """Generate a presigned URL to share an S3 object, with robust error handling."""
    try:
        response = s3_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": bucket_name, "Key": object_key},
            ExpiresIn=expiration,
        )
        print("Successfully generated S3 Pre-signed URL.")
        return response
    except Exception as e:
        print(
            f"ERROR: Could not generate presigned URL for key '{object_key}'. Reason: {e}"
        )
        return None


def get_oauth_access_token(client_id, client_secret):
    """Obtains an access token from the OAuth service."""
    token_url = os.environ.get("OAUTH_TOKEN_URL")
    if not token_url:
        print("ERROR: OAUTH_TOKEN_URL environment variable not set")
        return None
    payload = "grant_type=client_credentials"
    encoded_value = base64.b64encode(
        f"{client_id}:{client_secret}".encode("utf-8")
    ).decode("utf-8")
    headers = {
        "Accept": "*/*",
        "Content-Type": "application/x-www-form-urlencoded",
        "Authorization": f"Basic {encoded_value}",
    }
    try:
        token_response = requests.post(token_url, headers=headers, data=payload)
        token_response.raise_for_status()
        access_token = token_response.json().get("access_token")
        if not access_token:
            print("Error: Could not obtain access token.")
        return access_token
    except requests.exceptions.RequestException as e:
        print(f"Error obtaining access token: {e}")
        return None


def summarize_log_with_ai(log_text, template_json, access_token, app_key):
    """
    Calls Azure OpenAI to summarize the log and populate the failure template.
    """
    azure_endpoint = os.environ.get("AZURE_OPENAI_ENDPOINT")
    if not azure_endpoint:
        print("ERROR: AZURE_OPENAI_ENDPOINT environment variable not set")
        return None
    client = AzureOpenAI(
        azure_endpoint=azure_endpoint,
        api_key=access_token,
        api_version="2024-08-01-preview",
    )
    prompt = (
        "You are a log processing bot. Your only function is to populate a JSON template with data extracted from a log file from a Windows laptop. "
        "You MUST follow all output format rules precisely.\n\n"
        "Be descriptive when providing troubleshooting steps!"
        "### TASK ###\n"
        "Based on the `Input log` below, extract the following information:\n"
        "1. A numbered list of all unique error messages. Do not add suggestions.\n"
        "2. A numbered list of detailed troubleshooting suggestions, formulated as an Intune administrator, directly paired with each error.\n"
        "3. The total counts for Successes, Errors, and Warnings.\n\n"
        "### OUTPUT INSTRUCTIONS ###\n"
        "1. Insert the extracted data into the `Template` provided below by replacing the placeholders `${ERROR_ONLY}`, `${TROUBLESHOOT_SUGGESTIONS}`, and any count placeholders.\n"
        "2. Your FINAL response MUST be ONLY the populated, valid JSON object.\n"
        "3. DO NOT include any introductory text, explanations, apologies, or markdown formatting like ```json. Your entire response must start with `{` and end with `}`.\n"
        '4. All strings in the JSON must be properly escaped (e.g., newlines as \\n, double quotes as \\").\n\n'
        f"### Template ###\n{template_json}\n\n"
        f"### Input log ###\n{log_text}"
    )
    response = client.chat.completions.create(
        model="gemini-3.1-flash-lite",
        messages=[
            {
                "role": "system",
                "content": "You are a machine that only returns valid JSON. You do not engage in conversation. You follow formatting instructions perfectly.",
            },
            {"role": "user", "content": prompt},
        ],
        temperature=0,
        max_tokens=9000,
        user=f'{{"appkey": "{app_key}"}}',
    )
    content = response.choices[0].message.content
    if content is None:
        raise ValueError("Azure OpenAI response content was empty")
    return content.strip()


def send_webex_adaptive_card(room_id, bot_token, adaptive_card_json_str):
    """Sends the generated Adaptive Card to a Webex room."""
    url = "https://webexapis.com/v1/messages"
    headers = {
        "Authorization": f"Bearer {bot_token}",
        "Content-Type": "application/json",
    }
    try:
        adaptive_card_json = json.loads(adaptive_card_json_str)
    except json.JSONDecodeError as e:
        print(
            f"Failed to parse Adaptive Card JSON: {e}\nRaw JSON string was: {adaptive_card_json_str}"
        )
        return
    payload = {
        "roomId": room_id,
        "markdown": "Device Health Check Summary",
        "attachments": [
            {
                "contentType": "application/vnd.microsoft.card.adaptive",
                "content": adaptive_card_json,
            }
        ],
    }
    response = requests.post(url, headers=headers, json=payload)
    if response.status_code == 200:
        print("Adaptive Card successfully sent to Webex.")
    else:
        print(f"Failed to send card. Status: {response.status_code}\n{response.text}")


def lambda_handler(event, context):
    # --- Get creds from SECRETS MANAGER ---
    try:
        secrets_path = os.getenv("SECRETS_PATH")
        if not secrets_path:
            print("FATAL ERROR: Missing required env var SECRETS_PATH")
            return {
                "statusCode": 500,
                "body": json.dumps(
                    "Missing required environment variable: SECRETS_PATH"
                ),
            }
        secrets = get_secrets_from_json(secrets_path)
        webex_room_id = secrets.get("WEBEX_ROOM_ID")
        webex_bot_token = secrets.get("WEBEX_BOT_TOKEN")
        client_id = secrets.get("OAUTH_CLIENT_ID")
        client_secret = secrets.get("OAUTH_CLIENT_SECRET")
        app_key = secrets.get("AI_APP_KEY")

    except Exception as e:
        print(f"FATAL ERROR: Could not retrieve required secrets: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps(
                "Failed to retrieve required credentials from Secrets Manager"
            ),
        }

    if (
        "Records" not in event
        or not isinstance(event.get("Records"), list)
        or not event["Records"]
    ):
        print("This event is not a valid S3 trigger event. Exiting.")
        return {
            "statusCode": 400,
            "body": json.dumps("Input event was not a valid S3 event."),
        }

    s3_event = event["Records"][0]["s3"]
    bucket_name = s3_event["bucket"]["name"]
    encoded_key = s3_event["object"]["key"]
    object_key = urllib.parse.unquote_plus(encoded_key)

    print(f"Processing S3 object: s3://{bucket_name}/{object_key}")

    final_card_str = ""

    try:
        download_url = create_presigned_url(bucket_name, object_key)
        log_content_str = read_s3_file(bucket_name, object_key)
        log_details = parse_log_details(log_content_str)
        is_cloud_pc = log_details.get("model", "").lower().startswith("cloud pc")
        if is_cloud_pc and not log_details.get("cloud_pc_location"):
            log_details["cloud_pc_location"] = "Unknown"
        card_json_str = ""

        if log_details["failed"] > 0:
            # --- FAILURE PATH ---
            print(
                f"Failures detected ({log_details['failed']}). Storing details and sending alert."
            )

            try:
                item = {
                    "event_id": context.aws_request_id,
                    "timestamp": datetime.utcnow().isoformat(),
                    "hostname": log_details.get("hostname", "Unknown"),
                    "model": log_details.get("model", "Unknown"),
                    "device_owner": log_details.get("device_owner", "Unknown"),
                    "domain": log_details.get("domain", "Unknown"),
                    "errors": [
                        line.strip()
                        for line in log_content_str.splitlines()
                        if "[FAIL]" in line
                    ],
                }
                if log_details.get("cloud_pc_location"):
                    item["cloud_pc_location"] = log_details["cloud_pc_location"]
                failure_table.put_item(Item=item)
                print("Successfully stored failure data in DynamoDB.")
            except Exception as db_error:
                print(f"ERROR - Could not write to DynamoDB: {db_error}")

            failure_template_str = read_local_file("template_failure.json")

            hostname_display = log_details["hostname"]
            if is_cloud_pc and log_details.get("cloud_pc_location"):
                hostname_display = (
                    f"{hostname_display} ({log_details['cloud_pc_location']})"
                )
            failure_template_str = failure_template_str.replace(
                "${hostname}", hostname_display
            )
            failure_template_str = failure_template_str.replace(
                "${model}", log_details["model"]
            )
            failure_template_str = failure_template_str.replace(
                "${device_owner}", log_details["device_owner"]
            )
            failure_template_str = failure_template_str.replace(
                "${domain}", log_details["domain"]
            )
            failure_template_str = failure_template_str.replace(
                "${os_version}", log_details["os_version"]
            )
            failure_template_str = failure_template_str.replace(
                "${build_date}", log_details["build_date"]
            )
            failure_template_str = failure_template_str.replace(
                "${cloud_pc_location}", ""
            )
            failure_template_str = failure_template_str.replace(
                "${last_boot_time}", log_details["last_boot_time"]
            )
            failure_template_str = failure_template_str.replace(
                "${run_timestamp}", datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            )
            failure_template_str = failure_template_str.replace(
                "${success_count}", str(log_details["passed"])
            )
            failure_template_str = failure_template_str.replace(
                "${error_count}", str(log_details["failed"])
            )

            # Credentials are already retrieved at the beginning of the lambda_handler
            access_token = get_oauth_access_token(client_id, client_secret)
            if access_token:
                card_json_str = summarize_log_with_ai(
                    log_content_str, failure_template_str, access_token, app_key
                )
        else:
            # --- SUCCESS PATH ---
            print("No failures detected. Creating simple success card.")
            success_template_str = read_local_file("template_success.json")
            hostname_display = log_details.get("hostname", "Unknown")
            if is_cloud_pc and log_details.get("cloud_pc_location"):
                hostname_display = (
                    f"{hostname_display} ({log_details['cloud_pc_location']})"
                )
            card_json_str = success_template_str.replace(
                "${hostname}", hostname_display
            )
            card_json_str = card_json_str.replace("${model}", log_details["model"])
            card_json_str = card_json_str.replace(
                "${deviceOwner}", log_details.get("device_owner", "Unknown")
            )
            card_json_str = card_json_str.replace(
                "${domain}", log_details.get("domain", "Unknown")
            )
            card_json_str = card_json_str.replace(
                "${os_version}", log_details.get("os_version", "Unknown")
            )
            card_json_str = card_json_str.replace(
                "${build_date}", log_details.get("build_date", "Unknown")
            )
            card_json_str = card_json_str.replace("${cloud_pc_location}", "")
            card_json_str = card_json_str.replace(
                "${last_boot_time}", log_details.get("last_boot_time", "Unknown")
            )
            card_json_str = card_json_str.replace(
                "${success_count}", str(log_details["passed"])
            )
            card_json_str = card_json_str.replace(
                "${tests_performed}", str(log_details["passed"] + log_details["failed"])
            )
            card_json_str = card_json_str.replace(
                "${run_timestamp}", datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            )

        # --- Dynamically add the download button OR a warning message ---
        if card_json_str:
            try:
                card_object = json.loads(card_json_str)
                if "actions" not in card_object:
                    card_object["actions"] = []
                if "body" not in card_object:
                    card_object["body"] = []

                # Validate and fix any existing Action.OpenUrl items
                if "actions" in card_object and isinstance(
                    card_object["actions"], list
                ):
                    valid_actions = []
                    for action in card_object["actions"]:
                        if action.get("type") == "Action.OpenUrl":
                            url = action.get("url", "")
                            if (
                                url
                                and isinstance(url, str)
                                and url.startswith(("http://", "https://"))
                            ):
                                valid_actions.append(action)
                            else:
                                print(
                                    f"Removed invalid Action.OpenUrl with URL: '{url}'"
                                )
                        else:
                            valid_actions.append(action)
                    card_object["actions"] = valid_actions

                if download_url and download_url.startswith(("http://", "https://")):
                    card_object["actions"].append(
                        {
                            "type": "Action.OpenUrl",
                            "title": "Download Full Log",
                            "url": download_url,
                        }
                    )
                else:
                    card_object["body"].append(
                        {
                            "type": "TextBlock",
                            "text": "**Note:** A download link for the log file could not be generated due to a temporary error.",
                            "color": "Warning",
                            "spacing": "Large",
                            "wrap": True,
                        }
                    )

                final_card_str = json.dumps(card_object, ensure_ascii=False)
            except json.JSONDecodeError as e:
                print(
                    f"Warning: Could not parse card JSON to add button. Sending card as-is. Error: {e}"
                )
                final_card_str = card_json_str

        if final_card_str:
            send_webex_adaptive_card(webex_room_id, webex_bot_token, final_card_str)

        print("Processing complete. S3 object will be expired by lifecycle policy.")
        return {
            "statusCode": 200,
            "body": json.dumps("Process completed successfully."),
        }

    except Exception as e:
        print(f"An error occurred during execution: {e}")
        raise e
