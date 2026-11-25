# 使用 IAM outbound identity federation 实现 Global 与中国区双向跨 Partition 访问

2026 年 11 月 9 日，Amazon STS 发布了跨 partition 身份联邦功能，Amazon Web Services 中国（北京）区域和中国（宁夏）区域同步可用。本文在一个 Global 账号和一个中国区账号之间完成双向配置和验证，供需要在两个 partition 之间互访的团队参考。

- 发布公告：[Amazon STS now supports cross-partition federation for Amazon identities](https://www.amazonaws.cn/en/new/2026/amazon-sts-supports-cross-partition-federation-for-amazon-identities/)
- 官方博客：[Simplify cross-partition access with AWS IAM outbound identity federation](https://aws.amazon.com/cn/blogs/security/simplify-cross-partition-access-with-aws-iam-outbound-identity-federation/)
- 用户指南：[Federating Amazon identities across Amazon partitions](https://docs.amazonaws.cn/en_us/IAM/latest/UserGuide/id_roles_providers_outbound_cross_partition.html)

> **重要：** 中国区和 Global 之间的访问可能涉及数据出境。实施前请与合规团队确认方案符合相关法规要求。

## 背景

Global（`aws`）和中国区（`aws-cn`）是两个相互隔离的 partition，各自运行独立的 IAM。一个 partition 签发的凭证在另一个 partition 中无效，因此 `sts:AssumeRole` 不能跨 partition 使用，资源策略也无法引用另一个 partition 的 principal。

过去常见的做法有两种：

- 在对端账号创建 IAM 用户，把长期 access key 保存在本端。密钥需要自行保管和轮换。
- 使用 IAM Roles Anywhere。这种方式没有长期密钥，但需要运营自己的 PKI 来签发 X.509 证书。

跨 partition 身份联邦提供了第三种方式。工作负载调用本端 STS 的 `sts:GetWebIdentityToken`，获得一个由 AWS 签名的短期 JWT，再调用对端 STS 的 `sts:AssumeRoleWithWebIdentity`，用这个 JWT 换取对端的临时凭证。整个过程中没有长期密钥，签名和公钥发布都由 STS 负责。

## 方案优势

- **基于来源身份做授权**：目标端角色的 trust policy 可以按 JWT 中的账号、组织 ID、来源区域和 principal 设置条件。
- **两端可审计**：目标端 CloudTrail 事件记录来源 principal ARN、来源区域，以及一个可以关联到源端事件的 token ID。
- **全程临时凭证**：JWT 和换取的凭证都会自动过期。
- **无需自建基础设施**：不需要部署 PKI，也不需要托管 OpenID Provider。
- **沿用 IAM 模型**：使用现有的角色、trust policy 和权限策略完成控制。
- **不额外收费**：中国区两个区域和 Global 所有区域均可使用。

## 工作原理

JWT 和临时凭证的用途不同：

| | JWT | 临时凭证 |
|---|---|---|
| 签发方 | 源端 partition 的 STS | 目标端 partition 的 STS |
| 内容 | 带签名的身份声明，例如账号、角色、来源区域 | `AccessKeyId`、`SecretAccessKey`、`SessionToken` |
| 用途 | 只用于向目标端 STS 证明身份 | 签名 API 请求，访问目标端资源 |
| 有效期 | 60 至 3600 秒，默认 300 秒 | 默认 1 小时，上限为目标角色的 `MaxSessionDuration` |

JWT 只在换取凭证时使用一次，过期后不影响已签发的凭证。

完整流程如下：

1. **申请 token**：工作负载以本端 IAM 角色的身份调用 `sts:GetWebIdentityToken`。
2. **签发 token**：本端 STS 返回一个短期 JWT，其中包含账号 ID、principal ARN、来源区域等声明。
3. **提交 token**：工作负载调用对端 STS 的 `sts:AssumeRoleWithWebIdentity`，传入 JWT 和目标角色 ARN。这个请求不需要签名。
4. **获取公钥**：对端 STS 从源端 issuer 的 JWKS 端点获取验签公钥。
5. **验证**：对端 STS 校验签名，并评估目标角色的 trust policy。
6. **返回凭证**：对端 STS 返回目标角色的临时凭证。
7. **访问资源**：工作负载用这组凭证访问对端资源。

```
方向 1：Global → 中国区
  Global: CrossPartitionCaller
     │ ① sts:GetWebIdentityToken（us-east-1）
     ▼
  JWT（iss = <global-issuer-id>.tokens.sts.global.api.aws）
     │ ② sts:AssumeRoleWithWebIdentity（cn-northwest-1，无签名）
     ▼
  中国区: CrossPartitionTarget 临时凭证 ──③──▶ Amazon S3 存储桶

方向 2：中国区 → Global（与方向 1 对称）
  中国区: CrossPartitionCaller
     │ ① sts:GetWebIdentityToken（cn-northwest-1）
     ▼
  JWT（iss = <cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn）
     │ ② sts:AssumeRoleWithWebIdentity（us-east-1，无签名）
     ▼
  Global: CrossPartitionTarget 临时凭证 ──③──▶ STS / IAM
```

## 配置跨 partition 身份联邦

本文的示例环境如下：

| | 中国区 | Global |
|---|---|---|
| Partition | `aws-cn` | `aws` |
| 区域 | `cn-northwest-1`（宁夏） | `us-east-1` |
| 账号 ID（示例） | `111122223333` | `444455556666` |
| CLI profile | `ChinaCredentials` | `GlobalCredentials` |

每个账号各创建两个角色：

| 角色 | 作用 |
|---|---|
| `CrossPartitionCaller` | 发起方。工作负载在本端使用的身份，只有申请 JWT 的权限 |
| `CrossPartitionTarget` | 落地方。对端通过 JWT 换取的就是这个角色的临时凭证 |

两个方向使用相同的 audience：`cross-partition-test`。

### 前提条件

- 一个中国区账号和一个 Global 账号。
- 在两个账号中，具有以下权限的 IAM principal：`iam:EnableOutboundWebIdentityFederation`、`iam:CreateRole`、`iam:PutRolePolicy`、`iam:CreateOpenIDConnectProvider`。
- 中国区账号中的一个 S3 存储桶，作为方向 1 的访问目标。
- 已安装 AWS CLI v2 和 jq。

本文的演示通过 CLI assume `CrossPartitionCaller` 来模拟工作负载。在生产环境中，Amazon EC2 实例配置文件、AWS Lambda 执行角色或 Amazon EKS Pod 的角色就是这个角色，不需要额外的 assume 步骤。

### 步骤 0：配置两个 CLI profile

在 `~/.aws/config` 中为两个 partition 分别配置 profile：

```ini
[profile ChinaCredentials]
region = cn-northwest-1

[profile GlobalCredentials]
region = us-east-1
```

后续命令都会显式指定 `--profile` 和 `--region`。

### 步骤 1：在两个账号中开启 outbound identity federation

这是账号级设置，每个账号执行一次。

```bash
aws iam enable-outbound-web-identity-federation --profile ChinaCredentials
aws iam enable-outbound-web-identity-federation --profile GlobalCredentials
```

命令会返回各自的 issuer URL：

```json
{ "IssuerIdentifier": "https://<cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn" }
{ "IssuerIdentifier": "https://<global-issuer-id>.tokens.sts.global.api.aws" }
```

将两个 issuer 主机名保存为变量，后续步骤会用到：

```bash
CN_ACCT=111122223333
GL_ACCT=444455556666
AUD=cross-partition-test
CN_ISS=<cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn
GL_ISS=<global-issuer-id>.tokens.sts.global.api.aws
BUCKET=<your-china-bucket>
```

> **说明：** 开启之前调用 `aws iam get-outbound-web-identity-federation-info` 会返回 `FeatureDisabled`，该功能默认关闭。

### 步骤 2：创建发起方角色 CrossPartitionCaller

1. 创建 trust policy。演示中允许 CLI 使用的 IAM 身份 assume 这个角色。生产环境中，请改为工作负载所用的服务主体，例如 `"Service": "ec2.amazonaws.com"`。

   `cn-caller-trust.json`

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": { "AWS": "arn:aws-cn:iam::111122223333:user/<your-cli-user>" },
         "Action": "sts:AssumeRole"
       }
     ]
   }
   ```

   `gl-caller-trust.json` 的结构相同，principal 改为 `arn:aws:iam::444455556666:user/<your-cli-user>`。

2. 创建权限策略。这份策略两个账号共用，只允许申请 audience 为 `cross-partition-test`、时长不超过 300 秒、算法为 ES384 的 token。

   `token-policy.json`

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "sts:GetWebIdentityToken",
         "Resource": "*",
         "Condition": {
           "ForAllValues:StringEquals": { "sts:IdentityTokenAudience": "cross-partition-test" },
           "Null": { "sts:IdentityTokenAudience": "false" },
           "NumericLessThanEquals": { "sts:DurationSeconds": 300 },
           "StringEquals": { "sts:SigningAlgorithm": "ES384" }
         }
       }
     ]
   }
   ```

3. 在两个账号中创建角色并附加策略：

   ```bash
   aws iam create-role --profile ChinaCredentials \
     --role-name CrossPartitionCaller \
     --assume-role-policy-document file://cn-caller-trust.json
   aws iam put-role-policy --profile ChinaCredentials \
     --role-name CrossPartitionCaller \
     --policy-name AllowGetWebIdentityToken \
     --policy-document file://token-policy.json

   aws iam create-role --profile GlobalCredentials \
     --role-name CrossPartitionCaller \
     --assume-role-policy-document file://gl-caller-trust.json
   aws iam put-role-policy --profile GlobalCredentials \
     --role-name CrossPartitionCaller \
     --policy-name AllowGetWebIdentityToken \
     --policy-document file://token-policy.json
   ```

### 步骤 3：在每个账号中注册对端 issuer

每个账号都要把**对端**的 issuer 注册为 OIDC identity provider。`client-id-list` 必须包含约定的 audience。

```bash
# 中国区信任 Global issuer
aws iam create-open-id-connect-provider --profile ChinaCredentials \
  --url https://$GL_ISS \
  --client-id-list $AUD

# Global 信任中国区 issuer
aws iam create-open-id-connect-provider --profile GlobalCredentials \
  --url https://$CN_ISS \
  --client-id-list $AUD
```

> **说明：** `--thumbprint-list` 可以省略，IAM 会自动获取证书指纹。

### 步骤 4：创建落地方角色 CrossPartitionTarget

1. 创建 trust policy。目标角色信任对端的 OIDC provider，并同时校验 `sub`、`aud` 和 `source_region`。条件键的前缀是不带 `https://` 的 issuer 主机名。

   `cn-target-trust.json`（中国区，接收来自 Global 的请求）

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws-cn:iam::111122223333:oidc-provider/<global-issuer-id>.tokens.sts.global.api.aws"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "<global-issuer-id>.tokens.sts.global.api.aws:sub": "arn:aws:iam::444455556666:role/CrossPartitionCaller",
             "<global-issuer-id>.tokens.sts.global.api.aws:aud": "cross-partition-test",
             "<global-issuer-id>.tokens.sts.global.api.aws:source_region": "us-east-1"
           }
         }
       }
     ]
   }
   ```

   `gl-target-trust.json`（Global，接收来自中国区的请求）

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::444455556666:oidc-provider/<cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "<cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn:sub": "arn:aws-cn:iam::111122223333:role/CrossPartitionCaller",
             "<cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn:aud": "cross-partition-test",
             "<cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn:source_region": "cn-northwest-1"
           }
         }
       }
     ]
   }
   ```

   如果需要限定来源组织，可以再加一个 `:org_id` 条件。

2. 创建权限策略。中国区角色只能访问指定的存储桶，Global 角色只能读取自身信息。

   `cn-target-perm.json`

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "s3:ListBucket",
         "Resource": "arn:aws-cn:s3:::<your-china-bucket>"
       },
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject", "s3:PutObject"],
         "Resource": "arn:aws-cn:s3:::<your-china-bucket>/*"
       }
     ]
   }
   ```

   `gl-target-perm.json`

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": "iam:GetRole",
         "Resource": "arn:aws:iam::444455556666:role/CrossPartitionTarget"
       }
     ]
   }
   ```

3. 创建角色并附加策略：

   ```bash
   aws iam create-role --profile ChinaCredentials \
     --role-name CrossPartitionTarget \
     --assume-role-policy-document file://cn-target-trust.json
   aws iam put-role-policy --profile ChinaCredentials \
     --role-name CrossPartitionTarget \
     --policy-name S3BucketAccess \
     --policy-document file://cn-target-perm.json

   aws iam create-role --profile GlobalCredentials \
     --role-name CrossPartitionTarget \
     --assume-role-policy-document file://gl-target-trust.json
   aws iam put-role-policy --profile GlobalCredentials \
     --role-name CrossPartitionTarget \
     --policy-name SelfGetRole \
     --policy-document file://gl-target-perm.json
   ```

### 步骤 5：方向 1，从 Global 访问中国区 S3

1. 进入 Global 的 `CrossPartitionCaller` 角色。生产环境中工作负载已经以这个角色运行，可以跳过这一步。

   ```bash
   CALLER_CREDS=$(aws sts assume-role --profile GlobalCredentials --region us-east-1 \
     --role-arn arn:aws:iam::$GL_ACCT:role/CrossPartitionCaller \
     --role-session-name cross-partition-demo \
     --query Credentials --output json)
   export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$CALLER_CREDS")
   export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$CALLER_CREDS")
   export AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$CALLER_CREDS")
   ```

2. 向 Global STS 申请 JWT。跨 partition 场景下只能指定一个 audience。

   ```bash
   JWT=$(aws sts get-web-identity-token --region us-east-1 \
     --audience $AUD \
     --signing-algorithm ES384 \
     --duration-seconds 300 \
     --query WebIdentityToken --output text)
   ```

   JWT 解码后的 payload 如下：

   ```json
   {
     "aud": "cross-partition-test",
     "sub": "arn:aws:iam::444455556666:role/CrossPartitionCaller",
     "https://sts.amazonaws.com/": {
       "org_id": "o-exampleglobal",
       "aws_account": "444455556666",
       "ou_path": ["o-exampleglobal/r-exam/"],
       "original_session_exp": "2026-11-25T06:55:58Z",
       "source_region": "us-east-1",
       "principal_id": "arn:aws:iam::444455556666:role/CrossPartitionCaller"
     },
     "iss": "https://<global-issuer-id>.tokens.sts.global.api.aws",
     "iat": 1795586161,
     "exp": 1795586461,
     "jti": "11111111-aaaa-4bbb-8ccc-000000000001"
   }
   ```

3. 清除本端凭证，向中国区 STS 换取凭证。这个请求不需要签名。

   ```bash
   unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

   TARGET_CREDS=$(aws sts assume-role-with-web-identity --region cn-northwest-1 \
     --no-sign-request \
     --role-arn arn:aws-cn:iam::$CN_ACCT:role/CrossPartitionTarget \
     --role-session-name from-global \
     --web-identity-token "$JWT" \
     --output json)
   ```

   返回结果的主要字段：

   ```json
   {
     "AssumedRoleUser": {
       "Arn": "arn:aws-cn:sts::111122223333:assumed-role/CrossPartitionTarget/from-global"
     },
     "Audience": "cross-partition-test",
     "SubjectFromWebIdentityToken": "arn:aws:iam::444455556666:role/CrossPartitionCaller",
     "Provider": "arn:aws-cn:iam::111122223333:oidc-provider/<global-issuer-id>.tokens.sts.global.api.aws"
   }
   ```

4. 导出临时凭证，访问中国区存储桶：

   ```bash
   export AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId <<<"$TARGET_CREDS")
   export AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey <<<"$TARGET_CREDS")
   export AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken <<<"$TARGET_CREDS")

   aws sts get-caller-identity --region cn-northwest-1
   aws s3 ls s3://$BUCKET/ --region cn-northwest-1
   aws s3 cp s3://$BUCKET/seed.txt - --region cn-northwest-1
   echo "written from Global" | aws s3 cp - s3://$BUCKET/from-global.txt --region cn-northwest-1
   ```

   实际输出：

   ```
   arn:aws-cn:sts::111122223333:assumed-role/CrossPartitionTarget/from-global
   2026-11-25 05:55:03         63 from-global.txt
   2026-11-25 05:53:06         36 seed.txt
   hello from china
   upload: - to s3://<your-china-bucket>/from-global.txt
   ```

### 步骤 6：方向 2，从中国区访问 Global

方向 2 的步骤与方向 1 相同，只需对调 profile、区域和账号。

```bash
CALLER_CREDS=$(aws sts assume-role --profile ChinaCredentials --region cn-northwest-1 \
  --role-arn arn:aws-cn:iam::$CN_ACCT:role/CrossPartitionCaller \
  --role-session-name cross-partition-demo \
  --query Credentials --output json)
export AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$CALLER_CREDS")
export AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$CALLER_CREDS")
export AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$CALLER_CREDS")

JWT=$(aws sts get-web-identity-token --region cn-northwest-1 \
  --audience $AUD --signing-algorithm ES384 --duration-seconds 300 \
  --query WebIdentityToken --output text)

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

TARGET_CREDS=$(aws sts assume-role-with-web-identity --region us-east-1 \
  --no-sign-request \
  --role-arn arn:aws:iam::$GL_ACCT:role/CrossPartitionTarget \
  --role-session-name from-china \
  --web-identity-token "$JWT" \
  --output json)

export AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId <<<"$TARGET_CREDS")
export AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey <<<"$TARGET_CREDS")
export AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken <<<"$TARGET_CREDS")

aws sts get-caller-identity --region us-east-1
aws iam get-role --region us-east-1 --role-name CrossPartitionTarget --query Role.Arn
```

实际输出：

```
arn:aws:sts::444455556666:assumed-role/CrossPartitionTarget/from-china
"arn:aws:iam::444455556666:role/CrossPartitionTarget"
```

中国区签发的 JWT 中，`iss` 为 `https://<cn-issuer-id>.tokens.sts.global.api.amazonwebservices.com.cn`，`source_region` 为 `cn-northwest-1`，其他字段的结构与方向 1 相同。

## 验证访问控制

以下请求都应被拒绝。实测结果与预期一致。

| 用例 | 检查位置 | 结果 |
|---|---|---|
| 申请 audience 为 `wrong-aud` 的 token | 源端权限策略 `sts:IdentityTokenAudience` | `AccessDenied`（GetWebIdentityToken） |
| 申请 900 秒的 token | 源端权限策略 `sts:DurationSeconds` | `AccessDenied`（GetWebIdentityToken） |
| 用 us-west-2 签发的 token 换取中国区凭证 | 目标端 trust policy `source_region` | `AccessDenied`（AssumeRoleWithWebIdentity） |
| 用合法 token 换取未信任该 provider 的角色 | 目标端 trust policy | `AccessDenied`（AssumeRoleWithWebIdentity） |
| 在同一 partition 内交换 token | STS 服务端 | `InvalidIdentityToken`，提示改用 `AssumeRole` |
| 落地角色执行 `aws s3 ls` 列出所有存储桶 | 目标端权限策略 | `AccessDenied`（s3:ListAllMyBuckets） |
| 落地角色执行 `aws iam list-roles` | 目标端权限策略 | `AccessDenied`（iam:ListRoles） |

同一账号在不同区域签发的 token 使用同一个 issuer，只有 `source_region` 不同。因此可以在 trust policy 中用 `source_region` 限定允许的来源区域。

## 安全最佳实践

- **最小权限**：目标角色只授予必要的操作，并限定到具体资源。
- **使用条件键**：源端限制 `sts:IdentityTokenAudience`、`sts:DurationSeconds` 和 `sts:SigningAlgorithm`。目标端校验 `sub`、`aud` 和 `source_region`，按需增加 `org_id`。如需限定到具体计算资源，可以使用 `ec2_source_instance_arn` 或 `lambda_source_function_arn`。
- **缩短 token 有效期**：JWT 只用于换取凭证，300 秒通常已经足够。
- **开启两端 CloudTrail**：用 token ID 关联源端和目标端的事件，详见下文。
- **确认合规要求**：中国区与 Global 之间的数据流动，需要满足数据出境相关规定。

## 按来源控制跨 partition 访问

### 用 RCP 设置来源白名单

`sts:AssumeRoleWithWebIdentity` 也被 GitHub Actions、Amazon EKS 等其他 OIDC 联邦使用。下面的策略用 `StringLike` 只匹配 STS 签发的 issuer（`*.tokens.sts.*`），不会影响其他 OIDC provider。

只允许 Global partition 的 issuer 联邦进入中国区账号：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowlistGlobalPartition",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:FederatedProvider": "arn:*:iam::*:oidc-provider/*.tokens.sts.*"
        },
        "StringNotLike": {
          "aws:FederatedProvider": [
            "arn:*:iam::*:oidc-provider/*.tokens.sts.global.api.aws"
          ]
        }
      }
    }
  ]
}
```

各 partition 的 issuer 主机名后缀：

| Partition | Issuer 后缀 |
|---|---|
| `aws` | `tokens.sts.global.api.aws` |
| `aws-cn` | `tokens.sts.global.api.amazonwebservices.com.cn` |
| `aws-us-gov` | `tokens.sts.us-gov.api.aws` |
| `aws-eusc` | `tokens.sts.global.api.amazonwebservices.eu` |

### 撤销已签发的会话

AWS 在每次请求时都会按当前生效的策略进行授权，因此新增的 deny 会对尚未过期的会话立即生效。

拒绝某个来源区域签发的所有会话：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenySourceRegion",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringEquals": { "aws:CrossPartitionSourceRegion": "us-east-1" }
      }
    }
  ]
}
```

拒绝来自某个 issuer 的所有会话：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenySessionsFromIssuer",
      "Effect": "Deny",
      "Action": "*",
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:FederatedProvider": "arn:aws-cn:iam::*:oidc-provider/<global-issuer-id>.tokens.sts.global.api.aws"
        }
      }
    }
  ]
}
```

这些策略可以作为 SCP 或 RCP 应用到组织成员账号，也可以直接附加到目标角色上。

## 使用 CloudTrail 审计跨 partition 访问

源端在签发 JWT 时记录 `GetWebIdentityToken` 事件，目标端在换取凭证时记录 `AssumeRoleWithWebIdentity` 事件。两个事件中的 `webIdentityTokenId` 相同，并且等于 JWT 的 `jti`。

**源端（Global，us-east-1）**

```json
{
  "eventName": "GetWebIdentityToken",
  "eventTime": "2026-11-25T05:56:01Z",
  "awsRegion": "us-east-1",
  "userIdentity": {
    "arn": "arn:aws:sts::444455556666:assumed-role/CrossPartitionCaller/cross-partition-demo"
  },
  "responseElements": {
    "webIdentityTokenId": "11111111-aaaa-4bbb-8ccc-000000000001"
  }
}
```

**目标端（中国区，cn-northwest-1）**

```json
{
  "eventName": "AssumeRoleWithWebIdentity",
  "eventTime": "2026-11-25T05:56:03Z",
  "awsRegion": "cn-northwest-1",
  "requestParameters": {
    "roleSessionName": "from-global",
    "webIdentityTokenId": "11111111-aaaa-4bbb-8ccc-000000000001"
  },
  "responseElements": {
    "subjectFromWebIdentityToken": "arn:aws:iam::444455556666:role/CrossPartitionCaller"
  },
  "additionalEventData": {
    "crossPartitionData": {
      "sourcePrincipalArn": "arn:aws:iam::444455556666:role/CrossPartitionCaller",
      "sourceRegion": "us-east-1"
    }
  }
}
```

方向 2 的记录结构相同：`GetWebIdentityToken` 记录在中国区，`AssumeRoleWithWebIdentity` 记录在 Global，`crossPartitionData.sourceRegion` 为 `cn-northwest-1`。

查询目标端事件：

```bash
aws cloudtrail lookup-events --profile ChinaCredentials --region cn-northwest-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --query 'Events[].CloudTrailEvent' --output json | jq -r '.[]' | \
  jq -c '{eventTime,
          webIdentityTokenId: .requestParameters.webIdentityTokenId,
          crossPartitionData: .additionalEventData.crossPartitionData}'
```

## 清理资源

```bash
# 中国区
aws s3 rb s3://$BUCKET --force --profile ChinaCredentials --region cn-northwest-1
aws iam delete-role-policy --profile ChinaCredentials --role-name CrossPartitionTarget --policy-name S3BucketAccess
aws iam delete-role --profile ChinaCredentials --role-name CrossPartitionTarget
aws iam delete-role-policy --profile ChinaCredentials --role-name CrossPartitionCaller --policy-name AllowGetWebIdentityToken
aws iam delete-role --profile ChinaCredentials --role-name CrossPartitionCaller
aws iam delete-open-id-connect-provider --profile ChinaCredentials \
  --open-id-connect-provider-arn arn:aws-cn:iam::$CN_ACCT:oidc-provider/$GL_ISS
aws iam disable-outbound-web-identity-federation --profile ChinaCredentials

# Global
aws iam delete-role-policy --profile GlobalCredentials --role-name CrossPartitionTarget --policy-name SelfGetRole
aws iam delete-role --profile GlobalCredentials --role-name CrossPartitionTarget
aws iam delete-role-policy --profile GlobalCredentials --role-name CrossPartitionCaller --policy-name AllowGetWebIdentityToken
aws iam delete-role --profile GlobalCredentials --role-name CrossPartitionCaller
aws iam delete-open-id-connect-provider --profile GlobalCredentials \
  --open-id-connect-provider-arn arn:aws:iam::$GL_ACCT:oidc-provider/$CN_ISS
aws iam disable-outbound-web-identity-federation --profile GlobalCredentials
```

## 可用性与定价

跨 partition 身份联邦在 Global（`aws`）、中国区（`aws-cn`）、GovCloud（US）（`aws-us-gov`）和 European Sovereign Cloud（`aws-eusc`）的所有区域可用，不额外收费。中国区包括由光环新网运营的北京区域和由西云数据运营的宁夏区域。

该功能只支持跨 partition 的联邦。同一 partition 内的跨账号访问，请继续使用 `sts:AssumeRole`。

如果组织已经在运营 PKI，也可以使用 IAM Roles Anywhere 实现跨 partition 访问。

## 总结

本文在一个 Global 账号和一个中国区账号之间配置了双向跨 partition 身份联邦。从 Global 到中国区的 S3 读写，以及从中国区到 Global 的 API 调用都已验证通过。整个过程只用到临时凭证，访问由标准 IAM 角色和策略控制，两端 CloudTrail 可以通过 token ID 关联同一次访问。

Partition 是有意设计的隔离边界。建议把跨 partition 访问作为例外情况处理，在实施前确认符合监管、合规和安全要求。
