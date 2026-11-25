#!/usr/bin/env bash
# 删除本示例创建的全部资源，并关闭两个账号的 outbound identity federation。
source "$(dirname "$0")/lib.sh"
clear_creds

read -r -p "将删除两个账号中的测试资源和存储桶 s3://$CN_BUCKET，输入 yes 继续: " ans
[[ "$ans" == yes ]] || { echo "已取消"; exit 0; }

run() { "$@" 2>&1 | tail -1 || true; }

log "中国区"
run aws s3 rb "s3://$CN_BUCKET" --force --profile "$CN_PROFILE" --region "$CN_REGION"
run aws iam delete-role-policy --profile "$CN_PROFILE" --role-name "$TARGET_ROLE" --policy-name S3BucketAccess
run aws iam delete-role --profile "$CN_PROFILE" --role-name "$TARGET_ROLE"
run aws iam delete-role-policy --profile "$CN_PROFILE" --role-name "$CALLER_ROLE" --policy-name AllowGetWebIdentityToken
run aws iam delete-role --profile "$CN_PROFILE" --role-name "$CALLER_ROLE"
[[ -n "${GL_ISSUER_HOST:-}" ]] && run aws iam delete-open-id-connect-provider --profile "$CN_PROFILE" \
  --open-id-connect-provider-arn "arn:aws-cn:iam::$CN_ACCOUNT_ID:oidc-provider/$GL_ISSUER_HOST"
run aws iam disable-outbound-web-identity-federation --profile "$CN_PROFILE"

log "Global"
run aws iam delete-role-policy --profile "$GL_PROFILE" --role-name "$TARGET_ROLE" --policy-name SelfGetRole
run aws iam delete-role --profile "$GL_PROFILE" --role-name "$TARGET_ROLE"
run aws iam delete-role-policy --profile "$GL_PROFILE" --role-name "$CALLER_ROLE" --policy-name AllowGetWebIdentityToken
run aws iam delete-role --profile "$GL_PROFILE" --role-name "$CALLER_ROLE"
[[ -n "${CN_ISSUER_HOST:-}" ]] && run aws iam delete-open-id-connect-provider --profile "$GL_PROFILE" \
  --open-id-connect-provider-arn "arn:aws:iam::$GL_ACCOUNT_ID:oidc-provider/$CN_ISSUER_HOST"
run aws iam disable-outbound-web-identity-federation --profile "$GL_PROFILE"

rm -rf "$OUT_DIR"
log "清理完成"
