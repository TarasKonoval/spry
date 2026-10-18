COMPOSE ?= docker compose

# Windows: the recipes are POSIX shell, and native GNU make (winget install
# ezwinports.make) would hand them to cmd.exe. Run them with the bash, sed, awk,
# curl and friends that Git for Windows ships instead, whichever terminal make is
# started from. Installed Git elsewhere? make GIT_HOME="D:/Tools/Git" ...
# MSYS2/Cygwin make already has a POSIX shell, so it is left alone.
ifeq ($(OS),Windows_NT)
ifeq ($(findstring msys,$(MAKE_HOST))$(findstring cygwin,$(MAKE_HOST)),)
GIT_HOME ?= C:/Program Files/Git
export PATH := $(GIT_HOME)/bin;$(GIT_HOME)/usr/bin;$(PATH)
SHELL := bash.exe
.SHELLFLAGS := -c
endif
endif

# Local configuration (gitignored). These assignments beat variables exported in
# the shell, so override one on the command line instead: make aws-deploy-backend
# AWS_LAMBDA_ARCH=arm64
-include .env
# Every stack (ECR, Lambda, Aurora, S3 + CloudFront) is created in this one region.
AWS_REGION ?= us-east-1
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION PROJECT_NAME
# On Windows, stop Git's bash rewriting container paths such as /aws or
# /dev/null into C:/Program Files/Git/... before docker sees them.
export MSYS_NO_PATHCONV := 1
export MSYS2_ARG_CONV_EXCL := *

# The AWS CLI runs in a container so nothing has to be installed on the host.
# The repository is mounted at /aws (the image's workdir) so the CLI can read
# infra/*.yml. Pass AWS=aws to use a CLI installed on the host instead.
AWS ?= docker run --rm \
	-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
	-e AWS_DEFAULT_REGION=$(AWS_REGION) \
	-v $(CURDIR):/aws -w /aws \
	amazon/aws-cli:latest

AUTH_STACK ?= $(PROJECT_NAME)-auth
APP_STACK ?= $(PROJECT_NAME)-backend
ECR_STACK ?= $(PROJECT_NAME)-ecr
FRONTEND_STACK ?= $(PROJECT_NAME)-frontend
REPORTS_STACK ?= $(PROJECT_NAME)-reports
AI_STACK ?= $(PROJECT_NAME)-ai
# infra/reports.yml with the mailer's code inlined (gitignored; inside the repo
# because the containerised CLI only sees the repository).
REPORTS_TEMPLATE = infra/.build/reports.yml
MAILER_SOURCE = backend/app/reports/mailer.py
# When the weekly report is built, in APP_TIMEZONE. To test it, deploy once with
# SCHEDULE='rate(5 minutes)', then again without it: every run wakes Aurora.
SCHEDULE ?= cron(0 7 ? * MON *)
IMAGE_TAG ?= latest
# The Bedrock model behind the agenda parser (make llm-hello, make parse).
PARSER_MODEL ?= anthropic.claude-opus-5-5
# Runs app.ai.agenda in a throwaway backend container with the AWS credentials
# from .env: no database, no migrations. Rebuild the image (make up-build) after
# changing backend dependencies.
LLM_RUN = $(COMPOSE) run --rm --no-deps -T \
	-e RUN_MIGRATIONS_ON_START=false \
	-e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e AWS_REGION \
	-e PARSER_MODEL=$(PARSER_MODEL)
# x86_64 or arm64. arm64 is ~20% cheaper on Lambda and builds natively on
# Apple Silicon; the image platform is derived from it so the two cannot drift.
AWS_LAMBDA_ARCH ?= x86_64
IMAGE_PLATFORM = $(if $(filter arm64,$(AWS_LAMBDA_ARCH)),linux/arm64,linux/amd64)
# Every stack carries this tag, and CloudFormation copies it onto each resource
# that supports tags, so Cost Explorer and Resource Groups can find the project.
STACK_TAGS = --tags "PROJECT_NAME=$(PROJECT_NAME)"

# infra/certificate.sh reuses the CLI configured above. CloudFront only reads
# certificates from us-east-1, so that is where the frontend's goes.
CERT = AWS_CLI="$(AWS)" AWS_CERT_REGION=us-east-1 infra/certificate.sh

# $(call stack-output,<stack>,<output key>)
stack-output = $(AWS) cloudformation describe-stacks --stack-name $(1) \
	--query 'Stacks[0].Outputs[?OutputKey==`$(2)`].OutputValue' --output text

# CloudFormation refuses to update a stack that is still busy, and a Lambda in a
# VPC can keep one in *_CLEANUP_IN_PROGRESS for ~20 minutes while its network
# interfaces are released. Wait that out instead of failing.
# $(call stack-outputs,<stack>): every output as "Key<TAB>Value" lines
stack-outputs = $(AWS) cloudformation describe-stacks --stack-name $(1) \
	--query 'Stacks[0].Outputs[].[OutputKey,OutputValue]' --output text

# $(call image-digest,<repository uri>): the digest IMAGE_TAG points at
image-digest = $(AWS) ecr describe-images --repository-name "$${$(1)\#*/}" \
	--image-ids imageTag=$(IMAGE_TAG) --query 'imageDetails[0].imageDigest' \
	--output text | tr -d '[:space:]'

# $(call wait-stack-idle,<stack>)
wait-stack-idle = while status=$$($(AWS) cloudformation describe-stacks --stack-name $(1) \
		--query 'Stacks[0].StackStatus' --output text 2>/dev/null | tr -d '[:space:]'); \
		case "$$status" in *_IN_PROGRESS) true ;; *) false ;; esac; do \
		echo "$(1) is $$status — waiting for it to settle..."; sleep 30; done

# A stack whose first create failed sits in ROLLBACK_COMPLETE, which
# CloudFormation can only delete. It holds no resources, so clear it and let the
# deploy start over.
# $(call clear-failed-create,<stack>)
clear-failed-create = if [ "$$($(AWS) cloudformation describe-stacks --stack-name $(1) \
		--query 'Stacks[0].StackStatus' --output text 2>/dev/null | tr -d '[:space:]')" = ROLLBACK_COMPLETE ]; then \
		echo "$(1) failed to create earlier — deleting it before retrying"; \
		$(AWS) cloudformation delete-stack --stack-name $(1) && \
		$(AWS) cloudformation wait stack-delete-complete --stack-name $(1); fi

# Fail early and clearly when .env has no credentials in it.
define require-aws-credentials
	@test -n "$(AWS_ACCESS_KEY_ID)" -a -n "$(AWS_SECRET_ACCESS_KEY)" || { \
		echo "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are empty — set them in .env"; \
		exit 1; }
endef

define require-db-password
	@test -n "$(AWS_DB_PASSWORD)" || { \
		echo "AWS_DB_PASSWORD is empty — set it in .env (8+ chars, [A-Za-z0-9_-] only)"; \
		exit 1; }
endef

define require-reports-email
	@test -n "$(REPORTS_EMAIL)" || { \
		echo "REPORTS_EMAIL is empty — set it in .env (the verified sender and recipient of the report)"; \
		exit 1; }
endef

.PHONY: help up up-build down down-v logs ps migrate revision seed test lint fmt report-local shell-backend psql \
        llm-hello parse \
        aws-whoami aws-deploy aws-deploy-auth aws-auth-env aws-ecr aws-push aws-deploy-backend aws-migrate aws-url aws-status aws-logs \
        aws-deploy-reports report-now aws-reports-logs aws-deploy-ai aws-ai-url aws-ai-logs \
        aws-frontend-cert aws-deploy-frontend aws-frontend-url aws-destroy

help:
	@grep -hE '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Start the whole stack
	$(COMPOSE) up

up-build: ## Rebuild images and start the whole stack
	$(COMPOSE) up --build

down: ## Stop the stack
	$(COMPOSE) down

down-v: ## Stop the stack and delete the database volume
	$(COMPOSE) down -v

logs: ## Follow logs from every service
	$(COMPOSE) logs -f

ps: ## Show service status
	$(COMPOSE) ps

migrate: ## Apply database migrations
	$(COMPOSE) exec backend alembic upgrade head

revision: ## Autogenerate a migration: make revision m="add column"
	$(COMPOSE) exec backend alembic revision --autogenerate -m "$(m)"

seed: ## Insert demo meetings for today for one user: make seed owner=<cognito-sub>
	@test -n "$(owner)" || { echo "Usage: make seed owner=<cognito-sub> (the user's sub from the Cognito console)"; exit 1; }
	$(COMPOSE) exec backend python -m app.seed "$(owner)"

test: ## Run the backend test suite against a throwaway database
	$(COMPOSE) exec db psql -U app -d postgres -tc \
		"SELECT 1 FROM pg_database WHERE datname='meetings_test'" | grep -q 1 || \
		$(COMPOSE) exec db createdb -U app meetings_test
	$(COMPOSE) exec -e DATABASE_URL=postgresql+asyncpg://app:app@db:5432/meetings_test backend pytest -q

lint: ## Lint backend and frontend
	$(COMPOSE) exec backend ruff check .
	$(COMPOSE) exec frontend npm run lint

fmt: ## Format the backend code
	$(COMPOSE) exec backend ruff format .

report-local: ## Print the weekly report CSV from the compose database: make report-local WEEK=2026-W41 (default: last week)
	@$(COMPOSE) exec -T backend python -m app.reports.weekly $(WEEK)

llm-hello: ## Ask PARSER_MODEL on Bedrock one question from your laptop: checks model access
	$(require-aws-credentials)
	$(LLM_RUN) backend python -m app.ai.agenda hello

# TEXT reaches the container through the environment, never through the shell
# command line, so quotes and apostrophes in it (п'ятниці) need no escaping.
parse: export TEXT := $(TEXT)
parse: export TODAY := $(TODAY)
parse: ## Parse an agenda with PARSER_MODEL and print the JSON and usage: make parse TEXT="..." [TODAY=2026-10-19]
	$(require-aws-credentials)
	@test -n "$$TEXT" || { echo 'Usage: make parse TEXT="Пн 10:00, синк по прайсингу, 45 хв. ..." [TODAY=YYYY-MM-DD]'; exit 1; }
	@$(LLM_RUN) -e TEXT -e TODAY backend python -m app.ai.agenda parse

shell-backend: ## Open a shell in the backend container
	$(COMPOSE) exec backend sh

psql: ## Open psql against the application database
	$(COMPOSE) exec db psql -U app -d meetings

aws-whoami: ## Verify the AWS credentials in .env
	$(require-aws-credentials)
	$(AWS) sts get-caller-identity

aws-deploy: ## Deploy everything: sign-in, the backend, the agenda parser, then the frontend built against them
	@$(MAKE) --no-print-directory aws-deploy-auth
	@$(MAKE) --no-print-directory aws-deploy-backend
	@$(MAKE) --no-print-directory aws-deploy-ai
	@$(MAKE) --no-print-directory aws-deploy-frontend

aws-deploy-auth: ## Create/update the Cognito user pool (email + password; Google when GOOGLE_CLIENT_ID is set)
	$(require-aws-credentials)
	@urls="http://localhost:$(or $(FRONTEND_PORT),3000)/"; \
		site=$$($(call stack-output,$(FRONTEND_STACK),AllowedOrigins) 2>/dev/null | tr -d '[:space:]'); \
		case "$$site" in ""|None) ;; *) urls="$$urls,$$(echo "$$site" | sed 's|,|/,|g')/" ;; esac; \
		echo "Sign-in redirect URLs: $$urls"; \
		test -n "$(GOOGLE_CLIENT_ID)" || echo "GOOGLE_CLIENT_ID is empty — Google sign-in stays off"; \
		$(call wait-stack-idle,$(AUTH_STACK)); \
		$(call clear-failed-create,$(AUTH_STACK)); \
		$(AWS) cloudformation deploy \
			--stack-name $(AUTH_STACK) \
			--template-file infra/auth.yml \
			--no-fail-on-empty-changeset \
			$(STACK_TAGS) \
			--parameter-overrides \
				"ProjectName=$(PROJECT_NAME)" \
				"AppUrls=$$urls" \
				"GoogleClientId=$(GOOGLE_CLIENT_ID)" \
				"GoogleClientSecret=$(GOOGLE_CLIENT_SECRET)"
	@if [ -n "$(GOOGLE_CLIENT_ID)" ]; then \
		echo "Google Cloud console → the OAuth client → Authorized redirect URIs must include:"; \
		echo "  $$($(call stack-output,$(AUTH_STACK),GoogleRedirectUri) | tr -d '[:space:]')"; \
	fi
	@$(MAKE) --no-print-directory aws-auth-env

aws-auth-env: ## Print the Cognito settings to put in .env for local development
	@$(call stack-outputs,$(AUTH_STACK)) | awk -F '\t' ' \
		$$1 == "UserPoolId" { print "COGNITO_USER_POOL_ID=" $$2 } \
		$$1 == "UserPoolClientId" { print "COGNITO_CLIENT_ID=" $$2 } \
		$$1 == "HostedDomain" { print "COGNITO_DOMAIN=" $$2 } \
		$$1 == "GoogleEnabled" { print "COGNITO_GOOGLE_ENABLED=" $$2 }' | tr -d '\r'

aws-ecr: ## Create the ECR repository for the backend image
	$(require-aws-credentials)
	$(AWS) cloudformation deploy \
		--stack-name $(ECR_STACK) \
		--template-file infra/ecr.yml \
		--no-fail-on-empty-changeset \
		$(STACK_TAGS) \
		--parameter-overrides "ProjectName=$(PROJECT_NAME)"

aws-push: aws-ecr ## Build the backend Lambda image and push it to ECR
	$(require-aws-credentials)
	@repo=$$($(call stack-output,$(ECR_STACK),RepositoryUri) | tr -d '[:space:]'); \
		echo "Pushing $$repo:$(IMAGE_TAG) ($(IMAGE_PLATFORM))"; \
		$(AWS) ecr get-login-password | docker login --username AWS --password-stdin "$${repo%%/*}"; \
		docker build --platform $(IMAGE_PLATFORM) --provenance=false \
			-f backend/Dockerfile.lambda -t "$$repo:$(IMAGE_TAG)" ./backend; \
		docker push "$$repo:$(IMAGE_TAG)"

aws-deploy-backend: aws-push ## Deploy the backend to AWS (Lambda function URL + Aurora Serverless), then migrate
	$(require-aws-credentials)
	$(require-db-password)
	@pool=$$($(call stack-output,$(AUTH_STACK),UserPoolId) 2>/dev/null | tr -d '[:space:]'); \
		client=$$($(call stack-output,$(AUTH_STACK),UserPoolClientId) | tr -d '[:space:]'); \
		issuer=$$($(call stack-output,$(AUTH_STACK),Issuer) | tr -d '[:space:]'); \
		case "$$pool" in ""|None) echo "No user pool found — run: make aws-deploy-auth"; exit 1 ;; esac; \
		jwks=$$(curl -fsS "$$issuer/.well-known/jwks.json" | base64 | tr -d '\n'); \
		test -n "$$jwks" || { echo "Could not download $$issuer/.well-known/jwks.json"; exit 1; }; \
		vpc=$$($(AWS) ec2 describe-vpcs --filters Name=isDefault,Values=true \
		--query 'Vpcs[0].VpcId' --output text | tr -d '[:space:]'); \
		test "$$vpc" != "None" -a -n "$$vpc" || { \
			echo "No default VPC in $(AWS_REGION) — pass VpcId/SubnetIds yourself"; exit 1; }; \
		subnets=$$($(AWS) ec2 describe-subnets \
			--filters Name=vpc-id,Values=$$vpc Name=default-for-az,Values=true \
			--query 'Subnets[].SubnetId' --output text | tr '[:space:]' ',' | sed 's/,*$$//'); \
		repo=$$($(call stack-output,$(ECR_STACK),RepositoryUri) | tr -d '[:space:]'); \
		digest=$$($(call image-digest,repo)); \
		cors="$(AWS_CORS_ORIGINS)"; \
		if [ -z "$$cors" ]; then \
			cors=$$($(call stack-output,$(FRONTEND_STACK),AllowedOrigins) 2>/dev/null | tr -d '[:space:]'); \
			case "$$cors" in ""|None) cors='*' ;; esac; \
		fi; \
		echo "vpc=$$vpc subnets=$$subnets image=$$repo@$$digest cors=$$cors"; \
		echo "This takes ~15 minutes the first time (Aurora is the slow part)."; \
		$(call wait-stack-idle,$(APP_STACK)); \
		$(call clear-failed-create,$(APP_STACK)); \
		$(AWS) cloudformation deploy \
			--stack-name $(APP_STACK) \
			--template-file infra/backend.yml \
			--capabilities CAPABILITY_IAM \
			--no-fail-on-empty-changeset \
			$(STACK_TAGS) \
			--parameter-overrides \
				"ProjectName=$(PROJECT_NAME)" \
				"VpcId=$$vpc" \
				"SubnetIds=$$subnets" \
				ImageUri="$$repo@$$digest" \
				"Architecture=$(AWS_LAMBDA_ARCH)" \
				"DbPassword=$(AWS_DB_PASSWORD)" \
				"AppTimezone=$(APP_TIMEZONE)" \
				"CorsOrigins=$$cors" \
				"CognitoUserPoolId=$$pool" \
				"CognitoClientId=$$client" \
				"CognitoJwks=$$jwks"
	@$(MAKE) --no-print-directory aws-migrate
	@$(MAKE) --no-print-directory aws-url

aws-migrate: ## Apply database migrations (invokes the backend function directly)
	@fn=$$($(call stack-output,$(APP_STACK),FunctionName) | tr -d '[:space:]'); \
		echo "Migrating ($$fn)"; \
		err=$$($(AWS) lambda invoke --function-name "$$fn" \
			--cli-binary-format raw-in-base64-out --payload '{"action":"migrate"}' \
			--query FunctionError --output text /dev/null | tr -d '[:space:]'); \
		test "$$err" = "None" || { echo "Migration failed ($$err) — see make aws-logs"; exit 1; }

aws-url: ## Print the deployed API URL
	@$(call stack-output,$(APP_STACK),ApiUrl)

aws-status: ## Show the stack outputs and the API function's state
	@$(AWS) cloudformation describe-stacks --stack-name $(APP_STACK) \
		--query 'Stacks[0].Outputs' --output table
	@fn=$$($(call stack-output,$(APP_STACK),FunctionName) | tr -d '[:space:]'); \
		$(AWS) lambda get-function-configuration --function-name "$$fn" \
			--query '{state:State,lastUpdate:LastUpdateStatus,arch:Architectures[0],memory:MemorySize}' \
			--output table

aws-logs: ## Follow the backend function logs
	$(AWS) logs tail /aws/lambda/$(PROJECT_NAME)-backend --follow

aws-deploy-reports: aws-push ## Deploy the weekly report (bucket, queue, builder, schedule) next to the backend: make aws-deploy-reports [SCHEDULE='rate(5 minutes)']
	$(require-aws-credentials)
	$(require-db-password)
	$(require-reports-email)
	@fn=$$($(call stack-output,$(APP_STACK),FunctionName) 2>/dev/null | tr -d '[:space:]'); \
		case "$$fn" in ""|None) echo "No backend found — run: make aws-deploy-backend"; exit 1 ;; esac; \
		set -- $$($(AWS) lambda get-function-configuration --function-name "$$fn" \
			--query '[VpcConfig.VpcId, join(`,`, VpcConfig.SubnetIds), VpcConfig.SecurityGroupIds[0]]' \
			--output text | tr -d '\r'); \
		vpc=$$1; subnets=$$2; sg=$$3; \
		test -n "$$sg" -a "$$vpc" != "None" || { echo "$$fn is not in a VPC — cannot place the builder"; exit 1; }; \
		db=$$($(call stack-output,$(APP_STACK),DatabaseEndpoint) | tr -d '[:space:]'); \
		explicit=$$($(AWS) ec2 describe-route-tables \
			--filters Name=association.subnet-id,Values=$$subnets \
			--query 'RouteTables[].RouteTableId' --output text); \
		main=$$($(AWS) ec2 describe-route-tables \
			--filters Name=vpc-id,Values=$$vpc Name=association.main,Values=true \
			--query 'RouteTables[].RouteTableId' --output text); \
		tables=$$(echo $$explicit $$main | tr -s '[:space:]' '\n' | sort -u | paste -sd, -); \
		ours=$$($(AWS) cloudformation describe-stack-resource --stack-name $(REPORTS_STACK) \
			--logical-resource-id S3Endpoint --query 'StackResourceDetail.PhysicalResourceId' \
			--output text 2>/dev/null | tr -d '[:space:]'); \
		others=$$($(AWS) ec2 describe-vpc-endpoints --filters Name=vpc-id,Values=$$vpc \
			Name=service-name,Values=com.amazonaws.$(AWS_REGION).s3 Name=vpc-endpoint-type,Values=Gateway \
			Name=vpc-endpoint-state,Values=pending,available \
			--query 'VpcEndpoints[].VpcEndpointId' --output text | tr -s '[:space:]' '\n' \
			| grep -v -x -e "$${ours:-none}" -e '' | paste -sd, -); \
		if [ -n "$$others" ]; then endpoint=false; \
			echo "Reusing the VPC's S3 gateway endpoint $$others — it must cover route tables $$tables"; \
		else endpoint=true; fi; \
		repo=$$($(call stack-output,$(ECR_STACK),RepositoryUri) | tr -d '[:space:]'); \
		digest=$$($(call image-digest,repo)); \
		echo "vpc=$$vpc subnets=$$subnets sg=$$sg route-tables=$$tables create-s3-endpoint=$$endpoint"; \
		echo "image=$$repo@$$digest schedule=$(SCHEDULE)"; \
		test $$(wc -c < $(MAILER_SOURCE)) -le 4096 || { \
			echo "$(MAILER_SOURCE) is over CloudFormation's 4096-character inline code limit"; exit 1; }; \
		mkdir -p $(dir $(REPORTS_TEMPLATE)); \
		awk 'FNR == NR { code = code "          " $$0 "\n"; next } \
			/ZipFile: MAILER_SOURCE/ { sub(/MAILER_SOURCE.*/, "|"); printf "%s\n%s", $$0, code; next } \
			{ print }' $(MAILER_SOURCE) infra/reports.yml > $(REPORTS_TEMPLATE); \
		$(call wait-stack-idle,$(REPORTS_STACK)); \
		$(call clear-failed-create,$(REPORTS_STACK)); \
		$(AWS) cloudformation deploy \
			--stack-name $(REPORTS_STACK) \
			--template-file $(REPORTS_TEMPLATE) \
			--capabilities CAPABILITY_IAM \
			--no-fail-on-empty-changeset \
			$(STACK_TAGS) \
			--parameter-overrides \
				"ProjectName=$(PROJECT_NAME)" \
				ImageUri="$$repo@$$digest" \
				"Architecture=$(AWS_LAMBDA_ARCH)" \
				"VpcId=$$vpc" \
				"SubnetIds=$$subnets" \
				"SecurityGroupId=$$sg" \
				"RouteTableIds=$$tables" \
				"CreateS3Endpoint=$$endpoint" \
				"DbEndpoint=$$db" \
				"DbPassword=$(AWS_DB_PASSWORD)" \
				"AppTimezone=$(or $(APP_TIMEZONE),Europe/Kyiv)" \
				"ScheduleExpression=$(SCHEDULE)" \
				"ReportsEmail=$(REPORTS_EMAIL)"
	@echo "Reports go to s3://$$($(call stack-output,$(REPORTS_STACK),BucketName) | tr -d '[:space:]')/reports/"
	@verified=$$($(AWS) sesv2 get-email-identity --email-identity "$(REPORTS_EMAIL)" \
			--query VerifiedForSendingStatus --output text | tr -d '[:space:]'); \
		if [ "$$verified" = "True" ]; then echo "SES identity for REPORTS_EMAIL: verified"; \
		else echo "SES identity for REPORTS_EMAIL: not verified yet — click the link AWS emailed to it (valid 24 hours)"; fi

report-now: ## Queue a report build on AWS, e.g. to rebuild an old one: make report-now [WEEK=2026-W41] (default: last week)
	$(require-aws-credentials)
	@case "$(WEEK)" in \
		"") body='{"week": null, "source": "make"}' ;; \
		[0-9][0-9][0-9][0-9]-W[0-9][0-9]) body='{"week": "$(WEEK)", "source": "make"}' ;; \
		*) echo "WEEK looks like 2026-W41, not $(WEEK)"; exit 1 ;; \
	esac; \
		queue=$$($(call stack-output,$(REPORTS_STACK),QueueUrl) 2>/dev/null | tr -d '[:space:]'); \
		case "$$queue" in ""|None) echo "No report queue — run: make aws-deploy-reports"; exit 1 ;; esac; \
		echo "Queueing $$body"; \
		$(AWS) sqs send-message --queue-url "$$queue" --message-body "$$body" \
			--query MessageId --output text

aws-reports-logs: ## Follow the report builder's logs
	$(AWS) logs tail /aws/lambda/$(PROJECT_NAME)-report-builder --follow

aws-deploy-ai: aws-push ## Deploy the agenda parser (Lambda + function URL, outside the VPC) with PARSER_MODEL
	$(require-aws-credentials)
	@pool=$$($(call stack-output,$(AUTH_STACK),UserPoolId) 2>/dev/null | tr -d '[:space:]'); \
		client=$$($(call stack-output,$(AUTH_STACK),UserPoolClientId) | tr -d '[:space:]'); \
		case "$$pool" in ""|None) echo "No user pool found — run: make aws-deploy-auth"; exit 1 ;; esac; \
		site=$$($(call stack-output,$(FRONTEND_STACK),AllowedOrigins) 2>/dev/null | tr -d '[:space:]'); \
		case "$$site" in \
			""|None) origins='*'; echo "No frontend yet — the parser allows any origin until make aws-deploy-ai runs again after it" ;; \
			*) origins="$$site,http://localhost:$(or $(FRONTEND_PORT),3000)" ;; \
		esac; \
		repo=$$($(call stack-output,$(ECR_STACK),RepositoryUri) | tr -d '[:space:]'); \
		digest=$$($(call image-digest,repo)); \
		echo "image=$$repo@$$digest model=$(PARSER_MODEL) origins=$$origins"; \
		$(call wait-stack-idle,$(AI_STACK)); \
		$(call clear-failed-create,$(AI_STACK)); \
		$(AWS) cloudformation deploy \
			--stack-name $(AI_STACK) \
			--template-file infra/ai.yml \
			--capabilities CAPABILITY_IAM \
			--no-fail-on-empty-changeset \
			$(STACK_TAGS) \
			--parameter-overrides \
				"ProjectName=$(PROJECT_NAME)" \
				ImageUri="$$repo@$$digest" \
				"Architecture=$(AWS_LAMBDA_ARCH)" \
				"CognitoUserPoolId=$$pool" \
				"CognitoClientId=$$client" \
				"ParserModel=$(PARSER_MODEL)" \
				"AllowedOrigins=$$origins"
	@$(MAKE) --no-print-directory aws-ai-url

aws-ai-url: ## Print the agenda parser's URL (PARSER_URL for local development)
	@$(call stack-output,$(AI_STACK),ParserUrl)

aws-ai-logs: ## Follow the agenda parser's logs (one JSON line per parse)
	$(AWS) logs tail /aws/lambda/$(PROJECT_NAME)-agenda-parser --follow

aws-frontend-cert: ## Request and validate the HTTPS certificate for AWS_FRONTEND_DOMAIN (in us-east-1)
	$(require-aws-credentials)
	@test -n "$(AWS_FRONTEND_DOMAIN)" || { \
		echo "AWS_FRONTEND_DOMAIN is empty — set it in .env (e.g. app.example.com)"; exit 1; }
	@$(CERT) ensure "$(AWS_FRONTEND_DOMAIN)"

aws-deploy-frontend: ## Deploy the frontend to S3 + CloudFront, built against the deployed backend URL
	$(require-aws-credentials)
	@api=$$($(call stack-output,$(APP_STACK),ApiUrl) 2>/dev/null | tr -d '[:space:]'); \
		test -n "$$api" -a "$$api" != "None" || { \
			echo "No backend API found — run: make aws-deploy-backend"; exit 1; }; \
		domain=""; \
		if [ -n "$(AWS_FRONTEND_DOMAIN)" ]; then \
			cert=$$($(CERT) find "$(AWS_FRONTEND_DOMAIN)"); \
			test -n "$$cert" || { \
				echo "No issued us-east-1 certificate for $(AWS_FRONTEND_DOMAIN) — run: make aws-frontend-cert"; \
				exit 1; }; \
			zone=$$($(CERT) zone "$(AWS_FRONTEND_DOMAIN)"); \
			domain="DomainName=$(AWS_FRONTEND_DOMAIN) CertificateArn=$$cert HostedZoneId=$$zone"; \
			echo "custom domain: $(AWS_FRONTEND_DOMAIN) (Route 53 zone: $${zone:-none})"; \
		fi; \
		$(call wait-stack-idle,$(FRONTEND_STACK)); \
		$(call clear-failed-create,$(FRONTEND_STACK)); \
		echo "A new CloudFront distribution takes ~5 minutes to come up."; \
		$(AWS) cloudformation deploy \
			--stack-name $(FRONTEND_STACK) \
			--template-file infra/frontend.yml \
			--no-fail-on-empty-changeset \
			$(STACK_TAGS) \
			--parameter-overrides \
				"ProjectName=$(PROJECT_NAME)" \
				"PricingPlan=$(or $(AWS_CLOUDFRONT_PLAN),FREE)" \
				$$domain
	@# Now that the site's URL exists, let Cognito redirect back to it.
	@$(MAKE) --no-print-directory aws-deploy-auth
	@api=$$($(call stack-output,$(APP_STACK),ApiUrl) | tr -d '[:space:]'); \
		auth=$$($(call stack-outputs,$(AUTH_STACK)) | tr -d '\r'); \
		auth_out() { printf '%s\n' "$$auth" | awk -F '\t' -v k="$$1" '$$1 == k { print $$2 }'; }; \
		parser=$$($(call stack-output,$(AI_STACK),ParserUrl) 2>/dev/null | tr -d '[:space:]'); \
		case "$$parser" in None) parser="" ;; esac; \
		test -n "$$parser" || echo "No agenda parser found — Paste an agenda stays hidden (make aws-deploy-ai)"; \
		bucket=$$($(call stack-output,$(FRONTEND_STACK),BucketName) | tr -d '[:space:]'); \
		dist=$$($(call stack-output,$(FRONTEND_STACK),DistributionId) | tr -d '[:space:]'); \
		echo "Building the static export against $$api"; \
		rm -rf frontend/out; \
		docker build --target export --output type=local,dest=frontend/out \
			--build-arg NEXT_PUBLIC_API_BASE_URL="$$api" \
			--build-arg NEXT_PUBLIC_COGNITO_USER_POOL_ID="$$(auth_out UserPoolId)" \
			--build-arg NEXT_PUBLIC_COGNITO_CLIENT_ID="$$(auth_out UserPoolClientId)" \
			--build-arg NEXT_PUBLIC_COGNITO_DOMAIN="$$(auth_out HostedDomain)" \
			--build-arg NEXT_PUBLIC_COGNITO_GOOGLE_ENABLED="$$(auth_out GoogleEnabled)" \
			--build-arg NEXT_PUBLIC_PARSER_URL="$$parser" \
			./frontend || exit 1; \
		echo "Uploading to s3://$$bucket"; \
		$(AWS) s3 sync frontend/out "s3://$$bucket" --delete --exclude "*.html" \
			--cache-control "public,max-age=31536000,immutable" --only-show-errors || exit 1; \
		$(AWS) s3 sync frontend/out "s3://$$bucket" --delete --exclude "*" --include "*.html" \
			--cache-control "no-cache" --only-show-errors || exit 1; \
		$(AWS) cloudfront create-invalidation --distribution-id "$$dist" --paths "/*" \
			--query 'Invalidation.Status' --output text
	@$(MAKE) --no-print-directory aws-frontend-url
	@if [ -z "$(AWS_CORS_ORIGINS)" ]; then \
		allowed=$$($(call stack-output,$(FRONTEND_STACK),AllowedOrigins) | tr -d '[:space:]'); \
		fn=$$($(call stack-output,$(APP_STACK),FunctionName) | tr -d '[:space:]'); \
		current=$$($(AWS) lambda get-function-configuration --function-name "$$fn" \
			--query 'Environment.Variables.CORS_ORIGINS' --output text | tr -d '[:space:]'); \
		test "$$current" = "$$allowed" || echo "The API still allows CORS_ORIGINS=$$current — run make aws-deploy-backend to limit it to $$allowed"; \
	fi
	@if [ -n "$(AWS_FRONTEND_DOMAIN)" ] && [ -z "$$($(CERT) zone "$(AWS_FRONTEND_DOMAIN)")" ]; then \
		echo "Point $(AWS_FRONTEND_DOMAIN) at the distribution: CNAME $$($(call stack-output,$(FRONTEND_STACK),DistributionDomain) | tr -d '[:space:]')"; \
	fi

aws-frontend-url: ## Print the deployed site URL
	@$(call stack-output,$(FRONTEND_STACK),SiteUrl)

aws-destroy: ## Delete every stack, including the database and its data
	$(require-aws-credentials)
	@printf 'Delete %s, %s, %s, %s, %s and %s? The Aurora cluster and all its data, every user account and every report go with them (no snapshot). Type yes: ' \
		"$(AI_STACK)" "$(REPORTS_STACK)" "$(FRONTEND_STACK)" "$(APP_STACK)" "$(AUTH_STACK)" "$(ECR_STACK)"; \
		read answer; test "$$answer" = "yes" || { echo "Aborted."; exit 1; }
	@for stack in $(REPORTS_STACK) $(FRONTEND_STACK); do \
		bucket=$$($(call stack-output,$$stack,BucketName) 2>/dev/null | tr -d '[:space:]'); \
		if [ -n "$$bucket" ] && [ "$$bucket" != "None" ]; then \
			echo "Emptying s3://$$bucket"; \
			$(AWS) s3 rm "s3://$$bucket" --recursive --only-show-errors || true; \
		fi; \
	done
	-$(AWS) cloudformation delete-stack --stack-name $(AI_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(AI_STACK)
	@# The report builder uses the backend's security group, so it goes first.
	-$(AWS) cloudformation delete-stack --stack-name $(REPORTS_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(REPORTS_STACK)
	-$(AWS) cloudformation delete-stack --stack-name $(FRONTEND_STACK)
	-$(AWS) cloudformation wait stack-delete-complete --stack-name $(FRONTEND_STACK)
	@echo "Deleting $(APP_STACK) — Lambda releases its VPC network interfaces slowly, allow ~20 minutes."
	$(AWS) cloudformation delete-stack --stack-name $(APP_STACK)
	$(AWS) cloudformation wait stack-delete-complete --stack-name $(APP_STACK)
	$(AWS) cloudformation delete-stack --stack-name $(AUTH_STACK)
	$(AWS) cloudformation wait stack-delete-complete --stack-name $(AUTH_STACK)
	$(AWS) cloudformation delete-stack --stack-name $(ECR_STACK)
	$(AWS) cloudformation wait stack-delete-complete --stack-name $(ECR_STACK)
	@echo "All stacks deleted."
