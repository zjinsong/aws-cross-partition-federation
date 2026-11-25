"""跨 partition 身份联邦的 boto3 示例。

返回一个 boto3.Session，其凭证在过期前自动重新申请 JWT 并换取。
需要 boto3 1.40 或更高版本（支持 sts.get_web_identity_token）。

示例：
    # 在 Global 运行，访问中国区 S3
    python cross_partition_session.py \
        --source-region us-east-1 --dest-region cn-northwest-1 \
        --role-arn arn:aws-cn:iam::111122223333:role/CrossPartitionTarget \
        --audience cross-partition-test --bucket <your-china-bucket>
"""

import argparse

import boto3
import botocore.session
from botocore import UNSIGNED
from botocore.config import Config
from botocore.credentials import DeferredRefreshableCredentials


def cross_partition_session(
    role_arn,
    audience,
    source_region,
    dest_region,
    session_name="cross-partition-session",
    token_duration=300,
    source_session=None,
):
    """创建一个使用对端 partition 临时凭证的 boto3 Session。

    source_session 是工作负载在本端的身份，默认使用默认凭证链
    （EC2 实例配置文件、Lambda 执行角色等）。
    """
    source_session = source_session or boto3.Session()
    source_sts = source_session.client("sts", region_name=source_region)
    # AssumeRoleWithWebIdentity 不需要签名
    dest_sts = boto3.client(
        "sts", region_name=dest_region, config=Config(signature_version=UNSIGNED)
    )

    def refresh():
        token = source_sts.get_web_identity_token(
            Audience=[audience],
            SigningAlgorithm="ES384",
            DurationSeconds=token_duration,
        )["WebIdentityToken"]
        creds = dest_sts.assume_role_with_web_identity(
            RoleArn=role_arn,
            RoleSessionName=session_name,
            WebIdentityToken=token,
        )["Credentials"]
        return {
            "access_key": creds["AccessKeyId"],
            "secret_key": creds["SecretAccessKey"],
            "token": creds["SessionToken"],
            "expiry_time": creds["Expiration"].isoformat(),
        }

    botocore_session = botocore.session.get_session()
    botocore_session._credentials = DeferredRefreshableCredentials(
        refresh_using=refresh, method="cross-partition-identity-federation"
    )
    return boto3.Session(botocore_session=botocore_session, region_name=dest_region)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--source-region", required=True)
    parser.add_argument("--dest-region", required=True)
    parser.add_argument("--role-arn", required=True, help="对端 CrossPartitionTarget 角色 ARN")
    parser.add_argument("--audience", default="cross-partition-test")
    parser.add_argument("--source-profile", help="本端 CLI profile，默认使用默认凭证链")
    parser.add_argument("--bucket", help="可选：对端 S3 存储桶，用于列出对象")
    args = parser.parse_args()

    source = boto3.Session(profile_name=args.source_profile) if args.source_profile else None
    session = cross_partition_session(
        role_arn=args.role_arn,
        audience=args.audience,
        source_region=args.source_region,
        dest_region=args.dest_region,
        source_session=source,
    )

    print("对端身份:", session.client("sts").get_caller_identity()["Arn"])
    if args.bucket:
        resp = session.client("s3").list_objects_v2(Bucket=args.bucket)
        for obj in resp.get("Contents", []):
            print(f"  {obj['Key']}\t{obj['Size']}")


if __name__ == "__main__":
    main()
