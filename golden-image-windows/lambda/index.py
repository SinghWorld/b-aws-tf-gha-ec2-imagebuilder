"""
Triggered by EventBridge on EC2 Image Builder state change events.

On AVAILABLE: extracts the new AMI ID from the image build version ARN,
writes it to the SSM parameter that downstream Terraform reads, and
publishes a success notification.

On FAILED: publishes a failure notification only (does not touch the
parameter, so the last known-good AMI remains the active one).
"""
import json
import os
import boto3

ssm = boto3.client("ssm")
imagebuilder = boto3.client("imagebuilder")
sns = boto3.client("sns")

SSM_PARAMETER_NAME = os.environ["SSM_PARAMETER_NAME"]
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN", "")


def handler(event, context):
    detail = event.get("detail", {})
    status = detail.get("state", {}).get("status")
    image_arn = detail.get("imageArn") or detail.get("imageBuildVersionArn") or detail.get("imageVersionArn")

    if status == "AVAILABLE":
        image = imagebuilder.get_image(imageBuildVersionArn=image_arn)
        output_resources = image["image"].get("outputResources", {})
        amis = output_resources.get("amis", [])

        if not amis:
            _notify(f"Image build AVAILABLE but no AMIs found in output: {image_arn}")
            return {"status": "no_amis_found"}

        # Primary build region AMI — first entry corresponds to the
        # region the infrastructure configuration built in.
        new_ami_id = amis[0]["image"]
        region = amis[0]["region"]

        ssm.put_parameter(
            Name=SSM_PARAMETER_NAME,
            Value=new_ami_id,
            Type="String",
            Overwrite=True,
        )

        _notify(
            f"✅ New golden AMI published: {new_ami_id} ({region})\n"
            f"SSM parameter updated: {SSM_PARAMETER_NAME}\n"
            f"Build ARN: {image_arn}"
        )
        return {"status": "updated", "ami_id": new_ami_id}

    elif status == "FAILED":
        reason = detail.get("state", {}).get("reason", "unknown")
        _notify(
            f"❌ Golden image build FAILED.\n"
            f"Build ARN: {image_arn}\n"
            f"Reason: {reason}\n"
            f"Last known-good AMI in {SSM_PARAMETER_NAME} was NOT changed."
        )
        return {"status": "failed_notified"}

    return {"status": "ignored", "received_status": status}


def _notify(message: str):
    if not SNS_TOPIC_ARN:
        print(message)
        return
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject="Golden Image Pipeline Update",
        Message=message,
    )
