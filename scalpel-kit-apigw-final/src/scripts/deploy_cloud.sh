#!/bin/bash
# Deploy the cloud-side response generator with shared-secret auth.
# Run on a laptop with AWS CLI configured.
#
# Generates a fresh auth token. Configures Lambda with it. Prints it
# at the end so you can copy it to the Pi at ~/.local/lib/svcd/auth.token.

set -e

FUNCTION_NAME="${1:-svc-response-gen}"
ROLE_NAME="svc-response-gen-role"
REGION="${AWS_REGION:-us-east-1}"
RUNTIME="python3.12"
TIMEOUT=10
MEMORY=512

# Generate or load auth token (32 random bytes, base64 → ~43 chars URL-safe)
TOKEN_FILE="$HOME/.svcd_lambda_auth_token"
if [ -f "$TOKEN_FILE" ]; then
    AUTH_TOKEN=$(cat "$TOKEN_FILE")
    echo "[auth] Re-using existing token from $TOKEN_FILE"
else
    AUTH_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
    umask 077
    echo "$AUTH_TOKEN" > "$TOKEN_FILE"
    echo "[auth] Generated new token, saved to $TOKEN_FILE (mode 600)"
fi

echo "[1/5] Building deployment zip..."
WORK=$(mktemp -d)
cp src/cloud/lambda_function.py "$WORK/"
cp src/router/system_prompt.txt "$WORK/prompt.txt"
cd "$WORK"
zip -q cloud.zip lambda_function.py prompt.txt
cd -

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "[2/5] Updating existing function..."
    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file "fileb://$WORK/cloud.zip" \
        --region "$REGION" \
        --no-cli-pager > /dev/null

    # Wait for update to finish before changing config
    aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"

    aws lambda update-function-configuration \
        --function-name "$FUNCTION_NAME" \
        --environment "Variables={SVCD_AUTH_TOKEN=$AUTH_TOKEN}" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
else
    echo "[2/5] Creating new function..."
    ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || echo "")

    if [ -z "$ROLE_ARN" ]; then
        echo "Creating IAM role $ROLE_NAME ..."
        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document '{
                "Version":"2012-10-17",
                "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
            }' --no-cli-pager > /dev/null

        aws iam attach-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
            --no-cli-pager

        aws iam put-role-policy \
            --role-name "$ROLE_NAME" \
            --policy-name BedrockInvoke \
            --policy-document '{
                "Version":"2012-10-17",
                "Statement":[{"Effect":"Allow","Action":"bedrock:InvokeModel","Resource":"*"}]
            }' --no-cli-pager

        echo "Waiting 10s for IAM role to propagate..."
        sleep 10
        ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
    fi

    aws lambda create-function \
        --function-name "$FUNCTION_NAME" \
        --runtime "$RUNTIME" \
        --role "$ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --timeout "$TIMEOUT" \
        --memory-size "$MEMORY" \
        --zip-file "fileb://$WORK/cloud.zip" \
        --environment "Variables={SVCD_AUTH_TOKEN=$AUTH_TOKEN}" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
fi

echo "[3/5] Setting up function URL..."
URL_OUT=$(aws lambda create-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --auth-type NONE \
    --region "$REGION" \
    --no-cli-pager 2>/dev/null || \
    aws lambda get-function-url-config \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION" \
    --no-cli-pager)

FUNCTION_URL=$(echo "$URL_OUT" | python3 -c "import sys, json; print(json.load(sys.stdin)['FunctionUrl'])")

# Public invocation allowed at network layer; auth enforced in app layer
aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id PublicURLInvoke \
    --action lambda:InvokeFunctionUrl \
    --principal "*" \
    --function-url-auth-type NONE \
    --region "$REGION" \
    --no-cli-pager 2>/dev/null > /dev/null || true

echo "[4/5] Verifying auth..."
sleep 2
# Without auth — should be rejected
NO_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$FUNCTION_URL" -d '{"command":"echo test","history":[]}')
if [ "$NO_AUTH_CODE" = "403" ]; then
    echo "    ✓ Unauthenticated requests rejected (HTTP 403)"
else
    echo "    ⚠️  Expected 403 without auth, got $NO_AUTH_CODE — auth may not be enabled. Check Lambda env vars."
fi

# With auth — should work
WITH_AUTH=$(curl -s -X POST "$FUNCTION_URL" -H "X-Svcd-Auth: $AUTH_TOKEN" -d '{"command":"echo test","history":[]}')
if echo "$WITH_AUTH" | grep -q '"body"'; then
    echo "    ✓ Authenticated requests succeed"
else
    echo "    ⚠️  Authenticated request didn't return expected response. Check Bedrock model access."
    echo "        Response: $WITH_AUTH"
fi

echo ""
echo "[5/5] Done."
echo ""
echo "═══════════════════════════════════════════════════════"
echo " IMPORTANT — TWO secrets to deploy on the Pi:"
echo "═══════════════════════════════════════════════════════"
echo ""
echo " Function URL: $FUNCTION_URL"
echo ""
echo " Auth Token:   $AUTH_TOKEN"
echo ""
echo "═══════════════════════════════════════════════════════"
echo " On the honeypot Pi, run:"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "   export SVCD_CLOUD_URL='$FUNCTION_URL'"
echo "   echo \"export SVCD_CLOUD_URL='$FUNCTION_URL'\" >> ~/.bashrc"
echo ""
echo "   # Auth token goes in a SEPARATE file (NOT in .bashrc — leaks via snapshots)"
echo "   umask 077"
echo "   echo '$AUTH_TOKEN' > ~/.local/lib/svcd/auth.token"
echo "   chmod 600 ~/.local/lib/svcd/auth.token"
echo ""
echo "═══════════════════════════════════════════════════════"

rm -rf "$WORK"
