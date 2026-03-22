#!/usr/bin/env bash
# ses-verify-domain.sh — Verify a domain for AWS SES + add DNS records to Cloudflare
#
# Usage: ./ses-verify-domain.sh <domain> <cloudflare-zone-id>
#
# Requires:
#   - AWS CLI configured (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
#   - CLOUDFLARE_API_TOKEN env var
#   - AWS_SES_REGION env var (default: us-east-1)

set -euo pipefail

DOMAIN="${1:?Usage: $0 <domain> <cloudflare-zone-id>}"
ZONE_ID="${2:?Usage: $0 <domain> <cloudflare-zone-id>}"
REGION="${AWS_SES_REGION:-us-east-1}"
CF_TOKEN="${CLOUDFLARE_API_TOKEN:?CLOUDFLARE_API_TOKEN is required}"

echo "=== Verifying $DOMAIN in SES ($REGION) ==="

# 1. Request domain verification
VERIFY_TOKEN=$(aws ses verify-domain-identity --domain "$DOMAIN" --region "$REGION" --output text --query 'VerificationToken')
echo "Verification token: $VERIFY_TOKEN"

# 2. Request DKIM tokens
DKIM_TOKENS=$(aws ses verify-domain-dkim --domain "$DOMAIN" --region "$REGION" --output text --query 'DkimTokens[]')
echo "DKIM tokens: $DKIM_TOKENS"

# 3. Add verification TXT record
echo "Adding _amazonses.$DOMAIN TXT record..."
curl -sf -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"TXT\",\"name\":\"_amazonses.$DOMAIN\",\"content\":\"$VERIFY_TOKEN\",\"ttl\":300}" \
  | python3 -c "import sys,json;r=json.load(sys.stdin);print('  TXT:', 'OK' if r.get('success') else r.get('errors'))"

# 4. Add DKIM CNAME records
for token in $DKIM_TOKENS; do
  echo "Adding ${token}._domainkey.$DOMAIN CNAME..."
  curl -sf -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"CNAME\",\"name\":\"${token}._domainkey.$DOMAIN\",\"content\":\"${token}.dkim.amazonses.com\",\"ttl\":300,\"proxied\":false}" \
    | python3 -c "import sys,json;r=json.load(sys.stdin);print('  DKIM:', 'OK' if r.get('success') else r.get('errors'))"
done

# 5. Add SPF record
echo "Adding SPF TXT record..."
curl -sf -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"type\":\"TXT\",\"name\":\"$DOMAIN\",\"content\":\"v=spf1 include:amazonses.com ~all\",\"ttl\":300}" \
  | python3 -c "import sys,json;r=json.load(sys.stdin);print('  SPF:', 'OK' if r.get('success') else r.get('errors'))"

# 6. Wait for verification
echo ""
echo "=== Waiting for DNS propagation ==="
for i in $(seq 1 12); do
  STATUS=$(aws ses get-identity-verification-attributes --identities "$DOMAIN" --region "$REGION" --output text --query "VerificationAttributes.$DOMAIN.VerificationStatus" 2>/dev/null || echo "Pending")
  DKIM_STATUS=$(aws ses get-identity-dkim-attributes --identities "$DOMAIN" --region "$REGION" --output text --query "DkimAttributes.$DOMAIN.DkimVerificationStatus" 2>/dev/null || echo "Pending")
  echo "  [$i/12] Domain: $STATUS | DKIM: $DKIM_STATUS"
  if [ "$STATUS" = "Success" ] && [ "$DKIM_STATUS" = "Success" ]; then
    echo ""
    echo "=== $DOMAIN verified! ==="
    echo ""
    echo "Add these env vars to your product .env:"
    echo "  AWS_SES_REGION=$REGION"
    echo "  EMAIL_FROM=noreply@$DOMAIN"
    echo "  EMAIL_REPLY_TO=support@$DOMAIN"
    exit 0
  fi
  sleep 10
done

echo ""
echo "=== Verification still pending — DNS may need more time ==="
echo "Run: aws ses get-identity-verification-attributes --identities $DOMAIN --region $REGION"
exit 0
