version ?= "development"
login_version ?= "development"
values ?=
image_repo ?= "mirrors.tencent.com/build/blueking"
chart_repo ?=
namespace ?= "bk-user"
test_release_name ?= "bk-user-test"

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
	rm -Rf /opt/usermgr  &&\
	mkdir -p /opt/usermgr &&\
	cp -Rf ./src/api /opt/usermgr &&\
	rm -Rf /opt/usermgr/api/bkuser_global &&\
	cp -Rf ./src/bkuser_global /opt/usermgr/api/bkuser_global &&\
	cp -Rf ./src/api/support-files /opt/usermgr &&\
	cp -Rf ./VERSION /opt/usermgr &&\
	cp -Rf ./src/api/projects.yaml /opt/usermgr &&\
	pip3 download  -i https://mirrors.cloud.tencent.com/pypi/simple -r ./src/api/requirements.txt -d /opt/usermgr/pkgs &&\
	cd /opt &&\
	tar -zcvf ./usermgr_ce-2.4.2-bkofficial.tar.gz usermgr/