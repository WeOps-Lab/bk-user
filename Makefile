version ?= "development"
login_version ?= "development"
values ?=
image_repo ?= "mirrors.tencent.com/build/blueking"
chart_repo ?=
namespace ?= "bk-user"
test_release_name ?= "bk-user-test"

USERMGR_API_RELEASE_PATH=/opt/release/usermgr
VENV_PATH=/tmp/venv
USERMGR_SAAS_RELEASE_PATH=/opt/release/bk_user_manage
generate-release-md:
	rm docs/changelogs/*.md || true
	cd src/saas/ && mkdir -p changelogs/ && poetry run python manage.py generate_release_md
	mv src/saas/changelogs docs/
	mv src/saas/release.md docs/

link:
	rm src/api/bkuser_global || true
	rm src/saas/bkuser_global || true
	rm src/login/bkuser_global || true
	rm src/saas/bkuser_sdk || true

	ln -s ${PWD}/src/bkuser_global src/api || true
	ln -s ${PWD}/src/bkuser_global src/saas || true
	ln -s ${PWD}/src/bkuser_global src/login || true
	ln -s ${PWD}/src/sdk/bkuser_sdk src/saas || true

generate-sdk:
	cd src/ && swagger-codegen generate -i http://localhost:8004/redoc/\?format\=openapi -l python -o sdk/ -c config.json

build-api:
	docker build -f src/api/Dockerfile . -t ${image_repo}/bk-user-api:${version}

build-saas:
	docker build -f src/saas/Dockerfile . -t ${image_repo}/bk-user-saas:${version}

build-login:
	docker build -f src/login/Dockerfile . -t ${image_repo}/bk-login:${login_version}

build-all: build-api build-saas build-login

push:
	docker push ${image_repo}/bk-user-api:${version}
	docker push ${image_repo}/bk-user-saas:${version}
	docker push ${image_repo}/bk-login:${login_version}

helm-refresh:
	cd deploy/helm && helm dependency update bk-user --skip-refresh

helm-debug: helm-refresh
	cd deploy/helm && helm install ${test_release_name} bk-user --debug --dry-run -f local_values.yaml

helm-install: helm-refresh
	cd deploy/helm && helm upgrade --install ${test_release_name} bk-user -n ${namespace} -f local_values.yaml

helm-uninstall:
	helm uninstall ${test_release_name} -n ${namespace} || true

helm-package: helm-refresh
	cd deploy/helm && helm package bk-user -d dist/

helm-publish: deploy/helm/dist/*.tgz
	for f in $^; do \
		curl -kL -X POST -F chart=@$${f} -u ${credentials} ${chart_repo}; \
	done

release-api:
	rm -Rf $(USERMGR_API_RELEASE_PATH)
	mkdir -p $(USERMGR_API_RELEASE_PATH)

	cp -Rf ./src/api $(USERMGR_API_RELEASE_PATH)
	rm -Rf $(USERMGR_API_RELEASE_PATH)/bkuser_global
	cp -Rf ./src/bkuser_global $(USERMGR_API_RELEASE_PATH)/api/bkuser_global
	cp -Rf ./src/api/support-files $(USERMGR_API_RELEASE_PATH)
	cp -Rf ./VERSION $(USERMGR_API_RELEASE_PATH)
	cp -Rf ./src/api/projects.yaml $(USERMGR_API_RELEASE_PATH)

	virtualenv $(VENV_PATH) -p python3
	$(VENV_PATH)/bin/pip3 download -r ./src/api/requirements.txt -d $(USERMGR_API_RELEASE_PATH)/support-files/pkgs
	
	rm -Rf $(VENV_PATH)
	cp -Rf $(USERMGR_API_RELEASE_PATH)/api/bkuser_core/config/overlays/prod.py $(USERMGR_API_RELEASE_PATH)/api/bkuser_core/config/overlays/dev.py



release-saas:
	cd ./src/pages &&  npm install && npm run build
	rm -Rf $(USERMGR_SAAS_RELEASE_PATH)
	mkdir -p $(USERMGR_SAAS_RELEASE_PATH)
	cp -Rf ./src/saas $(USERMGR_SAAS_RELEASE_PATH)/src
	cp -Rf ./src/pages/dist $(USERMGR_SAAS_RELEASE_PATH)/src/static
	rm -Rf $(USERMGR_SAAS_RELEASE_PATH)/src/bkuser_global
	cp -Rf ./src/bkuser_global $(USERMGR_SAAS_RELEASE_PATH)/src/
	rm -Rf $(USERMGR_SAAS_RELEASE_PATH)/src/bkuser_sdk
	cp -Rf ./src/sdk/bkuser_sdk/ $(USERMGR_SAAS_RELEASE_PATH)/src/
	cp -Rf ./VERSION $(USERMGR_SAAS_RELEASE_PATH)
	cp -Rf ./src/saas/app.yml $(USERMGR_SAAS_RELEASE_PATH)
	cp -Rf ./src/saas/bk_user_manage.png $(USERMGR_SAAS_RELEASE_PATH)
	mkdir -p $(USERMGR_SAAS_RELEASE_PATH)/pkgs

	virtualenv $(VENV_PATH) -p python3
	$(VENV_PATH)/bin/pip3 download -r $(USERMGR_SAAS_RELEASE_PATH)/src/requirements.txt -d $(USERMGR_SAAS_RELEASE_PATH)/pkgs 
	rm -Rf $(VENV_PATH)
