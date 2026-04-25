#!/bin/bash
# Alternative cloud deploy — API Gateway HTTP API instead of Function URL.
#
# Use this if deploy_cloud.sh fails with 403 "Forbidden" from the Lambda URL.
# Workshop Studio accounts often block public Function URLs but allow
# API Gateway. This script uses API Gateway which is universally available.
#
# Same net result: the Pi gets a URL + token. The URL just looks like
# https://abc.execute-api.us-east-1.amazonaws.com/prod instead of
# https://abc.lambda-url.us-east-1.on.aws/
#
# Same auth model: X-Svcd-Auth header enforced by Lambda code.

set -e

FUNCTION_NAME="${1:-svc-response-gen}"
API_NAME="${FUNCTION_NAME}-api"
ROLE_NAME="svc-response-gen-role"
REGION="${AWS_REGION:-us-east-1}"
RUNTIME="python3.12"
TIMEOUT=10
MEMORY=512

# Reuse the existing auth token, or generate new
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

echo "[1/7] Building deployment zip..."
WORK=$(mktemp -d)
cp src/cloud/lambda_function.py "$WORK/"
cp src/router/system_prompt.txt "$WORK/prompt.txt"
cd "$WORK"
zip -q cloud.zip lambda_function.py prompt.txt
cd -

# --- Create or update Lambda ---
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" >/dev/null 2>&1; then
    echo "[2/7] Updating existing function..."
    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file "fileb://$WORK/cloud.zip" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
    aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
    aws lambda update-function-configuration \
        --function-name "$FUNCTION_NAME" \
        --environment "Variables={SVCD_AUTH_TOKEN=$AUTH_TOKEN}" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
else
    echo "[2/7] Creating new function..."
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

ACCOUNT_ID=$(aws sts get-caller-identity --query 'Account' --output text)
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"

# --- Create or find HTTP API ---
echo "[3/7] Setting up API Gateway HTTP API..."
API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
    --query "Items[?Name=='$API_NAME'].ApiId | [0]" --output text 2>/dev/null || echo "None")

if [ "$API_ID" = "None" ] || [ -z "$API_ID" ]; then
    echo "    Creating new HTTP API..."
    API_ID=$(aws apigatewayv2 create-api \
        --name "$API_NAME" \
        --protocol-type HTTP \
        --region "$REGION" \
        --query 'ApiId' --output text)
    echo "    API ID: $API_ID"
else
    echo "    Re-using existing API: $API_ID"
fi

# --- Lambda integration ---
echo "[4/7] Wiring Lambda to API Gateway..."
INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
    --query "Items[?IntegrationUri=='$LAMBDA_ARN'].IntegrationId | [0]" --output text 2>/dev/null || echo "None")

if [ "$INTEGRATION_ID" = "None" ] || [ -z "$INTEGRATION_ID" ]; then
    INTEGRATION_ID=$(aws apigatewayv2 create-integration \
        --api-id "$API_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "$LAMBDA_ARN" \
        --payload-format-version "2.0" \
        --region "$REGION" \
        --query 'IntegrationId' --output text)
fi

# Route: POST / → Lambda
ROUTE_EXISTS=$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='POST /'].RouteId | [0]" --output text 2>/dev/null || echo "None")

if [ "$ROUTE_EXISTS" = "None" ] || [ -z "$ROUTE_EXISTS" ]; then
    aws apigatewayv2 create-route \
        --api-id "$API_ID" \
        --route-key "POST /" \
        --target "integrations/$INTEGRATION_ID" \
        --region "$REGION" \
        --no-cli-pager > /dev/null
fi

# Stage (auto-deploy)
STAGE_EXISTS=$(aws apigatewayv2 get-stage --api-id "$API_ID" --stage-name '$default' --region "$REGION" 2>/dev/null || echo "NO")
if [ "$STAGE_EXISTS" = "NO" ]; then
    aws apigatewayv2 create-stage \
        --api-id "$API_ID" \
        --stage-name '$default' \
        --auto-deploy \
        --region "$REGION" \
        --no-cli-pager > /dev/null
fi

# --- Permission for API Gateway to invoke Lambda ---
echo "[5/7] Granting API Gateway permission to invoke Lambda..."
aws lambda add-permission \
    --function-name "$FUNCTION_NAME" \
    --statement-id "APIGatewayInvoke-$(date +%s)" \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/" \
    --region "$REGION" \
    --no-cli-pager 2>/dev/null > /dev/null || echo "    (permission already exists)"

FUNCTION_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/"

# --- Verify ---
echo "[6/7] Verifying auth..."
sleep 5  # let API Gateway stage deploy

NO_AUTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$FUNCTION_URL" \
    -H "Content-Type: application/json" \
    -d '{"command":"echo test","history":[]}')
if [ "$NO_AUTH_CODE" = "403" ]; then
    echo "    ✓ Unauthenticated requests rejected (HTTP 403)"
elif [ "$NO_AUTH_CODE" = "200" ]; then
    echo "    ✗ WARNING: Unauthenticated request succeeded — auth not enforced!"
else
    echo "    ⚠️  Expected 403, got $NO_AUTH_CODE"
fi

WITH_AUTH_RESP=$(curl -s -X POST "$FUNCTION_URL" \
    -H "X-Svcd-Auth: $AUTH_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"command":"echo test","history":[]}')
if echo "$WITH_AUTH_RESP" | grep -q '"body"'; then
    echo "    ✓ Authenticated requests succeed"
    echo "    Sample response: $(echo $WITH_AUTH_RESP | head -c 150)..."
else
    echo "    ⚠️  Authenticated request didn't return expected response"
    echo "        Response: $WITH_AUTH_RESP"
fi

echo ""
echo "[7/7] Done."
echo ""
echo "═══════════════════════════════════════════════════════"
echo " IMPORTANT — TWO secrets to deploy on the Pi:"
echo "═══════════════════════════════════════════════════════"
echo ""
echo " API URL:    $FUNCTION_URL"
echo " Auth Token: $AUTH_TOKEN"
echo ""
echo "═══════════════════════════════════════════════════════"
echo " On the honeypot Pi, run:"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "   echo \"export SVCD_CLOUD_URL='$FUNCTION_URL'\" >> ~/.bashrc"
echo "   source ~/.bashrc"
echo ""
echo "   umask 077"
echo "   echo '$AUTH_TOKEN' > ~/.local/lib/svcd/auth.token"
echo "   chmod 600 ~/.local/lib/svcd/auth.token"
echo ""
echo "═══════════════════════════════════════════════════════"

rm -rf "$WORK"
