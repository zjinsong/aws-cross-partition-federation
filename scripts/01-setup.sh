#!/usr/bin/env bash
# 在中国区和 Global 两个账号中创建双向跨 partition 身份联邦所需的资源。
# 可重复执行：已存在的资源会跳过。
source "$(dirname "$0")/lib.sh"
clear_creds

# ---- 步骤 1：开启 outbound identity federation，获取 issuer ----
enable_federation() { # $1=profile
  aws iam get-outbound-web-identity-federation-info --profile "$1" \
      --query IssuerIdentifier --output text 2>/dev/null \
    || aws iam enable-outbound-web-identity-federation --profile "$1" \
      --query IssuerIdentifier --output text
}

log "步骤 1：开启 outbound identity federation"
CN_ISSUER_HOST=$(enable_federation "$CN_PROFILE" | sed 's#^https://##')
GL_ISSUER_HOST=$(enable_federation "$GL_PROFILE" | sed 's#^https://##')
export CN_ISSUER_HOST GL_ISSUER_HOST
echo "中国区 issuer: $CN_ISSUER_HOST"
echo "Global issuer: $GL_ISSUER_HOST"

# 写回 config.env，供后续脚本使用
sed -i '/^CN_ISSUER_HOST=/d;/^GL_ISSUER_HOST=/d' "$CONFIG"
printf 'CN_ISSUER_HOST=%s\nGL_ISSUER_HOST=%s\n' "$CN_ISSUER_HOST" "$GL_ISSUER_HOST" >> "$CONFIG"

# ---- 通用函数 ----
ensure_role() { # $1=profile $2=role $3=trust_template
  local doc; doc=$(render "$3")
  if aws iam get-role --profile "$1" --role-name "$2" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --profile "$1" --role-name "$2" --policy-document "$doc"
    echo "已存在，更新 trust policy: $2"
  else
    aws iam create-role --profile "$1" --role-name "$2" --assume-role-policy-document "$doc" \
      --query Role.Arn --output text
  fi
}
put_policy() { # $1=profile $2=role $3=policy_name $4=template
  local doc; doc=$(render "$4")
  aws iam put-role-policy --profile "$1" --role-name "$2" \
    --policy-name "$3" --policy-document "$doc"
  echo "已附加 $3 → $2"
}
ensure_oidc() { # $1=profile $2=partition $3=account $4=issuer_host
  local arn="arn:$2:iam::$3:oidc-provider/$4"
  if aws iam get-open-id-connect-provider --profile "$1" --open-id-connect-provider-arn "$arn" >/dev/null 2>&1; then
    aws iam add-client-id-to-open-id-connect-provider --profile "$1" \
      --open-id-connect-provider-arn "$arn" --client-id "$AUDIENCE" 2>/dev/null || true
    echo "已存在: $arn"
  else
    aws iam create-open-id-connect-provider --profile "$1" \
      --url "https://$4" --client-id-list "$AUDIENCE" \
      --query OpenIDConnectProviderArn --output text
  fi
}

# ---- 步骤 2：发起方角色 ----
log "步骤 2：创建 $CALLER_ROLE"
ensure_role "$CN_PROFILE" "$CALLER_ROLE" cn-caller-trust.json
put_policy  "$CN_PROFILE" "$CALLER_ROLE" AllowGetWebIdentityToken caller-token-policy.json
ensure_role "$GL_PROFILE" "$CALLER_ROLE" gl-caller-trust.json
put_policy  "$GL_PROFILE" "$CALLER_ROLE" AllowGetWebIdentityToken caller-token-policy.json

# ---- 步骤 3：注册对端 issuer ----
log "步骤 3：注册对端 issuer 为 OIDC provider"
ensure_oidc "$CN_PROFILE" aws-cn "$CN_ACCOUNT_ID" "$GL_ISSUER_HOST"
ensure_oidc "$GL_PROFILE" aws    "$GL_ACCOUNT_ID" "$CN_ISSUER_HOST"

# ---- 步骤 4：落地方角色 ----
log "步骤 4：创建 $TARGET_ROLE"
ensure_role "$CN_PROFILE" "$TARGET_ROLE" cn-target-trust.json
put_policy  "$CN_PROFILE" "$TARGET_ROLE" S3BucketAccess cn-target-permissions.json
ensure_role "$GL_PROFILE" "$TARGET_ROLE" gl-target-trust.json
put_policy  "$GL_PROFILE" "$TARGET_ROLE" SelfGetRole gl-target-permissions.json

# ---- 步骤 5：中国区测试存储桶 ----
log "步骤 5：准备中国区存储桶 s3://$CN_BUCKET"
if ! aws s3api head-bucket --profile "$CN_PROFILE" --region "$CN_REGION" --bucket "$CN_BUCKET" >/dev/null 2>&1; then
  aws s3api create-bucket --profile "$CN_PROFILE" --region "$CN_REGION" --bucket "$CN_BUCKET" \
    --create-bucket-configuration "LocationConstraint=$CN_REGION" --query Location --output text
fi
echo "hello from china $(date -u +%FT%TZ)" \
  | aws s3 cp - "s3://$CN_BUCKET/seed.txt" --profile "$CN_PROFILE" --region "$CN_REGION"

log "等待 15 秒，让 IAM 变更生效"
sleep 15
log "配置完成。下一步: scripts/02-test.sh"
