version ?= "develop"
login_version ?= "develop"
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

test:
	cd src/api && export DJANGO_SETTINGS_MODULE="bkuser_core.config.overlays.unittest" && poetry run pytest bkuser_core/tests --disable-pytest-warnings

link:
	rm src/api/bkuser_global || true
	rm src/saas/bkuser_global || true
	rm src/login/bkuser_global || true

	ln -s ${PWD}/src/bkuser_global src/api || true
	ln -s ${PWD}/src/bkuser_global src/saas || true
	ln -s ${PWD}/src/bkuser_global src/login || true

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

	/bin/cp -Rf ./src/api $(USERMGR_API_RELEASE_PATH)
	rm -Rf $(USERMGR_API_RELEASE_PATH)/bkuser_global
	/bin/cp -Rf ./src/bkuser_global $(USERMGR_API_RELEASE_PATH)/api/bkuser_global
	/bin/cp -Rf ./src/build/api/support-files $(USERMGR_API_RELEASE_PATH)
	/bin/cp -Rf ./VERSION $(USERMGR_API_RELEASE_PATH)
	/bin/cp -Rf ./src/api/projects.yaml $(USERMGR_API_RELEASE_PATH)

	virtualenv $(VENV_PATH) -p python3
	$(VENV_PATH)/bin/pip3 download -r ./src/api/requirements.txt -d $(USERMGR_API_RELEASE_PATH)/support-files/pkgs
	
	rm -Rf $(VENV_PATH)
	/bin/cp -Rf $(USERMGR_API_RELEASE_PATH)/api/bkuser_core/config/overlays/prod.py $(USERMGR_API_RELEASE_PATH)/api/bkuser_core/config/overlays/dev.py



release-saas:
	cd ./src/pages && npm config set registry https://mirrors.tencent.com/npm/ &&  npm install && npm run build && mv ./src/pages/dist/ ./src/saas/static
	/bin/cp -Rf ./src/build/saas/bk_user_manage.png ./src/saas/
	/bin/cp -Rf ./src/build/saas/manage.py ./src/saas/
	/bin/cp -Rf ./src/build/saas/.env ./src/saas/bkuser_shell/config/common
	/bin/cp -Rf ./src/build/saas/support-files ./src/saas/

	rm -Rf $(USERMGR_SAAS_RELEASE_PATH)
	mkdir -p $(USERMGR_SAAS_RELEASE_PATH)
	/bin/cp -Rf ./src/saas $(USERMGR_SAAS_RELEASE_PATH)/src
	mkdir -p $(USERMGR_SAAS_RELEASE_PATH)/pkgs

	virtualenv $(VENV_PATH) -p python3
	$(VENV_PATH)/bin/pip3 download -r $(USERMGR_SAAS_RELEASE_PATH)/src/requirements.txt -d $(USERMGR_SAAS_RELEASE_PATH)/pkgs 
	rm -Rf $(VENV_PATH)
